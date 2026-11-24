--------------------------------------------------------------------------------
-- LWS_C2FO_LOAD_RUN_LOG  -  one row per BICC->mirror LOAD run, for OIC polling.
--
-- The inbound-load OIC integration submits LWS_C2FO_COMMON_PKG.submit_load, which
-- reserves a row here as SUBMITTED and spawns a DBMS_SCHEDULER job. OIC then polls
-- this single row (by RUN_ID) for the terminal STATUS (SUCCESS/ERROR/SKIPPED),
-- exactly as the outbound integration polls LWS_OB_RUN_LOG.
--
-- This is the load-side analogue of LWS_OB_RUN_LOG (70_outbound_staging.sql). The
-- per-stage audit detail still lands in LWS_C2FO_PROCESS_STAGE_LOG (keyed by the
-- same INSTANCE_ID = RUN_ID); this table is the run-level summary OIC watches.
--------------------------------------------------------------------------------
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_LOAD_RUN_LOG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_LOAD_RUN_LOG (
    RUN_ID          NUMBER          NOT NULL,
    INSTANCE_ID     VARCHAR2(100),                  -- = RUN_ID, correlates to LWS_C2FO_PROCESS_STAGE_LOG
    BUCKET_NAME     VARCHAR2(400),
    FOLDER_PATH     VARCHAR2(500),
    ENTITIES_TOTAL  NUMBER,                         -- distinct enabled entities attempted
    ENTITIES_FAILED NUMBER,                         -- entities whose load raised
    START_TIME      DATE,
    END_TIME        DATE,
    STATUS          VARCHAR2(20),                   -- SUBMITTED / RUNNING / SUCCESS / ERROR / SKIPPED
    ERROR_MESSAGE   VARCHAR2(4000),
    CONSTRAINT PK_LWS_C2FO_LOAD_RUN_LOG PRIMARY KEY (RUN_ID)
);

