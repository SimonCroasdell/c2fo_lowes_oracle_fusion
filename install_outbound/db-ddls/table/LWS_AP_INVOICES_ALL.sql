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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (
    INVOICE_ID                  NUMBER(18)      NOT NULL,
    INVOICE_NUM                 VARCHAR2(50)    NOT NULL,
    INVOICE_TYPE_LOOKUP_CODE    VARCHAR2(25),
    INVOICE_DATE                DATE,
    VENDOR_ID                   NUMBER(18),
    VENDOR_SITE_ID              NUMBER(18),
    INVOICE_AMOUNT              NUMBER,
    INVOICE_CURRENCY_CODE       VARCHAR2(15),
    PAYMENT_CURRENCY_CODE       VARCHAR2(15),
    PAYMENT_CROSS_RATE          NUMBER,
    AMOUNT_PAID                 NUMBER,
    TOTAL_TAX_AMOUNT            NUMBER,
    DESCRIPTION                 VARCHAR2(240),
    SOURCE                      VARCHAR2(80),
    TERMS_ID                    NUMBER(18),
    TERMS_DATE                  DATE,
    GL_DATE                     DATE,
    ORG_ID                      NUMBER(18),
    PO_HEADER_ID                NUMBER(18),
    PAYMENT_STATUS_FLAG         VARCHAR2(1),
    APPROVAL_STATUS             VARCHAR2(20),
    WFAPPROVAL_STATUS           VARCHAR2(30),
    PAY_GROUP_LOOKUP_CODE       VARCHAR2(25),
    PAYMENT_METHOD_CODE         VARCHAR2(30),
    CANCELLED_DATE              DATE,
    CUST_REGISTRATION_NUMBER    VARCHAR2(30),
    REMIT_TO_SUPPLIER_ID        NUMBER(18),
    EXCHANGE_RATE               NUMBER,
    EXCHANGE_RATE_TYPE          VARCHAR2(30),
    EXCHANGE_DATE               DATE,
    ATTRIBUTE_CATEGORY          VARCHAR2(150),
    ATTRIBUTE1                  VARCHAR2(150),
    ATTRIBUTE2                  VARCHAR2(150),
    ATTRIBUTE3                  VARCHAR2(150),
    ATTRIBUTE4                  VARCHAR2(150),
    ATTRIBUTE5                  VARCHAR2(150),
    ATTRIBUTE6                  VARCHAR2(150),
    ATTRIBUTE7                  VARCHAR2(150),
    ATTRIBUTE8                  VARCHAR2(150),
    ATTRIBUTE9                  VARCHAR2(150),
    ATTRIBUTE10                 VARCHAR2(150),
    ATTRIBUTE11                 VARCHAR2(150),
    ATTRIBUTE12                 VARCHAR2(150),
    ATTRIBUTE13                 VARCHAR2(150),
    ATTRIBUTE14                 VARCHAR2(150),
    ATTRIBUTE15                 VARCHAR2(150),
    CREATION_DATE               DATE,
    CREATED_BY                  VARCHAR2(64),
    LAST_UPDATE_DATE            DATE,
    LAST_UPDATED_BY             VARCHAR2(64),
    CONSTRAINT PK_AP_INVOICES_ALL PRIMARY KEY (INVOICE_ID)
);
CREATE INDEX IDX_AP_INV_VENDOR      ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (VENDOR_ID);
CREATE INDEX IDX_AP_INV_VENDOR_SITE ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (VENDOR_SITE_ID);
CREATE INDEX IDX_AP_INV_ORG         ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (ORG_ID);
CREATE INDEX IDX_AP_INV_TERMS       ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (TERMS_ID);
CREATE INDEX IDX_AP_INV_PO          ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (PO_HEADER_ID);
CREATE INDEX IDX_AP_INV_NUM         ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (INVOICE_NUM);
-- Composite for the inbound net-debit aggregate (validate_batch): the supplier
-- balance is summed per (vendor_id, org_id, invoice_currency_code), so this index
-- lets that gate seek instead of scanning the single-column VENDOR_ID index then
-- filtering org/currency row by row.
CREATE INDEX IDX_AP_INV_NETDEBIT    ON LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL (VENDOR_ID, ORG_ID, INVOICE_CURRENCY_CODE);


