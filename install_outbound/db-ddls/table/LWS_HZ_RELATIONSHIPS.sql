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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_HZ_RELATIONSHIPS;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_HZ_RELATIONSHIPS (
    RELATIONSHIP_ID             NUMBER(18)      NOT NULL,
    SUBJECT_ID                  NUMBER(18),
    SUBJECT_TABLE_NAME          VARCHAR2(30),
    OBJECT_ID                   NUMBER(18),
    OBJECT_TABLE_NAME           VARCHAR2(30),
    RELATIONSHIP_CODE           VARCHAR2(30),
    RELATIONSHIP_TYPE           VARCHAR2(30),
    STATUS                      VARCHAR2(1),
    START_DATE                  DATE,
    END_DATE                    DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_HZ_RELATIONSHIPS PRIMARY KEY (RELATIONSHIP_ID)
);
CREATE INDEX IDX_HZ_REL_SUBJECT ON LWS_CUSTOM_C2FO_SA.LWS_HZ_RELATIONSHIPS (SUBJECT_ID);
CREATE INDEX IDX_HZ_REL_OBJECT  ON LWS_CUSTOM_C2FO_SA.LWS_HZ_RELATIONSHIPS (OBJECT_ID);


