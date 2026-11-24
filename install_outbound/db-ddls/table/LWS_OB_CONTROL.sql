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
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_CONTROL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_OB_CONTROL (
    FILE_NAME       VARCHAR2(100)   NOT NULL,
    ROW_COUNT       VARCHAR2(30),
    ERP_BURST_ID    VARCHAR2(30),   -- literal 'control'
    CONSTRAINT PK_LWS_OB_CONTROL PRIMARY KEY (FILE_NAME)
);

--==============================================================================
-- RUN LOG  -- one row per outbound run, for OIC monitoring / audit
--==============================================================================
