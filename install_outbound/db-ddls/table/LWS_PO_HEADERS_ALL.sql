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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_PO_HEADERS_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_PO_HEADERS_ALL (
    PO_HEADER_ID                NUMBER(18)      NOT NULL,
    SEGMENT1                    VARCHAR2(30),
    TYPE_LOOKUP_CODE            VARCHAR2(25),
    VENDOR_ID                   NUMBER(18),
    VENDOR_SITE_ID              NUMBER(18),
    TERMS_ID                    NUMBER(18),
    CURRENCY_CODE               VARCHAR2(15),
    ORG_ID                      NUMBER(18),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_PO_HEADERS_ALL PRIMARY KEY (PO_HEADER_ID)
);
CREATE INDEX IDX_PO_HDR_VENDOR ON LWS_CUSTOM_C2FO_SA.LWS_PO_HEADERS_ALL (VENDOR_ID);

--==============================================================================
-- HZ: TRADING COMMUNITY (PARTIES / CONTACTS)
--==============================================================================

