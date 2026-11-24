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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_TERMS_TL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_TERMS_TL (
    TERM_ID                     NUMBER(18)      NOT NULL,
    LANGUAGE                    VARCHAR2(4)     NOT NULL,
    NAME                        VARCHAR2(50),
    DESCRIPTION                 VARCHAR2(240),
    SOURCE_LANG                 VARCHAR2(4),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_AP_TERMS_TL PRIMARY KEY (TERM_ID, LANGUAGE)
);


