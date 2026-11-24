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
DROP SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_OB_RUN_SEQ;
CREATE SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_OB_RUN_SEQ START WITH 1 INCREMENT BY 1 NOCACHE;

--==============================================================================
-- PROJECT CONFIG  -- now the key/value LWS_C2FO_CONFIG table, shipped separately
-- in c2fo_config_kv_ddl.sql and shared by all three flows. The OCI object-storage
-- settings the file writer reads (load_ob_config) live under CONFIG_GROUP 'COMMON';
-- the outbound notification topic under 'OUTBOUND'. Install c2fo_config_kv_ddl.sql
-- once; no config table is created here anymore.
--==============================================================================
