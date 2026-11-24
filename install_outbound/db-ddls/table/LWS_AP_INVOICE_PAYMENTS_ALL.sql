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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL (
    INVOICE_PAYMENT_ID          NUMBER(18)      NOT NULL,
    INVOICE_ID                  NUMBER(18)      NOT NULL,
    CHECK_ID                    NUMBER(18),
    ACCOUNTING_DATE             DATE,
    AMOUNT                      NUMBER,
    PAYMENT_NUM                 NUMBER,
    REVERSAL_FLAG               VARCHAR2(1),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_AP_INVOICE_PAYMENTS PRIMARY KEY (INVOICE_PAYMENT_ID)
);
CREATE INDEX IDX_AP_INVPAY_INVOICE ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL (INVOICE_ID);
CREATE INDEX IDX_AP_INVPAY_CHECK   ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL (CHECK_ID);


