--------------------------------------------------------------------------------
-- C2FO REVERSAL due-date-restore failure staging
-- Purpose: scratch carrier for the SHORTFALL path of the due-date-restore leg. The
--          installment upsert is partial-success, so OIC parses the adf.batch
--          RESPONSE and bulk-inserts the FAILED (VOUCHER_ID, VOUCHER_LINE_ID) for a
--          chunk here. mark_rev_dd_failures then writes one 'DD' verdict per reversal
--          row in the chunk: a staged match -> 'N' (failed restore); everything else
--          -> 'Y' (restored), clearing the chunk afterwards. Presence means FAILED
--          (the inverse of a read-back). Twin of the award LWS_AP_C2FO_DD_APPLIED_STG,
--          re-keyed to the reversal match keys.
-- Grain  : scratch/transient, not keyed; cleared per chunk by mark_rev_dd_failures.
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_DD_APPLIED_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_DD_APPLIED_STG (
    INSTANCE_ID        VARCHAR2(150)  NOT NULL,   -- reversal batch (OIC $Instance_Id)
    CHUNK_ID           NUMBER         NOT NULL,    -- the chunk this page load belongs to
    VOUCHER_ID         NUMBER         NOT NULL,    -- reversal match key (AP_INVOICES_ALL.INVOICE_ID)
    VOUCHER_LINE_ID    NUMBER         NOT NULL,    -- reversal match key (installment PAYMENT_NUM)
    HTTP_STATUS        NUMBER,                      -- the failing part's httpStatus (>= 400)
    MESSAGE            VARCHAR2(2000),              -- the failing part's error detail
    CREATED_DATE       TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REV_DD_APPLIED_STG
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_DD_APPLIED_STG (INSTANCE_ID, CHUNK_ID, VOUCHER_ID, VOUCHER_LINE_ID);
