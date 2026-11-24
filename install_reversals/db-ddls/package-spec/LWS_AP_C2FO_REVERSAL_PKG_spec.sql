--------------------------------------------------------------------------------
-- Package : LWS_AP_C2FO_REVERSAL_PKG
-- Purpose : C2FO award REVERSAL, ATP edition. The sibling of LWS_AP_C2FO_AWARD_PKG,
--           built as a deliberate CLONE of the inbound award flow so the two OIC
--           integrations and the ATP contract mirror it (companion design:
--           "C2FO Integration - Technical Design - Award Reversal"). It UNDOES a
--           previously-processed award: OFFSET the discount credit memo with a
--           positive STANDARD invoice (where income<>0), then RESTORE the original
--           invoice's due date + discount schedule, then acknowledge each invoice
--           back to C2FO.
--
-- Record of truth: reversal-file rows land 1:1 into LWS_C2FO_REVERSAL_DATA and are
--           processed in place; the ORIGINAL award (LWS_C2FO_AWARD_DATA) is READ to
--           resolve the CM number/id + the stored pre-acceleration schedule, and
--           STAMPED (REVERSED_FLAG/_DATE/_REASON) on a successful reversal. One
--           reversal row = VOUCHER_ID + VOUCHER_LINE_ID; the batch = INSTANCE_ID (the
--           OIC loader run id). CORRELATION_ID (from the control file) is carried for
--           the C2FO ack echo.
--
-- ARCHITECTURAL CONSTRAINT (client ruling): the database MUST NOT call ERP REST. OIC
--           issues every Fusion REST/ESS call (FBDI import, Validate, the due-date
--           batch upsert) and REPORTS each outcome back via the annotate_* procs.
--           The one ATP-side external write is DBMS_CLOUD to OCI object storage (read
--           the reversal file; write the ack + ack-control files).
--
-- State machine (LWS_C2FO_REVERSAL_DATA, processed in place):
--   record_status: 'N' not processed | 'Y' success | 'E' error.
--   stage        : STAGED -> RESOLVED -> REVERSED (success); or an error stage on a
--                  resolve / offset / due-date failure.
--   offset_status / dd_status: the two halves tracked separately (BR#7) so a
--                  partially applied reversal is detectable.
--   ack_status / ack_message : the per-invoice acknowledgement built into the ack CSV.
--
-- How OIC uses it (call order); p_instance_id is the OIC loader run id (the batch):
--   1. LOAD_REVERSAL_FILE(...)        -> bulk-load the reversal CSV from the bucket.
--   2. RESOLVE_REVERSALS(...)         -> match each row to its award; stamp resolved
--                                        refs + ORIG_* schedule; gate REV_REQUIRED;
--                                        Error rows for unknown / already-reversed.
--   3. (OIC reads LWS_C2FO_REV_FBDI_V -> FBDI import a positive STANDARD invoice ->
--       Validate -> queries Fusion for the created '-C2FOR' invoices.)
--   4. ANNOTATE_REVERSAL_OFFSET_RESULT(...) -> OIC writes back each offset verdict.
--   5. (OIC reads LWS_C2FO_REV_DD_V -> batch-upserts invoiceInstallments back to the
--       original due date + ORIG_* tiers.)
--   6. ANNOTATE_REVERSAL_DD_RESULT(...)      -> OIC writes back each DD verdict; this
--       stamps the reversal row REVERSED + the AWARD row REVERSED_FLAG on success.
--   7. WRITE_REVERSAL_ACK(...)        -> renders the 12-col ack CSV + 4-col ack
--       control (echoing CORRELATION_ID + rollup status) to OCI for C2FO.
--------------------------------------------------------------------------------

CREATE OR REPLACE PACKAGE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REVERSAL_PKG AS

    -- Process-stage constants (reversal state machine):
    --   STAGED -> RESOLVED -> OFFSET_CREATED -> OFFSET_VALIDATED -> REVERSED.
    -- The offset invoice, like the award credit memo, is CREATED by Import Payables
    -- Invoices then VALIDATED by a second Fusion step, so the offset leg is a two-stage
    -- split (twin of the award CM_CREATED -> CM_VALIDATED leg):
    --   * offset read-back diff / whole-chunk offset verdict promotes RESOLVED ->
    --     OFFSET_CREATED on success;
    --   * the offset VALIDATE read-back diff (diff_chunk_rev_validate_verdicts) promotes
    --     OFFSET_CREATED -> OFFSET_VALIDATED on success.
    -- DD-only rows (rev_required='N', income=0) have no offset invoice, so
    -- validate_reversals promotes them straight to OFFSET_VALIDATED at resolve time
    -- (mirrors the award's income=0 -> CM_VALIDATED shortcut). The due-date-restore leg
    -- (diff/insert/mark + annotate_reversal_dd_result*) reads stage='OFFSET_VALIDATED';
    -- only annotate_reversal_dd_result* advances to REVERSED (terminal). Re-run safety is
    -- on record_status + offset_status/dd_status + the verdict NOT-EXISTS guards.
    C_STAGE_STAGED           CONSTANT VARCHAR2(40) := 'STAGED';
    C_STAGE_RESOLVED         CONSTANT VARCHAR2(40) := 'RESOLVED';
    C_STAGE_OFFSET_CREATED   CONSTANT VARCHAR2(40) := 'OFFSET_CREATED';
    C_STAGE_OFFSET_VALIDATED CONSTANT VARCHAR2(40) := 'OFFSET_VALIDATED';
    C_STAGE_REVERSED         CONSTANT VARCHAR2(40) := 'REVERSED';
    -- offset FBDI chunk size: rows per Import Payables Invoices chunk (chunk_rev_offsets)
    C_REV_CHUNK_DEFAULT CONSTANT NUMBER := 50000;
    -- error stages
    C_ERR_NO_AWARD        CONSTANT VARCHAR2(40) := 'AWARD_NOT_FOUND';
    C_ERR_ALREADY_REV     CONSTANT VARCHAR2(40) := 'ALREADY_REVERSED';
    C_ERR_VALIDATION      CONSTANT VARCHAR2(40) := 'VALIDATION_ERROR';
    C_ERR_OFFSET          CONSTANT VARCHAR2(40) := 'OFFSET_IMPORT_ERROR';
    C_ERR_DD_RESTORE      CONSTANT VARCHAR2(40) := 'DUE_DATE_RESTORE_ERROR';
    -- per-invoice acknowledgement Status values (file spec)
    C_ACK_SUCCESS     CONSTANT VARCHAR2(10) := 'Success';
    C_ACK_ERROR       CONSTANT VARCHAR2(10) := 'Error';
    -- ack-control rollup Status values (file spec)
    C_ROLL_COMPLETE   CONSTANT VARCHAR2(20) := 'Complete';
    C_ROLL_PARTIAL    CONSTANT VARCHAR2(20) := 'Partial_Complete';
    C_ROLL_ERROR      CONSTANT VARCHAR2(20) := 'Error';

    -- 0. Bulk-load one reversal CSV straight from the OCI bucket into
    --    LWS_C2FO_REVERSAL_DATA. Clone of load_award_file: DBMS_CLOUD external table
    --    over the object, then a set-based INSERT. Stamps INSTANCE_ID, CORRELATION_ID,
    --    FILE_NAME, RECORD_STATUS='N', STAGE='STAGED'; resolved refs + ORIG_* + outcome
    --    stay empty (resolve_reversals fills them). Returns o_rows_loaded so OIC can
    --    assert control.row_count = o_rows_loaded before accepting the batch. Archives
    --    the reversal drop (data + control) to the archive bucket, best-effort.
    PROCEDURE load_reversal_file (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_object_name   IN  VARCHAR2,
        p_instance_id   IN  VARCHAR2,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        o_rows_loaded   OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 1. RESOLVE + VALIDATE each 'N' reversal row in one pass:
    --    (a) RESOLVE - match to its award (VOUCHER_ID + VOUCHER_LINE_ID), stamping the
    --        resolved refs (ERP_INVOICE_ID / ERP_ORG_ID / CM_INVOICE_ID / CM_INVOICE_NUM
    --        / INCOME / tax / currency / source / terms / supplier ids) and the ORIG_*
    --        restore schedule, setting REV_REQUIRED='N' for income=0 rows (DD restore
    --        only). No matching / already-reversed award -> terminal 'E' (AWARD_NOT_FOUND).
    --    (b) VALIDATE the live Fusion state of each matched row (read from the mirror by
    --        the resolved refs) - three gates:
    --          * NOT PAID  - the named installment (ERP_INVOICE_ID + VOUCHER_LINE_ID)
    --            must not be fully paid (AP_PAYMENT_SCHEDULES_ALL.PAYMENT_STATUS_FLAG='Y')
    --            => block; we do NOT reset the due date of a paid invoice. ALWAYS applies.
    --          * INVOICE HOLD  - an unreleased hold on the invoice
    --            (AP_HOLDS_ALL where RELEASE_LOOKUP_CODE IS NULL) => block, unless ignored.
    --          * VENDOR/SITE HOLD - the supplier site holds payments
    --            (LWS_POZ_SUPPLIER_SITES_ALL_M.HOLD_ALL_PAYMENTS_FLAG / HOLD_FLAG='Y')
    --            => block, unless ignored.
    --        p_ignore_hold ('Y'/'N', an OIC integration property - NOT a file column)
    --        when 'Y' SKIPS the two HOLD gates only; the not-paid gate always applies.
    --    Rows that pass BOTH resolve + validate are STAGE='RESOLVED' (ready for the
    --    offset/DD steps). Any failure is terminal 'E' with ack Status='Error'. One
    --    fast set-based pass (low volume).
    PROCEDURE validate_reversals (
        p_instance_id   IN  VARCHAR2,
        p_ignore_hold   IN  VARCHAR2 DEFAULT 'N',   -- 'Y' bypasses the two HOLD gates only
        o_resolved      OUT NUMBER,                 -- rows ready to process (passed both)
        o_errored       OUT NUMBER,                 -- unmatched / already-reversed / paid / held
        o_offset_req    OUT NUMBER,                 -- resolved rows needing an offset (income<>0)
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 1b. Assign FBDI import CHUNK_IDs to the offset-eligible resolved rows
    --    (REV_REQUIRED='Y'). BU + import-source aware exactly like the award
    --    chunk_cm_awards: Import Payables Invoices runs per BU AND per source, so a
    --    chunk must never span two ORG_IDs or two SOURCE_CODEs. Sub-chunks within each
    --    (BU, source) by C_REV_CHUNK_DEFAULT (or the INBOUND.CM_CHUNK_SIZE knob), then
    --    collapses to a running 1..N CHUNK_ID so OIC loops a simple While. Clone of the
    --    award CM-creation path (replaces per-row REST so thousands of reversals scale).
    PROCEDURE chunk_rev_offsets (
        p_instance_id   IN  VARCHAR2,
        p_chunk_size    IN  NUMBER DEFAULT NULL,
        o_chunk_count   OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 2. WHOLE-CHUNK OFFSET verdict (the happy path). Twin of the award
    --    insert_chunk_cm_verdicts. When OIC's Import Payables Invoices for a chunk
    --    reports success as a whole (every offset invoice created), OIC calls this ONCE
    --    with p_status='Y' to insert one 'OFFSET' verdict ('Y') per offset-eligible row
    --    in the chunk (INSERT ... SELECT from LWS_C2FO_REVERSAL_DATA) -- every reversal
    --    row still gets its own verdict without per-record work in OIC. Also called with
    --    p_status='N' (+ error stage/message) from the import/validate failure + timeout
    --    branches to terminally fail the whole chunk. One 'OFFSET' verdict per row into
    --    LWS_AP_C2FO_REV_VERDICT_LOAD, consumed by annotate_reversal_offset_result_bulk
    --    (or _chunk). Use diff_chunk_rev_verdicts ONLY on the shortfall path (partial
    --    create, must find which rows are missing).
    PROCEDURE insert_chunk_rev_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,               -- 'Y' (all created) | 'N' (chunk failed)
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,  -- error stage on 'N' (default C_ERR_OFFSET)
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 2b. OFFSET read-back diff -> per-row verdict (the SHORTFALL path only). After OIC
    --    imports a chunk's offset invoices it pages the created invoices (number
    --    '<CM>-R') into LWS_AP_C2FO_REV_CREATED_STG; this LEFT JOINs the chunk's sent
    --    reversal rows to that staging on offset_invoice_num = INVOICE_NUMBER and writes
    --    one OFFSET verdict per row (match -> 'Y' + OFFSET_INVOICE_ID; no match -> 'N'),
    --    consumed by annotate_reversal_offset_result_bulk. Clears the chunk's staging
    --    rows. Clone of diff_chunk_cm_verdicts.
    PROCEDURE diff_chunk_rev_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_created       OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 2c. BULK offset verdict write-back (the set path). Consumes every unconsumed
    --     'OFFSET' verdict for the batch from LWS_AP_C2FO_REV_VERDICT_LOAD in one MERGE.
    PROCEDURE annotate_reversal_offset_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 2d. Per-chunk offset verdict write-back (used when OIC imports + restores one
    --     chunk at a time). Identical to annotate_reversal_offset_result_bulk but scoped
    --     to a single chunk: consumes only that chunk's unprocessed 'OFFSET' verdicts.
    --     Twin of annotate_cm_result_chunk. Call inside the chunk loop, before the
    --     due-date restore for the chunk.
    PROCEDURE annotate_reversal_offset_result_chunk (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 2e. OFFSET VALIDATE read-back diff -> one OFFSET verdict per row. Twin of
    --    diff_chunk_rev_verdicts for the second (VALIDATE) Fusion step. The offset
    --    invoice is CREATED by Import Payables Invoices (the create diff promoted the row
    --    to OFFSET_CREATED), then a second job VALIDATES it. OIC pages the Fusion
    --    "validated offset invoices" list into LWS_AP_C2FO_REV_VALIDATED_STG for this
    --    chunk; this LEFT JOINs the chunk's CREATED-but-unvalidated rows (stage=
    --    OFFSET_CREATED) to that staging on offset number = INVOICE_NUMBER and writes one
    --    OFFSET verdict per row: match -> 'Y' (validated); no match -> 'N' at C_ERR_OFFSET
    --    (created but not validated). Consumed by annotate_reversal_offset_result_bulk /
    --    _chunk, which promote the 'Y' rows OFFSET_CREATED -> OFFSET_VALIDATED. Clears the
    --    chunk's staging rows (idempotent re-run). Twin of the award
    --    diff_chunk_cm_validate_verdicts.
    PROCEDURE diff_chunk_rev_validate_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_validated     OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 3. WHOLE-CHUNK DUE-DATE-restore verdict (the happy path). Twin of
    --    insert_chunk_rev_verdicts but for the DD leg: when OIC's installment upsert for
    --    a chunk succeeds as a whole, OIC calls this ONCE with p_status='Y' (or 'SKIP')
    --    to insert one 'DD' verdict per row in the chunk; p_status='N' (+ message) on a
    --    whole-chunk DD failure. One 'DD' verdict per row into LWS_AP_C2FO_REV_VERDICT_LOAD,
    --    consumed by annotate_reversal_dd_result_bulk. Nothing wrote DD verdicts before
    --    (the bulk close reads 'DD' rows) -- this is that writer.
    PROCEDURE insert_chunk_rev_dd_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,               -- 'Y'/'SKIP' (restored) | 'N' (chunk failed)
        p_http_status   IN  NUMBER   DEFAULT NULL,
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,               -- SUCCESS / ERROR
        o_message       OUT VARCHAR2
    );

    -- 3b. Per-row DUE-DATE-restore verdict insert (the SHORTFALL path). OIC parses the
    --     installment upsert RESPONSE and pages the FAILED (voucher_id, voucher_line_id)
    --     for the chunk into LWS_AP_C2FO_REV_CREATED_STG (reused as a scratch carrier;
    --     presence = FAILED, the inverse of a read-back). This writes one 'DD' verdict
    --     per row in the chunk: a staged match -> 'N' (failed restore); everything else
    --     -> 'Y' (restored). Clears the chunk's staging rows. Twin of mark_dd_failures.
    --     Use this OR insert_chunk_rev_dd_verdicts per chunk, not both.
    PROCEDURE mark_rev_dd_failures (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_failed        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 3d. DUE-DATE-restore verdict write-back + FINAL CLOSE (single-row). OIC reports
    --    each installment restore outcome. 'Y' => the reversal row is complete:
    --    STAGE='REVERSED', RECORD_STATUS='Y', ack Status='Success', AND the AWARD row
    --    is stamped REVERSED_FLAG='Y' / REVERSED_DATE / REVERSED_REASON. 'N' => 'E',
    --    C_ERR_DD_RESTORE, ack Error (offset already succeeded -> partial reversal,
    --    flagged; award NOT flipped so a corrected re-send can act again - BR#8).
    PROCEDURE annotate_reversal_dd_result (
        p_instance_id    IN  VARCHAR2,
        p_voucher_id     IN  NUMBER,
        p_voucher_line_id IN NUMBER,
        p_dd_ok          IN  VARCHAR2,              -- Y / SKIP / N
        p_http_status    IN  NUMBER   DEFAULT NULL,
        p_error_msg      IN  VARCHAR2 DEFAULT NULL
    );

    -- 3e. BULK due-date-restore verdict write-back + final close (the set path).
    PROCEDURE annotate_reversal_dd_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- 4. Write the two acknowledgement files to OCI for C2FO:
    --    a) Reversal Ack CSV (12 cols) = the 10 spec input fields + Status + Status
    --       Message, one row per reversal row, RFC-4180 quoted, header row.
    --    b) Reversal Ack Control CSV (4 cols) = ack file_name, row_count,
    --       Correlation_ID (echo), rollup Status (Complete / Partial_Complete / Error).
    PROCEDURE write_reversal_ack (
        p_instance_id    IN  VARCHAR2,
        p_correlation_id IN  VARCHAR2 DEFAULT NULL,
        o_ack_file       OUT VARCHAR2,
        o_ack_control    OUT VARCHAR2,
        o_rollup_status  OUT VARCHAR2,
        o_status         OUT VARCHAR2,
        o_message        OUT VARCHAR2
    );

END LWS_AP_C2FO_REVERSAL_PKG;
/
