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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_EXT_BANK_ACCOUNTS;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_EXT_BANK_ACCOUNTS (
    EXT_BANK_ACCOUNT_ID         NUMBER(18)      NOT NULL,
    BANK_ID                     NUMBER(18),
    BRANCH_ID                   NUMBER(18),
    CURRENCY_CODE               VARCHAR2(15),
    COUNTRY_CODE                VARCHAR2(2),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_IBY_EXT_BANK_ACCTS PRIMARY KEY (EXT_BANK_ACCOUNT_ID)
);
CREATE INDEX IDX_IBY_EBA_BANK   ON LWS_CUSTOM_C2FO_SA.LWS_IBY_EXT_BANK_ACCOUNTS (BANK_ID);
CREATE INDEX IDX_IBY_EBA_BRANCH ON LWS_CUSTOM_C2FO_SA.LWS_IBY_EXT_BANK_ACCOUNTS (BRANCH_ID);


