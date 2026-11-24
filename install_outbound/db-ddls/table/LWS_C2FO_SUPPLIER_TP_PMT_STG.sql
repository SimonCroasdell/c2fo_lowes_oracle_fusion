--------------------------------------------------------------------------------
-- C2FO BICC landing table: Supplier Third-Party Payment Relationships
--------------------------------------------------------------------------------
-- Source PVO : FscmTopModelAM.PrcExtractAM.PozBiccExtractAM.SupplierThirdPartyPaymentExtractPVO
-- Base table : POZ_SUP_THIRDPARTY_PAYMENT_REL
-- Purpose    : raw VARCHAR2(4000) landing for the third-party-payment relationship
--              extract (who a supplier's payments are remitted to). Loaded by the
--              generic map-driven loader (LWS_C2FO_COMMON_PKG.load_csv_to_stg_proc);
--              the typed mirror (LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL) is populated
--              from here by lws_c2fo_bridge_pkg.bridge_supplier_tp_pmt_proc.
-- NOTE       : every column named in LWS_C2FO_PVO_COLUMN_MAP for this PVO MUST
--              exist here or the whole file load aborts with ORA-00904.
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_SUPPLIER_TP_PMT_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_SUPPLIER_TP_PMT_STG (
    TPP_RELATIONSHIP_ID        VARCHAR2(4000),
    VENDOR_SITE_ID             VARCHAR2(4000),
    REMIT_TO_SUPPLIER_ID       VARCHAR2(4000),
    REMIT_TO_ADDRESS_ID        VARCHAR2(4000),
    DEFAULT_RELATIONSHIP_FLAG  VARCHAR2(4000),
    DESCRIPTION                VARCHAR2(4000),
    FROM_DATE                  VARCHAR2(4000),
    TO_DATE                    VARCHAR2(4000),
    OBJECT_VERSION_NUMBER      VARCHAR2(4000),
    CREATED_BY                 VARCHAR2(4000),
    CREATION_DATE              VARCHAR2(4000),
    LAST_UPDATED_BY            VARCHAR2(4000),
    LAST_UPDATE_LOGIN          VARCHAR2(4000),
    LAST_UPDATE_DATE           VARCHAR2(4000),
    FILE_NAME                  VARCHAR2(500),
    SOURCE_CODE                VARCHAR2(100),
    INSTANCE_ID                VARCHAR2(100),
    RECORD_STATUS              VARCHAR2(30)  DEFAULT 'INPROCESS',
    CREATED_DATE               TIMESTAMP     DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_DATE          TIMESTAMP
);
/
