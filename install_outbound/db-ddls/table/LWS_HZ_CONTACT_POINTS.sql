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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_HZ_CONTACT_POINTS;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_HZ_CONTACT_POINTS (
    CONTACT_POINT_ID            NUMBER(18)      NOT NULL,
    CONTACT_POINT_TYPE          VARCHAR2(30),
    OWNER_TABLE_NAME            VARCHAR2(30),
    OWNER_TABLE_ID              NUMBER(18),
    STATUS                      VARCHAR2(1),
    PRIMARY_FLAG                VARCHAR2(1),
    EMAIL_ADDRESS               VARCHAR2(320),
    PHONE_COUNTRY_CODE          VARCHAR2(10),
    PHONE_AREA_CODE             VARCHAR2(20),
    PHONE_NUMBER                VARCHAR2(40),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_HZ_CONTACT_POINTS PRIMARY KEY (CONTACT_POINT_ID)
);
CREATE INDEX IDX_HZ_CP_OWNER ON LWS_CUSTOM_C2FO_SA.LWS_HZ_CONTACT_POINTS (OWNER_TABLE_NAME, OWNER_TABLE_ID);

--==============================================================================
-- ZX: TAX
--==============================================================================

