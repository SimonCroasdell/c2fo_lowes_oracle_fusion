--------------------------------------------------------------------------------
-- C2FO REVERSAL verdict-load surrogate-key sequence
-- Feeds VERDICT_ROW_ID on LWS_AP_C2FO_REV_VERDICT_LOAD via TRG_REV_VERDICT_LOAD_BI.
--------------------------------------------------------------------------------

DROP SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_SEQ;
CREATE SEQUENCE LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_SEQ START WITH 1 INCREMENT BY 1 NOCACHE;
