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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_CHECKS_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_CHECKS_ALL (
    CHECK_ID                    NUMBER(18)      NOT NULL,
    PAYMENT_ID                  NUMBER(18),
    CHECK_NUMBER                VARCHAR2(50),
    CHECK_DATE                  DATE,
    AMOUNT                      NUMBER,
    STATUS_LOOKUP_CODE          VARCHAR2(25),
    FUTURE_PAY_DUE_DATE         DATE,
    CURRENCY_CODE               VARCHAR2(15),
    VENDOR_ID                   NUMBER(18),
    VENDOR_SITE_ID              NUMBER(18),
    ORG_ID                      NUMBER(18),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_AP_CHECKS_ALL PRIMARY KEY (CHECK_ID)
);
CREATE INDEX IDX_AP_CHECKS_PAYMENT ON LWS_CUSTOM_C2FO_SA.LWS_AP_CHECKS_ALL (PAYMENT_ID);


