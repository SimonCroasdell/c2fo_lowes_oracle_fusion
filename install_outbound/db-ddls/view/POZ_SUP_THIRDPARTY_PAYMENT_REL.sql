--------------------------------------------------------------------------------
-- C2FO bridging view (Fusion-named, over the LWS_-prefixed mirror table)
-- View   : POZ_SUP_THIRDPARTY_PAYMENT_REL  ->  LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL
-- Purpose: expose the typed mirror under its Fusion object name so the outbound
--          extract package references it by the native name (see the other
--          POZ_* bridging views for the convention).
--------------------------------------------------------------------------------

DROP VIEW LWS_CUSTOM_C2FO_SA.POZ_SUP_THIRDPARTY_PAYMENT_REL;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.POZ_SUP_THIRDPARTY_PAYMENT_REL AS
SELECT * FROM LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL;
