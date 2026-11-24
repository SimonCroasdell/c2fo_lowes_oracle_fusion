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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_PO;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_PO (
    K_PO_HEADER_ID              NUMBER(18)      NOT NULL,   -- PO_HEADERS_ALL.PO_HEADER_ID
    COMPANY_ID                  VARCHAR2(60),   -- org|vendor|site
    DIVISION_ID                 VARCHAR2(60),
    PO_ID                       VARCHAR2(80),   -- org|vendor|site|po_header_id
    AMOUNT                      VARCHAR2(50),
    CURRENCY                    VARCHAR2(15),   -- PO_HEADERS_ALL.CURRENCY_CODE
    CREATE_DATE                 VARCHAR2(10),   -- YYYY-MM-DD
    APPROVED_DATE               VARCHAR2(10),   -- YYYY-MM-DD
    SHIP_DATE                   VARCHAR2(10),   -- YYYY-MM-DD
    SHIP_ORIG_COUNTRY           VARCHAR2(60),   -- HR_LOCATIONS_ALL.COUNTRY
    SHIP_ORIG_STATE             VARCHAR2(90),   -- HR_LOCATIONS_ALL.REGION_2
    ESTIMATED_ARRIVAL_DATE      VARCHAR2(10),   -- YYYY-MM-DD
    ACTUAL_ARRIVAL_DATE         VARCHAR2(10),   -- YYYY-MM-DD
    SUPPLIER_COUNTRY            VARCHAR2(60),
    COMPANY_CODE                VARCHAR2(240),  -- HR_ALL_ORGANIZATION_UNITS.NAME
    WAREHOUSE_CODE              VARCHAR2(150),  -- HR_LOCATIONS_ALL.LOCATION_CODE
    ERP_ORG_ID                  VARCHAR2(18),
    ERP_PONUMBER                VARCHAR2(30),   -- PO_HEADERS_ALL.SEGMENT1
    ERP_PO_HEADER_ID            VARCHAR2(18),
    ERP_SUPPLIER                VARCHAR2(360),  -- POZ_SUPPLIERS_V.VENDOR_NAME
    ERP_SUPPLIER_NUMBER         VARCHAR2(30),   -- POZ_SUPPLIERS_V.SEGMENT1
    ERP_VENDOR_ID               VARCHAR2(18),
    ERP_SUPPLIERSITE            VARCHAR2(30),   -- POZ_SUPPLIER_SITES_ALL_M.VENDOR_SITE_CODE
    ERP_VENDOR_SITE_ID          VARCHAR2(18),
    ERP_POTYPE                  VARCHAR2(25),   -- PO_HEADERS_ALL.TYPE_LOOKUP_CODE
    ERP_PODATE                  VARCHAR2(10),   -- YYYY-MM-DD
    ERP_BILLTO_LOC              VARCHAR2(150),  -- HR_LOCATIONS_ALL.LOCATION_CODE
    ERP_BUYER                   VARCHAR2(240),
    ERP_AUTHORIZATION_STATUS    VARCHAR2(25),
    ERP_TERMS                   VARCHAR2(50),   -- AP_TERMS_TL.NAME
    ERP_CLOSED_CODE             VARCHAR2(25),
    ERP_SHIP_TO_LOCATION_ID     VARCHAR2(18),
    ERP_BURST_ID                VARCHAR2(30),   -- literal 'po'
    CONSTRAINT PK_LWS_OB_PO PRIMARY KEY (K_PO_HEADER_ID)
);

--==============================================================================
-- FEEDBACK  (erp_burst_id = 'feedback')  -- 18 file columns (17 per the spec's
--   count, which excludes erp_burst_id). Reports payment status of awarded
--   invoices. Driven off LWS_AP_C2FO_AWARD_STAGING (PROCESS_FLAG='Y'), so the
--   grain is one row per AWARDED invoice installment (award INVOICE_ID +
--   PAYMENT_NUM). PK held as those two key columns (not in the file).
--==============================================================================
