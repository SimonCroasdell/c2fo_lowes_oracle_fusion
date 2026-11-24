--------------------------------------------------------------------------------
-- LWS_C2FO_PROCESS_STAGE_LOG  -  per-stage audit log for the BICC load pipeline
-- (list_files / extract_zip / load_csv / merge stages, one row per stage per file)
--
-- Extracted verbatim from the shared-drive install driver
--   02 - Code shared/c2fo/c2fo/test/00_run_all_ddl.sql (was inline-only there).
-- LWS_C2FO_COMMON_PKG.log_process_stage_proc writes to this table; it has no
-- standalone DDL file on the shared drive, so it is captured here for the
-- self-contained installer. Order it with the other tracking table (step 1).
--------------------------------------------------------------------------------
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_PROCESS_STAGE_LOG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_PROCESS_STAGE_LOG (
    LOG_ID               NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    FILE_SEQ_ID          NUMBER,
    INSTANCE_ID          VARCHAR2(100),
    STAGE_NAME           VARCHAR2(200),
    STATUS               VARCHAR2(30),
    MESSAGE              VARCHAR2(4000),
    ENTITY_GROUP         VARCHAR2(100),
    FILE_NAME            VARCHAR2(500),
    DEP_FILE_NAME        VARCHAR2(500),
    ATTRIBUTE1           VARCHAR2(500),
    ATTRIBUTE2           VARCHAR2(500),
    CREATED_DATE         TIMESTAMP      DEFAULT SYSTIMESTAMP
);
