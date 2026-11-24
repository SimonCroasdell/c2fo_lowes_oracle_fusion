-- table_LWS_C2FO_AP_TERM_TRANSLATIONS_STG.sql
-- BICC landing (_STG) table for AP_PAYMENT_TERMS (PaymentTermHeaderTranslationPVO),
-- read by LWS_C2FO_BRIDGE_PKG.bridge_ap_terms_proc -> LWS_AP_TERMS_TL.
-- Columns = the FULL PVO attribute set listed in LWS_C2FO_PVO_COLUMN_MAP (all text;
-- typed on the way into the mirror). The loader builds its INSERT column list from
-- the map, so every mapped column MUST exist here or the file load raises ORA-00904.

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AP_TERM_TRANSLATIONS_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AP_TERM_TRANSLATIONS_STG (
    TERM_ID               VARCHAR2(4000),
    LANGUAGE              VARCHAR2(4000),
    SOURCE_LANG           VARCHAR2(4000),
    NAME                  VARCHAR2(4000),
    DESCRIPTION           VARCHAR2(4000),
    OBJECT_VERSION_NUMBER VARCHAR2(4000),
    CREATED_BY            VARCHAR2(4000),
    CREATION_DATE         VARCHAR2(4000),
    LAST_UPDATED_BY       VARCHAR2(4000),
    LAST_UPDATE_DATE      VARCHAR2(4000),
    LAST_UPDATE_LOGIN     VARCHAR2(4000),
    FILE_NAME             VARCHAR2(500),
    SOURCE_CODE           VARCHAR2(100),
    INSTANCE_ID           VARCHAR2(100),
    RECORD_STATUS         VARCHAR2(30) DEFAULT 'INPROCESS',
    CREATED_DATE          TIMESTAMP DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_DATE     TIMESTAMP
);
/
