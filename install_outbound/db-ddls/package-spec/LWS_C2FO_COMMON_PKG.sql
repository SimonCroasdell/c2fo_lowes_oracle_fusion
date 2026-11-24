--------------------------------------------------------------------------------
-- LWS_C2FO_COMMON_PKG  (LWS_CUSTOM_C2FO_SA)
-- Reconstructed full source, version-controlled, with the gzip + file-matching
-- fixes applied (2026-08-16).
--
-- WHAT CHANGED vs the originally-installed body:
--   1. extract_zip_proc: Fusion BICC delivers .csv.gz (gzip), not PKZIP .zip.
--      APEX_ZIP cannot read a gzip stream, so nothing was ever staged and every
--      load produced 0 rows silently. Replaced the APEX_ZIP block with
--      UTL_COMPRESS.LZ_UNCOMPRESS (verified to decompress the .gz directly on
--      this ATP) and write the plain CSV to temp/<pvo_leaf>.csv.
--   2. process_bicc_file_proc:
--      a. list_files_proc lists the WHOLE folder and tags every object with the
--         current entity_group, so c_files previously returned every file for
--         every entity. Now c_files only selects the file whose name matches the
--         anchored PVO-leaf pattern  %_<leaf>-batch%  (leaf = last dot-segment of
--         PVO_NAME, lowercased). The anchor resolves the substring collisions
--         supplierextractpvo vs suppliersiteextractpvo and
--         purchasingdocumentlineextractpvo vs ...linelocationextractpvo.
--      b. After extract, load ONLY temp/<pvo_leaf>.csv (not "list all of temp/"),
--         so one entity's temp CSV can never be loaded into another's table.
--   3. Removed merge_to_stg_proc (the STG self-merge). It did MERGE INTO stg USING
--      (SELECT ... FROM the SAME stg) - a no-op that only deduped + relabelled
--      RECORD_STATUS and never moved data (and was where a data-loss bug lived).
--      Nothing downstream needs it: the typed bridge (LWS_C2FO_BRIDGE_PKG) reads
--      _STG directly (WHERE RECORD_STATUS <> 'ERROR') and dedupes on the mirror PK.
--      Pipeline is now: list -> extract -> load (rows land INPROCESS) -> bridge.
--      STG cleanup moved to the bridge: each bridge DELETEs its consumed rows, with
--      an optional bridge_all_proc(p_truncate_all=>'Y') space-reclaim sweep.
--
-- The load is HEADER-DRIVEN: load_csv_to_stg_proc reads the CSV header and maps each
-- token to its STG column by name via LWS_C2FO_PVO_COLUMN_MAP (column_position is a
-- name dictionary, NOT an ordering authority), so column order need not match the map.
--------------------------------------------------------------------------------

CREATE OR REPLACE EDITIONABLE PACKAGE LWS_CUSTOM_C2FO_SA.LWS_C2FO_COMMON_PKG AS

    FUNCTION get_project_config_fun RETURN VARCHAR2;

    PROCEDURE log_process_stage_proc (
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_status         IN VARCHAR2,
        p_message        IN VARCHAR2,
        p_entity_group   IN VARCHAR2 DEFAULT NULL,
        p_stage_name     IN VARCHAR2 DEFAULT NULL,
        p_file_name      IN VARCHAR2 DEFAULT NULL,
        p_dep_file_name  IN VARCHAR2 DEFAULT NULL,
        p_attribute1     IN VARCHAR2 DEFAULT NULL,
        p_attribute2     IN VARCHAR2 DEFAULT NULL
    );

    PROCEDURE list_files_proc (
        p_entity_group   IN VARCHAR2,
        p_bucket_name    IN VARCHAR2,
        p_folder_path    IN VARCHAR2 DEFAULT NULL,
        p_pvo_name       IN VARCHAR2 DEFAULT NULL,
        p_stg_table_name IN VARCHAR2 DEFAULT NULL,
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_err_msg        OUT VARCHAR2
    );

    PROCEDURE extract_zip_proc (
        p_entity_group   IN VARCHAR2,
        p_bucket_name    IN VARCHAR2,
        p_folder_path    IN VARCHAR2 DEFAULT NULL,
        p_file_name      IN VARCHAR2,
        p_stg_table_name IN VARCHAR2,
        p_pvo_name       IN VARCHAR2,
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_archive_flag   IN VARCHAR2 DEFAULT 'Y',
        p_err_msg        OUT VARCHAR2
    );

    PROCEDURE load_csv_to_stg_proc (
        p_entity_group   IN VARCHAR2,
        p_pvo_name       IN VARCHAR2,
        p_stg_table_name IN VARCHAR2,
        p_bucket_name    IN VARCHAR2,
        p_folder_path    IN VARCHAR2 DEFAULT NULL,
        p_file_name      IN VARCHAR2,
        p_source_code    IN VARCHAR2 DEFAULT NULL,
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_err_msg        OUT VARCHAR2
    );

    PROCEDURE archive_file_proc (
        p_bucket_name       IN VARCHAR2,
        p_folder_path       IN VARCHAR2 DEFAULT NULL,
        p_file_name         IN VARCHAR2,
        p_archive_bucket    IN VARCHAR2,
        p_archive_folder    IN VARCHAR2 DEFAULT NULL,
        p_err_msg           OUT VARCHAR2
    );

    PROCEDURE move_to_error_proc (
        p_bucket_name       IN VARCHAR2,
        p_folder_path       IN VARCHAR2 DEFAULT NULL,
        p_file_name         IN VARCHAR2,
        p_error_bucket      IN VARCHAR2,
        p_error_folder      IN VARCHAR2 DEFAULT NULL,
        p_err_msg           OUT VARCHAR2
    );

    PROCEDURE process_bicc_file_proc (
        p_entity_group   IN VARCHAR2,
        p_bucket_name    IN VARCHAR2,
        p_folder_path    IN VARCHAR2,
        p_stg_table_name IN VARCHAR2,
        p_pvo_name       IN VARCHAR2,
        p_pk_columns     IN VARCHAR2,
        p_file_name      IN VARCHAR2 DEFAULT NULL,
        p_archive_flag   IN VARCHAR2 DEFAULT 'Y',
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_err_msg        OUT VARCHAR2
    );

    -- Synchronous "load everything now": loop process_bicc_file_proc over every
    -- enabled entity in LWS_C2FO_PVO_COLUMN_MAP (bucket->STG), then run the typed
    -- bridge (STG->mirror). Writes the run-level outcome to LWS_C2FO_LOAD_RUN_LOG
    -- row p_run_id. Called by the async job that submit_load spawns; can also be
    -- run inline for a foreground load.
    PROCEDURE run_load (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_archive_flag  IN  VARCHAR2 DEFAULT 'Y',
        p_truncate_all  IN  VARCHAR2 DEFAULT 'N',
        p_run_id        IN  NUMBER   DEFAULT NULL,
        o_run_id        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

    -- Async submit: reserve a LWS_C2FO_LOAD_RUN_LOG row (SUBMITTED) and spawn a
    -- one-shot DBMS_SCHEDULER job that runs run_load. Returns o_run_id for OIC to
    -- poll. Mirrors LWS_OB_EXTRACT_ATP_PKG.submit_outbound.
    PROCEDURE submit_load (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_archive_flag  IN  VARCHAR2 DEFAULT 'Y',
        p_truncate_all  IN  VARCHAR2 DEFAULT 'N',
        o_run_id        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    );

END lws_c2fo_common_pkg;
/


