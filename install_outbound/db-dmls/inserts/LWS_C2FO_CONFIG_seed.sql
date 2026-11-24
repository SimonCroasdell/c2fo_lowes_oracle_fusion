--------------------------------------------------------------------------------
-- !! PER-ENVIRONMENT VALUES !!  The settings seeded below are environment-
-- specific and MUST be reviewed for every environment (DEV/TEST/PROD). They
-- differ per OCI tenancy / Fusion pod:
--   * OCI object-storage DBMS_CLOUD credential name
--   * OCI object-storage namespace
--   * OCI object-storage base URI (region host)
--   * INBOUND error/log bucket + folder
--   * INBOUND archive bucket + folder
-- Do NOT ship one environment's values to another.
--
-- DML seed for LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG. Run AFTER
-- 01_ddl/table_LWS_C2FO_CONFIG.sql (the CREATE TABLE).
--------------------------------------------------------------------------------

--==============================================================================
-- SEED. The environment-specific values (object-storage credential/namespace/URI
-- and the error + archive buckets) are PROMPTED FOR at install time so each
-- environment supplies its own - no hand-editing of NULLs. Press Enter to take the
-- shown default where one is offered. Adding a parameter later = one more INSERT
-- here (no DDL).
--
-- NOTE: install_all.sql runs with SET DEFINE OFF (so '&' in other scripts/values is
-- literal). We turn DEFINE ON only for this ACCEPT/substitution block and set it
-- OFF again at the end so the rest of the install is unaffected. See the memory
-- note on SET DEFINE OFF vs substitution.
--==============================================================================
SET DEFINE ON

ACCEPT obj_cred    CHAR PROMPT 'OCI object-storage DBMS_CLOUD credential name [OCI$RESOURCE_PRINCIPAL]: ' DEFAULT 'OCI$RESOURCE_PRINCIPAL'
ACCEPT obj_ns      CHAR PROMPT 'OCI object-storage namespace: '
ACCEPT obj_uri     CHAR PROMPT 'OCI object-storage base URI (no trailing slash, e.g. https://objectstorage.<region>.oraclecloud.com): '
ACCEPT err_bucket  CHAR PROMPT 'INBOUND error bucket name (write_error_file + write_run_log_file): '
ACCEPT err_folder  CHAR PROMPT 'INBOUND error folder within that bucket [c2fo/inbound_errors]: ' DEFAULT 'c2fo/inbound_errors'
ACCEPT arch_bucket CHAR PROMPT 'INBOUND archive bucket name (award file moved here after load): '
ACCEPT arch_folder CHAR PROMPT 'INBOUND archive folder within that bucket (blank = bucket root): ' DEFAULT ''
ACCEPT log_bucket CHAR PROMPT 'INBOUND log bucket name (outbound bucket so list of non-awarded invoices goes to C2FO): '
ACCEPT log_folder CHAR PROMPT 'INBOUND log folder within that bucket (e.g. C2FO/log): ' DEFAULT ''

-- COMMON: OCI object-storage triple, shared by all flows -----------------------
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('COMMON', 'OBJ_STORAGE_CREDENTIALS', '&&obj_cred', 'Y', 'DBMS_CLOUD credential name for OCI object storage');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('COMMON', 'OBJ_STORAGE_NAMESPACE', '&&obj_ns', 'Y', 'OCI object-storage namespace');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('COMMON', 'OBJ_URI', '&&obj_uri', 'Y', 'Object-storage base URI, no trailing slash');
-- Retention (days) for the DBMS_CLOUD per-operation log/bad tables (COPY$..._LOG /
-- COPY$..._BAD, tracked in USER_LOAD_OPERATIONS). run_load's Stage 3 keeps anything
-- newer so load-failure evidence survives for debugging, and drops only operations
-- older than this. Optional: code defaults to 3 when the row is absent/disabled.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('COMMON', 'OPLOG_RETENTION_DAYS', '3', 'N', 'Days to retain DBMS_CLOUD operation log/bad tables before run_load purges them');

-- INBOUND (award/credit-memo flow) --------------------------------------------
-- NOTE: source code, pay group and activity type are NOT stored here. They are
-- volatile runtime values that OIC passes into the procedures as parameters
-- (source_code -> build_fbdi_cm_set; activity_type -> run_inbound/validate_batch;
-- pay_group -> build_duedate_set, optional - null means "do not touch pay group").
--
-- OIC-ONLY RE-ARCHITECTURE: the DB no longer calls Fusion ERP REST (client ruling -
-- OIC is the only sanctioned caller). So the Fusion REST base URL / credential and
-- the DBMS_PARALLEL_EXECUTE / retry knobs are OIC's concern, NOT the package's.
-- load_config in LWS_AP_C2FO_AWARD_PKG reads ONLY the COMMON obj-storage triple and
-- the two ERROR_ keys below. The four dead keys (FUSION_REST_BASE_URL,
-- FUSION_REST_CRED, PARALLEL_LEVEL, MAX_PATCH_RETRIES) are seeded ENABLED_FLAG='N'
-- so they are inert here yet self-documenting; delete them once no doc references
-- them. Do NOT make them MANDATORY - a mandatory dead key would fail load_config.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, ENABLED_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'FUSION_REST_BASE_URL', NULL, 'N', 'N', 'DEAD (OIC-only): Fusion REST base - now OIC-owned, not read by the package');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, ENABLED_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'FUSION_REST_CRED', NULL, 'N', 'N', 'DEAD (OIC-only): Fusion REST credential - now OIC-owned, not read by the package');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'ERROR_BUCKET', '&&err_bucket', 'Y', 'OCI bucket for the error-file + run-log return to C2FO (write_error_file / write_run_log_file)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'ERROR_FOLDER', NULLIF('&&err_folder', ''), 'N', 'Folder within ERROR_BUCKET for error/log files');
-- Archive bucket/folder the award file is MOVED to after a successful load
-- (load_award_file). ARCHIVE_BUCKET is mandatory and set per environment (no
-- hardcoded fallback in the package). ARCHIVE_FOLDER unset => archive at bucket
-- root.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'ARCHIVE_BUCKET', '&&arch_bucket', 'Y', 'OCI bucket the award file is moved to after a successful load (load_award_file)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'ARCHIVE_FOLDER', NULLIF('&&arch_folder', ''), 'N', 'Folder within ARCHIVE_BUCKET for archived award files (NULL = bucket root)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, ENABLED_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'PARALLEL_LEVEL', '4', 'N', 'N', 'DEAD (OIC-only): due-date concurrency is an OIC knob now, not a DB parallel level');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, ENABLED_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'MAX_PATCH_RETRIES', '3', 'N', 'N', 'DEAD (OIC-only): REST retry cap is an OIC knob now, not read by the package');
-- Award-history purge window (DB design BR#12): the separate purge deletes award
-- rows whose CREATED_DATE is older than this many months. Optional here; the purge
-- proc supplies its own default if unset.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'AWARD_RETENTION_MONTHS', NULL, 'N', 'Award-history retention window in months for the scheduled purge (BR#12)');

-- CM FBDI import chunk size: rows per FBDI import chunk (chunk_cm_awards). Optional
-- empirical tuning knob - raise/lower to find the import "knee"; the package falls
-- back to its code default (50000) if unset.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'CM_CHUNK_SIZE', '50000', 'N', 'Rows per CM FBDI import chunk (chunk_cm_awards));

-- Supplier-exclusion lists re-applied at inbound award validation (validate_batch),
-- so an award for a supplier that changed eligibility after its invoices were offered
-- is rejected. These MIRROR the outbound extract's OIC exclusion lists (the
-- p_exclude_* params on LWS_OB_EXTRACT_ATP_PKG.extract_invoices) - keep the values
-- here ALIGNED with the outbound OIC lookup so both ends filter identically.
-- Comma-separated; blank/absent => exclude none (same as the outbound NULL default).
-- NOTE: do NOT list C2FO / C2FO_BANK in EXCL_PAY_GROUPS - the "already C2FO pay group"
-- gate (BR#16) handles re-awards; listing them here would false-reject re-awards.
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'EXCL_VENDOR_TYPES', 'CC,GVT,RE,PRO,PR,NP,ENT,LGL,FN,HR,CNS,PH,RK,UT,TX,I2,I3,IS', 'N', 'Comma list of supplier vendor_type_lookup_code values excluded from awarding (match outbound p_exclude_vendor_types)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'EXCL_PAYMENT_TERMS', 'Immediate,Net Monthly Account,End of Month, NET 07, NET 10,NET 05, 00.9% NET 010, NET 04, 03.0% NET 010,05.0% NET 010,NET 03,02.0% NET 010,00.5% NET 010,01.0% NET 001,01.0% NET 010,NET 01,1% 10 NET 11,5% 10 NET 11', 'N', 'Comma list of payment-term NAMES excluded from awarding, supplier-wide (match outbound p_exclude_payment_terms)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'EXCL_PAY_GROUPS', 'A1,A2,A3,IM', 'N', 'Comma list of invoice pay_group_lookup_code values excluded from awarding (match outbound p_exclude_pay_groups)');


INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'LOG_BUCKET', '@@log_bucket', 'N', 'Bucket for Error file of award to go back to C2FO');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('INBOUND', 'LOG_FOLDER', '@@log_folder', 'N', 'Folder for Error file of award to go back to C2FO');


-- OUTBOUND --------------------------------------------------------------------
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('OUTBOUND', 'NOTIFICATION_TOPIC_OCID', NULL, 'N', 'OCI Notifications topic OCID for outbound-run self-notify');

COMMIT;

-- Clear the prompted substitution vars (so a re-run re-prompts, not silently
-- reuses the cached values) and restore DEFINE OFF for the rest of the install.
UNDEFINE obj_cred obj_ns obj_uri err_bucket err_folder arch_bucket arch_folder
SET DEFINE OFF
