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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_FUN_ALL_BUSINESS_UNITS_V;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_FUN_ALL_BUSINESS_UNITS_V (
    BU_ID                       NUMBER(18)      NOT NULL,
    BU_NAME                     VARCHAR2(240),
    STATUS                      VARCHAR2(30),
    SET_ID                      NUMBER(18),
    DEFAULT_LEGAL_ENTITY_ID     NUMBER(18),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_FUN_ALL_BU_V PRIMARY KEY (BU_ID)
);

--==============================================================================
-- PO: PURCHASING
--==============================================================================

