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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M (
    VENDOR_SITE_ID              NUMBER(18)      NOT NULL,
    VENDOR_ID                   NUMBER(18)      NOT NULL,
    VENDOR_SITE_CODE            VARCHAR2(30),
    ORG_ID                      NUMBER(18),
    PARTY_SITE_ID               NUMBER(18),
    LOCATION_ID                 NUMBER(18),
    TERMS_ID                    NUMBER(18),
    PAY_GROUP_LOOKUP_CODE       VARCHAR2(30),
    PAYMENT_METHOD_CODE         VARCHAR2(30),
    HOLD_ALL_PAYMENTS_FLAG      VARCHAR2(1),
    HOLD_FLAG                   VARCHAR2(1),
    INACTIVE_DATE               DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_POZ_SUP_SITES PRIMARY KEY (VENDOR_SITE_ID)
);
CREATE INDEX IDX_POZ_SITE_VENDOR ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M (VENDOR_ID);
CREATE INDEX IDX_POZ_SITE_TERMS  ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M (TERMS_ID);


