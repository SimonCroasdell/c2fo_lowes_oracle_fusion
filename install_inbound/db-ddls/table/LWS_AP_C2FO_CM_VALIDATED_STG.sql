--==============================================================================
-- CM VALIDATED STAGING  -- the read-back target for the CM VALIDATE leg
--   Import Payables Invoices CREATES the credit memo (read back into
--   LWS_AP_C2FO_CM_CREATED_STG); a second Fusion step VALIDATES it. After the
--   validate job OIC queries Fusion for the chunk's validated CMs and bulk-inserts
--   each (InvoiceNumber, InvoiceId) here, scoped by (INSTANCE_ID, CHUNK_ID). Then
--   diff_chunk_cm_validate_verdicts LEFT JOINs the chunk's CREATED-but-unvalidated
--   awards to these rows on cm_invoice_num = INVOICE_NUMBER: match -> 'Y' (validated);
--   no match -> 'N' at C_ERR_CM_REVAL (CM created but not validated -> compensation).
--   Column-identical to LWS_AP_C2FO_CM_CREATED_STG but a SEPARATE table so the create
--   and validate read-backs never collide within a chunk. Scratch/transient: not
--   keyed, cleared per chunk by diff_chunk_cm_validate_verdicts (idempotent re-run).
--==============================================================================
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_VALIDATED_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_VALIDATED_STG (
    INSTANCE_ID     VARCHAR2(150)  NOT NULL,   -- award batch (OIC $Instance_Id)
    CHUNK_ID        NUMBER         NOT NULL,    -- the chunk this page load belongs to
    INVOICE_NUMBER  VARCHAR2(50)   NOT NULL,    -- Fusion InvoiceNumber = '<orig-45>-C2FO'
    CM_INVOICE_ID   NUMBER,                     -- Fusion InvoiceId (captured for the Y verdict)
    CREATED_DATE    TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_CM_VALIDATED_STG
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_VALIDATED_STG (INSTANCE_ID, CHUNK_ID, INVOICE_NUMBER);

--==============================================================================
-- DUE-DATE APPLIED STAGING  -- OIC stages the due dates Fusion ACTUALLY holds
--   after the due-date batch upsert (partial-success). OIC re-queries Fusion for the
--   block's installment due dates and bulk-inserts them here, scoped by (INSTANCE_ID,
--   CHUNK_ID); diff_chunk_dd_verdicts compares each award's intended pay_date against
--   APPLIED_DUE_DATE (match -> DD 'Y'; mismatch/absent -> 'N', CM then cancelled).
--   Mirrors LWS_AP_C2FO_CM_CREATED_STG. Scratch/transient, cleared per chunk by the proc.
--==============================================================================
