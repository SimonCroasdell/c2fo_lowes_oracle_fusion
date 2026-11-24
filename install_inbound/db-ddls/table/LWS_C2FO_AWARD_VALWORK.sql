--------------------------------------------------------------------------------
-- LWS_C2FO_AWARD_VALWORK  -- inbound validation work table (session-scoped)
--
-- Used only by LWS_AP_C2FO_AWARD_PKG.validate_batch (set-based). Populated once
-- per run by a single INSERT..SELECT that resolves every award against the mirror
-- (ap_invoices_all + ap_payment_schedules_all). The eligibility gates and the
-- final PASS stamp then read from here, so the heavy joins and the net-debit
-- aggregate run ONCE for the whole batch instead of once per award.
--
-- ON COMMIT PRESERVE ROWS: validate_batch does a single COMMIT at the end of the
-- run and must keep the work rows up to that point. Rows are automatically
-- discarded when the session (the one-time validation scheduler job) ends.
-- Nothing persists between runs; validate_batch also DELETEs it on entry as a
-- belt-and-braces guard.
--
-- Key = the award composite (INVOICE_ID, INSTANCE_ID), the same key as
-- LWS_C2FO_AWARD_DATA, so every gate joins one-to-one back to the award row.
--------------------------------------------------------------------------------
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_VALWORK;
CREATE GLOBAL TEMPORARY TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_VALWORK (
    INVOICE_ID        VARCHAR2(240)  NOT NULL,  -- award composite key (AWARD_DATA.INVOICE_ID VARCHAR2(240))
    INSTANCE_ID       VARCHAR2(150)  NOT NULL,   -- matches AWARD_DATA.INSTANCE_ID VARCHAR2(150)
    -- resolved invoice identity (ap_invoices_all)
    INV_ID            NUMBER,                    -- NULL => invoice not found
    ORG_ID            NUMBER,
    VENDOR_ID         NUMBER,
    SITE_ID           NUMBER,
    SOURCE_CODE       VARCHAR2(80),
    -- invoice-level eligibility snapshot (read once; gated set-based)
    APPROVAL_STATUS   VARCHAR2(20),
    WFAPPROVAL_STATUS VARCHAR2(30),
    CANCELLED_DATE    DATE,
    INV_TYPE          VARCHAR2(40),
    INV_DATE          DATE,
    TERMS_DATE        DATE,
    PAY_GROUP         VARCHAR2(30),
    PAY_TERM          VARCHAR2(50),
    PAYMENT_STATUS    VARCHAR2(1),
    -- resolved installment (ap_payment_schedules_all); NULL => named instalment
    -- not found unpaid
    PAY_NUM           NUMBER,
    DISC_AVAIL        NUMBER,
    INST_DUE          DATE,
    DISC1_DATE        DATE,
    DISC2_DATE        DATE,
    DISC3_DATE        DATE,
    DISC2_AMT         NUMBER,
    DISC3_AMT         NUMBER,
    SCHED_HOLD        VARCHAR2(1),
    AMT_REMAIN        NUMBER,
    INST_FOUND        VARCHAR2(1),               -- 'Y' when a matching unpaid instalment resolved
    -- derived
    REAWARD_N         NUMBER,
    CM_NUM            VARCHAR2(50),
    -- net-debit balance is NOT held here: it depends only on
    -- (vendor_id, org_id, currency), so it is computed once per distinct combo
    -- into LWS_C2FO_NETDEBIT_WORK and the net-debit gate joins to that.
    -- award payload needed by the CM-balance gate
    INCOME            NUMBER,
    TAX_RATE          NUMBER,
    CONSTRAINT PK_C2FO_AWARD_VALWORK PRIMARY KEY (INVOICE_ID, INSTANCE_ID)
)
ON COMMIT PRESERVE ROWS;
