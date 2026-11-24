--------------------------------------------------------------------------------
-- C2FO ATP Staging Schema - Fusion mirror tables
-- Source: Oracle Fusion Applications 26A (core AP/TCA/IBY/ZX/CE/HR tables)
-- Purpose: BICC landing tables feeding outbound extracts + inbound validation
-- Column scope: query-referenced columns + common business/key columns + DFF attributes
-- Constraints: primary keys + indexes on common join columns (no FKs - loader owns integrity)
-- NOTE: view-sourced entities (_V) are flat landing tables here, not recreated views.
-- NOTE: bank-detail-only columns are intentionally held (see bank_details extract - pending).
-- NOTE: all mirror tables carry the LWS_ prefix; the outbound package reaches them
--       through Fusion-named bridging views (see c2fo_bridging_views.sql).
--------------------------------------------------------------------------------

--==============================================================================
-- AP: PAYABLES
--==============================================================================

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_EXTERNAL_PAYEES_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_EXTERNAL_PAYEES_ALL (
    EXT_PAYEE_ID                NUMBER(18)      NOT NULL,
    PAYEE_PARTY_ID              NUMBER(18),
    PARTY_SITE_ID               NUMBER(18),
    SUPPLIER_SITE_ID            NUMBER(18),
    ORG_ID                      NUMBER(18),
    ORG_TYPE                    VARCHAR2(30),
    PAYMENT_FUNCTION            VARCHAR2(30),
    DEFAULT_PAYMENT_METHOD_CODE VARCHAR2(30),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_IBY_EXT_PAYEES PRIMARY KEY (EXT_PAYEE_ID)
);
CREATE INDEX IDX_IBY_PAYEE_PARTY ON LWS_CUSTOM_C2FO_SA.LWS_IBY_EXTERNAL_PAYEES_ALL (PAYEE_PARTY_ID);


