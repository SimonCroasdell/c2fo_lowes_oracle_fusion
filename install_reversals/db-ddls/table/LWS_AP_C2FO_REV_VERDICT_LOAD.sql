--------------------------------------------------------------------------------
-- C2FO REVERSAL verdict-load table
-- Purpose: OIC writes each per-invoice reversal outcome here; the package consumes
--          them in one set-based MERGE (annotate_reversal_*_result_bulk). The
--          reversal twin of LWS_AP_C2FO_VERDICT_LOAD, but keyed on the reversal
--          match keys (VOUCHER_ID + VOUCHER_LINE_ID) and with its own verdict kinds
--          (OFFSET | DD). Kept separate from the award verdict table so the two flows
--          do not share state or key shape (the award table's CHECK forbids OFFSET
--          and keys on the award composite INVOICE_ID).
-- Key    : surrogate PK VERDICT_ROW_ID (from LWS_AP_C2FO_REV_VERDICT_SEQ, assigned by
--          TRG_REV_VERDICT_LOAD_BI because the OIC DB adapter inserts the PK as an
--          explicit NULL and bypasses a column DEFAULT).
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_LOAD;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_LOAD (
    VERDICT_ROW_ID   NUMBER              NOT NULL,   -- surrogate PK (sequence)
    INSTANCE_ID      VARCHAR2(150)       NOT NULL,   -- reversal batch (= LWS_C2FO_REVERSAL_DATA.INSTANCE_ID)
    VOUCHER_ID       NUMBER              NOT NULL,   -- reversal match key back to the reversal row
    VOUCHER_LINE_ID  NUMBER              NOT NULL,   -- reversal match key (installment)
    VERDICT_KIND     VARCHAR2(6)         NOT NULL,   -- 'OFFSET' | 'DD'
    STATUS           VARCHAR2(10)        NOT NULL,   -- OFFSET: Y/N ; DD: Y/SKIP/N
    OFFSET_NUM       VARCHAR2(50),                   -- created offset invoice number (OFFSET phase)
    HTTP_STATUS      NUMBER,                         -- last REST status
    MESSAGE          VARCHAR2(4000),                 -- verdict message
    PROCESSED_FLAG   VARCHAR2(1) DEFAULT 'N' NOT NULL, -- 'Y' once a bulk MERGE has consumed it
    CREATED_DATE     TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT PK_LWS_AP_C2FO_REV_VERDICT_LOAD PRIMARY KEY (VERDICT_ROW_ID),
    CONSTRAINT CK_REV_VERDICT_LOAD_KIND CHECK (VERDICT_KIND IN ('OFFSET','DD'))
);

-- The bulk MERGE selects one batch's unprocessed verdicts of one kind.
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REV_VERDICT_LOAD_BATCH
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_LOAD (INSTANCE_ID, VERDICT_KIND, PROCESSED_FLAG);
