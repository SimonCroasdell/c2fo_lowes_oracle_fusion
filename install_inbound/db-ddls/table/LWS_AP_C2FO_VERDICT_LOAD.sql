--------------------------------------------------------------------------------
-- C2FO Inbound AWARD run-log + verdict-load tables
-- Purpose: operational tables that support the award process. The award records
--          themselves live in the full-fidelity landing table LWS_C2FO_AWARD_DATA
--          (72_award_data.sql) - the record of truth for processing, reporting and
--          reversal. The narrow LWS_AP_C2FO_AWARD_STAGING is RETIRED.
-- Keys   : one award = the file's composite INVOICE_ID (ORG_ID|INVOICE_ID|
--          PAYMENT_NUM|INVOICE_NUM); the batch = INSTANCE_ID (the OIC loader run
--          id). Both the run log and the verdict-load carrier speak that key so the
--          write-back MERGEs join LWS_C2FO_AWARD_DATA on (INSTANCE_ID, INVOICE_ID).
-- Source : OIC / DBMS_CLOUD lands the award file into LWS_C2FO_AWARD_DATA;
--          validation reads the LWS_CUSTOM_C2FO_SA mirror via the Fusion-named
--          bridging views (60_bridging_views.sql). No live Fusion access.
-- Shared : configuration lives in the key/value LWS_C2FO_CONFIG table
--          (20_config_kv.sql), seeded under CONFIG_GROUP 'INBOUND' + the shared
--          'COMMON' obj-storage triple. Install that script once.
--------------------------------------------------------------------------------

--==============================================================================
-- RUN LOG  -- one row per inbound run, for OIC monitoring / audit
--   INSTANCE_ID is the OIC loader run id (the batch key on LWS_C2FO_AWARD_DATA);
--   RUN_ID is our own numeric run surrogate that OIC polls.
--==============================================================================
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_LOAD;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_LOAD (
    VERDICT_ROW_ID   NUMBER              NOT NULL,   -- surrogate PK (sequence)
    INSTANCE_ID      VARCHAR2(150)       NOT NULL,   -- award batch these verdicts belong to (= LWS_C2FO_AWARD_DATA.INSTANCE_ID)
    RUN_ID           NUMBER,                         -- owning run (audit / purge grouping)
    INVOICE_ID       VARCHAR2(240)       NOT NULL,   -- composite award key back to the award row
    VERDICT_KIND     VARCHAR2(2)         NOT NULL,   -- 'CM' | 'DD'
    STATUS           VARCHAR2(10)        NOT NULL,   -- CM: Y/N ; DD: Y/SKIP/N
    CM_INVOICE_ID    NUMBER,                         -- created CM id (CM phase)
    HTTP_STATUS      NUMBER,                         -- last REST status (DD phase)
    COMP_STATUS      VARCHAR2(20),                   -- COMPENSATED|FAILED (DD phase, status='N')
    ERROR_STAGE      VARCHAR2(80),                   -- CM phase failure stage (import vs reval)
    MESSAGE          VARCHAR2(4000),                 -- verdict message
    PROCESSED_FLAG   VARCHAR2(1) DEFAULT 'N' NOT NULL, -- 'Y' once a bulk MERGE has consumed it
    CREATED_DATE     TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT PK_LWS_AP_C2FO_VERDICT_LOAD PRIMARY KEY (VERDICT_ROW_ID),
    CONSTRAINT CK_VERDICT_LOAD_KIND  CHECK (VERDICT_KIND IN ('CM','DD'))
);

-- The bulk MERGE selects one batch's unprocessed verdicts of one kind.
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_VERDICT_LOAD_BATCH
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_LOAD (INSTANCE_ID, VERDICT_KIND, PROCESSED_FLAG);

