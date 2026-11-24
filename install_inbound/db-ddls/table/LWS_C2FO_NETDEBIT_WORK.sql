--------------------------------------------------------------------------------
-- LWS_C2FO_NETDEBIT_WORK  -- per-supplier net-debit balances (session-scoped)
--
-- Used only by LWS_AP_C2FO_AWARD_PKG.validate_batch (set-based). The supplier
-- net-debit position depends only on (vendor_id, org_id, invoice_currency_code),
-- not on the individual award. A 100K-award batch typically spans only a few
-- hundred distinct suppliers, so the heavy signed-balance aggregate is computed
-- ONCE per distinct (vendor_id, org_id, currency) into this table, then the
-- net-debit gate JOINS each award to its precomputed balance - instead of
-- recomputing the same balance once per award.
--
-- Populated by one INSERT from the DISTINCT resolved (vendor_id, org_id,
-- currency) combos present in the batch (i.e. from LWS_C2FO_AWARD_VALWORK where
-- the invoice resolved). ON COMMIT PRESERVE ROWS: held until validate_batch's
-- single end-of-run COMMIT; discarded when the session (the validation job) ends.
--------------------------------------------------------------------------------
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_NETDEBIT_WORK;
CREATE GLOBAL TEMPORARY TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_NETDEBIT_WORK (
    VENDOR_ID    NUMBER        NOT NULL,
    ORG_ID       NUMBER        NOT NULL,
    CURRENCY     VARCHAR2(10)  NOT NULL,   -- award currency (AWARD_DATA.CURRENCY)
    NET_BALANCE  NUMBER,
    CONSTRAINT PK_C2FO_NETDEBIT_WORK PRIMARY KEY (VENDOR_ID, ORG_ID, CURRENCY)
)
ON COMMIT PRESERVE ROWS;
