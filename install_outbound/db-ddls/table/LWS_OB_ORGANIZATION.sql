--------------------------------------------------------------------------------
-- C2FO Outbound OUTPUT staging tables
-- Purpose: hold the formatted outbound rows that OIC selects from and delivers
--          as CSV files (invoice / organization / user / po / control).
-- Source : populated by LWS_OB_EXTRACT_ATP_PKG from the LWS_CUSTOM_C2FO_SA
--          BICC mirror (NOT live Fusion).
-- Layout : columns match the Fusion BIP file layouts exactly, in file order.
--          erp_burst_id is always the last data column of each file.
-- Typing : all file columns are VARCHAR2 - these are pre-formatted output
--          strings (numbers/dates already rendered), so OIC writes them
--          verbatim with no locale/format drift.
--          * Direct passthrough columns INHERIT the exact width of their source
--            column in c2fo_staging_ddl.sql (LWS_CUSTOM_C2FO_SA mirror).
--          * Composite / pipe-joined / pre-rendered columns are sized by
--            construction from their parts (see inline notes).
-- Keys   : NATURAL keys per table (no surrogate sort column). OIC applies its
--          own ORDER BY when it selects.
-- Grain  : the INVOICE file is at PAYMENT-INSTALLMENT grain - one row per
--          AP_PAYMENT_SCHEDULES_ALL (INVOICE_ID, PAYMENT_NUM), because the
--          payment due date lives on the installment, not the invoice.
--          PAYMENT_NUM therefore appears inside invoice_id and as voucher_line_id.
-- Lifecycle: each table is TRUNCATEd at the start of a run, so it always
--            reflects exactly what was sent on the last run until the next.
--------------------------------------------------------------------------------

--==============================================================================
-- INVOICE  (erp_burst_id = 'invoice')  -- 55 file columns (matches Outbound_V2 spec order)
-- PK = (INVOICE_ID, PAYMENT_NUM) held as separate key columns (not in file).
--==============================================================================
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_ORGANIZATION;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_ORGANIZATION (
    K_ORG_ID                    NUMBER(18)      NOT NULL,   -- HR_ALL_ORGANIZATION_UNITS.ORGANIZATION_ID (BU)
    K_VENDOR_ID                 NUMBER(18)      NOT NULL,   -- POZ_SUPPLIERS_V.VENDOR_ID
    K_VENDOR_SITE_ID            NUMBER(18)      NOT NULL,   -- POZ_SUPPLIER_SITES_ALL_M.VENDOR_SITE_ID
    K_PARTY_SITE_ID             NUMBER(18)      NOT NULL,   -- HZ_PARTY_SITES.PARTY_SITE_ID (address)
    COMPANY_ID                  VARCHAR2(60),   -- org|vendor|site
    COMPANY_NAME                VARCHAR2(360),  -- POZ_SUPPLIERS_V.VENDOR_NAME
    ADDRESS_1                   VARCHAR2(240),  -- POZ_SUPPLIER_ADDRESS_V.ADDRESS1
    ADDRESS_2                   VARCHAR2(240),  -- POZ_SUPPLIER_ADDRESS_V.ADDRESS2
    CITY                        VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.CITY
    STATE                       VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.STATE
    POSTAL_CODE                 VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.POSTAL_CODE
    COUNTRY                     VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.COUNTRY
    RESERVE_PERCENTAGE          VARCHAR2(30),
    RESERVE_AMOUNT              VARCHAR2(50),
    RESERVE_INVOICE_PRIORITY    VARCHAR2(30),
    RESERVE_BEFORE_ADJUSTMENTS  VARCHAR2(30),
    TAX_ID                      VARCHAR2(50),   -- ZX_REGISTRATIONS.REGISTRATION_NUMBER
    PAN_NUMBER                  VARCHAR2(30),
    GSTIN_NUMBER                VARCHAR2(30),
    BANK_ACCT_COUNTRY           VARCHAR2(60),   -- IBY_EXT_BANK_ACCOUNTS.COUNTRY_CODE / CE branch country
    MISSING_BANK_DETAILS        VARCHAR2(1),
    INCORPORATED_COUNTRY        VARCHAR2(60),
    ACCOUNT_GROUP               VARCHAR2(60),
    INDUSTRY_CODE               VARCHAR2(60),
    ENTERPRISE_TYPE             VARCHAR2(60),
    PAYMENT_TERM                VARCHAR2(50),   -- AP_TERMS_TL.NAME
    PAYMENT_TERM_DESC           VARCHAR2(240),  -- AP_TERMS_TL.DESCRIPTION
    ERP_BURST_ID                VARCHAR2(30),   -- literal 'org'
    CONSTRAINT PK_LWS_OB_ORGANIZATION PRIMARY KEY (K_ORG_ID, K_VENDOR_ID, K_VENDOR_SITE_ID, K_PARTY_SITE_ID)
);

--==============================================================================
-- USER  (erp_burst_id = 'user')  -- 14 file columns
-- PK = (ORG_ID, VENDOR_ID, VENDOR_SITE_ID, CONTACT_PARTY_ID).
--   Multiple users (contacts) per org are allowed. MOAC: org_id in the key so
--   the same site/contact emits one user row per business unit (per company_id).
--==============================================================================
