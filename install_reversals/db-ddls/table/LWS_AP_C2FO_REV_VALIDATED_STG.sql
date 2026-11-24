--------------------------------------------------------------------------------
-- C2FO REVERSAL offset-invoice validated-staging
-- Purpose: the read-back target for the OFFSET VALIDATE leg. Import Payables Invoices
--          CREATES the offset invoice (read back into LWS_AP_C2FO_REV_CREATED_STG);
--          a second Fusion step VALIDATES it. After the validate job OIC queries
--          Fusion for the chunk's validated offset invoices (number
--          '<CM_INVOICE_NUM(1,48)>-R') and bulk-inserts each (InvoiceNumber,
--          InvoiceId) here, scoped by (INSTANCE_ID, CHUNK_ID). Then
--          diff_chunk_rev_validate_verdicts LEFT JOINs the chunk's CREATED-but-
--          unvalidated reversal rows to these rows on offset_invoice_num =
--          INVOICE_NUMBER: match -> OFFSET verdict 'Y' (validated); no match -> 'N'
--          at C_ERR_OFFSET (offset created but not validated -> partial reversal).
--          Column-identical to LWS_AP_C2FO_REV_CREATED_STG but a SEPARATE table so the
--          create and validate read-backs never collide within a chunk. Twin of the
--          award flow's LWS_AP_C2FO_CM_VALIDATED_STG.
-- Grain  : scratch/transient, not keyed; cleared per chunk by
--          diff_chunk_rev_validate_verdicts (idempotent re-run).
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VALIDATED_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VALIDATED_STG (
    INSTANCE_ID        VARCHAR2(150)  NOT NULL,   -- reversal batch (OIC $Instance_Id)
    CHUNK_ID           NUMBER         NOT NULL,    -- the chunk this page load belongs to
    INVOICE_NUMBER     VARCHAR2(50)   NOT NULL,    -- Fusion InvoiceNumber = '<CM_INVOICE_NUM(1,48)>-R'
    OFFSET_INVOICE_ID  NUMBER,                     -- Fusion InvoiceId (captured for the Y verdict)
    CREATED_DATE       TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REV_VALIDATED_STG
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VALIDATED_STG (INSTANCE_ID, CHUNK_ID, INVOICE_NUMBER);
