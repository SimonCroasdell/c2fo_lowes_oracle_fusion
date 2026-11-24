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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_AWARD_RUN_LOG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_AWARD_RUN_LOG (
    RUN_ID          NUMBER          NOT NULL,
    INSTANCE_ID     VARCHAR2(150),                  -- OIC loader run id = batch key on LWS_C2FO_AWARD_DATA
    TOTAL_COUNT     NUMBER,
    VALIDATED_COUNT NUMBER,
    NO_OF_CMS_REQUIRED NUMBER,   -- validated awards with income<>0 = CMs the run must create (OIC uses as the all-chunks target)
    ERROR_COUNT     NUMBER,
    CM_CREATED_CNT  NUMBER,
    PROCESSED_COUNT NUMBER,   -- SUCCESSFULLY_PROCESSED (both halves done)
    START_TIME      DATE,
    END_TIME        DATE,
    STATUS          VARCHAR2(20),   -- RUNNING / SUCCESS / ERROR / FATAL
    ERROR_MESSAGE   VARCHAR2(4000),
    VALIDATE_JOB_NAME VARCHAR2(128), -- one-time job that ran validation (async run_inbound)
    -- OIC-supplied runtime params, persisted so the background jobs (separate
    -- sessions) can read them back by RUN_ID instead of relying on session globals.
    ACTIVITY_TYPE   VARCHAR2(200),  -- in-scope award activity gate (was config)
    SOURCE_CODE     VARCHAR2(30),   -- invoice source for the FBDI CM set (was config)
    PAY_GROUP       VARCHAR2(30),   -- pay group for accelerated invoices; used only when UPDATE_PAY_GROUP='Y'
    UPDATE_PAY_GROUP  VARCHAR2(1) DEFAULT 'N',  -- BR#16 gate: Y apply pay group, N leave untouched
    CM_PAYMENT_METHOD VARCHAR2(100),            -- BR#16: CM header payment method (OIC CM_PAYMENT_METHOD lookup)
    CONSTRAINT PK_LWS_AP_C2FO_AWARD_RUN_LOG PRIMARY KEY (RUN_ID)
);

