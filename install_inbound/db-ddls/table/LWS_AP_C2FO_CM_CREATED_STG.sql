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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_CREATED_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_CREATED_STG (
    INSTANCE_ID     VARCHAR2(150)  NOT NULL,   -- award batch (OIC $Instance_Id)
    CHUNK_ID        NUMBER         NOT NULL,    -- the chunk this page load belongs to
    INVOICE_NUMBER  VARCHAR2(50)   NOT NULL,    -- Fusion InvoiceNumber = '<orig-45>-C2FO'
    CM_INVOICE_ID   NUMBER,                     -- Fusion InvoiceId (captured for the Y verdict)
    CREATED_DATE    TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_CM_CREATED_STG
    ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_CM_CREATED_STG (INSTANCE_ID, CHUNK_ID, INVOICE_NUMBER);

