--------------------------------------------------------------------------------
-- Package : LWS_AP_C2FO_AWARD_PKG
-- Purpose : C2FO inbound AWARD processing, ATP edition. Fusion port of the EBS
--           XXC2FO_AWARD_PKG.process_award, restricted to the single in-scope
--           activity type EP_CREATE_CM_UPD_DD_DD_AND_UPDATE_DD_DD_PG_TYPE
--           ("create credit memo, update due dates and pay group").
--
--           For each awarded invoice this performs BOTH halves of the EBS type-2
--           flow: (a) create a credit memo (negative CREDIT invoice booking the
--           C2FO discount) and (b) accelerate the ORIGINAL invoice by moving its
--           payment-schedule due date (and matching discount date) to the C2FO
--           pay date, and set the invoice pay group to C2FO.
--
-- Replaces: XXC2FO_AWARD_PKG (EBS - direct DML on AP tables, fnd_request,
--           fnd_profile, UTL_FILE, Java SFTP). On Fusion (SaaS) there is no direct
--           table access, so:
--             * validation reads the LWS_CUSTOM_C2FO_SA mirror via the Fusion-
--               named bridging views (shared with outbound);
--             * the CM is created by FBDI "Import Payables Invoices" (OIC-owned);
--             * the original-invoice due-date change is issued as a Fusion REST
--               call BY OIC (batch upsert of invoiceInstallments, per-call PATCH
--               fallback), NOT from the database.
--
-- ARCHITECTURAL CONSTRAINT (client ruling): the database MUST NOT call ERP REST
--           services. ERP REST sits behind the client's API gateway and OIC is the
--           only sanctioned caller (the LWS_CUSTOM_C2FO_USER schema was refused an
--           ACL to the Fusion host for exactly this reason). So this package holds
--           NO UTL_HTTP / DBMS_CLOUD.SEND_REQUEST to Fusion. It PREPARES the work
--           (validation + CM set + due-date set), OIC EXECUTES the REST, and OIC
--           REPORTS each outcome back via the annotate_* procedures. This mirrors
--           the FBDI CM path (build_fbdi_cm_set -> OIC import -> annotate_cm_result).
--
-- Record of truth: awards are landed 1:1 (all 74 file columns) into
--           LWS_C2FO_AWARD_DATA (c2fo_award_data_ddl.sql) and processed IN PLACE -
--           the same row carries the file data, the resolved keys, the state machine
--           and the CM/DD/reversal outcome, so it also serves reporting and reversal.
--           The narrow LWS_AP_C2FO_AWARD_STAGING is RETIRED. One award = the file's
--           composite INVOICE_ID (ORG_ID|INVOICE_ID|PAYMENT_NUM|INVOICE_NUM); the
--           batch = INSTANCE_ID (the OIC loader run id).
--
-- Execution : OIC owns scheduling, all ERP REST (FBDI CM import + the due-date
--           upsert/PATCH), and the poll loops. ATP owns validation (mirror reads)
--           and building the two work sets OIC consumes. RUN_INBOUND still hands
--           validation to a ONE-TIME DBMS_SCHEDULER job and returns immediately so
--           OIC never blocks at 500K rows; there is no DB-side REST rig.
--
-- Naming  : all custom objects carry the LWS_ prefix. Mirror tables are read
--           through views named after the Fusion objects (see
--           c2fo_bridging_views.sql), so the validation SQL references
--           ap_invoices_all / ap_payment_schedules_all / poz_suppliers_v etc.
--
-- State machine (LWS_C2FO_AWARD_DATA, processed in place):
--   record_status: 'N' not processed | 'Y' success | 'E' error ('E' is TERMINAL -
--                  Business Rule 10, no reset-to-'N', no reprocessing).
--   stage        : EP_STAGED_FOR_INTERFACE -> SUCCESSFULLY_VALIDATED ->
--                  EP_INTERFACED -> EP_NEW_CREDIT_MEMO_INVOICE_CREATED ->
--                  EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED -> SUCCESSFULLY_PROCESSED.
--   error_code / error_message: the failure stage code + free-text detail.
--   two-step outcome (BR#9): cm_status + dd_status tracked separately so a
--                  partially applied award is always detectable / compensable.
--
-- How OIC uses it (call order); p_instance_id is the OIC loader run id (the batch):
--   1. RUN_INBOUND(p_instance_id, ...)   -> submits the async validation job for
--        the batch's 'N' rows; returns run id immediately. OIC polls the run log.
--   2. BUILD_FBDI_CM_SET(p_instance_id, ...) -> returns the validated rows' CM lines
--        as a REF CURSOR for OIC to write the FBDI file (GROUP_ID = instance id).
--   3. (OIC runs Load Interface File for Import -> APXIIMPT -> Validate job.)
--   4. ANNOTATE_CM_RESULT(...)           -> OIC writes back each CM's verdict
--        (created id, Validated/failed) onto the award row (keyed by invoice_id).
--   5. (removed) BUILD_DUEDATE_SET -> the due-date work is now the view
--        LWS_C2FO_DD_UPSERT_V, read directly by OIC "Run a SQL Statement"
--        (instance_id + chunk_id + dd_batch_no). OIC batch-upserts to
--        invoiceInstallments. The DB issues NO REST here.
--   6. ANNOTATE_DUEDATE_RESULT(...)      -> OIC writes back each installment's
--        verdict (OK / AP-810830 known-skip / failed). On a terminal failure OIC
--        performs the compensating cancelInvoice/debit-memo REST call itself and
--        reports the compensation outcome here; the DB only stamps the state.
--   7. WRITE_ERROR_FILE(p_instance_id, ...) -> renders the batch 'E' rows to a CSV
--        in OCI for return to C2FO.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_AWARD_PKG AS

    -- Process-stage constants (ported from the EBS state machine).
    C_STAGE_STAGED       CONSTANT VARCHAR2(80) := 'EP_STAGED_FOR_INTERFACE';
    C_STAGE_VALIDATED    CONSTANT VARCHAR2(80) := 'SUCCESSFULLY_VALIDATED';
    C_STAGE_INTERFACED   CONSTANT VARCHAR2(80) := 'EP_INTERFACED';
    C_STAGE_CM_CREATED   CONSTANT VARCHAR2(80) := 'EP_NEW_CREDIT_MEMO_INVOICE_CREATED';
    C_STAGE_CM_VALIDATED CONSTANT VARCHAR2(80) := 'EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED';
    C_STAGE_DD_SENT      CONSTANT VARCHAR2(80) := 'EP_DUE_DATE_UPSERT_SENT';
    C_STAGE_PROCESSED    CONSTANT VARCHAR2(80) := 'SUCCESSFULLY_PROCESSED';
    -- Terminal for a zero-income award: its due date was updated but no CM was ever
    -- built. Distinct from SUCCESSFULLY_PROCESSED so reporting can tell DD-only awards
    -- apart from full CM+DD awards.
    C_STAGE_PROC_NO_CM   CONSTANT VARCHAR2(80) := 'PROCESSED_NO_CM';
    -- error stages
    C_ERR_DUPLICATE      CONSTANT VARCHAR2(80) := 'DUPLICATE';
    C_ERR_VALIDATION     CONSTANT VARCHAR2(80) := 'VALIDATION_ERROR';
    C_ERR_NET_DEBIT      CONSTANT VARCHAR2(80) := 'NET_DEBIT_ERROR';
    C_ERR_CM_EXISTS      CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_CM_EXISTS';
    C_ERR_IMPORT         CONSTANT VARCHAR2(80) := 'EP_INTERFACE_IMPORT_ERROR';
    C_ERR_CM_REVAL       CONSTANT VARCHAR2(80) := 'EP_NEW_CREDIT_MEMO_INVOICE_NEEDS_REVALIDATION_ERROR';
    C_ERR_CM_DD          CONSTANT VARCHAR2(80) := 'EP_NEW_CREDIT_MEMO_SCHEDULE_DUE_DATES_UPDATE_ERROR';
    C_ERR_ORIG_DD        CONSTANT VARCHAR2(80) := 'EP_ORIGINAL_INVOICE_SCHEDULE_DUE_DATES_UPDATE_ERROR';
    C_ERR_ORIG_PG        CONSTANT VARCHAR2(80) := 'EP_ORIGINAL_INVOICE_PAY_GROUP_UPDATE_ERROR';
    C_ERR_COMPENSATION   CONSTANT VARCHAR2(80) := 'COMPENSATION_FAILED';
    -- C_ERR_ON_HOLD kept for backward compatibility; the three hold conditions it
    -- used to cover now each have their own code below (INSTALMENT / SITE / DISABLED).
    C_ERR_ON_HOLD        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_ON_HOLD';

    -- Specific validation error codes. Each distinct reject carries its own code so
    -- the C2FO error file can be filtered by reason instead of a single generic
    -- VALIDATION_ERROR. error_message carries a short plain-English reason (+ the
    -- offending value in brackets where useful).
    C_ERR_VOUCHER_BAD      CONSTANT VARCHAR2(80) := 'VOUCHER_NOT_NUMERIC';
    C_ERR_INV_NOT_FOUND    CONSTANT VARCHAR2(80) := 'INVOICE_NOT_FOUND';
    C_ERR_SITE_MISMATCH    CONSTANT VARCHAR2(80) := 'VENDOR_SITE_MISMATCH';
    C_ERR_NOT_APPROVED     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_NOT_APPROVED';
    C_ERR_WF_NOT_APPROVED  CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_WF_NOT_APPROVED';
    C_ERR_CANCELLED        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_CANCELLED';
    C_ERR_BAD_TYPE         CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_INV_TYPE';
    C_ERR_FUTURE_INV_DATE  CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_FUTURE_INV_DATE';
    C_ERR_FUTURE_TERMS     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_FUTURE_TERMS_DATE';
    C_ERR_ALREADY_C2FO     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_ALREADY_C2FO';
    C_ERR_PAID             CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_PAID';
    C_ERR_INST_NOT_FOUND   CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_INST_NOT_FOUND';
    C_ERR_ZERO_AMOUNT      CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_ZERO_AMOUNT';
    C_ERR_INST_HOLD        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_INSTALMENT_HOLD';
    C_ERR_SITE_HOLD        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_SITE_HOLD';
    C_ERR_SUPP_DISABLED    CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_SUPPLIER_DISABLED';
    C_ERR_INVOICE_HOLD     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_INVOICE_HOLD';
    C_ERR_DD_MISMATCH      CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_DUE_DATE';
    C_ERR_CM_IMBALANCE     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_CM_IMBALANCE';
    -- Supplier-level outbound-eligibility re-checks (a supplier that changed status
    -- after its invoices were offered makes ALL its awards ineligible).
    C_ERR_FACTORING        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_FACTORING';
    C_ERR_ASSIGNED_FACTOR  CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_ASSIGNED_FACTOR';
    C_ERR_VENDOR_TYPE      CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_VENDOR_TYPE';
    C_ERR_PAYMENT_TERM     CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_PAYMENT_TERM';
    C_ERR_PAY_GROUP        CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_PAY_GROUP';
    -- Pay group CHANGED since the invoice was offered to C2FO (award erp_pay_group,
    -- the invoice pay group at offer time, no longer matches the live invoice pay
    -- group OR an active supplier-site default pay group). Distinct from the excluded
    -- pay group reject (C_ERR_PAY_GROUP): ANY change rejects, even to a non-excluded
    -- pay group, and applies regardless of the pay-group-update flag.
    C_ERR_PG_CHANGED       CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_PAY_GROUP_CHANGED';
    -- Payment term CHANGED since the invoice was offered to C2FO. Twin of
    -- C_ERR_PG_CHANGED: the award erp_payment_term (the term at offer time) no
    -- longer matches the live invoice payment term OR an active supplier-site
    -- default payment term. ANY change rejects, regardless of any exclusion list.
    C_ERR_PT_CHANGED       CONSTANT VARCHAR2(80) := 'EP_VALIDATION_ERROR_PAYMENT_TERM_CHANGED';

    -- 0. Bulk-load one award CSV straight from the OCI bucket into LWS_C2FO_AWARD_DATA.
    --    Called by the OIC file-load integration AFTER it has read the tiny control
    --    file (file_name + row_count). The DB reads the big award file itself
    --    (DBMS_CLOUD external table over the object, then set-based INSERT ... SELECT),
    --    so OIC never streams/parses 300-500K rows. Stamps INSTANCE_ID (=the OIC
    --    loader run id / batch key), FILE_NAME, RECORD_STATUS='N', STAGE staged; the
    --    resolved keys and CM/DD outcome stay empty (validation fills them). Returns
    --    o_rows_loaded so OIC can assert control.row_count = o_rows_loaded AND
    --    control.file_name = p_object_name before accepting the batch.
    --    After the load commits, the whole award drop is MOVED to the archive bucket
    --    (INBOUND.ARCHIVE_BUCKET): the award CSV, its sibling PDF (same base name,
    --    .pdf) and the control file (base with '_control' before the date/extension).
    --    Each move is independent and best-effort - a failure of any one is a non-fatal
    --    warning appended to o_message; the load result stands. OIC still reads the
    --    control file over REST for the count/name match before calling this proc.
    --      p_bucket_name : OCI bucket holding the award file (OIC integration property)
    --      p_folder_path : optional folder/prefix inside the bucket (NULL = bucket root)
    --      p_object_name : the award CSV object name (must equal the control file_name)
    --      p_instance_id : the OIC loader run id; becomes INSTANCE_ID on every row
    PROCEDURE load_award_file (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_object_name   IN  VARCHAR2,
        p_instance_id   IN  VARCHAR2,
        o_rows_loaded   OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 1. Master OIC entry (ASYNC). Creates the run-log row, persists the OIC-
    --    supplied runtime params (activity type; source code / pay group for later
    --    steps), submits a ONE-TIME DBMS_SCHEDULER job that validates the batch's
    --    'N' rows against the mirror, and RETURNS IMMEDIATELY with the run id. OIC
    --    polls LWS_AP_C2FO_AWARD_RUN_LOG by run id for status + counts. At 500K
    --    rows OIC never blocks on validation. p_pay_group is optional and only
    --    stored here for the later due-date step (NULL => leave pay group unchanged).
    PROCEDURE run_inbound (
        p_instance_id       IN  VARCHAR2,               -- OIC loader run id = batch key on LWS_C2FO_AWARD_DATA
        p_activity_type     IN  VARCHAR2,               -- in-scope award activity (BR#2 gate)
        p_source_code       IN  VARCHAR2,               -- invoice source for the FBDI CM set
        p_pay_group         IN  VARCHAR2 DEFAULT NULL,  -- accelerated-invoice pay group; used only when the update is on
        p_update_pay_group  IN  VARCHAR2 DEFAULT 'N',   -- BR#16 gate: 'Y' apply pay group, 'N' leave it untouched
        p_cm_payment_method IN  VARCHAR2 DEFAULT NULL,  -- BR#16: CM header payment method (OIC CM_PAYMENT_METHOD lookup)
        o_run_id            OUT NUMBER,
        o_job_name          OUT VARCHAR2,               -- the submitted validation job
        o_status            OUT VARCHAR2,               -- SUCCESS (submitted) / ERROR
        o_message           OUT VARCHAR2
    );

    -- Validation body run by the one-time job (separate session). Reads the run's
    -- persisted activity type from the run log and stamps the state machine. Public
    -- so the job's PL/SQL block can call it; not normally called by OIC directly.
    PROCEDURE run_validation (
        p_instance_id   IN  VARCHAR2,
        p_run_id        IN  NUMBER
    );

    -- Validation core. p_activity_type is the in-scope gate (BR#2). Exposed for
    -- targeted synchronous reruns of a batch that is still all 'N'.
    PROCEDURE validate_batch (
        p_instance_id      IN  VARCHAR2,
        p_activity_type    IN  VARCHAR2,
        p_update_pay_group IN  VARCHAR2 DEFAULT 'N',  -- BR#16: gate the "not already C2FO pay group" exclusion
        o_validated        OUT NUMBER,
        o_errored          OUT NUMBER
    );

    -- 1b. CHUNKING pre-step for the CM FBDI import. Stamps CHUNK_ID (1..N) on this
    --    instance's validated-not-yet-interfaced rows in groups of p_chunk_size, so
    --    OIC can loop the FBDI build/import one bounded chunk at a time instead of
    --    submitting one 500K-row import. p_chunk_size NULL => the INBOUND.CM_CHUNK_SIZE
    --    config knob (empirically tuned), else a code default. o_chunk_count = MAX
    --    chunk assigned = the OIC loop bound (0 when there is nothing to import).
    --    Idempotent: re-running for the same instance re-chunks the same VALIDATED
    --    rows (rows already advanced to INTERFACED by build_fbdi_cm_set are skipped),
    --    so a resumed run only re-chunks what has not been built yet.
    PROCEDURE chunk_cm_awards (
        p_instance_id   IN  VARCHAR2,
        p_chunk_size    IN  NUMBER DEFAULT NULL,
        o_chunk_count   OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 1c. Per-chunk identity. A chunk is, by construction (chunk_cm_awards), exactly
    --     one (ORG_ID, SOURCE, VENDOR_ID) triple, so every row in a chunk shares one
    --     supplier number. OIC calls this inside its While 1..N loop to learn the
    --     chunk's SUPPLIER NUMBER (+ BU + source) so it can query Fusion for THIS
    --     chunk's created credit memos by supplier number - replacing the coarse
    --     creationDate>chunkStartTime proxy, which is not granular enough to isolate
    --     a chunk.
    --     o_supplier_number is the award's ERP_SUPPLIER_NUMBER, returned verbatim:
    --     it is exactly the supplier number the OUTBOUND extract emitted and Fusion
    --     stores no leading zeros, so it matches a Fusion SupplierNumber query
    --     directly (no padding/stripping). o_org_id (BU) and o_source_code (import
    --     source) are returned too for optional tightening (a chunk is one BU + one
    --     source as well). o_status='EMPTY' when the chunk id resolves to no rows.
    PROCEDURE get_chunk_identity (
        p_instance_id     IN  VARCHAR2,
        p_chunk_id        IN  NUMBER,
        o_supplier_number OUT VARCHAR2,
        o_vendor_id       OUT NUMBER,
        o_org_id          OUT NUMBER,
        o_source_code     OUT VARCHAR2,
        o_status          OUT VARCHAR2,             -- SUCCESS / EMPTY / ERROR
        o_message         OUT VARCHAR2
    );

    -- 2. Emit the validated rows' CM header+line as a REF CURSOR for OIC's FBDI
    --    file build. GROUP_ID = the batch id (BR#1). Sets the deterministic
    --    cm_invoice_num on each row BEFORE the line is emitted (BR#5) and moves the
    --    row to EP_INTERFACED. p_source_code stamps the CM invoice source; if NULL,
    --    the value persisted on the run log at run_inbound time is used. Each CM
    --    header also carries the payment method OIC persisted at run_inbound
    --    (CM_PAYMENT_METHOD lookup, BR#16) and ALL populated original-invoice header
    --    DFF segments (ATTRIBUTE_CATEGORY + ATTRIBUTE1..15) copied verbatim from the
    --    mirror invoice (BR#17).
    --    p_chunk_id: when supplied, emit + flip ONLY that chunk's rows (set by
    --    chunk_cm_awards); NULL => the whole instance in one set (unchunked path).
    PROCEDURE build_fbdi_cm_set (
        p_instance_id   IN  VARCHAR2,
        p_run_id        IN  NUMBER,
        p_source_code   IN  VARCHAR2 DEFAULT NULL,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_cursor        OUT SYS_REFCURSOR
    );

    -- 2b. OIC path (this version can't map build_fbdi_cm_set's weak REF CURSOR):
    --    OIC reads the CM rows from the view LWS_C2FO_CM_FBDI_V (named/typed cols)
    --    via "Run a SQL Statement", builds+imports the chunk's FBDI, and ONLY then
    --    calls this to advance that chunk to EP_INTERFACED. Flipping AFTER a
    --    confirmed import (not before the read) means a half-built chunk is never
    --    stranded in INTERFACED: a resumed run still sees it as VALIDATED and
    --    rebuilds it. Idempotent (a re-call for an already-INTERFACED chunk is a
    --    no-op). p_chunk_id NULL => whole instance (unchunked path).
    PROCEDURE flip_chunk_to_interfaced (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_flipped       OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 2c. Due-date path (Integration #3 LWS_C2FO_DUEDATE_UPSERT). After #3 has
    --    successfully batch-upserted a CM chunk's installment due dates in Fusion,
    --    it calls this to advance those rows from EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED
    --    to EP_DUE_DATE_UPSERT_SENT, so a re-read of LWS_C2FO_DD_UPSERT_V for the same
    --    chunk returns nothing (re-run guard). This is NOT the terminal state - the
    --    final record_status='Y'/SUCCESSFULLY_PROCESSED stamp comes from
    --    annotate_duedate_result_bulk off the DD verdict rows. Idempotent (a re-call
    --    for an already-sent chunk is a no-op). p_chunk_id NULL => whole instance.
    PROCEDURE flip_chunk_duedates_sent (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_flipped       OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4. OIC writes back one CM's import/validate verdict onto the award row.
    --    p_cm_ok='Y' -> stage EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED, cm_status='OK';
    --    'N' -> record_status='E' with p_error_stage (import vs revalidation) + msg.
    --    SINGLE-AWARD path: kept for the exception + compensation tail. At batch
    --    volume (300-500K) use annotate_cm_result_bulk instead. p_invoice_id is the
    --    composite award key.
    PROCEDURE annotate_cm_result (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_cm_invoice_id IN  NUMBER,
        p_cm_ok         IN  VARCHAR2,               -- Y / N
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,  -- one of C_ERR_IMPORT / C_ERR_CM_REVAL
        p_error_msg     IN  VARCHAR2 DEFAULT NULL
    );

    -- 4b. BULK CM write-back (the volume path). OIC bulk-inserts one 'CM' verdict
    --    per award into LWS_AP_C2FO_VERDICT_LOAD (STATUS 'Y'/'N', cm_invoice_id,
    --    error_stage/message on failure), then calls this ONCE for the batch. One
    --    MERGE stamps every award's CM outcome exactly as annotate_cm_result would
    --    (Y -> cm_status='OK', EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED; N -> terminal
    --    'E' at the reported stage). Only unprocessed 'CM' verdicts are consumed;
    --    the MERGE marks them PROCESSED_FLAG='Y' so a re-run is a no-op. o_applied =
    --    award rows stamped.
    PROCEDURE annotate_cm_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4b-chunk. Per-chunk CM write-back (used when OIC imports + upserts one chunk at
    --    a time). Identical to annotate_cm_result_bulk but scoped to a single chunk:
    --    consumes only that chunk's unprocessed 'CM' verdicts, so a per-chunk call
    --    stamps ONLY that chunk's awards into EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED and
    --    leaves other chunks' awards untouched. Call this inside the chunk loop,
    --    before the due-date upsert for the chunk.
    PROCEDURE annotate_cm_result_chunk (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4c. Set-based CM verdict insert for a whole chunk (the happy path). Success is
    --    the common case: when the per-chunk count check confirms every CM was
    --    created, OIC calls this ONCE with p_status='Y' instead of shipping a row per
    --    award. It inserts one 'CM' verdict per award in the chunk (INSERT ... SELECT
    --    from LWS_C2FO_AWARD_DATA), so every award still gets its own status without
    --    any per-record work in OIC. Also called with p_status='N' from the import /
    --    validate failure + timeout branches to terminally fail the whole chunk. The
    --    end-of-batch annotate_cm_result_bulk MERGE consumes these rows.
    PROCEDURE insert_chunk_cm_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,               -- 'Y' (all created) | 'N' (chunk failed)
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,  -- C_ERR_IMPORT / C_ERR_CM_REVAL on 'N'
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4d. Per-row CM-creation diff (the shortfall path, paged). When the per-chunk
    --    count check is short, OIC PAGES the Fusion created-CM list into
    --    LWS_AP_C2FO_CM_CREATED_STG for this chunk (it cannot hold the run-wide,
    --    tens-of-thousands list in a flow variable), then calls this ONCE. It diffs the
    --    chunk's SENT awards (record_status='N', stage=SUCCESSFULLY_VALIDATED) against
    --    the staged created CMs by cm_invoice_num = InvoiceNumber and inserts one 'CM'
    --    verdict per award into LWS_AP_C2FO_VERDICT_LOAD: matched -> 'Y' + its
    --    CM_INVOICE_ID; unmatched -> 'N' at C_ERR_IMPORT. The end-of-loop
    --    annotate_cm_result_bulk consumes these. Clears this chunk's staging rows at
    --    the end so a re-run starts clean. Authoritative per-row: it replaces the
    --    blanket chunk 'N' on the shortfall branch.
    PROCEDURE diff_chunk_cm_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_created       OUT NUMBER,                 -- awards matched (Y)
        o_missing       OUT NUMBER,                 -- awards not created (N)
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4d-bis. Per-row CM-VALIDATION diff (the validate shortfall path, paged). Twin of
    --    diff_chunk_cm_verdicts for the VALIDATE leg. Import Payables Invoices CREATES
    --    the CM (caught by the created-diff); a second Fusion step VALIDATES it. After
    --    the validate job OIC PAGES the Fusion validated-CM list into
    --    LWS_AP_C2FO_CM_VALIDATED_STG for this chunk, then calls this ONCE. It diffs the
    --    chunk's CREATED-but-unvalidated awards (record_status='N', cm_status='OK',
    --    stage=C_STAGE_CM_CREATED) against the staged validated CMs by
    --    cm_invoice_num = InvoiceNumber and inserts one 'CM' verdict per award: matched
    --    -> 'Y' (validated, promoted to CM_VALIDATED, keeps its CM_INVOICE_ID);
    --    unmatched -> 'N' at C_ERR_CM_REVAL
    --    (CM created but did not validate -> compensation targets just that bad CM). The
    --    end-of-loop annotate_cm_result_chunk/_bulk consumes these. Clears this chunk's
    --    staging rows at the end (idempotent re-run).
    PROCEDURE diff_chunk_cm_validate_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_validated     OUT NUMBER,                 -- CMs validated (Y)
        o_missing       OUT NUMBER,                 -- CMs created but not validated (N)
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4e. Per-row DUE-DATE verdicts by diffing intended vs applied due dates.
    --     After the due-date batch upsert (partial-success), OIC re-queries Fusion for
    --     the chunk's installment due dates and stages them in LWS_AP_C2FO_DD_APPLIED_STG.
    --     This compares each DD-sent award's intended pay_date against the applied due
    --     date: match -> DD verdict 'Y'; mismatch/absent -> 'N' (comp_status left NULL
    --     here; the OIC cancel step stamps COMPENSATED/FAILED before annotate runs).
    --     Writes one 'DD' verdict per award; clears the chunk's staging rows. Mirrors
    --     diff_chunk_cm_verdicts.
    PROCEDURE diff_chunk_dd_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,                 -- installments confirmed applied (Y)
        o_failed        OUT NUMBER,                 -- installments not applied (N)
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4e-bis. Response-driven DUE-DATE verdicts (the current #3 path). Instead of a
    --     read-back, OIC parses the adf.batch upsert RESPONSE: every part whose
    --     httpStatus >= 400 is a FAILED installment. OIC bulk-inserts those failed
    --     Fusion InvoiceIds into LWS_AP_C2FO_DD_APPLIED_STG as (instance_id, chunk_id,
    --     invoice_id, installment_number) with APPLIED_DUE_DATE left NULL (the table is
    --     reused as a scratch carrier; here presence means FAILED, the INVERSE of the
    --     read-back diff). This proc writes one 'DD' verdict per award in the chunk:
    --     a staged (erp_invoice_id, payment_num) match -> 'N' (failed); everything else
    --     in the chunk -> 'Y' (applied). Clears the chunk's staging rows. The downstream
    --     cancel loop (LWS_C2FO_DD_CANCEL_V) + stamp_dd_comp_status + annotate are
    --     unchanged. Use this OR diff_chunk_dd_verdicts, not both, per chunk.
    PROCEDURE mark_dd_failures (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,                 -- awards marked applied (Y)
        o_failed        OUT NUMBER,                 -- awards marked failed (N)
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 4f. Stamp the CM-cancel outcome onto one failed DD verdict. After the OIC cancel
    --     step POSTs cancelInvoice for a DD-failed award (from LWS_C2FO_DD_CANCEL_V),
    --     it calls this per row: p_comp_status='COMPENSATED' (CM cancelled -> the award
    --     closes C_ERR_ORIG_DD) or 'FAILED' (CM could not be cancelled -> stranded
    --     C_ERR_COMPENSATION). annotate_duedate_result_bulk then reads comp_status.
    PROCEDURE stamp_dd_comp_status (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,               -- award_key (composite)
        p_comp_status   IN  VARCHAR2                -- 'COMPENSATED' | 'FAILED'
    );

    -- 4g. Stamp the CM-OFFSET outcome onto one failed award's verdict. The shared
    --     child integration LWS_C2FO_CM_OFFSET (fed by LWS_C2FO_CM_OFFSET_V) creates
    --     a positive STANDARD invoice to offset a faulty/unvalidated CM, then calls
    --     this per row: p_offset_status='COMPENSATED' (offset invoice created ->
    --     the award closes C_ERR_ORIG_DD) or 'FAILED' (offset could not be created
    --     -> stranded C_ERR_COMPENSATION). Unlike stamp_dd_comp_status this stamps
    --     the award's unconsumed 'N' verdict of EITHER kind, because the offset is
    --     invoked from #2 (a 'CM' verdict failed validation) AND #3 (a 'DD' verdict
    --     failed the upsert). annotate_*_result_bulk then reads comp_status.
    PROCEDURE update_offset_status (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,               -- award_key (composite)
        p_offset_status IN  VARCHAR2                -- 'COMPENSATED' | 'FAILED'
    );

    -- 5. (removed) build_duedate_set — the due-date read is now the view
    --    LWS_C2FO_DD_UPSERT_V, read directly by OIC "Run a SQL Statement"
    --    (filtered by instance_id + chunk_id + dd_batch_no). The procedure/REF-CURSOR
    --    form was never wired into the flow and has been dropped.

    -- 6. OIC writes back one installment's due-date verdict after its REST call.
    --    p_dd_ok='Y'  -> award complete: record_status='Y', SUCCESSFULLY_PROCESSED.
    --    p_dd_ok='SKIP' (AP-810830, installment paid between extract & write-back)
    --                   -> dd_status='KNOWN_SKIP', award closed without acceleration.
    --    p_dd_ok='N'  -> due-date update failed after OIC's retries. OIC then performs
    --                   the compensating cancelInvoice/debit-memo REST call and reports
    --                   its result in p_comp_status ('COMPENSATED' / 'FAILED'); the DB
    --                   stamps C_ERR_ORIG_DD (compensated) or C_ERR_COMPENSATION (fatal).
    --    SINGLE-AWARD path: kept for the compensation tail. At batch volume use
    --    annotate_duedate_result_bulk instead. p_invoice_id is the composite award key.
    PROCEDURE annotate_duedate_result (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_dd_ok         IN  VARCHAR2,               -- Y / SKIP / N
        p_http_status   IN  NUMBER   DEFAULT NULL,
        p_comp_status   IN  VARCHAR2 DEFAULT NULL,  -- COMPENSATED / FAILED (only when p_dd_ok='N')
        p_error_msg     IN  VARCHAR2 DEFAULT NULL
    );

    -- 6b. BULK due-date write-back (the volume path). OIC bulk-inserts one 'DD'
    --    verdict per award into LWS_AP_C2FO_VERDICT_LOAD (STATUS 'Y'/'SKIP'/'N',
    --    http_status, and comp_status 'COMPENSATED'/'FAILED' + message when 'N'),
    --    then calls this ONCE for the batch. One MERGE stamps every award's due-date
    --    outcome exactly as annotate_duedate_result would (Y/SKIP -> completed;
    --    N -> terminal C_ERR_ORIG_DD if compensated else C_ERR_COMPENSATION). Only
    --    unprocessed 'DD' verdicts are consumed and marked PROCESSED_FLAG='Y'.
    --    o_applied = award rows stamped.
    PROCEDURE annotate_duedate_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 7. Render the batch's record_status='E' rows to an RFC-4180 CSV and write it
    --    to the OCI error bucket/folder for return to C2FO.
    PROCEDURE write_error_file (
        p_instance_id   IN  VARCHAR2,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 7b. Render a human-/client-facing RUN LOG for the instance (the C2FO-INBOUND
    --     -LOG format: Header section with counts + timing, Prechecks, Overall
    --     Status, then one Error Line per failed award) and write it to the same
    --     OCI error bucket/folder. A SEPARATE step from write_error_file (different
    --     audience, different shape) - OIC invokes it once at end of the instance
    --     and references o_object_name as the log link in the ErrorHandler call.
    --     The ErrorHandler link is NOT a URL: it is the semicolon-delimited pair
    --     '<bucket>;<folder>/<object>;' (the service builds the clickable link from
    --     it). So the proc returns the bucket, the full object path, and a ready-made
    --     o_error_link = '<bucket>;<path>;' to map straight into the ErrorHandler.
    PROCEDURE write_run_log_file (
        p_instance_id   IN  VARCHAR2,
        o_bucket        OUT VARCHAR2,                 -- OCI bucket name
        o_object_path   OUT VARCHAR2,                 -- folder/.../object within the bucket
        o_error_link    OUT VARCHAR2,                 -- '<bucket>;<object_path>;' for the ErrorHandler
        o_status        OUT VARCHAR2,                 -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 8. Award-history purge (BR#12). A SEPARATE, scheduled step - NEVER part of an
    --    inbound run. Deletes award rows whose CREATION_DATE is older than the
    --    retention window (INBOUND / AWARD_RETENTION_MONTHS from config; p_override
    --    wins for an ad-hoc run) AND whose RECORD_STATUS <> 'N' - an aged in-flight
    --    ('N') row is NEVER purged (it is an exception to investigate, reported in
    --    o_aged_inflight, not silent data loss). Deletes in bounded, per-batch-
    --    committed chunks so it is safe at 500K. o_deleted = rows removed.
    PROCEDURE purge_award_history (
        p_override_months IN  NUMBER   DEFAULT NULL,  -- ad-hoc window; NULL => use config
        p_commit_batch    IN  NUMBER   DEFAULT 10000, -- rows per commit chunk
        o_deleted         OUT NUMBER,
        o_aged_inflight   OUT NUMBER,                 -- aged 'N' rows left in place (investigate)
        o_status          OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message         OUT VARCHAR2
    );
    -- 9. Render the batch'srecord_status NOT IN ('SUCCESSFULLY_PROCESSED','PROCESSED_NO_CM')  rows 
    -- to an RFC-4180 CSV and write it  to the OCI OUTBOUND error bucket/folder for return to C2FO.
    PROCEDURE write_error_records_csv_file (
        p_instance_id   IN  VARCHAR2,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

END LWS_AP_C2FO_AWARD_PKG;
/

