--------------------------------------------------------------------------------
-- C2FO AWARD REVERSAL landing table
-- Purpose: one row per invoice named in a C2FO reversal file. Holds (1) the raw
--          reversal-file columns 1:1 with the file header, (2) the control file's
--          CORRELATION_ID (echoed on the ack), (3) the award refs RESOLVED from
--          LWS_C2FO_AWARD_DATA (erp_invoice_id, cm_invoice_id/num, income, the
--          ORIG_* pre-acceleration schedule), (4) a REV_REQUIRED gate (income<>0
--          => an offsetting invoice is needed; income=0 => due-date restore only),
--          (5) the reversal state machine, and (6) the per-row acknowledgement
--          Status/Message the ack file is built from.
-- Why a separate table (not reuse LWS_C2FO_AWARD_DATA): the award table is the
--          record of truth for the ORIGINAL award; it is STAMPED on a successful
--          reversal (REVERSED_FLAG/_DATE/_REASON) but the inbound reversal rows, the
--          C2FO ack contract and the reversal-run state are kept here so they do not
--          pollute the award record. (Design decision 2026-10-09.)
-- Source : the OIC LWS_C2FO_REVERSAL_FILE_LOAD integration lists the OCI bucket,
--          reads the 3-col control file (file_name,row_count,correlation_ID), then
--          calls load_reversal_file (DBMS_CLOUD external table -> name-matched
--          INSERT). No live Fusion access from the DB (client ruling: OIC owns ERP
--          REST); the DB prepares/records and writes the ack files to OCI only.
-- Naming : all custom objects carry the LWS_ prefix; owner LWS_CUSTOM_C2FO_SA.
-- Key    : identity of one reversal row = the file's VOUCHER_ID + VOUCHER_LINE_ID
--          (= the award VOUCHER_ID / PAYMENT_NUM) within one INSTANCE_ID (the OIC
--          loader run). PK (INSTANCE_ID, VOUCHER_ID, VOUCHER_LINE_ID).
-- Spec   : the 11-column SAMPLE layout (spec sheet lists 10 and omits VOUCHER_LINE_ID;
--          the installment is required to match a single award row, so the sample's
--          column 4 is built in - OPEN ISSUE #2, confirm official with C2FO).
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA (
    -- reversal file columns 1..11 (file/header order; names match the CSV header) --
    COMPANY_ID              VARCHAR2(240 BYTE),   -- 1  ORG_ID|VENDOR_ID|VENDOR_SITE_ID composite
    INVOICE_ID              VARCHAR2(240 BYTE),   -- 2  ORG_ID|INVOICE_ID|INVOICE_NUM composite (reference)
    VOUCHER_ID              NUMBER NOT NULL,      -- 3  AP_INVOICES_ALL.INVOICE_ID (numeric; match key)
    VOUCHER_LINE_ID         NUMBER NOT NULL,      -- 4  AP_PAYMENT_SCHEDULES_ALL.PAYMENT_NUM (installment; match key) [sample-only]
    FISCAL_YEAR             NUMBER,               -- 5
    ORIGINAL_DUE_DATE       VARCHAR2(25 BYTE),    -- 6  pre-acceleration due date (also on the award row)
    TRANSACTION_TYPE        NUMBER,               -- 7  1=base(+) 2=adjustment(-)
    ERP_LEGAL_ENTITY        VARCHAR2(50 BYTE),    -- 8  ORG_ID (labelled legal entity; is the BU/org)
    ERP_VENDOR_ID           NUMBER,               -- 9  SEGMENT1 (POZ_SUPPLIERS) parent supplier number
    FUND_TYPE               VARCHAR2(50 BYTE),    -- 10 C2FO-generated; required only for DSF
    REVERSAL_REASON         VARCHAR2(400 BYTE),   -- 11 C2FO-generated free text (-> REVERSED_REASON + ack)
    -- resolved award refs (filled by resolve_reversals from LWS_C2FO_AWARD_DATA) ----
    AWARD_INVOICE_ID        VARCHAR2(240 BYTE),   -- the matched award's composite INVOICE_ID (award PK part)
    AWARD_INSTANCE_ID       VARCHAR2(150 BYTE),   -- the matched award's INSTANCE_ID (award PK part)
    ERP_INVOICE_ID          NUMBER,               -- resolved AP_INVOICES_ALL.INVOICE_ID (due-date restore target)
    ERP_ORG_ID              NUMBER,               -- resolved AP_INVOICES_ALL.ORG_ID
    VENDOR_ID               NUMBER,               -- resolved award VENDOR_ID (FBDI supplier name/number)
    ERP_VENDOR_SITE_ID      NUMBER,               -- resolved award ERP_VENDOR_SITE_ID (FBDI supplier site code)
    CM_INVOICE_ID           NUMBER,               -- the award's created CM invoice id (reference)
    CM_INVOICE_NUM          VARCHAR2(50 BYTE),    -- the award's CM number (offset is numbered off this)
    INCOME                  NUMBER,               -- award income (gates REV_REQUIRED; sign/amount of the offset)
    ERP_TAX_RATE            NUMBER,               -- award tax rate (gross the offset header, mirror the CM)
    CURRENCY                VARCHAR2(10 BYTE),     -- award currency (offset invoice currency)
    SOURCE_CODE             VARCHAR2(30 BYTE),     -- award invoice source (offset import source)
    TERMS_ID                NUMBER,                -- award payment terms (offset derives the same due date)
    -- the pre-acceleration schedule to RESTORE (copied from the award ORIG_* cols) --
    RESTORE_DUE_DATE          VARCHAR2(25 BYTE),  -- = award ORIGINAL_DUE_DATE (the value to put back)
    ORIG_FIRST_DISCOUNT_DATE  VARCHAR2(25 BYTE),
    ORIG_FIRST_DISCOUNT_AMT   NUMBER,
    ORIG_SECOND_DISCOUNT_DATE VARCHAR2(25 BYTE),
    ORIG_SECOND_DISCOUNT_AMT  NUMBER,
    ORIG_THIRD_DISCOUNT_DATE  VARCHAR2(25 BYTE),
    ORIG_THIRD_DISCOUNT_AMT   NUMBER,
    -- reversal gate / outcome -----------------------------------------------------
    REV_REQUIRED            VARCHAR2(1) DEFAULT 'Y', -- 'Y' income<>0 (offset needed) | 'N' income=0 (DD restore only)
    OFFSET_INVOICE_NUM      VARCHAR2(50 BYTE),    -- the created offsetting invoice number (<CM_INVOICE_NUM>-REV)
    OFFSET_STATUS           VARCHAR2(40 BYTE),    -- offset half outcome (OK / FAILED / SKIP)
    DD_STATUS               VARCHAR2(40 BYTE),    -- due-date-restore half outcome (OK / FAILED / SKIP)
    HTTP_STATUS             NUMBER,               -- last REST status (OIC-reported)
    -- run / batch tracking (INSTANCE_ID = the OIC loader run id; CORRELATION_ID from control) --
    INSTANCE_ID             VARCHAR2(150 BYTE) NOT NULL, -- OIC loader run id (batch key); part of PK
    CHUNK_ID                NUMBER,               -- FBDI import chunk (chunk_rev_offsets, BU+source aware); OIC While 1..N loop key
    CORRELATION_ID          VARCHAR2(240 BYTE),   -- UUID from the control file; echoed on the ack control
    FILE_NAME               VARCHAR2(200 BYTE),   -- source reversal file name (audit)
    -- state machine (mirrors the award state machine) ------------------------------
    RECORD_STATUS           VARCHAR2(50 BYTE),    -- N not processed | Y success | E error (terminal for this run)
    STAGE                   VARCHAR2(200 BYTE),   -- STAGED -> RESOLVED -> REVERSED (or E on resolve/offset/dd failure)
    ERROR_CODE              VARCHAR2(200 BYTE),
    ERROR_MESSAGE           VARCHAR2(2000 BYTE),
    -- acknowledgement (built into the 12-col ack CSV by write_reversal_ack) ---------
    ACK_STATUS              VARCHAR2(10 BYTE),    -- Success | Error (per-invoice ack Status)
    ACK_MESSAGE             VARCHAR2(2000 BYTE),  -- ack Status Message
    -- audit -----------------------------------------------------------------------
    CREATION_DATE           TIMESTAMP DEFAULT SYSTIMESTAMP,
    CREATED_BY              VARCHAR2(64 BYTE),
    LAST_UPDATE_DATE        TIMESTAMP DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_BY         VARCHAR2(64 BYTE),
    CONSTRAINT PK_LWS_C2FO_REVERSAL_DATA PRIMARY KEY (INSTANCE_ID, VOUCHER_ID, VOUCHER_LINE_ID)
);

-- Batch + status scan (resolve, work-set builders, ack writer, run reporting).
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REVERSAL_DATA_INST_STATUS
    ON LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA (INSTANCE_ID, RECORD_STATUS);

-- Award-match scan (resolve_reversals matches on voucher_id + voucher_line_id).
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REVERSAL_DATA_VOUCHER
    ON LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA (VOUCHER_ID, VOUCHER_LINE_ID);

-- Per-chunk scan (REV_FBDI_V filter, build_fbdi_rev_set, flip, diff - OIC loops chunks).
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_REVERSAL_DATA_CHUNK
    ON LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA (INSTANCE_ID, CHUNK_ID);
