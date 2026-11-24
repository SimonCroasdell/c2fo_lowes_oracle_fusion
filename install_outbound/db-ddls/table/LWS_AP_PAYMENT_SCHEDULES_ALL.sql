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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_PAYMENT_SCHEDULES_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_AP_PAYMENT_SCHEDULES_ALL (
    INVOICE_ID                  NUMBER(18)      NOT NULL,
    PAYMENT_NUM                 NUMBER          NOT NULL,
    DUE_DATE                    DATE,
    GROSS_AMOUNT                NUMBER,
    AMOUNT_REMAINING            NUMBER,
    DISCOUNT_DATE               DATE,
    SECOND_DISCOUNT_DATE        DATE,
    THIRD_DISCOUNT_DATE         DATE,
    DISCOUNT_AMOUNT_AVAILABLE   NUMBER,
    SECOND_DISC_AMT_AVAILABLE   NUMBER,
    THIRD_DISC_AMT_AVAILABLE    NUMBER,
    PAYMENT_STATUS_FLAG         VARCHAR2(1),
    PAYMENT_METHOD_CODE         VARCHAR2(30),
    REMIT_TO_SUPPLIER_NAME      VARCHAR2(360),
    REMIT_TO_SUPPLIER_ID        NUMBER(18),
    REMITTANCE_MESSAGE1         VARCHAR2(150),
    REMITTANCE_MESSAGE2         VARCHAR2(150),
    REMITTANCE_MESSAGE3         VARCHAR2(150),
    HOLD_FLAG                   VARCHAR2(1),
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_AP_PAYMENT_SCHEDULES PRIMARY KEY (INVOICE_ID, PAYMENT_NUM)
);
CREATE INDEX IDX_AP_PS_DUE_DATE ON LWS_CUSTOM_C2FO_SA.LWS_AP_PAYMENT_SCHEDULES_ALL (DUE_DATE);


