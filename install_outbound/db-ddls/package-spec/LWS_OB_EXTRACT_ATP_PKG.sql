--------------------------------------------------------------------------------
-- Package : LWS_OB_EXTRACT_ATP_PKG
-- Purpose : C2FO outbound extract, ATP edition. Reads the LWS_CUSTOM_C2FO_SA BICC
--           mirror (via Fusion-named bridging views), populates the LWS_OB_*
--           output staging tables, then writes the CSV files (invoice /
--           organization / user / po / control) directly to an OCI bucket.
--
-- Replaces: XXC2FO_OB_EXTRACT_PKG (EBS, concurrent-program driven, UTL_FILE +
--           FTP). File delivery is now DBMS_CLOUD.PUT_OBJECT to OCI object
--           storage (no UTL_FILE, no FTP); no fnd_* calls.
--
-- Naming  : all custom objects carry an LWS_ prefix. Mirror tables are named
--           LWS_<fusion_object>; the package reads them through views NAMED after
--           the Fusion objects (see c2fo_bridging_views.sql), so the cursors below
--           reference ap_invoices_all / poz_suppliers_v / etc. unchanged.
--
-- How OIC uses it:
--   * call RUN_OUTBOUND(p_file_prefix, p_bucket_name, p_folder_path, p_max_mb, ...)
--     -> runs the extracts AND writes the CSV files to the bucket, returns
--        run_id + status. OIC just triggers; no row-by-row selection in OIC.
--   * if p_bucket_name is NULL, RUN_OUTBOUND only populates the LWS_OB_* tables
--     (extract-only mode, e.g. for testing); call WRITE_FILES_TO_BUCKET later.
--
-- File split: any file exceeding p_max_mb (default 200, uncompressed) is split
--   into numbered parts (<prefix>_<entity>_<yyyymmdd>_001.csv, _002.csv, ...).
--   Every part gets its own control-file row; control row_count excludes the
--   header line (per the C2FO spec).
--
-- Lifecycle: RUN_OUTBOUND truncates all five output tables first, so they always
--            show exactly what was produced by the latest run.
--
-- Notes on the port from EBS:
--   * approval filter uses AP_INVOICES_ALL.APPROVAL_STATUS IN ('APPROVED',
--     'NOT REQUIRED') instead of AP_INVOICES_PKG.Get_Approval_Status (the PL/SQL
--     package does not exist in ATP; APPROVAL_STATUS reproduces its output).
--   * the old xxc2fo_int_ebs_ap_pay_pkg.* helper calls are inlined using mirror
--     columns; see the per-column comments. Where the EBS helper logic cannot be
--     reproduced from the mirrored columns alone it is flagged TODO_VERIFY.
--   * INVOICE grain = one row per payment installment (AP_PAYMENT_SCHEDULES_ALL).
--------------------------------------------------------------------------------

-- Schema-level collection type for the pipelined file_lines() reader. A SQL type
-- (not a package PL/SQL type) is required as a pipelined function's return type.
-- Element width 32767 so wide CSV rows (e.g. the ~57-col invoice) are not truncated.
CREATE OR REPLACE TYPE LWS_CUSTOM_C2FO_SA.LWS_OB_LINE_TAB AS TABLE OF VARCHAR2(32767);
/

CREATE OR REPLACE PACKAGE LWS_CUSTOM_C2FO_SA.LWS_OB_EXTRACT_ATP_PKG AS

    -- Date formatter. Declared in the spec (not just the body) so it can be
    -- referenced from the SQL inside the extract cursors; a package-private
    -- PL/SQL function cannot be called from SQL (PLS-00231).
    FUNCTION dstr  (p_d   IN DATE)     RETURN VARCHAR2;

    -- RFC 4180 CSV field: wraps in double-quotes and doubles internal quotes when
    -- the value contains a comma, quote, CR or LF; otherwise returns it unchanged.
    FUNCTION csv_field (p_val IN VARCHAR2) RETURN VARCHAR2;

    -- ASYNC ENTRY POINT for OIC. Allocates a run_id, logs the run as SUBMITTED,
    -- spawns a ONE-TIME DBMS_SCHEDULER job that runs run_outbound in the background,
    -- and returns IMMEDIATELY. OIC does not hold the ATP connection for the extract,
    -- so a multi-million-row run cannot hit the ATP adapter execution limit. The
    -- run outcome is recorded in LWS_OB_RUN_LOG, which OIC polls on the run_id.
    PROCEDURE submit_outbound (
        p_file_prefix         IN  VARCHAR2,
        p_extract_po          IN  VARCHAR2 DEFAULT 'N',
        p_invoice_date_from   IN  DATE     DEFAULT NULL,
        p_invoice_date_to     IN  DATE     DEFAULT NULL,
        p_pay_due_date_from   IN  DATE     DEFAULT NULL,
        p_pay_due_date_to     IN  DATE     DEFAULT NULL,
        p_po_date_from        IN  DATE     DEFAULT NULL,
        p_po_date_to          IN  DATE     DEFAULT NULL,
        -- Comma-separated BU names in C2FO scope (matches HR_ALL_ORGANIZATION_UNITS.NAME).
        -- NULL/empty => no BU restriction (all BUs in scope).
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        -- Comma-separated pay-group codes to EXCLUDE (AP_INVOICES_ALL.PAY_GROUP_LOOKUP_CODE).
        -- NULL/empty => exclude none.
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        -- Comma-separated payment term NAMES to EXCLUDE (AP_TERMS_TL.NAME via the
        -- invoice's terms_id; same value emitted as erp_payment_term). NULL/empty => exclude none.
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL,
        -- Comma-separated supplier vendor_type_lookup_code values to EXCLUDE
        -- (POZ_SUPPLIERS_V.VENDOR_TYPE_LOOKUP_CODE). NULL/empty => exclude none.
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL,
        -- Max years of PAST-due invoices to send (future-due always sent).
        -- NULL / <= 0 => no lower bound on due_date.
        p_max_past_years      IN  NUMBER   DEFAULT NULL,
        -- Include-only lists (comma-separated; NULL => no restriction).
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,   -- supplier segment1
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,   -- invoice_num
        p_bucket_name         IN  VARCHAR2 DEFAULT NULL,
        p_folder_path         IN  VARCHAR2 DEFAULT NULL,
        -- Local-file mode: when p_bucket_name is NULL and p_directory is set, the
        -- CSVs are written to this ATP directory object (default DATA_PUMP_DIR)
        -- instead of a bucket, and are retrievable via get_local_file.
        p_directory           IN  VARCHAR2 DEFAULT NULL,
        p_max_mb              IN  NUMBER   DEFAULT 200,
        -- FEEDBACK window: how many days AFTER payment an awarded invoice keeps
        -- appearing in the feedback file. Unpaid awards always appear; a paid award
        -- appears only while (SYSDATE - payment date) <= this many days. NULL => no
        -- upper bound (every processed award is reported, paid or not).
        p_feedback_report_days IN NUMBER   DEFAULT NULL,
        o_run_id              OUT NUMBER,
        o_status              OUT VARCHAR2,                    -- SUBMITTED / ERROR (submit only)
        o_message             OUT VARCHAR2
    );

    -- Background worker (invoked by submit_outbound's scheduler job; also callable
    -- directly for a synchronous run at low volume). Truncates outputs, runs the
    -- enabled extracts, builds the control rows, logs the run, and self-notifies on
    -- completion. Returns run_id + status/message to any synchronous caller.
    PROCEDURE run_outbound (
        p_file_prefix         IN  VARCHAR2,
        p_extract_po          IN  VARCHAR2 DEFAULT 'N',        -- 'Y' to include the PO file
        p_invoice_date_from   IN  DATE     DEFAULT NULL,
        p_invoice_date_to     IN  DATE     DEFAULT NULL,
        p_pay_due_date_from   IN  DATE     DEFAULT NULL,
        p_pay_due_date_to     IN  DATE     DEFAULT NULL,
        p_po_date_from        IN  DATE     DEFAULT NULL,
        p_po_date_to          IN  DATE     DEFAULT NULL,
        -- BU scope + pay-group exclusion (comma-separated; NULL => no restriction).
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        -- Payment term NAMES to EXCLUDE (comma-separated; NULL => exclude none).
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL,
        -- Supplier vendor_type_lookup_code values to EXCLUDE (comma-separated; NULL => exclude none).
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL,
        -- Max years of PAST-due invoices to send (future-due always sent).
        p_max_past_years      IN  NUMBER   DEFAULT NULL,
        -- Include-only lists (comma-separated; NULL => no restriction).
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,       -- supplier segment1
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,       -- invoice_num
        p_bucket_name         IN  VARCHAR2 DEFAULT NULL,       -- NULL = no bucket (extract only, or local mode)
        p_folder_path         IN  VARCHAR2 DEFAULT NULL,
        -- Local-file mode: bucket NULL + directory set => write CSVs to this ATP
        -- directory object (default DATA_PUMP_DIR) rather than a bucket.
        p_directory           IN  VARCHAR2 DEFAULT NULL,
        p_max_mb              IN  NUMBER   DEFAULT 200,        -- split threshold, uncompressed MB
        -- Days after payment an awarded invoice stays in the feedback file (see
        -- submit_outbound). NULL => no upper bound.
        p_feedback_report_days IN NUMBER   DEFAULT NULL,
        -- When submit_outbound spawned this run it already created the RUN_ID row;
        -- pass it in so the worker updates that row rather than allocating a new one.
        -- NULL (a direct synchronous call) => allocate a fresh RUN_ID.
        p_run_id              IN  NUMBER   DEFAULT NULL,
        o_run_id              OUT NUMBER,
        o_status              OUT VARCHAR2,                    -- SUCCESS / ERROR / SKIPPED (another run active)
        o_message             OUT VARCHAR2
    );

    -- Individual extracts (called by run_outbound; exposed for targeted reruns).
    PROCEDURE extract_invoices (
        p_invoice_date_from   IN  DATE,
        p_invoice_date_to     IN  DATE,
        p_pay_due_date_from   IN  DATE,
        p_pay_due_date_to     IN  DATE,
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        -- Payment term NAMES to EXCLUDE (comma-separated; NULL => exclude none).
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL,
        -- Supplier vendor_type_lookup_code values to EXCLUDE (comma-separated; NULL => exclude none).
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL,
        -- Max years of PAST-due invoices to include (future-due always sent).
        -- NULL / <= 0 => no lower bound on due_date.
        p_max_past_years      IN  NUMBER   DEFAULT NULL,
        -- Include-only lists (comma-separated; NULL => no restriction).
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,  -- supplier segment1
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,  -- invoice_num
        o_count               OUT NUMBER
    );

    PROCEDURE extract_organizations ( o_count OUT NUMBER );

    PROCEDURE extract_users ( o_count OUT NUMBER );

    -- Feedback extract: payment status of AWARDED invoices in the days after award.
    -- Driven off the inbound award landing table (LWS_C2FO_AWARD_DATA, RECORD_STATUS='Y'),
    -- NOT a CM-pattern scan - the award rows carry resolved keys + the CM id directly.
    -- Reports every unpaid award, plus paid awards within p_report_days of payment
    -- (AP_CHECKS_ALL.check_date). NULL p_report_days => no upper bound.
    PROCEDURE extract_feedback (
        p_report_days IN  NUMBER  DEFAULT NULL,
        o_count       OUT NUMBER
    );

    -- PO extract disabled: the mirror lacks PO_LINES_ALL and several PO_HEADERS_ALL
    -- columns needed to reproduce the EBS logic. Re-enable once the mirror is extended.
    /*
    PROCEDURE extract_pos (
        p_po_date_from   IN  DATE,
        p_po_date_to     IN  DATE,
        o_count          OUT NUMBER
    );
    */

    -- Writes the staged LWS_OB_* rows out as CSV files to an OCI bucket, splitting
    -- any file that would exceed p_max_mb into numbered parts (_001, _002, ...).
    -- Each written part (incl. its header row) gets its own LWS_OB_CONTROL row.
    -- Called at the end of run_outbound; exposed for targeted re-delivery.
    -- Destination is a bucket when p_bucket_name is set; otherwise, when p_directory
    -- is set, the files go to that ATP directory object (local-file mode). Exactly
    -- one of the two should be supplied.
    PROCEDURE write_files_to_bucket (
        p_file_prefix   IN  VARCHAR2,
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_directory     IN  VARCHAR2 DEFAULT NULL,  -- ATP dir object for local-file mode
        p_extract_po    IN  VARCHAR2 DEFAULT 'N',
        p_max_mb        IN  NUMBER   DEFAULT 200,   -- split threshold, uncompressed CSV MB
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- Returns a file previously written in local-file mode as a BLOB, so any client
    -- can pull it down with a plain SELECT (no SQLcl / DBMS_CLOUD needed). Reads from
    -- p_directory (default DATA_PUMP_DIR). Raises if the file does not exist.
    FUNCTION get_local_file (
        p_file_name   IN  VARCHAR2,
        p_directory   IN  VARCHAR2 DEFAULT 'DATA_PUMP_DIR'
    ) RETURN BLOB;

    -- Streams a local-file-mode CSV back one ROW PER LINE (no size cap), so a file
    -- can be viewed as result rows: SELECT * FROM TABLE(file_lines('...csv')).
    -- Reads from p_directory (default DATA_PUMP_DIR) via UTL_FILE line-by-line.
    FUNCTION file_lines (
        p_file_name   IN  VARCHAR2,
        p_directory   IN  VARCHAR2 DEFAULT 'DATA_PUMP_DIR'
    ) RETURN LWS_OB_LINE_TAB PIPELINED;

END LWS_OB_EXTRACT_ATP_PKG;
/

