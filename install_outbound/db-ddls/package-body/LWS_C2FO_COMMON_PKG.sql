CREATE OR REPLACE EDITIONABLE PACKAGE BODY LWS_CUSTOM_C2FO_SA.LWS_C2FO_COMMON_PKG AS

    g_credential_name  VARCHAR2(200);
    g_name_space       VARCHAR2(200);
    g_obj_uri          VARCHAR2(500);

    -- Leaf token of a fully-qualified PVO name (last dot-segment, lowercased).
    -- e.g. 'FscmTopModelAM...InvoiceHeaderExtractPVO' -> 'invoiceheaderextractpvo'.
    -- Used to match BICC files named file_<ampath>_<leaf>-batch<n>-<date>.csv.gz.
    FUNCTION pvo_leaf_fun (p_pvo_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN LOWER(REGEXP_SUBSTR(p_pvo_name, '[^.]+$'));
    END pvo_leaf_fun;

    -- Key/value config reader (COMMON group). Returns p_default when the row is
    -- absent/disabled; raises when a MANDATORY_FLAG='Y' row resolves to NULL.
    FUNCTION cfg (
        p_group   IN VARCHAR2,
        p_key     IN VARCHAR2,
        p_default IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 IS
        l_val  VARCHAR2(4000);
        l_mand VARCHAR2(1);
    BEGIN
        SELECT config_value, mandatory_flag
        INTO   l_val, l_mand
        FROM   lws_c2fo_config
        WHERE  config_group = p_group
        AND    config_key   = p_key
        AND    enabled_flag = 'Y';

        IF l_val IS NULL THEN
            IF l_mand = 'Y' THEN
                RAISE_APPLICATION_ERROR(-20050,
                    'Missing mandatory config: ' || p_group || '.' || p_key);
            END IF;
            RETURN p_default;
        END IF;
        RETURN l_val;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_default;
    END cfg;

    FUNCTION get_project_config_fun RETURN VARCHAR2 IS
    BEGIN
        g_credential_name := cfg('COMMON', 'OBJ_STORAGE_CREDENTIALS');
        g_name_space      := cfg('COMMON', 'OBJ_STORAGE_NAMESPACE');
        g_obj_uri         := cfg('COMMON', 'OBJ_URI');
        RETURN 'Y';
    EXCEPTION
        WHEN OTHERS THEN
            RETURN 'N';
    END get_project_config_fun;

    FUNCTION build_obj_storage_url (
        p_bucket_name  IN VARCHAR2,
        p_folder_path  IN VARCHAR2 DEFAULT NULL,
        p_file_name    IN VARCHAR2 DEFAULT NULL
    ) RETURN VARCHAR2 IS
        l_url VARCHAR2(2000);
    BEGIN
        l_url := g_obj_uri
                 || '/n/' || g_name_space
                 || '/b/' || p_bucket_name
                 || '/o/';
        IF p_folder_path IS NOT NULL THEN
            l_url := l_url || p_folder_path || '/';
        END IF;
        IF p_file_name IS NOT NULL THEN
            l_url := l_url || p_file_name;
        END IF;
        RETURN l_url;
    END build_obj_storage_url;

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
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO lws_c2fo_process_stage_log (
            instance_id, stage_name, status, message,
            entity_group, file_name, dep_file_name,
            attribute1, attribute2
        ) VALUES (
            p_instance_id, p_stage_name, p_status, SUBSTR(p_message, 1, 4000),
            p_entity_group, p_file_name, p_dep_file_name,
            p_attribute1, p_attribute2
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
    END log_process_stage_proc;

    PROCEDURE list_files_proc (
        p_entity_group   IN VARCHAR2,
        p_bucket_name    IN VARCHAR2,
        p_folder_path    IN VARCHAR2 DEFAULT NULL,
        p_pvo_name       IN VARCHAR2 DEFAULT NULL,
        p_stg_table_name IN VARCHAR2 DEFAULT NULL,
        p_instance_id    IN VARCHAR2 DEFAULT NULL,
        p_err_msg        OUT VARCHAR2
    ) IS
        l_url           VARCHAR2(2000);
        l_proj_config   VARCHAR2(5);
        l_leaf          VARCHAR2(200) := pvo_leaf_fun(p_pvo_name);
        CURSOR c_files (p_cred VARCHAR2, p_uri VARCHAR2) IS
        SELECT object_name
        FROM   TABLE(dbms_cloud.list_objects(p_cred, p_uri))
        WHERE  object_name NOT LIKE 'temp/%'
        AND    object_name NOT LIKE '%/'
        AND    bytes > 0
        -- Only files belonging to THIS entity's PVO. Anchored on '_<leaf>-batch'
        -- to avoid substring collisions between related PVO leaf tokens.
        -- If no PVO given, fall back to the old "list everything" behaviour.
        AND    ( p_pvo_name IS NULL
                 OR LOWER(object_name) LIKE '%\_' || l_leaf || '-batch%' ESCAPE '\' )
        -- Insert in oldest-batch-first order so FILE_SEQ_ID also ascends with batch#.
        ORDER BY TO_NUMBER(REGEXP_SUBSTR(object_name, '-batch([0-9]+)', 1, 1, NULL, 1)) NULLS LAST,
                 object_name;
    BEGIN
        l_proj_config := get_project_config_fun();
        IF l_proj_config = 'N' THEN
            p_err_msg := 'ERROR: Could not load project configuration';
            RETURN;
        END IF;

        l_url := build_obj_storage_url(p_bucket_name, p_folder_path);

        FOR rec IN c_files(g_credential_name, l_url) LOOP
            INSERT INTO lws_c2fo_file_process_status (
                file_name, entity_group, pvo_name, stg_table_name,
                status, process_time, bucket_name, folder_path,
                instance_id
            ) VALUES (
                rec.object_name, p_entity_group, p_pvo_name, p_stg_table_name,
                'INITIATE', SYSTIMESTAMP, p_bucket_name, p_folder_path,
                p_instance_id
            );
        END LOOP;
        COMMIT;

        p_err_msg := 'SUCCESS';
        log_process_stage_proc(
            p_instance_id  => p_instance_id,
            p_status       => 'SUCCESS',
            p_message      => 'Files listed successfully',
            p_entity_group => p_entity_group,
            p_stage_name   => 'list_files_proc',
            p_attribute1   => p_bucket_name
        );
    EXCEPTION
        WHEN OTHERS THEN
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
            log_process_stage_proc(
                p_instance_id  => p_instance_id,
                p_status       => 'ERROR',
                p_message      => p_err_msg,
                p_entity_group => p_entity_group,
                p_stage_name   => 'list_files_proc'
            );
    END list_files_proc;

    -- Decompress the .csv.gz for p_file_name and stage the plain CSV as
    -- temp/<pvo_leaf>.csv. Uses UTL_COMPRESS.LZ_UNCOMPRESS (handles the gzip
    -- container directly on this ATP). Replaces the old APEX_ZIP implementation
    -- which only understood PKZIP .zip archives.
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
    ) IS
        l_gz            BLOB;
        l_plain         BLOB;
        l_url           VARCHAR2(2000);
        l_temp_file     VARCHAR2(500);
        l_temp_url      VARCHAR2(2000);
        l_proj_config   VARCHAR2(5);
        l_archive_msg   VARCHAR2(4000);
    BEGIN
        l_proj_config := get_project_config_fun();
        IF l_proj_config = 'N' THEN
            p_err_msg := 'ERROR: Could not load project configuration';
            RETURN;
        END IF;

        l_url := build_obj_storage_url(p_bucket_name, p_folder_path, p_file_name);
        -- Deterministic per-entity temp name so the load step can pick exactly
        -- this entity's CSV and nothing else.
        l_temp_file := pvo_leaf_fun(p_pvo_name) || '.csv';
        l_temp_url  := build_obj_storage_url(p_bucket_name, p_folder_path) || 'temp/' || l_temp_file;

        dbms_lob.createtemporary(l_gz, FALSE);

        l_gz := dbms_cloud.get_object(
            credential_name => g_credential_name,
            object_uri      => l_url
        );

        -- gzip -> plain. LZ_UNCOMPRESS returns the decompressed BLOB.
        l_plain := utl_compress.lz_uncompress(l_gz);

        dbms_cloud.put_object(
            credential_name => g_credential_name,
            object_uri      => l_temp_url,
            contents        => l_plain
        );

        dbms_lob.freetemporary(l_gz);
        BEGIN dbms_lob.freetemporary(l_plain); EXCEPTION WHEN OTHERS THEN NULL; END;

        UPDATE lws_c2fo_file_process_status
        SET    status = 'EXTRACTED', process_time = SYSTIMESTAMP
        WHERE  file_name = p_file_name
        AND    entity_group = p_entity_group
        AND    status = 'INITIATE';

        COMMIT;

        -- NOTE: source-file cleanup is NOT done here per-file anymore. It is a single
        -- end-of-run DELETE sweep in run_load (Stage 4), which only fires when the
        -- whole run succeeds. Doing it per-file would delete a file before the run is
        -- known-good, and the previous per-file archive_file_proc call is retired.
        l_archive_msg := 'DEFERRED_TO_RUN_END';

        p_err_msg := 'SUCCESS';
        log_process_stage_proc(
            p_instance_id  => p_instance_id,
            p_status       => 'SUCCESS',
            p_message      => 'Decompressed ' || p_file_name || ' -> temp/' || l_temp_file
                              || CASE WHEN p_archive_flag = 'Y'
                                      THEN ' | archive=' || NVL(l_archive_msg, 'SKIPPED')
                                      ELSE '' END,
            p_entity_group => p_entity_group,
            p_stage_name   => 'extract_zip_proc',
            p_file_name    => p_file_name
        );
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN dbms_lob.freetemporary(l_gz); EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN dbms_lob.freetemporary(l_plain); EXCEPTION WHEN OTHERS THEN NULL; END;
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
            UPDATE lws_c2fo_file_process_status
            SET    status = 'EXTRACT_ERROR', process_time = SYSTIMESTAMP,
                   err_msg = SUBSTR(p_err_msg, 1, 4000)
            WHERE  file_name = p_file_name AND entity_group = p_entity_group;
            COMMIT;
            log_process_stage_proc(
                p_instance_id  => p_instance_id,
                p_status       => 'ERROR',
                p_message      => p_err_msg,
                p_entity_group => p_entity_group,
                p_stage_name   => 'extract_zip_proc',
                p_file_name    => p_file_name
            );
    END extract_zip_proc;

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
    ) IS
        l_url            VARCHAR2(2000);
        l_ext_tbl_name   VARCHAR2(128);
        l_ext_table_sql  CLOB;
        l_field_list     CLOB;
        l_col_list       CLOB;
        l_stg_col_list   CLOB;
        l_insert_sql     CLOB;
        l_proj_config    VARCHAR2(5);
        l_row_count      NUMBER := 0;
        l_cnt            NUMBER := 0;        -- columns actually mapped + inserted
        l_ignore_cnt     NUMBER := 0;        -- CSV columns with no map row (consumed, dropped)

        -- Map is a NAME dictionary, not an ordering authority: column_position is
        -- alphabetical and does NOT match the CSV column order once a file is a
        -- subset of the map (e.g. AP_PAY_SCHEDS: 26 CSV cols vs 98 map rows), so
        -- positional binding by column_position silently misaligns data. Instead we
        -- read the CSV HEADER and build the field/column lists in FILE order, looking
        -- up each header token in this dictionary to find its STG column.
        --   key   = pvo_column_name uppercased, non-alphanumerics stripped
        --           (the transform BICC applies: ApFooBar -> APFOOBAR == header token)
        --   value = stg_column_name
        TYPE t_dict IS TABLE OF VARCHAR2(128) INDEX BY VARCHAR2(200);
        l_dict     t_dict;
        l_key      VARCHAR2(200);
        l_stg_col  VARCHAR2(128);

        -- header reading / tokenizing
        l_hdr_blob BLOB;
        l_nl       NUMBER;
        l_hdr      VARCHAR2(32767);
        l_start    PLS_INTEGER;
        l_comma    PLS_INTEGER;
        l_tok      VARCHAR2(4000);

        PROCEDURE add_col(p_field VARCHAR2, p_col VARCHAR2, p_insert BOOLEAN) IS
        BEGIN
            IF l_field_list IS NOT NULL THEN
                l_field_list := l_field_list || ', ';
                l_col_list   := l_col_list   || ', ';
            END IF;
            l_field_list := l_field_list || '"' || p_field || '" CHAR(4000)';
            l_col_list   := l_col_list   || '"' || p_col   || '" VARCHAR2(4000)';
            IF p_insert THEN
                IF l_stg_col_list IS NOT NULL THEN
                    l_stg_col_list := l_stg_col_list || ', ';
                END IF;
                l_stg_col_list := l_stg_col_list || p_col;
            END IF;
        END add_col;
    BEGIN
        l_proj_config := get_project_config_fun();
        IF l_proj_config = 'N' THEN
            p_err_msg := 'ERROR: Could not load project configuration';
            RETURN;
        END IF;

        l_url := build_obj_storage_url(p_bucket_name, p_folder_path, p_file_name);
        l_ext_tbl_name := 'C2FO_EXT_' || SUBSTR(REPLACE(p_stg_table_name, 'LWS_C2FO_', ''), 1, 100);

        -- 1) Build the name dictionary (normalized token -> STG column). A duplicate
        --    normalized token within a PVO would make the mapping ambiguous, so error.
        FOR rec IN (
            SELECT pvo_column_name, stg_column_name
            FROM   lws_c2fo_pvo_column_map
            WHERE  pvo_name = p_pvo_name
            AND    stg_table_name = p_stg_table_name
            AND    is_enabled = 'Y'
        ) LOOP
            l_key := REGEXP_REPLACE(UPPER(rec.pvo_column_name), '[^A-Z0-9]', '');
            IF l_dict.EXISTS(l_key) THEN
                p_err_msg := 'ERROR: duplicate normalized column token ''' || l_key
                    || ''' for PVO ' || p_pvo_name || ' (maps both '
                    || l_dict(l_key) || ' and ' || rec.stg_column_name || ')';
                log_process_stage_proc(p_instance_id => p_instance_id, p_status => 'ERROR',
                    p_message => p_err_msg, p_entity_group => p_entity_group,
                    p_stage_name => 'load_csv_to_stg_proc', p_file_name => p_file_name);
                RETURN;
            END IF;
            l_dict(l_key) := rec.stg_column_name;
        END LOOP;

        IF l_dict.COUNT = 0 THEN
            p_err_msg := 'ERROR: No column mappings found for PVO: ' || p_pvo_name;
            log_process_stage_proc(
                p_instance_id  => p_instance_id,
                p_status       => 'ERROR',
                p_message      => p_err_msg,
                p_entity_group => p_entity_group,
                p_stage_name   => 'load_csv_to_stg_proc',
                p_file_name    => p_file_name
            );
            RETURN;
        END IF;

        -- 2) Read the CSV header line (first line) from the same file the ext table loads.
        --    BICC headers are ASCII column names, but the file may carry a UTF-8 BOM
        --    (EF BB BF) and is UTF-8 encoded. Strip the BOM and any stray CR AT THE RAW
        --    level, then cast: casting raw bytes that are invalid in the DB charset (or a
        --    byte slice split mid-character) raises ORA-29275, so we work in RAW first and
        --    only cast the clean, single-byte-safe header slice.
        l_hdr_blob := dbms_cloud.get_object(credential_name => g_credential_name,
                                            object_uri      => l_url);
        l_nl := dbms_lob.instr(l_hdr_blob, HEXTORAW('0A'), 1, 1);
        IF l_nl = 0 THEN l_nl := LEAST(dbms_lob.getlength(l_hdr_blob), 32767) + 1; END IF;
        DECLARE
            l_raw   RAW(32767);
            l_len   PLS_INTEGER := LEAST(l_nl - 1, 32767);
        BEGIN
            l_raw := dbms_lob.substr(l_hdr_blob, l_len, 1);
            -- strip leading UTF-8 BOM (EF BB BF) if present
            IF UTL_RAW.LENGTH(l_raw) >= 3
               AND UTL_RAW.SUBSTR(l_raw, 1, 3) = HEXTORAW('EFBBBF') THEN
                l_raw := UTL_RAW.SUBSTR(l_raw, 4);
            END IF;
            -- strip trailing CR (CRLF files) if present
            IF UTL_RAW.LENGTH(l_raw) >= 1
               AND UTL_RAW.SUBSTR(l_raw, UTL_RAW.LENGTH(l_raw), 1) = HEXTORAW('0D') THEN
                l_raw := UTL_RAW.SUBSTR(l_raw, 1, UTL_RAW.LENGTH(l_raw) - 1);
            END IF;
            l_hdr := UTL_RAW.CAST_TO_VARCHAR2(l_raw);
        END;
        BEGIN dbms_lob.freetemporary(l_hdr_blob); EXCEPTION WHEN OTHERS THEN NULL; END;

        -- 3) Walk header tokens IN FILE ORDER, building field/column/insert lists.
        --    Known token -> insert into its STG column. Unknown token -> consume the
        --    position with a throwaway column so downstream columns stay aligned, but
        --    do NOT insert it. Map rows absent from the header are simply never emitted
        --    (their STG columns stay NULL).
        l_start := 1;
        LOOP
            l_comma := INSTR(l_hdr, ',', l_start);
            IF l_comma = 0 THEN
                l_tok := SUBSTR(l_hdr, l_start);
            ELSE
                l_tok := SUBSTR(l_hdr, l_start, l_comma - l_start);
            END IF;
            l_key := REGEXP_REPLACE(UPPER(TRIM(l_tok)), '[^A-Z0-9]', '');

            IF l_dict.EXISTS(l_key) THEN
                l_stg_col := l_dict(l_key);
                add_col(l_stg_col, l_stg_col, TRUE);
                l_cnt := l_cnt + 1;
            ELSE
                l_ignore_cnt := l_ignore_cnt + 1;
                add_col('C2FO_IGNORE_' || l_ignore_cnt, 'C2FO_IGNORE_' || l_ignore_cnt, FALSE);
            END IF;

            EXIT WHEN l_comma = 0;
            l_start := l_comma + 1;
        END LOOP;

        IF l_cnt = 0 THEN
            p_err_msg := 'ERROR: header for ' || p_file_name
                || ' matched no mapped columns for PVO ' || p_pvo_name;
            log_process_stage_proc(p_instance_id => p_instance_id, p_status => 'ERROR',
                p_message => p_err_msg, p_entity_group => p_entity_group,
                p_stage_name => 'load_csv_to_stg_proc', p_file_name => p_file_name);
            RETURN;
        END IF;

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl_name;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        l_ext_table_sql := 'BEGIN DBMS_CLOUD.CREATE_EXTERNAL_TABLE('
            || 'table_name => ''' || l_ext_tbl_name || ''', '
            || 'credential_name => ''' || g_credential_name || ''', '
            || 'file_uri_list => ''' || l_url || ''', '
            || 'format => JSON_OBJECT('
            ||   '''type'' VALUE ''CSV'''
            || ', ''skipheaders'' VALUE ''1'''
            || ', ''delimiter'' VALUE '','
            || ''', ''characterset'' VALUE ''AL32UTF8'''
            || ', ''blankasnull'' VALUE ''true'''
            || ', ''ignoremissingcolumns'' VALUE ''true'''
            || ', ''ignoreblanklines'' VALUE ''true'''
            || ', ''rejectlimit'' VALUE ''0'''
            || ', ''trimspaces'' VALUE ''lrtrim'''
            || '), '
            || 'field_list => ''' || l_field_list || ''', '
            || 'column_list => ''' || l_col_list || '''); END;';

        EXECUTE IMMEDIATE l_ext_table_sql;

        l_insert_sql := 'INSERT INTO ' || p_stg_table_name || ' ('
            || l_stg_col_list
            || ', FILE_NAME, SOURCE_CODE, INSTANCE_ID, RECORD_STATUS'
            || ') SELECT '
            || l_stg_col_list
            || ', ''' || p_file_name || ''''
            || ', ''' || NVL(p_source_code, p_entity_group) || ''''
            || ', ''' || p_instance_id || ''''
            || ', ''INPROCESS'''
            || ' FROM ' || l_ext_tbl_name;

        EXECUTE IMMEDIATE l_insert_sql;
        l_row_count := SQL%ROWCOUNT;
        COMMIT;

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl_name;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        UPDATE lws_c2fo_file_process_status
        SET    status = 'LOADED',
               process_time = SYSTIMESTAMP,
               loaded_record_count = l_row_count
        WHERE  file_name = p_file_name
        AND    entity_group = p_entity_group;
        COMMIT;

        p_err_msg := 'SUCCESS';
        log_process_stage_proc(
            p_instance_id  => p_instance_id,
            p_status       => 'SUCCESS',
            p_message      => 'Loaded ' || l_row_count || ' rows into ' || p_stg_table_name
                              || ' (' || l_cnt || ' header cols mapped, '
                              || l_ignore_cnt || ' unmapped/ignored)',
            p_entity_group => p_entity_group,
            p_stage_name   => 'load_csv_to_stg_proc',
            p_file_name    => p_file_name
        );
    EXCEPTION
        WHEN OTHERS THEN
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl_name;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
            UPDATE lws_c2fo_file_process_status
            SET    status = 'LOAD_ERROR', process_time = SYSTIMESTAMP,
                   err_msg = SUBSTR(p_err_msg, 1, 4000)
            WHERE  file_name = p_file_name AND entity_group = p_entity_group;
            COMMIT;
            log_process_stage_proc(
                p_instance_id  => p_instance_id,
                p_status       => 'ERROR',
                p_message      => p_err_msg,
                p_entity_group => p_entity_group,
                p_stage_name   => 'load_csv_to_stg_proc',
                p_file_name    => p_file_name
            );
    END load_csv_to_stg_proc;

    PROCEDURE archive_file_proc (
        p_bucket_name       IN VARCHAR2,
        p_folder_path       IN VARCHAR2 DEFAULT NULL,
        p_file_name         IN VARCHAR2,
        p_archive_bucket    IN VARCHAR2,
        p_archive_folder    IN VARCHAR2 DEFAULT NULL,
        p_err_msg           OUT VARCHAR2
    ) IS
        l_source_url   VARCHAR2(2000);
        l_archive_url  VARCHAR2(2000);
        l_blob         BLOB;
        l_proj_config  VARCHAR2(5);
    BEGIN
        l_proj_config := get_project_config_fun();
        l_source_url  := build_obj_storage_url(p_bucket_name, p_folder_path, p_file_name);
        l_archive_url := build_obj_storage_url(p_archive_bucket, p_archive_folder, p_file_name);

        -- Copy SERVER-SIDE within Object Storage. The previous get_object -> BLOB ->
        -- put_object approach streamed the whole file through the DB session, which
        -- silently failed for large .gz (e.g. the 190MB invoice-header extract) and
        -- left the source in place -> it was re-listed and re-loaded every run.
        -- BULK_COPY performs the copy inside OCI, so file size is not a DB-memory limit.
        BEGIN
            dbms_cloud.bulk_copy(
                source_credential_name => g_credential_name,
                source_location_uri    => l_source_url,
                target_location_uri    => l_archive_url
            );
        EXCEPTION
            WHEN OTHERS THEN
                -- Fallback for small files / environments where BULK_COPY is unavailable:
                -- stream through the DB. Large files will still fail here (and surface
                -- via p_err_msg), which is the correct, visible outcome.
                l_blob := dbms_cloud.get_object(
                    credential_name => g_credential_name,
                    object_uri      => l_source_url
                );
                dbms_cloud.put_object(
                    credential_name => g_credential_name,
                    object_uri      => l_archive_url,
                    contents        => l_blob
                );
                BEGIN dbms_lob.freetemporary(l_blob); EXCEPTION WHEN OTHERS THEN NULL; END;
        END;

        -- Only delete the source AFTER a confirmed copy (the copy above raised if it
        -- failed, so reaching here means the archive object exists).
        dbms_cloud.delete_object(
            credential_name => g_credential_name,
            object_uri      => l_source_url
        );

        p_err_msg := 'SUCCESS';
    EXCEPTION
        WHEN OTHERS THEN
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
    END archive_file_proc;

    PROCEDURE move_to_error_proc (
        p_bucket_name       IN VARCHAR2,
        p_folder_path       IN VARCHAR2 DEFAULT NULL,
        p_file_name         IN VARCHAR2,
        p_error_bucket      IN VARCHAR2,
        p_error_folder      IN VARCHAR2 DEFAULT NULL,
        p_err_msg           OUT VARCHAR2
    ) IS
        l_source_url  VARCHAR2(2000);
        l_error_url   VARCHAR2(2000);
        l_blob        BLOB;
        l_proj_config VARCHAR2(5);
    BEGIN
        l_proj_config := get_project_config_fun();
        l_source_url  := build_obj_storage_url(p_bucket_name, p_folder_path, p_file_name);
        l_error_url   := build_obj_storage_url(p_error_bucket, p_error_folder, p_file_name);

        l_blob := dbms_cloud.get_object(
            credential_name => g_credential_name,
            object_uri      => l_source_url
        );

        dbms_cloud.put_object(
            credential_name => g_credential_name,
            object_uri      => l_error_url,
            contents        => l_blob
        );

        dbms_cloud.delete_object(
            credential_name => g_credential_name,
            object_uri      => l_source_url
        );

        p_err_msg := 'SUCCESS';
    EXCEPTION
        WHEN OTHERS THEN
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
    END move_to_error_proc;

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
    ) IS
        l_instance_id   VARCHAR2(100);
        l_temp_folder   VARCHAR2(500);
        l_temp_csv      VARCHAR2(500) := pvo_leaf_fun(p_pvo_name) || '.csv';

        CURSOR c_files IS
        SELECT file_name
        FROM   lws_c2fo_file_process_status
        WHERE  entity_group = p_entity_group
        AND    stg_table_name = p_stg_table_name
        AND    status = 'INITIATE'
        AND    (p_file_name IS NULL OR file_name = p_file_name)
        -- Oldest batch first: BICC names files ..._<leaf>-batch<n>-<date>. Applying
        -- lower batch numbers before higher ones means the bridge's newest-per-PK
        -- dedup is a belt-and-braces (not the sole guard) against out-of-order loads.
        ORDER BY TO_NUMBER(REGEXP_SUBSTR(file_name, '-batch([0-9]+)', 1, 1, NULL, 1)) NULLS LAST,
                 file_name;
    BEGIN
        l_instance_id := NVL(p_instance_id, TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3'));

        list_files_proc(
            p_entity_group   => p_entity_group,
            p_bucket_name    => p_bucket_name,
            p_folder_path    => p_folder_path,
            p_pvo_name       => p_pvo_name,
            p_stg_table_name => p_stg_table_name,
            p_instance_id    => l_instance_id,
            p_err_msg        => p_err_msg
        );

        IF p_err_msg != 'SUCCESS' THEN RETURN; END IF;

        l_temp_folder := NVL(p_folder_path, '') || '/temp';

        FOR rec IN c_files LOOP
            extract_zip_proc(
                p_entity_group   => p_entity_group,
                p_bucket_name    => p_bucket_name,
                p_folder_path    => p_folder_path,
                p_file_name      => rec.file_name,
                p_stg_table_name => p_stg_table_name,
                p_pvo_name       => p_pvo_name,
                p_instance_id    => l_instance_id,
                p_archive_flag   => p_archive_flag,
                p_err_msg        => p_err_msg
            );

            IF p_err_msg != 'SUCCESS' THEN
                CONTINUE;
            END IF;

            -- Load ONLY this entity's decompressed CSV (temp/<pvo_leaf>.csv),
            -- not everything in temp/, so entities can't cross-contaminate.
            load_csv_to_stg_proc(
                p_entity_group   => p_entity_group,
                p_pvo_name       => p_pvo_name,
                p_stg_table_name => p_stg_table_name,
                p_bucket_name    => p_bucket_name,
                p_folder_path    => l_temp_folder,
                p_file_name      => l_temp_csv,
                p_source_code    => p_entity_group,
                p_instance_id    => l_instance_id,
                p_err_msg        => p_err_msg
            );

            -- On successful load the rows sit in STG tagged INPROCESS; the typed
            -- bridge (LWS_C2FO_BRIDGE_PKG) reads them straight from STG and upserts
            -- into the mirror on the mirror PK, so there is no STG-side merge step.
            -- Just drop the decompressed temp CSV now that it is loaded.
            IF p_err_msg = 'SUCCESS' THEN
                DECLARE
                    l_csv_del_url VARCHAR2(2000);
                BEGIN
                    l_csv_del_url := build_obj_storage_url(p_bucket_name, l_temp_folder, l_temp_csv);
                    dbms_cloud.delete_object(
                        credential_name => g_credential_name,
                        object_uri      => l_csv_del_url
                    );
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END IF;
        END LOOP;

        p_err_msg := 'SUCCESS';
        log_process_stage_proc(
            p_instance_id  => l_instance_id,
            p_status       => 'SUCCESS',
            p_message      => 'BICC file processing complete for ' || p_entity_group,
            p_entity_group => p_entity_group,
            p_stage_name   => 'process_bicc_file_proc'
        );
    EXCEPTION
        WHEN OTHERS THEN
            p_err_msg := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400)
                         || ' | AT: '    || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 400)
                         || ' | STACK: ' || SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK,     1, 400);
            log_process_stage_proc(
                p_instance_id  => l_instance_id,
                p_status       => 'ERROR',
                p_message      => p_err_msg,
                p_entity_group => p_entity_group,
                p_stage_name   => 'process_bicc_file_proc'
            );
    END process_bicc_file_proc;

    PROCEDURE run_load (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_archive_flag  IN  VARCHAR2 DEFAULT 'Y',
        p_truncate_all  IN  VARCHAR2 DEFAULT 'N',
        p_run_id        IN  NUMBER   DEFAULT NULL,
        o_run_id        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_instance_id  VARCHAR2(100);
        l_total        NUMBER := 0;
        l_failed       NUMBER := 0;
        l_err          VARCHAR2(4000);
        l_bridge_st    VARCHAR2(20);
        l_bridge_msg   VARCHAR2(4000);

        -- One row per (entity_group, pvo_name, stg_table_name) FEED, not per entity.
        -- An entity can map to more than one PVO/STG feed (e.g. VENDOR_CONTACTS ->
        -- OrganizationContactExtractPVO + PartyContactPointExtractPVO); grouping by
        -- entity alone with MAX(pvo)/MAX(stg) would silently load only one feed.
        -- PK-column string is per-feed (harmless if empty - the bridge ON-clauses are
        -- hardcoded, this only tags the file-status rows).
        CURSOR c_entities IS
            SELECT entity_group,
                   pvo_name,
                   stg_table_name,
                   LISTAGG(CASE WHEN is_pk = 'Y' THEN stg_column_name END, ',')
                       WITHIN GROUP (ORDER BY column_position) AS pk_columns
            FROM   lws_c2fo_pvo_column_map
            WHERE  is_enabled = 'Y'
            GROUP  BY entity_group, pvo_name, stg_table_name;
    BEGIN
        -- Reserve / adopt the run-log row. When called by submit_load's job the row
        -- already exists (p_run_id); flip it to RUNNING. Foreground callers pass NULL
        -- and get a fresh row.
        IF p_run_id IS NULL THEN
            o_run_id := lws_c2fo_load_run_seq.NEXTVAL;
            INSERT INTO lws_c2fo_load_run_log
                (run_id, instance_id, bucket_name, folder_path, start_time, status)
            VALUES
                (o_run_id, TO_CHAR(o_run_id), p_bucket_name, p_folder_path, SYSDATE, 'RUNNING');
        ELSE
            o_run_id := p_run_id;
            UPDATE lws_c2fo_load_run_log
            SET    status = 'RUNNING', start_time = NVL(start_time, SYSDATE),
                   bucket_name = p_bucket_name, folder_path = p_folder_path
            WHERE  run_id = o_run_id;
        END IF;
        COMMIT;

        l_instance_id := TO_CHAR(o_run_id);

        -- Stage 1: bucket -> STG, per enabled entity. One entity's failure does not
        -- abort the run; it is counted and the rest still load, so a single bad
        -- extract cannot strand every mirror table.
        FOR e IN c_entities LOOP
            l_total := l_total + 1;
            l_err   := NULL;
            BEGIN
                process_bicc_file_proc(
                    p_entity_group   => e.entity_group,
                    p_bucket_name    => p_bucket_name,
                    p_folder_path    => p_folder_path,
                    p_stg_table_name => e.stg_table_name,
                    p_pvo_name       => e.pvo_name,
                    p_pk_columns     => e.pk_columns,
                    p_archive_flag   => p_archive_flag,
                    p_instance_id    => l_instance_id,
                    p_err_msg        => l_err
                );
            EXCEPTION
                WHEN OTHERS THEN
                    l_err := 'ERROR: ' || SQLCODE || ' - ' || SUBSTR(SQLERRM, 1, 400);
            END;

            IF l_err IS NULL OR l_err != 'SUCCESS' THEN
                l_failed := l_failed + 1;
                log_process_stage_proc(
                    p_instance_id  => l_instance_id,
                    p_status       => 'ERROR',
                    p_message      => 'Load failed for ' || e.entity_group || ': ' || l_err,
                    p_entity_group => e.entity_group,
                    p_stage_name   => 'run_load'
                );
            END IF;
        END LOOP;

        -- Catch load failures that process_bicc_file_proc swallowed. A per-FILE
        -- extract/load error is logged to the stage log then CONTINUE'd, and the
        -- entity still returns 'SUCCESS' - so the entity-level check above misses
        -- it. Count any ERROR rows this run wrote at the file stages so a masked
        -- failure still flips the run to ERROR for the OIC poll.
        DECLARE
            l_stage_errs NUMBER := 0;
        BEGIN
            SELECT COUNT(*)
            INTO   l_stage_errs
            FROM   lws_c2fo_process_stage_log
            WHERE  instance_id = l_instance_id
            AND    status = 'ERROR'
            AND    stage_name IN ('load_csv_to_stg_proc',
                                  'extract_zip_proc',
                                  'list_files_proc');
            l_failed := l_failed + l_stage_errs;
        END;

        -- Stage 2: STG -> typed mirror (all entities, dependency order). Same
        -- INSTANCE_ID so the stage log ties back to this run.
        lws_c2fo_bridge_pkg.bridge_all_proc(
            p_instance_id  => l_instance_id,
            p_truncate_all => p_truncate_all,
            o_status       => l_bridge_st,
            o_message      => l_bridge_msg
        );

        -- Stage 3: age-based purge of the DBMS_CLOUD per-operation log/bad tables
        -- left behind by the external-table loads (the COPY$..._LOG / COPY$..._BAD
        -- objects tracked in USER_LOAD_OPERATIONS). Each load_csv_to_stg_proc leaves
        -- a pair, so they accumulate every run and clutter the schema. We KEEP recent
        -- ones because they hold the diagnostic evidence (rejected rows, parse errors)
        -- for a failed/partial load; only operations older than the retention window
        -- are dropped. Retention days come from config COMMON.OPLOG_RETENTION_DAYS
        -- (default 3). Purge-only: best effort, must never flip the run to ERROR.
        DECLARE
            l_retain_days NUMBER;
            l_dropped     NUMBER := 0;
            l_obj_dropped NUMBER := 0;
        BEGIN
            l_retain_days := TO_NUMBER(cfg('COMMON', 'OPLOG_RETENTION_DAYS', '3'));

            FOR op IN (
                SELECT id
                FROM   user_load_operations
                WHERE  start_time < SYSTIMESTAMP - NUMTODSINTERVAL(l_retain_days, 'DAY')
            ) LOOP
                BEGIN
                    dbms_cloud.delete_operation(id => op.id);
                    l_dropped := l_dropped + 1;
                EXCEPTION
                    WHEN OTHERS THEN NULL;  -- skip one that won't drop, keep going
                END;
            END LOOP;

            -- COPYOBJ% scratch tables: DBMS_CLOUD leaves these per external-table load
            -- and they are NOT tracked in USER_LOAD_OPERATIONS, so DELETE_OPERATION
            -- above never removes them (confirmed: 831 orphans, none in the view).
            -- Drop them directly, age-based on CREATED so recent ones are kept as
            -- diagnostic evidence, same retention window as the op log.
            --   * Use ALL_OBJECTS, NOT USER_OBJECTS: USER_* resolves to the SESSION
            --     user, and here the package owner (_SA) differs from the connecting
            --     user (_USER) - USER_OBJECTS would see nothing. Filter explicitly on
            --     OWNER = the package owner so scope is correct in any session.
            --   * CREATED lives on ALL_OBJECTS, not ALL_TABLES (ALL_TABLES has no
            --     creation date), so the age gate must read it here.
            -- Each DROP is wrapped so one failure cannot abort the sweep or flip the
            -- run. Quote the name and schema-qualify: generated COPYOBJ names can be
            -- mixed-case, and the owner is _SA regardless of the session user.
            FOR t IN (
                SELECT owner, object_name
                FROM   all_objects
                WHERE  owner = 'LWS_CUSTOM_C2FO_SA'
                AND    object_type = 'TABLE'
                AND    object_name LIKE 'COPYOBJ%'
                AND    created < SYSDATE - l_retain_days
            ) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'DROP TABLE "' || t.owner || '"."' || t.object_name || '" PURGE';
                    l_obj_dropped := l_obj_dropped + 1;
                EXCEPTION
                    WHEN OTHERS THEN NULL;  -- skip one that won't drop, keep going
                END;
            END LOOP;

            log_process_stage_proc(
                p_instance_id  => l_instance_id,
                p_status       => 'SUCCESS',
                p_message      => 'Operation-log cleanup: dropped ' || l_dropped
                                  || ' op(s) and ' || l_obj_dropped
                                  || ' COPYOBJ table(s) older than ' || l_retain_days || ' day(s)',
                p_stage_name   => 'run_load'
            );
        EXCEPTION
            WHEN OTHERS THEN
                log_process_stage_proc(
                    p_instance_id  => l_instance_id,
                    p_status       => 'WARNING',
                    p_message      => 'DBMS_CLOUD operation-log cleanup skipped: '
                                      || SUBSTR(SQLERRM, 1, 400),
                    p_stage_name   => 'run_load'
                );
        END;

        -- Stage 4: end-of-run bucket cleanup. Client requirement: once the data is
        -- loaded, the source files must be DELETED from the bucket (not archived).
        -- A single sweep at the end also clears the historical build-up without a
        -- separate purge job. Runs BEFORE the terminal status is written, so the
        -- run-log stays RUNNING until cleanup finishes and the OIC poll only sees
        -- SUCCESS once the folder is actually cleaned - an honest status. It only
        -- runs when the load fully succeeded (bridge OK, zero load failures), so a
        -- failed/partial run never deletes files that have not been loaded - those
        -- stay for the next run. The 'temp/' subfolder (decompressed CSVs) is
        -- excluded. Best effort: a delete failure is logged WARNING; the load
        -- outcome (l_bridge_st / l_failed) decides the run status, not the cleanup.
        --
        -- DBMS_CLOUD.LIST_OBJECTS returns at most one page per call, so re-list and
        -- delete in a loop until the (filtered) folder is empty - this clears a
        -- multi-thousand-file backlog that one page could not. A pass that deletes
        -- nothing breaks the loop so a persistently-undeletable object cannot spin.
        IF l_bridge_st = 'SUCCESS' AND l_failed = 0 AND p_archive_flag = 'Y' THEN
            DECLARE
                l_list_uri  VARCHAR2(2000);
                l_del_uri   VARCHAR2(2000);
                l_deleted   NUMBER := 0;
                l_failed_d  NUMBER := 0;
                l_pass_del  NUMBER;
                l_pass      NUMBER := 0;
            BEGIN
                l_list_uri := build_obj_storage_url(p_bucket_name, p_folder_path);

                LOOP
                    l_pass     := l_pass + 1;
                    l_pass_del := 0;

                    FOR f IN (
                        SELECT object_name
                        FROM   TABLE(dbms_cloud.list_objects(g_credential_name, l_list_uri))
                        WHERE  object_name NOT LIKE 'temp/%'
                        AND    object_name NOT LIKE '%temp/%'
                        AND    object_name NOT LIKE '%/'
                    ) LOOP
                        BEGIN
                            l_del_uri := build_obj_storage_url(p_bucket_name, p_folder_path, f.object_name);
                            dbms_cloud.delete_object(
                                credential_name => g_credential_name,
                                object_uri      => l_del_uri
                            );
                            l_deleted  := l_deleted + 1;
                            l_pass_del := l_pass_del + 1;
                        EXCEPTION
                            WHEN OTHERS THEN
                                l_failed_d := l_failed_d + 1;
                        END;
                    END LOOP;

                    -- Stop when a full pass deleted nothing: either the folder is
                    -- empty, or every remaining object failed to delete (counted in
                    -- l_failed_d). Either way another pass would not make progress.
                    EXIT WHEN l_pass_del = 0;
                END LOOP;

                log_process_stage_proc(
                    p_instance_id  => l_instance_id,
                    p_status       => CASE WHEN l_failed_d = 0 THEN 'SUCCESS' ELSE 'WARNING' END,
                    p_message      => 'End-of-run bucket cleanup: deleted ' || l_deleted
                                      || ' file(s) over ' || l_pass || ' pass(es)'
                                      || CASE WHEN l_failed_d > 0
                                              THEN '; ' || l_failed_d || ' delete(s) failed'
                                              ELSE '' END,
                    p_stage_name   => 'run_load'
                );
            EXCEPTION
                WHEN OTHERS THEN
                    log_process_stage_proc(
                        p_instance_id  => l_instance_id,
                        p_status       => 'WARNING',
                        p_message      => 'End-of-run bucket cleanup skipped: '
                                          || SUBSTR(SQLERRM, 1, 400),
                        p_stage_name   => 'run_load'
                    );
            END;
        END IF;

        -- Terminal status: bridge failure OR any load failure (entity-level or a
        -- swallowed per-file error) => ERROR. Written LAST, after the cleanup sweep,
        -- so SUCCESS means loaded AND cleaned and the OIC poll reflects the whole run.
        IF l_bridge_st = 'SUCCESS' AND l_failed = 0 THEN
            o_status  := 'SUCCESS';
            o_message := l_total || ' feeds loaded; bridge OK';
        ELSE
            o_status  := 'ERROR';
            o_message := SUBSTR(l_failed || ' load failure(s) across ' || l_total
                         || ' feeds; bridge=' || l_bridge_st || ': ' || l_bridge_msg, 1, 4000);
        END IF;

        UPDATE lws_c2fo_load_run_log
        SET    status = o_status, end_time = SYSDATE,
               entities_total = l_total, entities_failed = l_failed,
               error_message = CASE WHEN o_status = 'ERROR' THEN o_message END
        WHERE  run_id = o_run_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR('run_load fatal: ' || SQLERRM, 1, 4000);
            IF o_run_id IS NOT NULL THEN
                UPDATE lws_c2fo_load_run_log
                SET    status = 'ERROR', end_time = SYSDATE,
                       entities_total = l_total, entities_failed = l_failed,
                       error_message = o_message
                WHERE  run_id = o_run_id;
                COMMIT;
            END IF;
    END run_load;

    PROCEDURE submit_load (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_archive_flag  IN  VARCHAR2 DEFAULT 'Y',
        p_truncate_all  IN  VARCHAR2 DEFAULT 'N',
        o_run_id        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_job_name  VARCHAR2(128);
        l_plsql     VARCHAR2(4000);

        FUNCTION slit (p_s IN VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            IF p_s IS NULL THEN RETURN 'NULL'; END IF;
            RETURN '''' || REPLACE(p_s, '''', '''''') || '''';
        END slit;
    BEGIN
        -- Reserve the run_id up front and log SUBMITTED, so OIC has an id to poll
        -- on LWS_C2FO_LOAD_RUN_LOG the moment submit returns; run_load flips this
        -- same row to RUNNING then a terminal state.
        o_run_id := lws_c2fo_load_run_seq.NEXTVAL;
        INSERT INTO lws_c2fo_load_run_log
            (run_id, instance_id, bucket_name, folder_path, start_time, status)
        VALUES
            (o_run_id, TO_CHAR(o_run_id), p_bucket_name, p_folder_path, SYSDATE, 'SUBMITTED');
        COMMIT;

        l_job_name := 'LWS_C2FO_LOAD_' || o_run_id;

        -- One-shot background job. Params inlined as literals (SET_JOB_ARGUMENT_VALUE
        -- cannot cleanly bind here); the worker's OUT params are discarded - the run's
        -- outcome reaches OIC through the LWS_C2FO_LOAD_RUN_LOG row for this run_id.
        l_plsql :=
            'DECLARE v_id NUMBER; v_st VARCHAR2(20); v_msg VARCHAR2(4000); BEGIN '
            || 'LWS_CUSTOM_C2FO_SA.LWS_C2FO_COMMON_PKG.run_load('
            || 'p_bucket_name=>'  || slit(p_bucket_name)
            || ',p_folder_path=>' || slit(p_folder_path)
            || ',p_archive_flag=>'|| slit(NVL(p_archive_flag, 'Y'))
            || ',p_truncate_all=>'|| slit(NVL(p_truncate_all, 'N'))
            || ',p_run_id=>'      || o_run_id
            || ',o_run_id=>v_id, o_status=>v_st, o_message=>v_msg); END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name   => l_job_name,
            job_type   => 'PLSQL_BLOCK',
            job_action => l_plsql,
            start_date => SYSTIMESTAMP,
            enabled    => TRUE,
            auto_drop  => TRUE,
            comments   => 'C2FO BICC->mirror load async run ' || o_run_id
        );

        o_status  := 'SUBMITTED';
        o_message := 'Load run ' || o_run_id || ' submitted as job ' || l_job_name;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            IF o_run_id IS NOT NULL THEN
                UPDATE lws_c2fo_load_run_log
                SET    status = 'ERROR', end_time = SYSDATE,
                       error_message = 'Submit failed: ' || o_message
                WHERE  run_id = o_run_id;
                COMMIT;
            END IF;
    END submit_load;

END lws_c2fo_common_pkg;
/
