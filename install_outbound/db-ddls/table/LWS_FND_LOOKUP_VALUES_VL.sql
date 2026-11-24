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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL (
    LOOKUP_TYPE                 VARCHAR2(30)    NOT NULL,
    LOOKUP_CODE                 VARCHAR2(30)    NOT NULL,
    MEANING                     VARCHAR2(240),
    DESCRIPTION                 VARCHAR2(240),
    TAG                         VARCHAR2(150),
    ENABLED_FLAG                VARCHAR2(1),
    START_DATE_ACTIVE           DATE,
    END_DATE_ACTIVE             DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_FND_LOOKUP_VALUES_VL PRIMARY KEY (LOOKUP_TYPE, LOOKUP_CODE)
);
