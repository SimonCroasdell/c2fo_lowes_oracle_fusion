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
DROP SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_SEQ;
CREATE SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_SEQ START WITH 1 INCREMENT BY 1 NOCACHE;

-- The OIC DB adapter inserts VERDICT_ROW_ID as an explicit NULL, which bypasses a
-- column DEFAULT, so the surrogate PK is assigned here instead.
