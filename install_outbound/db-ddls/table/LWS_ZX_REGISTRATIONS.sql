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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_ZX_REGISTRATIONS;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_ZX_REGISTRATIONS (
    REGISTRATION_ID             NUMBER(18)      NOT NULL,
    PARTY_TAX_PROFILE_ID        NUMBER(18),
    REGISTRATION_NUMBER         VARCHAR2(50),
    REGISTRATION_STATUS_CODE    VARCHAR2(30),
    REGISTRATION_TYPE_CODE      VARCHAR2(30),
    TAX_REGIME_CODE             VARCHAR2(30),
    TAX                         VARCHAR2(30),
    EFFECTIVE_FROM              DATE,
    EFFECTIVE_TO                DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_ZX_REGISTRATIONS PRIMARY KEY (REGISTRATION_ID)
);
CREATE INDEX IDX_ZX_REG_PTP ON LWS_CUSTOM_C2FO_SA.LWS_ZX_REGISTRATIONS (PARTY_TAX_PROFILE_ID);


