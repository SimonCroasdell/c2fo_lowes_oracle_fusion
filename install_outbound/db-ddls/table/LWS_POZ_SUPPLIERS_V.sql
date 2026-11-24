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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V (
    VENDOR_ID                   NUMBER(18)      NOT NULL,
    PARTY_ID                    NUMBER(18),
    VENDOR_NAME                 VARCHAR2(360),
    SEGMENT1                    VARCHAR2(30),
    VENDOR_TYPE_LOOKUP_CODE     VARCHAR2(30),
    ENABLED_FLAG                VARCHAR2(1),
    START_DATE_ACTIVE           DATE,
    END_DATE_ACTIVE             DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    -- Supplier descriptive flexfield attributes (SupplierExtractPVO Attribute1-20).
    -- Sourced 1:1 from LWS_C2FO_SUPPLIERS_STG.ATTRIBUTE1-20 by the supplier bridge.
    -- Held as VARCHAR2 to match the all-text STG landing (no typing at this layer).
    ATTRIBUTE1                  VARCHAR2(4000),
    ATTRIBUTE2                  VARCHAR2(4000),
    ATTRIBUTE3                  VARCHAR2(4000),
    ATTRIBUTE4                  VARCHAR2(4000),
    ATTRIBUTE5                  VARCHAR2(4000),
    ATTRIBUTE6                  VARCHAR2(4000),
    ATTRIBUTE7                  VARCHAR2(4000),
    ATTRIBUTE8                  VARCHAR2(4000),
    ATTRIBUTE9                  VARCHAR2(4000),
    ATTRIBUTE10                 VARCHAR2(4000),
    ATTRIBUTE11                 VARCHAR2(4000),
    ATTRIBUTE12                 VARCHAR2(4000),
    ATTRIBUTE13                 VARCHAR2(4000),
    ATTRIBUTE14                 VARCHAR2(4000),
    ATTRIBUTE15                 VARCHAR2(4000),
    ATTRIBUTE16                 VARCHAR2(4000),
    ATTRIBUTE17                 VARCHAR2(4000),
    ATTRIBUTE18                 VARCHAR2(4000),
    ATTRIBUTE19                 VARCHAR2(4000),
    ATTRIBUTE20                 VARCHAR2(4000),
    CONSTRAINT PK_POZ_SUPPLIERS_V PRIMARY KEY (VENDOR_ID)
);
CREATE INDEX IDX_POZ_SUP_PARTY ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V (PARTY_ID);

-- NOTE: the ATTRIBUTE1-20 add-column guard for already-installed mirrors is a
-- separate anonymous block -> anon_LWS_POZ_SUPPLIERS_V_add_attributes.sql
-- (run it immediately after this file).


