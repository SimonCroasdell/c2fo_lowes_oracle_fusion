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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_FEEDBACK;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_FEEDBACK (
    -- natural-key columns (NOT emitted to the CSV; used only for row identity)
    K_INVOICE_ID                NUMBER(18)      NOT NULL,   -- awarded AP_INVOICES_ALL.INVOICE_ID
    K_PAYMENT_NUM               NUMBER          NOT NULL,   -- AP_PAYMENT_SCHEDULES_ALL.PAYMENT_NUM
    -- file columns, in spec order ---------------------------------------------
    COMPANY_ID                  VARCHAR2(60),   -- org|vendor|site
    DIVISION_ID                 VARCHAR2(60),   -- blank
    INVOICE_ID                  VARCHAR2(120),  -- org|invoice_id|invoice_num (3-part; differs from invoice file)
    AMOUNT                      VARCHAR2(50),   -- INVOICE_AMOUNT - DISCOUNT_AMOUNT_AVAILABLE - TOTAL_TAX_AMOUNT
    CURRENCY                    VARCHAR2(15),   -- AP_INVOICES_ALL.INVOICE_CURRENCY_CODE
    PAYMENT_DUE_DATE            VARCHAR2(10),   -- YYYY-MM-DD (apsa.DUE_DATE)
    TRANSACTION_TYPE           VARCHAR2(1),    -- 1 STANDARD / 2 CREDIT
    VOUCHER_ID                  VARCHAR2(18),   -- AP_INVOICES_ALL.INVOICE_ID rendered
    FISCAL_YEAR                 VARCHAR2(20),   -- year of invoice_date (TODO_VERIFY GL_PERIODS)
    ADJUSTED_INVOICE_ID         VARCHAR2(18),   -- award.CM_INVOICE_ID (the C2FO credit memo)
    EXPECTED_AMOUNT_PAID        VARCHAR2(50),   -- AP_INVOICE_PAYMENTS_ALL.AMOUNT
    PAYMENT_TERM                VARCHAR2(120),  -- terms_id|NAME|DESCRIPTION
    PAYMENT_METHOD              VARCHAR2(30),   -- AP_INVOICES_ALL.PAYMENT_METHOD_CODE
    PAYMENT_INITIATION_DATE     VARCHAR2(10),   -- YYYY-MM-DD (AP_CHECKS_ALL.CHECK_DATE; IBY held) TODO_VERIFY
    PAYMENT_INITIATION_DOCUMENT VARCHAR2(50),   -- AP_CHECKS_ALL.CHECK_NUMBER (IBY held) TODO_VERIFY
    STATUS                      VARCHAR2(10),   -- Paid / Unpaid (from payment_status_flag)
    FUND_TYPE                   VARCHAR2(120),  -- blank (C2FO platform-supplied)
    FUND_PARTNER                VARCHAR2(120),  -- blank ERP-side / vendor_site|remit_to (TODO_VERIFY)
    ERP_BURST_ID                VARCHAR2(30),   -- literal 'feedback'
    CONSTRAINT PK_LWS_OB_FEEDBACK PRIMARY KEY (K_INVOICE_ID, K_PAYMENT_NUM)
);

--==============================================================================
-- CONTROL  (erp_burst_id = 'control')  -- 3 file columns
-- PK = FILE_NAME (one control row per emitted file). EBS-style build retained.
--==============================================================================
