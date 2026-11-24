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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_PAYMENTS_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_PAYMENTS_ALL (
    PAYMENT_ID                  NUMBER(18)      NOT NULL,
    PAYMENT_STATUS              VARCHAR2(30),
    PAYMENT_DATE                DATE,
    PAYMENT_AMOUNT              NUMBER,
    PAYMENT_CURRENCY_CODE       VARCHAR2(15),
    PAYMENT_METHOD_CODE         VARCHAR2(30),
    ORG_ID                      NUMBER(18),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_IBY_PAYMENTS_ALL PRIMARY KEY (PAYMENT_ID)
);

--==============================================================================
-- CE: CASH MANAGEMENT (BANKS / BRANCHES) - view-sourced -> flat tables
-- (bank-detail-only columns intentionally held pending bank_details extract)
--==============================================================================

