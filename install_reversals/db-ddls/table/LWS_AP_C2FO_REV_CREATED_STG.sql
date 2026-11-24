--------------------------------------------------------------------------------
-- C2FO REVERSAL offset-invoice created-staging
-- Purpose: the read-back target for the chunked offset FBDI import. After OIC runs
--          Import Payables Invoices for a chunk, it queries Fusion for the created
--          offset invoices (number '<CM_INVOICE_NUM(1,48)>-R') and bulk-inserts each
--          (InvoiceNumber, InvoiceId) here, scoped by (INSTANCE_ID, CHUNK_ID). Then
--          diff_chunk_rev_verdicts LEFT JOINs the chunk's sent reversal rows to these
--          rows on offset_invoice_num = INVOICE_NUMBER to write one OFFSET verdict per
--          row (match -> 'Y' + OFFSET_INVOICE_ID; no match -> 'N'). The twin of the
--          award flow's LWS_AP_C2FO_CM_CREATED_STG.
-- Grain  : scratch/transient, not keyed; cleared per chunk by diff_chunk_rev_verdicts
--          (idempotent re-run).
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_CREATED_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_CREATED_STG (
    INSTANCE_ID        VARCHAR2(150)  NOT NULL,   -- reversal batch (OIC $Instance_Id)
    CHUNK_ID           NUMBER         NOT NULL,    -- the chunk this page load belongs to
    INVOICE_NUMBER     VARCHAR2(50)   NOT NULL,    -- Fusion InvoiceNumber = '<CM_INVOICE_NUM(1,48)>-R'
    OFFSET_INVOICE_ID  NUMBER,                     -- Fusion InvoiceId (captured for the Y verdict)
    CREATED_DATE       TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REV_CREATED_STG
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_CREATED_STG (INSTANCE_ID, CHUNK_ID, INVOICE_NUMBER);
