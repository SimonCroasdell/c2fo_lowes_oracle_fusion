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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_ADDRESS_V;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_ADDRESS_V (
    VENDOR_ADDRESS_ID           NUMBER(18),
    VENDOR_ID                   NUMBER(18)      NOT NULL,
    PARTY_SITE_ID               NUMBER(18),
    ADDRESS_NAME                VARCHAR2(240),
    ADDRESS1                    VARCHAR2(240),
    ADDRESS2                    VARCHAR2(240),
    ADDRESS3                    VARCHAR2(240),
    ADDRESS4                    VARCHAR2(240),
    CITY                        VARCHAR2(60),
    STATE                       VARCHAR2(60),
    PROVINCE                    VARCHAR2(60),
    POSTAL_CODE                 VARCHAR2(60),
    COUNTRY                     VARCHAR2(60),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE
);
CREATE INDEX IDX_POZ_ADDR_VENDOR ON LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_ADDRESS_V (VENDOR_ID);

--==============================================================================
-- HR / FUN: ORG STRUCTURE
--==============================================================================

