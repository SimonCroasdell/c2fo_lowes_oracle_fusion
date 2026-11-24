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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_USER;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_USER (
    K_ORG_ID            NUMBER(18)      NOT NULL,   -- HR_ALL_ORGANIZATION_UNITS.ORGANIZATION_ID (BU)
    K_VENDOR_ID         NUMBER(18)      NOT NULL,   -- POZ_SUPPLIERS_V.VENDOR_ID
    K_VENDOR_SITE_ID    NUMBER(18)      NOT NULL,   -- POZ_SUPPLIER_SITES_ALL_M.VENDOR_SITE_ID
    K_CONTACT_PARTY_ID  NUMBER(18)      NOT NULL,   -- HZ_PARTIES.PARTY_ID of the contact
    COMPANY_ID          VARCHAR2(60),   -- org|vendor|site
    DIVISION_ID         VARCHAR2(60),
    EMAIL_ADDRESS       VARCHAR2(320),  -- HZ_CONTACT_POINTS.EMAIL_ADDRESS
    FIRST_NAME          VARCHAR2(150),  -- HZ_PARTIES.PERSON_FIRST_NAME
    LAST_NAME           VARCHAR2(150),  -- HZ_PARTIES.PERSON_LAST_NAME
    TITLE               VARCHAR2(60),   -- HZ_PARTIES.PERSON_TITLE
    PHONE_NUMBER        VARCHAR2(60),   -- HZ_CONTACT_POINTS phone parts joined
    ADDRESS_1           VARCHAR2(240),  -- POZ_SUPPLIER_ADDRESS_V.ADDRESS1
    ADDRESS_2           VARCHAR2(240),  -- POZ_SUPPLIER_ADDRESS_V.ADDRESS2
    CITY                VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.CITY
    STATE               VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.STATE
    POSTAL_CODE         VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.POSTAL_CODE
    COUNTRY             VARCHAR2(60),   -- POZ_SUPPLIER_ADDRESS_V.COUNTRY
    ERP_BURST_ID        VARCHAR2(30),   -- literal 'user'
    CONSTRAINT PK_LWS_OB_USER PRIMARY KEY (K_ORG_ID, K_VENDOR_ID, K_VENDOR_SITE_ID, K_CONTACT_PARTY_ID)
);

--==============================================================================
-- PO  (erp_burst_id = 'po')  -- reconstructed from the EBS package (no Fusion
--      example available). ebs_* prefixes carried through as erp_* to match
--      Fusion naming. PK = PO_HEADER_ID.
--==============================================================================
