--------------------------------------------------------------------------------
-- !! PER-ENVIRONMENT VALUES !!  The lookup MEANING / LOOKUP_CODE values seeded
-- below (in-scope business-unit names + invoice types) are client/environment
-- specific and MUST be reviewed for every environment. BU names must match the
-- target pod's business-unit names exactly (case/whitespace).
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- c2fo_fnd_lookup_seed.sql
--
-- Config seed for LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL.
--
-- WHY THIS EXISTS
--   The outbound invoice extract (LWS_OB_EXTRACT_ATP_PKG.extract_invoices) gates
--   every invoice on two lookups:
--     * XX_ZZZZ_C2FO_OPERATING_UNIT_LT - the buyer business units in scope for
--       C2FO. Filter:  haou.name IN (SELECT meaning FROM fnd_lookup_values_vl
--                                     WHERE lookup_type = 'XX_ZZZZ_C2FO_OPERATING_UNIT_LT'
--                                       AND enabled_flag = 'Y' AND <active dates>)
--       => MEANING must EXACTLY equal the business-unit NAME (haou.name, which the
--          BU->org-units bridge loads from BU_NAME). Whitespace/case must match.
--     * XX_ZZZZ_C2FO_INVOICE_TYPE_LT - the invoice types in scope. Filter:
--          aia.invoice_type_lookup_code IN (SELECT lookup_code ...)
--       => LOOKUP_CODE must EXACTLY equal AP_INVOICES_ALL.INVOICE_TYPE_LOOKUP_CODE.
--
--   These two lists are small, client-specific, and change rarely, so they are
--   seeded as config data here rather than extracted from BICC (there is no C2FO
--   custom-lookup PVO). If empty, BOTH IN-lists are empty and the invoice file
--   comes out with ZERO rows - so this seed is a hard prerequisite alongside the
--   AP_TERMS and BU->org-units bridges.
--
-- HOW TO USE
--   1. Replace the placeholder OPERATING_UNIT rows below with the REAL business-unit
--      names in C2FO scope. The name must match LWS_HR_ALL_ORGANIZATION_UNITS.NAME
--      (= LWS_FUN_ALL_BUSINESS_UNITS_V.BU_NAME) character-for-character. To list the
--      candidates after the BU bridge has run:
--          SELECT organization_id, name FROM LWS_CUSTOM_C2FO_SA.LWS_HR_ALL_ORGANIZATION_UNITS ORDER BY name;
--   2. Confirm the invoice-type codes. The set below is the common AP standard set;
--      keep only the types C2FO should accelerate. To see what actually occurs:
--          SELECT DISTINCT invoice_type_lookup_code FROM LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL ORDER BY 1;
--      (Note: the extract already hard-excludes 'EXPENSE REPORT' and 'PREPAYMENT'
--       regardless of this list, so there is no need to list those as disabled.)
--   3. Run this script. Re-runnable: MERGE upserts on the PK (LOOKUP_TYPE, LOOKUP_CODE).
--------------------------------------------------------------------------------

--==============================================================================
-- 1. OPERATING-UNIT (business-unit) scope list
--    MEANING = business-unit name (must equal haou.name). LOOKUP_CODE is a short
--    stable key you choose (BU id or a code); only MEANING is matched by the
--    extract, but LOOKUP_CODE is the PK so it must be unique + non-null.
--    <<< REPLACE THESE PLACEHOLDER ROWS WITH THE REAL BUs >>>
--==============================================================================
MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL t
USING (
    SELECT 'XX_ZZZZ_C2FO_OPERATING_UNIT_LT' AS lookup_type, lookup_code, meaning FROM (
        SELECT 'BU_PLACEHOLDER_1' AS lookup_code, 'REPLACE WITH REAL BU NAME 1' AS meaning FROM dual
        UNION ALL
        SELECT 'BU_PLACEHOLDER_2', 'REPLACE WITH REAL BU NAME 2' FROM dual
    )
) s
ON (t.LOOKUP_TYPE = s.lookup_type AND t.LOOKUP_CODE = s.lookup_code)
WHEN MATCHED THEN UPDATE SET
    t.MEANING = s.meaning, t.ENABLED_FLAG = 'Y', t.LAST_UPDATE_DATE = SYSDATE
WHEN NOT MATCHED THEN INSERT (
    LOOKUP_TYPE, LOOKUP_CODE, MEANING, DESCRIPTION, ENABLED_FLAG,
    START_DATE_ACTIVE, END_DATE_ACTIVE, CREATION_DATE, LAST_UPDATE_DATE
) VALUES (
    s.lookup_type, s.lookup_code, s.meaning, 'C2FO operating-unit scope', 'Y',
    NULL, NULL, SYSDATE, SYSDATE
);

--==============================================================================
-- 2. INVOICE-TYPE scope list
--    LOOKUP_CODE = AP_INVOICES_ALL.INVOICE_TYPE_LOOKUP_CODE. Standard AP set;
--    trim to the types C2FO should accelerate for this client.
--==============================================================================
MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL t
USING (
    SELECT 'XX_ZZZZ_C2FO_INVOICE_TYPE_LT' AS lookup_type, lookup_code, meaning FROM (
        SELECT 'STANDARD'      AS lookup_code, 'Standard invoice'      AS meaning FROM dual
        UNION ALL SELECT 'CREDIT',       'Credit memo'           FROM dual
        UNION ALL SELECT 'DEBIT',        'Debit memo'            FROM dual
        UNION ALL SELECT 'MIXED',        'Mixed invoice'         FROM dual
    )
) s
ON (t.LOOKUP_TYPE = s.lookup_type AND t.LOOKUP_CODE = s.lookup_code)
WHEN MATCHED THEN UPDATE SET
    t.MEANING = s.meaning, t.ENABLED_FLAG = 'Y', t.LAST_UPDATE_DATE = SYSDATE
WHEN NOT MATCHED THEN INSERT (
    LOOKUP_TYPE, LOOKUP_CODE, MEANING, DESCRIPTION, ENABLED_FLAG,
    START_DATE_ACTIVE, END_DATE_ACTIVE, CREATION_DATE, LAST_UPDATE_DATE
) VALUES (
    s.lookup_type, s.lookup_code, s.meaning, 'C2FO invoice-type scope', 'Y',
    NULL, NULL, SYSDATE, SYSDATE
);

COMMIT;
