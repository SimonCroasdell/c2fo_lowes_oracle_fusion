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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_INVOICE;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_INVOICE (
    -- natural-key columns (NOT emitted to the CSV; used only for row identity)
    K_INVOICE_ID                        NUMBER(18)      NOT NULL,   -- AP_INVOICES_ALL.INVOICE_ID
    K_PAYMENT_NUM                       NUMBER          NOT NULL,   -- AP_PAYMENT_SCHEDULES_ALL.PAYMENT_NUM
    -- file columns, in Fusion file order --------------------------------------
    COMPANY_ID                          VARCHAR2(60),   -- org|vendor|site = 3x NUMBER(18)+2 pipes
    DIVISION_ID                         VARCHAR2(60),   -- always null/blank in current DM
    INVOICE_ID                          VARCHAR2(120),  -- org|voucher_id|payment_num|invoice_num (INVOICE_NUM 50)
    AMOUNT                              VARCHAR2(50),   -- rendered NUMBER
    CURRENCY                            VARCHAR2(15),   -- AP_INVOICES_ALL.INVOICE_CURRENCY_CODE
    PAYMENT_DUE_DATE                    VARCHAR2(10),   -- YYYY-MM-DD
    TRANSACTION_TYPE                    VARCHAR2(1),    -- 1 / 2
    TRANSACTION_DATE                    VARCHAR2(10),   -- YYYY-MM-DD
    POSTING_DATE                        VARCHAR2(10),   -- YYYY-MM-DD (GL_DATE)
    VOUCHER_ID                          VARCHAR2(18),   -- INVOICE_ID rendered
    VOUCHER_LINE_ID                     VARCHAR2(18),   -- PAYMENT_NUM rendered
    FISCAL_YEAR                         VARCHAR2(20),
    PAYMENT_TERM                        VARCHAR2(120),  -- terms_id|NAME(50)|DESCRIPTION(240) trimmed; sized by construction
    PAYMENT_METHOD                      VARCHAR2(30),   -- AP_INVOICES_ALL.PAYMENT_METHOD_CODE
    ADJ_INVOICE_ID                      VARCHAR2(120),  -- same shape as INVOICE_ID
    ADJ_REASON_CODE                     VARCHAR2(240),  -- AP_INVOICES_ALL.DESCRIPTION
    DESCRIPTION                         VARCHAR2(240),  -- AP_INVOICES_ALL.DESCRIPTION
    VAT_AMOUNT                          VARCHAR2(50),   -- AP_INVOICES_ALL.TOTAL_TAX_AMOUNT (signed by transaction_type)
    AMOUNT_GROSSVAT                     VARCHAR2(50),
    AMOUNT_NETVAT                       VARCHAR2(50),
    VAT_TO_BE_DISCOUNTED                VARCHAR2(50),
    BUYER_NAME                          VARCHAR2(240),  -- HR_ALL_ORGANIZATION_UNITS.NAME
    BUYER_ADDRESS                       VARCHAR2(600),  -- concat of HR_LOCATIONS_ALL address parts
    BUYER_TAX_ID                        VARCHAR2(50),   -- ZX_REGISTRATIONS.REGISTRATION_NUMBER
    LOCAL_CURRENCY_KEY                  VARCHAR2(15),   -- AP_INVOICES_ALL.PAYMENT_CURRENCY_CODE
    LOCAL_CURRENCY_RATE                 VARCHAR2(50),
    LOCAL_CURRENCY_ORIGINAL_INV_AMOUNT  VARCHAR2(50),
    LOCAL_CURRENCY_ORIGINAL_VAT         VARCHAR2(50),
    MARKET_TYPE                         VARCHAR2(60),
    PO_ID                               VARCHAR2(80),   -- org|vendor|site|po_header_id = 4x NUMBER(18)+3 pipes
    MISSING_BANK_DETAILS_FLAG           VARCHAR2(1),
    ERP_LEGAL_ENTITY                    VARCHAR2(240),  -- HR_ALL_ORGANIZATION_UNITS.NAME
    ERP_REFERENCE_NUMBER                VARCHAR2(50),
    ERP_VENDOR_ID                       VARCHAR2(18),   -- POZ_SUPPLIERS_V.VENDOR_ID rendered
    ERP_TAX_CODE                        VARCHAR2(150),  -- ZX_LINES.TAX_RATE_CODE
    ERP_PAYMENT_TERM                    VARCHAR2(50),   -- AP_TERMS_TL.NAME
    ERP_PAYMENT_TERM_DESC               VARCHAR2(240),  -- AP_TERMS_TL.DESCRIPTION
    ERP_PO_PAYMENT_TERM                 VARCHAR2(50),   -- AP_TERMS_TL.NAME (via PO)
    ERP_PO_PAYMENT_TERM_DESC            VARCHAR2(240),  -- AP_TERMS_TL.DESCRIPTION (via PO)
    ERP_TERMS_DATE                      VARCHAR2(10),   -- YYYY-MM-DD (AP_INVOICES_ALL.TERMS_DATE)
    ERP_NET_DUE_DATE                    VARCHAR2(10),   -- YYYY-MM-DD (AP_PAYMENT_SCHEDULES_ALL.DUE_DATE)
    ERP_INVOICE_AMOUNT                  VARCHAR2(50),   -- AP_INVOICES_ALL.INVOICE_AMOUNT rendered
    ERP_DISCOUNT_BASE_AMOUNT            VARCHAR2(50),
    ERP_CASH_DISCOUNT_AMOUNT            VARCHAR2(50),
    ERP_PAYEE                           VARCHAR2(18),   -- AP_INVOICES_ALL.REMIT_TO_SUPPLIER_ID rendered
    ERP_VENDOR_SITE_ID                  VARCHAR2(18),   -- POZ_SUPPLIER_SITES_ALL_M.VENDOR_SITE_ID rendered
    ERP_VENDOR_SITE_CODE                VARCHAR2(30),   -- POZ_SUPPLIER_SITES_ALL_M.VENDOR_SITE_CODE
    ERP_INVOICE_ID                      VARCHAR2(18),   -- AP_INVOICES_ALL.INVOICE_ID rendered
    ERP_INVOICE_NUM                     VARCHAR2(50),   -- AP_INVOICES_ALL.INVOICE_NUM
    ERP_PAY_GROUP                       VARCHAR2(30),   -- AP_INVOICES_ALL.PAY_GROUP_LOOKUP_CODE
    ERP_SUP_PAY_PRIORITY                VARCHAR2(50),
    ERP_TAX_RATE                        VARCHAR2(50),   -- rendered NUMBER (percentage_rate)
    ERP_DOC_TYPE                        VARCHAR2(25),   -- AP_INVOICES_ALL.INVOICE_TYPE_LOOKUP_CODE
    ERP_BUSINESS_UNIT                   VARCHAR2(240),  -- HR_ALL_ORGANIZATION_UNITS.NAME
    ERP_SUPPLIER_NUMBER                 VARCHAR2(30),   -- POZ_SUPPLIERS_V.SEGMENT1
    ERP_PURPOSE_PAYMENT                 VARCHAR2(240),  -- purpose code/description; custom logic if not in ERP
    ERP_BURST_ID                        VARCHAR2(30),   -- literal 'invoice'
    CONSTRAINT PK_LWS_OB_INVOICE PRIMARY KEY (K_INVOICE_ID, K_PAYMENT_NUM)
);

--==============================================================================
-- ORGANIZATION  (erp_burst_id = 'org')  -- 24 file columns
-- PK = (ORG_ID, VENDOR_ID, VENDOR_SITE_ID, PARTY_SITE_ID).
--   MOAC: a supplier site can be paid from multiple business units, so the same
--   VENDOR_SITE_ID emits one org row PER ORG_ID (one per company_id sent).
--   "Emit a row per address" -> PARTY_SITE_ID (the address) is in the key too.
--==============================================================================
