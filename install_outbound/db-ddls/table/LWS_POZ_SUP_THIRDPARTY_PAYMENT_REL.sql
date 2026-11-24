--------------------------------------------------------------------------------
-- C2FO ATP Staging Schema - Fusion mirror table
-- Entity : POZ_SUP_THIRDPARTY_PAYMENT_REL (supplier third-party payment relationship)
-- Source : SupplierThirdPartyPaymentExtractPVO  ->  LWS_C2FO_SUPPLIER_TP_PMT_STG
-- Purpose: typed mirror reached by the outbound package through the Fusion-named
--          bridging view POZ_SUP_THIRDPARTY_PAYMENT_REL. Links a supplier site to
--          the remit-to (third-party) supplier its payments are directed to.
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL (
    TPP_RELATIONSHIP_ID         NUMBER(18)      NOT NULL,
    VENDOR_SITE_ID              NUMBER(18),
    REMIT_TO_SUPPLIER_ID        NUMBER(18),
    REMIT_TO_ADDRESS_ID         NUMBER(18),
    DEFAULT_RELATIONSHIP_FLAG   VARCHAR2(1),
    DESCRIPTION                 VARCHAR2(240),
    FROM_DATE                   DATE,
    TO_DATE                     DATE,
    OBJECT_VERSION_NUMBER       NUMBER,
    CREATED_BY                  VARCHAR2(64),
    CREATION_DATE               DATE,
    LAST_UPDATED_BY             VARCHAR2(64),
    LAST_UPDATE_LOGIN           VARCHAR2(32),
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_POZ_SUP_TPP_REL PRIMARY KEY (TPP_RELATIONSHIP_ID)
);
CREATE INDEX IDX_POZ_TPP_VENDOR_SITE ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL (VENDOR_SITE_ID);
CREATE INDEX IDX_POZ_TPP_REMIT_SUPP  ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL (REMIT_TO_SUPPLIER_ID);
