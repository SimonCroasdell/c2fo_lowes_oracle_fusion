--------------------------------------------------------------------------------
-- C2FO REVERSAL verdict-load before-insert trigger
-- Assigns VERDICT_ROW_ID from LWS_AP_C2FO_REV_VERDICT_SEQ when the inserter leaves
-- it NULL. The OIC DB adapter inserts the surrogate PK as an explicit NULL (which
-- bypasses a column DEFAULT), so a trigger is required - same pattern as the award
-- verdict table's TRG_VERDICT_LOAD_BI.
--------------------------------------------------------------------------------

DROP TRIGGER LWS_CUSTOM_C2FO_SA.TRG_REV_VERDICT_LOAD_BI;
CREATE OR REPLACE TRIGGER LWS_CUSTOM_C2FO_SA.TRG_REV_VERDICT_LOAD_BI
BEFORE INSERT ON LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_LOAD
FOR EACH ROW
WHEN (NEW.VERDICT_ROW_ID IS NULL)
BEGIN
    :NEW.VERDICT_ROW_ID := LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REV_VERDICT_SEQ.NEXTVAL;
END;
/
