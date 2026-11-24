--==============================================================================
-- C2FO INBOUND  -  INSTALL READINESS CHECK
--==============================================================================
-- Read-only. Makes NO changes. Run as the schema owner (LWS_CUSTOM_C2FO_SA) or
-- as a user with that current_schema. Safe to run before AND after the install:
--
--   BEFORE install  -> PRE-INSTALL sections confirm the prerequisite BICC->ATP +
--                      outbound layer is present and the config is seeded. The
--                      POST-INSTALL section will report the 11 inbound objects as
--                      "not yet created" - that is expected pre-install.
--   AFTER install   -> re-run; every section should read PASS and the POST-INSTALL
--                      section should show all 11 inbound objects VALID.
--
-- Nothing here depends on install order; each section is independent.
--==============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF

PROMPT
PROMPT ================================================================================
PROMPT  C2FO INBOUND READINESS CHECK  -  schema LWS_CUSTOM_C2FO_SA
PROMPT ================================================================================

--------------------------------------------------------------------------------
-- 1. PRE-INSTALL: the 6 prerequisite objects must exist (and views be VALID).
--    These are owned by the BICC->ATP + outbound build, NOT by this tree.
--------------------------------------------------------------------------------
PROMPT
PROMPT -- 1. PREREQUISITE OBJECTS (expect 6 rows, every view/synonym STATUS=VALID) ----
COLUMN object_name   FORMAT A32
COLUMN object_type   FORMAT A14
COLUMN status        FORMAT A8
COLUMN result        FORMAT A6

SELECT req.object_name,
       NVL(ao.object_type, '** MISSING **') AS object_type,
       ao.status,
       CASE
         WHEN ao.object_name IS NULL                      THEN 'FAIL'
         WHEN ao.status = 'INVALID'                       THEN 'FAIL'
         ELSE 'PASS'
       END AS result
FROM   ( SELECT 'AP_INVOICES_ALL'              AS object_name FROM dual
         UNION ALL SELECT 'AP_PAYMENT_SCHEDULES_ALL'       FROM dual
         UNION ALL SELECT 'FND_LOOKUP_VALUES_VL'           FROM dual
         UNION ALL SELECT 'LWS_POZ_SUPPLIERS_V'            FROM dual
         UNION ALL SELECT 'LWS_POZ_SUPPLIER_SITES_ALL_M'   FROM dual
         UNION ALL SELECT 'LWS_C2FO_CONFIG'                FROM dual ) req
LEFT JOIN all_objects ao
       ON ao.owner = 'LWS_CUSTOM_C2FO_SA'
      AND ao.object_name = req.object_name
ORDER BY req.object_name;

--------------------------------------------------------------------------------
-- 2. PRE-INSTALL: mandatory OCI / bucket config must resolve to a NON-NULL value.
--    The award package reads these at runtime via cfg(); a present-but-null or
--    disabled mandatory key raises ORA-20050 at runtime (not at compile).
--    (CM_CHUNK_SIZE / AWARD_RETENTION_MONTHS are optional - they have defaults.)
--------------------------------------------------------------------------------
PROMPT
PROMPT -- 2. MANDATORY CONFIG KEYS (expect 7 rows, all result=PASS) -------------------
COLUMN config_group FORMAT A8
COLUMN config_key   FORMAT A24
COLUMN resolved     FORMAT A8
COLUMN result       FORMAT A6

SELECT req.config_group,
       req.config_key,
       CASE WHEN c.config_value IS NULL THEN 'NULL' ELSE 'set'  END AS resolved,
       CASE
         WHEN c.config_group IS NULL          THEN 'FAIL'   -- row absent
         WHEN c.enabled_flag <> 'Y'           THEN 'FAIL'   -- disabled
         WHEN c.config_value IS NULL          THEN 'FAIL'   -- present but null
         ELSE 'PASS'
       END AS result
FROM   ( SELECT 'COMMON'  AS config_group, 'OBJ_STORAGE_CREDENTIALS' AS config_key FROM dual
         UNION ALL SELECT 'COMMON',  'OBJ_STORAGE_NAMESPACE'   FROM dual
         UNION ALL SELECT 'COMMON',  'OBJ_URI'                 FROM dual
         UNION ALL SELECT 'INBOUND', 'ERROR_BUCKET'            FROM dual
         UNION ALL SELECT 'INBOUND', 'ERROR_FOLDER'            FROM dual
         UNION ALL SELECT 'INBOUND', 'ARCHIVE_BUCKET'          FROM dual
         UNION ALL SELECT 'INBOUND', 'ARCHIVE_FOLDER'          FROM dual ) req
LEFT JOIN lws_c2fo_config c
       ON c.config_group = req.config_group
      AND c.config_key   = req.config_key
ORDER BY req.config_group, req.config_key;

--------------------------------------------------------------------------------
-- 3. POST-INSTALL: the 11 inbound objects this tree creates must all be VALID.
--    BEFORE install this lists them as "** NOT CREATED **" (expected).
--    AFTER install every row must read PASS with STATUS=VALID.
--------------------------------------------------------------------------------
PROMPT
PROMPT -- 3. INBOUND OBJECTS (pre-install: NOT CREATED; post-install: all VALID/PASS) -
COLUMN object_name FORMAT A32
COLUMN object_type FORMAT A14
COLUMN status      FORMAT A14
COLUMN result      FORMAT A6

SELECT req.object_name,
       NVL(ao.object_type, '(none)')                 AS object_type,
       NVL(ao.status, '** NOT CREATED **')           AS status,
       CASE
         WHEN ao.object_name IS NULL THEN 'n/a'   -- not installed yet
         WHEN ao.status = 'INVALID'  THEN 'FAIL'
         ELSE 'PASS'
       END AS result
FROM   ( SELECT 'LWS_C2FO_AWARD_DATA'          AS object_name FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_AWARD_RUN_LOG'      FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_VERDICT_LOAD'       FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_CM_CREATED_STG'     FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_DD_APPLIED_STG'     FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_AWARD_RUN_SEQ'      FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_VERDICT_SEQ'        FROM dual
         UNION ALL SELECT 'TRG_VERDICT_LOAD_BI'            FROM dual
         UNION ALL SELECT 'LWS_C2FO_DD_UPSERT_V'           FROM dual
         UNION ALL SELECT 'LWS_C2FO_DD_CANCEL_V'           FROM dual
         UNION ALL SELECT 'LWS_C2FO_CM_OFFSET_V'           FROM dual
         UNION ALL SELECT 'LWS_C2FO_CM_FBDI_V'             FROM dual
         UNION ALL SELECT 'LWS_AP_C2FO_AWARD_PKG'          FROM dual ) req
LEFT JOIN all_objects ao
       ON ao.owner = 'LWS_CUSTOM_C2FO_SA'
      AND ao.object_name = req.object_name
      AND ao.object_type <> 'PACKAGE BODY'   -- report the package once (spec row carries status)
ORDER BY req.object_name;

--------------------------------------------------------------------------------
-- 4. POST-INSTALL: any invalid inbound object - show the compile errors.
--    Expect ZERO rows after a clean install.
--------------------------------------------------------------------------------
PROMPT
PROMPT -- 4. COMPILE ERRORS ON INBOUND OBJECTS (expect NO rows) ----------------------
COLUMN name     FORMAT A28
COLUMN type     FORMAT A14
COLUMN line_pos FORMAT A10
COLUMN text     FORMAT A80

SELECT e.name,
       e.type,
       e.line || ':' || e.position AS line_pos,
       e.text
FROM   all_errors e
WHERE  e.owner = 'LWS_CUSTOM_C2FO_SA'
AND    e.name IN (
         'LWS_C2FO_AWARD_DATA','LWS_AP_C2FO_AWARD_RUN_LOG','LWS_AP_C2FO_VERDICT_LOAD',
         'LWS_AP_C2FO_CM_CREATED_STG','LWS_AP_C2FO_DD_APPLIED_STG','TRG_VERDICT_LOAD_BI',
         'LWS_C2FO_DD_UPSERT_V','LWS_C2FO_DD_CANCEL_V','LWS_C2FO_CM_OFFSET_V',
         'LWS_C2FO_CM_FBDI_V','LWS_AP_C2FO_AWARD_PKG')
ORDER  BY e.name, e.sequence;

PROMPT
PROMPT ================================================================================
PROMPT  Readiness check complete.
PROMPT    - Section 1 & 2 must be ALL PASS before installing.
PROMPT    - Section 3 must be ALL PASS, Section 4 EMPTY, after installing.
PROMPT ================================================================================
SET FEEDBACK ON
