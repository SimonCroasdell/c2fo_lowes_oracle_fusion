--------------------------------------------------------------------------------
-- C2FO Inbound AWARD landing table (full-fidelity record of truth)
-- Purpose: land the ENTIRE C2FO award file (all 74 columns, one row per awarded
--          invoice installment) into a single durable table that serves three
--          jobs: (1) drive the type-2 inbound process (create credit memo +
--          accelerate the original invoice), (2) reporting, (3) award reversal.
-- Source : the OIC scheduled loader lists the OCI bucket, reads the tiny control
--          file, then calls the DB (DBMS_CLOUD.COPY_DATA) to bulk-load the award
--          CSV straight into this table. Validation reads the LWS_CUSTOM_C2FO_SA
--          mirror via the Fusion-named bridging views (60_bridging_views.sql).
--          No live Fusion access from the DB (client ruling: OIC owns ERP REST).
-- Naming : ported from the MSHS baseline XX_AP_C2FO_AWARD_DATA. The CF_ column
--          prefix is DROPPED and columns match the award-file field names 1:1
--          (self-documenting COPY_DATA field_list). custom_name(s) -> ATTRIBUTE1..5.
--          All custom objects carry the LWS_ prefix; owner LWS_CUSTOM_C2FO_SA.
-- Key    : identity of one award = the file's INVOICE_ID field (the composite
--          ORG_ID|INVOICE_ID|PAYMENT_NUM|INVOICE_NUM) + INSTANCE_ID (the OIC
--          loader run). PK (INVOICE_ID, INSTANCE_ID) as in the baseline.
-- State  : RECORD_STATUS / STAGE / ERROR_CODE / ERROR_MESSAGE (ported baseline
--          state machine). Processing outcomes are held in EXPLICIT columns
--          (resolved keys + CM/DD outcome + reversal) added below the file cols.
-- Dedup  : one incoming award (same composite INVOICE_ID) is rejected only when
--          it repeats within the SAME batch, or a PRIOR batch processed it
--          successfully and it has not since been reversed. A prior ERROR, or a
--          prior success later REVERSED, is accepted (legit re-award). A manual
--          Fusion reversal that never updated this table is caught by a mirror
--          cross-check at validation (CM gone/cancelled or due date reverted).
-- Shared : configuration lives in the key/value LWS_C2FO_CONFIG table
--          (20_config_kv.sql), 'COMMON' obj-storage triple. Install once.
--------------------------------------------------------------------------------

--==============================================================================
-- AWARD DATA  -- full award-file record of truth. One row per awarded installment.
--==============================================================================
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA (
    -- award file columns 1..74 (in file order; names match the CSV header) ------
    COMPANY_ID                          VARCHAR2(240 BYTE),   -- 1  ORG_ID|VENDOR_ID|VENDOR_SITE_ID
    COMPANY_NAME                        VARCHAR2(240 BYTE),   -- 2
    DIVISION_ID                         VARCHAR2(240 BYTE),   -- 3
    INVOICE_ID                          VARCHAR2(240 BYTE)  NOT NULL, -- 4  ORG_ID|INVOICE_ID|PAYMENT_NUM|INVOICE_NUM (award key)
    ORIGINAL_AMOUNT                     NUMBER,               -- 5
    CURRENCY                            VARCHAR2(10 BYTE),    -- 6
    ORIGINAL_DUE_DATE                   VARCHAR2(25 BYTE),    -- 7
    TRANSACTION_TYPE                    NUMBER,               -- 8  1=base 2=adjustment
    ORIGINAL_INVOICE_TRANSACTION_DATE   VARCHAR2(25 BYTE),    -- 9
    VOUCHER_ID                          NUMBER,               -- 10
    VOUCHER_LINE_ID                     NUMBER,               -- 11 == ap_payment_schedules_all.PAYMENT_NUM
    FISCAL_YEAR                         NUMBER,               -- 12
    DISCOUNT_PERCENTAGE                 NUMBER,               -- 13
    INCOME                              NUMBER,               -- 14 discount currency amount
    DISCOUNTED_INVOICE_AMOUNT           NUMBER,               -- 15 disc_invoice_amount
    PAY_DATE                            VARCHAR2(25 BYTE),    -- 16 new DueDate
    OFFER_APR_AMOUNT                    NUMBER,               -- 17
    COVERS_ADJUSTMENT                   NUMBER,               -- 18
    ADJUSTED_INVOICE_AMOUNT             NUMBER,               -- 19
    ADJ_INVOICE_ID                      VARCHAR2(240 BYTE),   -- 20
    SURVIVING_INVOICE_ID                VARCHAR2(240 BYTE),   -- 21
    SURVIVING_INVOICE_DUE_DATE          VARCHAR2(25 BYTE),    -- 22
    SUPPLIER_ADDRESS_1                  VARCHAR2(240 BYTE),   -- 23
    SUPPLIER_ADDRESS_2                  VARCHAR2(240 BYTE),   -- 24 (file header sic: supper_address_2)
    SUPPLIER_CITY                       VARCHAR2(60 BYTE),    -- 25
    SUPPLIER_STATE                      VARCHAR2(150 BYTE),   -- 26
    SUPPLIER_POSTAL_CODE                VARCHAR2(60 BYTE),    -- 27
    SUPPLIER_COUNTRY                    VARCHAR2(60 BYTE),    -- 28
    SUPPLIER_TAX_ID                     VARCHAR2(30 BYTE),    -- 29
    SEQUENTIAL_DOCUMENT_NUMBER          VARCHAR2(60 BYTE),    -- 30 e.g. C2FO-Doc-5878-4653648-1 (string, not numeric)
    BUYER_NAME                          VARCHAR2(240 BYTE),   -- 31
    BUYER_ADDRESS                       VARCHAR2(1500 BYTE),  -- 32
    BUYER_TAX_ID                        VARCHAR2(30 BYTE),    -- 33
    ORIGINAL_AMOUNT_GROSSVAT            NUMBER,               -- 34
    ORIGINAL_AMOUNT_NETVAT              NUMBER,               -- 35
    VAT_TO_BE_DISCOUNTED                NUMBER,               -- 36
    ORIGINAL_VAT                        NUMBER,               -- 37
    AWARDED_VAT                         NUMBER,               -- 38
    VAT_REDUCTION                       NUMBER,               -- 39
    ORIGINAL_VAT_PERCENTAGE             NUMBER,               -- 40
    DISCOUNT_REASON_CODE                VARCHAR2(90 BYTE),    -- 41
    LOCAL_CURRENCY_KEY                  VARCHAR2(9 BYTE),     -- 42
    LOCAL_CURRENCY_RATE                 NUMBER,               -- 43
    LOCAL_CURRENCY_ORIGINAL_INV_AMOUNT  NUMBER,               -- 44
    LOCAL_CURRENCY_INCOME               NUMBER,               -- 45
    LOCAL_CURRENCY_NET_AWARD_AMOUNT     NUMBER,               -- 46
    LOCAL_CURRENCY_ORIGINAL_VAT         NUMBER,               -- 47
    LOCAL_CURRENCY_AWARDED_VAT          NUMBER,               -- 48
    LOCAL_CURRENCY_VAT_REDUCTION        NUMBER,               -- 49
    MARKET_TYPE                         VARCHAR2(25 BYTE),    -- 50
    PO_ID                               VARCHAR2(240 BYTE),   -- 51 composite PO key (ORG|PO|LINE|SHIP), e.g. 4x 15-digit ids piped
    FUND_TYPE                           VARCHAR2(50 BYTE),    -- 52
    ERP_LEGAL_ENTITY                    VARCHAR2(50 BYTE),    -- 53
    ERP_REFERENCE_NUMBER                NUMBER,               -- 54 (baseline sic: ERP_REFRENCE_NUMBER)
    ERP_VENDOR_ID                       NUMBER,               -- 55
    ERP_TAX_CODE                        VARCHAR2(150 BYTE),   -- 56
    ERP_PAYMENT_TERM                    VARCHAR2(50 BYTE),    -- 57
    ERP_BASELINE_DATE                   VARCHAR2(25 BYTE),    -- 58
    ERP_NET_DUE_DATE                    VARCHAR2(25 BYTE),    -- 59
    ERP_INVOICE_AMOUNT                  NUMBER,               -- 60
    ERP_DISCOUNT_BASE_AMOUNT            NUMBER,               -- 61
    ERP_CASH_DISC_AMOUNT                NUMBER,               -- 62
    ERP_PAYEE                           VARCHAR2(25 BYTE),    -- 63
    ERP_VENDOR_SITE_ID                  NUMBER,               -- 64
    ERP_VENDOR_SITE_CODE                VARCHAR2(15 BYTE),    -- 65
    ERP_INVOICE_NUM                     VARCHAR2(50 BYTE),    -- 66
    ERP_PAY_GROUP                       VARCHAR2(25 BYTE),    -- 67
    ERP_SUP_PAY_PRIORITY                NUMBER,               -- 68
    ERP_TAX_RATE                        NUMBER,               -- 69
    ERP_DOC_TYPE                        VARCHAR2(25 BYTE),    -- 70
    ERP_BUSINESS_UNIT                   VARCHAR2(240 BYTE),   -- 71
    ERP_SUPPLIER_NUMBER                 VARCHAR2(30 BYTE),    -- 72
    ERP_PURPOSE_OF_PAYMENT              VARCHAR2(240 BYTE),   -- 73
    ERP_BURST_ID                        VARCHAR2(50 BYTE),    -- 74 e.g. 'invoice'
    -- derived (NOT from file): populated by validation from the mirror -----------
    ERP_ORG_ID                          NUMBER,               -- resolved AP_INVOICES_ALL.ORG_ID
    ERP_INVOICE_ID                      NUMBER,               -- resolved AP_INVOICES_ALL.INVOICE_ID (parsed from the composite invoice_id)
    -- custom_name(s) catch-all --------------------------------------------------
    ATTRIBUTE1                          VARCHAR2(150 BYTE),
    ATTRIBUTE2                          VARCHAR2(150 BYTE),
    ATTRIBUTE3                          VARCHAR2(150 BYTE),
    ATTRIBUTE4                          VARCHAR2(150 BYTE),
    ATTRIBUTE5                          VARCHAR2(150 BYTE),
    -- run / batch tracking (BATCH_ID = the OIC loader instance id) --------------
    INSTANCE_ID                         VARCHAR2(150 BYTE)  NOT NULL, -- OIC loader run id; part of PK
    CHUNK_ID                            NUMBER,               -- optional parallel-chunk grouping for large runs
    -- state machine (ported baseline) -------------------------------------------
    RECORD_STATUS                       VARCHAR2(50 BYTE),    -- N not processed | Y success | E error (terminal)
    STAGE                               VARCHAR2(200 BYTE),   -- stage progression (staged/validated/interfaced/...)
    ERROR_CODE                          VARCHAR2(200 BYTE),   -- error stage code (holds the full stage-code constants, e.g. EP_ORIGINAL_INVOICE_SCHEDULE_DUE_DATES_UPDATE_ERROR = 51 chars; matches STAGE width)
    ERROR_MESSAGE                       VARCHAR2(2000 BYTE),
    -- resolved identity (filled at validation from the mirror) ------------------
    --   the resolved AP invoice id + org id live in ERP_INVOICE_ID / ERP_ORG_ID above.
    PAYMENT_NUM                         NUMBER,               -- target AP_PAYMENT_SCHEDULES_ALL.PAYMENT_NUM (=voucher_line_id)
    VENDOR_ID                           NUMBER,               -- supplier (net-debit grouping)
    DISCOUNT_AMOUNT                     NUMBER,               -- matching-tier discount available on the target installment (BR#6)
    -- original installment discount schedule (read from the invoice at validation;
    --   record-of-truth for reversal so the pre-acceleration discount tiers can be
    --   restored). The due-date upsert (#3) does NOT send these; it sends
    --   FirstDiscountDate = PAY_DATE. Stored only for audit/reversal.
    ORIG_FIRST_DISCOUNT_DATE            VARCHAR2(25 BYTE),    -- apsa.discount_date at validation
    ORIG_FIRST_DISCOUNT_AMT             NUMBER,               -- apsa.discount_amount_available
    ORIG_SECOND_DISCOUNT_DATE           VARCHAR2(25 BYTE),    -- apsa.second_discount_date
    ORIG_SECOND_DISCOUNT_AMT            NUMBER,               -- apsa.second_disc_amt_available
    ORIG_THIRD_DISCOUNT_DATE            VARCHAR2(25 BYTE),    -- apsa.third_discount_date
    ORIG_THIRD_DISCOUNT_AMT             NUMBER,               -- apsa.third_disc_amt_available
    -- CM build inputs (filled at validation; the award file carries no accounting)
    CM_INVOICE_AMOUNT                   NUMBER,               -- CM header amount (positive; emitted negative on the FBDI line)
    CM_INVOICE_LINE_AMOUNT              NUMBER,               -- CM single-line amount (positive; emitted negative)
    EXPENSE_CCID                        NUMBER,               -- CM distribution (expense) account -- TODO_VERIFY source
    LIABILITY_CCID                      NUMBER,               -- CM liability account -- TODO_VERIFY source
    TERMS_ID                            NUMBER,               -- CM payment terms (from the mirror invoice)
    -- CM / due-date outcome (filled by OIC verdict write-back) -------------------
    CM_INVOICE_NUM                      VARCHAR2(50 BYTE),    -- deterministic CM number (BR#5)
    CM_INVOICE_ID                       NUMBER,               -- created CM invoice id (needed to reverse)
    CM_STATUS                           VARCHAR2(40 BYTE),    -- CM half outcome
    DD_STATUS                           VARCHAR2(40 BYTE),    -- due-date half outcome (OIC-reported)
    HTTP_STATUS                         NUMBER,               -- last REST status (OIC-reported)
    PAY_GROUP                           VARCHAR2(30 BYTE),    -- OIC-supplied pay group for the accelerated invoice (BR#16); NULL => unchanged
    SOURCE_CODE                         VARCHAR2(30 BYTE),    -- CM invoice source (persisted for audit)
    FILE_NAME                           VARCHAR2(200 BYTE),   -- source award file name (audit)
    -- reversal ------------------------------------------------------------------
    REVERSED_FLAG                       VARCHAR2(1) DEFAULT 'N', -- 'Y' once this award has been reversed
    REVERSED_DATE                       TIMESTAMP,            -- when reversed
    REVERSED_REASON                     VARCHAR2(200 BYTE),   -- e.g. MANUAL_FUSION / REQUESTED
    -- audit ---------------------------------------------------------------------
    CREATION_DATE                       TIMESTAMP DEFAULT SYSTIMESTAMP,
    CREATED_BY                          VARCHAR2(64 BYTE),
    LAST_UPDATE_DATE                    TIMESTAMP DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_BY                     VARCHAR2(64 BYTE),
    CONSTRAINT PK_LWS_C2FO_AWARD_DATA PRIMARY KEY (INVOICE_ID, INSTANCE_ID)
);

-- Dedup / re-award scan (BR#4 rewrite): find prior rows for the same award key
-- and inspect their success/reversed state across batches.
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_AWARD_DATA_KEY_STATE
    ON LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA (INVOICE_ID, RECORD_STATUS, REVERSED_FLAG);

-- Batch + status scan (validation, work-set builders, run reporting).
CREATE INDEX LWS_CUSTOM_C2FO_SA.IX_AWARD_DATA_INST_STATUS
    ON LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA (INSTANCE_ID, RECORD_STATUS);
