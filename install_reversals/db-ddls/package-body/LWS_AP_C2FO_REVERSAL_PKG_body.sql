
CREATE OR REPLACE PACKAGE BODY LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_REVERSAL_PKG AS

    g_schema        CONSTANT VARCHAR2(30) := 'LWS_CUSTOM_C2FO_SA';
    C_DATE_FMT      CONSTANT VARCHAR2(20) := 'YYYY-MM-DD';

    -- Config (loaded once per call chain from the key/value LWS_C2FO_CONFIG). The DB
    -- makes no ERP REST calls, so only the obj-storage triple + the reversal buckets.
    g_ob_credential   VARCHAR2(200);
    g_ob_namespace    VARCHAR2(200);
    g_ob_uri          VARCHAR2(500);
    g_ack_bucket      VARCHAR2(200);
    g_ack_folder      VARCHAR2(200);
    g_archive_bucket  VARCHAR2(200);
    g_archive_folder  VARCHAR2(200);
    g_sid             VARCHAR2(60);
    g_client_number   VARCHAR2(60);

    --------------------------------------------------------------------------
    -- Key/value config reader (identical to the award package's cfg()).
    --------------------------------------------------------------------------
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
                RAISE_APPLICATION_ERROR(-20060,
                    'Missing mandatory config: ' || p_group || '.' || p_key);
            END IF;
            RETURN p_default;
        END IF;
        RETURN l_val;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_default;
    END cfg;

    --------------------------------------------------------------------------
    -- Config loader. COMMON obj-storage triple + REVERSAL ack/archive buckets and
    -- the ack-name tokens (SID / ClientNumber). Returns FALSE on a missing mandatory.
    --------------------------------------------------------------------------
    FUNCTION load_config RETURN BOOLEAN IS
    BEGIN
        g_ob_credential  := cfg('COMMON', 'OBJ_STORAGE_CREDENTIALS');
        g_ob_namespace   := cfg('COMMON', 'OBJ_STORAGE_NAMESPACE');
        g_ob_uri         := cfg('COMMON', 'OBJ_URI');
        g_ack_bucket     := cfg('REVERSAL', 'ACK_BUCKET');
        g_ack_folder     := cfg('REVERSAL', 'ACK_FOLDER');
        g_archive_bucket := cfg('REVERSAL', 'ARCHIVE_BUCKET');
        g_archive_folder := cfg('REVERSAL', 'ARCHIVE_FOLDER');
        g_sid            := cfg('REVERSAL', 'SID');
        g_client_number  := cfg('REVERSAL', 'CLIENT_NUMBER');
        RETURN TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END load_config;

    --------------------------------------------------------------------------
    -- RFC 4180 CSV field escaping (same rule as the award/outbound packages).
    --------------------------------------------------------------------------
    FUNCTION csv_field (p_val IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN
            RETURN NULL;
        END IF;
        IF INSTR(p_val, ',') > 0 OR INSTR(p_val, '"') > 0
           OR INSTR(p_val, CHR(13)) > 0 OR INSTR(p_val, CHR(10)) > 0 THEN
            RETURN '"' || REPLACE(p_val, '"', '""') || '"';
        END IF;
        RETURN p_val;
    END csv_field;

    --------------------------------------------------------------------------
    -- Object-storage URI builder (mirrors the award package helper).
    --------------------------------------------------------------------------
    FUNCTION object_uri (
        p_bucket_name IN VARCHAR2,
        p_folder_path IN VARCHAR2,
        p_object_name IN VARCHAR2
    ) RETURN VARCHAR2 IS
        l_url VARCHAR2(2000);
    BEGIN
        l_url := g_ob_uri || '/n/' || g_ob_namespace
                 || '/b/' || p_bucket_name || '/o/';
        IF p_folder_path IS NOT NULL THEN
            l_url := l_url || p_folder_path || '/';
        END IF;
        RETURN l_url || p_object_name;
    END object_uri;

    --------------------------------------------------------------------------
    -- 0. Bulk reversal-file loader (clone of load_award_file). DBMS_CLOUD external
    --    table over the CSV object, then one set-based INSERT into
    --    LWS_C2FO_REVERSAL_DATA. The 11 reversal-file columns are named 1:1 with the
    --    table's file columns, so the external-table column_list doubles as the insert
    --    column list. Archives the reversal data + its control file (best-effort).
    --------------------------------------------------------------------------
    PROCEDURE load_reversal_file (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_object_name   IN  VARCHAR2,
        p_instance_id   IN  VARCHAR2,
        p_correlation_id IN VARCHAR2 DEFAULT NULL,
        o_rows_loaded   OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_url        VARCHAR2(2000);
        l_ext_tbl    VARCHAR2(60);
        l_ext_sql    VARCHAR2(4000);
        l_ins_sql    VARCHAR2(8000);
        l_ctl_name   VARCHAR2(240);
        l_arch_stamp VARCHAR2(16);
        l_csv_arch   VARCHAR2(240);
        l_ctl_arch   VARCHAR2(240);
        -- The 11 reversal-file columns, in file/header order. Table column names match
        -- the file header 1:1, so this list serves BOTH the external table and INSERT.
        C_FILE_COLS  CONSTANT VARCHAR2(1000) :=
            'COMPANY_ID, INVOICE_ID, VOUCHER_ID, VOUCHER_LINE_ID, FISCAL_YEAR, '
         || 'ORIGINAL_DUE_DATE, TRANSACTION_TYPE, ERP_LEGAL_ENTITY, ERP_VENDOR_ID, '
         || 'FUND_TYPE, REVERSAL_REASON';
        l_col_list_typed VARCHAR2(4000);
    BEGIN
        IF NOT load_config THEN
            o_rows_loaded := 0;
            o_status  := 'ERROR';
            o_message := 'load_reversal_file: mandatory config missing (COMMON obj-storage triple)';
            RETURN;
        END IF;

        l_col_list_typed := REGEXP_REPLACE(C_FILE_COLS,
                                '([A-Za-z0-9_]+)', '\1 VARCHAR2(4000)');

        l_url := object_uri(p_bucket_name, p_folder_path, p_object_name);
        l_ext_tbl := 'LWS_REV_EXT_' || TO_CHAR(SYS_CONTEXT('USERENV','SID'));

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        l_ext_sql := 'BEGIN DBMS_CLOUD.CREATE_EXTERNAL_TABLE('
            || 'table_name => ''' || l_ext_tbl || ''', '
            || 'credential_name => ''' || g_ob_credential || ''', '
            || 'file_uri_list => ''' || l_url || ''', '
            || 'format => JSON_OBJECT('
            ||   '''type'' VALUE ''CSV'''
            || ', ''skipheaders'' VALUE ''1'''
            || ', ''delimiter'' VALUE '','
            || ''', ''quote'' VALUE ''"'''
            || ', ''characterset'' VALUE ''AL32UTF8'''
            || ', ''blankasnull'' VALUE ''true'''
            || ', ''ignoreblanklines'' VALUE ''true'''
            || ', ''rejectlimit'' VALUE ''0'''
            || ', ''trimspaces'' VALUE ''lrtrim'''
            || '), '
            || 'column_list => ''' || l_col_list_typed || '''); END;';
        EXECUTE IMMEDIATE l_ext_sql;

        l_ins_sql := 'INSERT INTO ' || g_schema || '.LWS_C2FO_REVERSAL_DATA ('
            || C_FILE_COLS
            || ', INSTANCE_ID, CORRELATION_ID, FILE_NAME, REV_REQUIRED, RECORD_STATUS, STAGE, '
            || 'CREATION_DATE, CREATED_BY, LAST_UPDATE_DATE, LAST_UPDATED_BY) '
            || 'SELECT ' || C_FILE_COLS
            || ', :inst, :corr, :fname, ''Y'', ''N'', :stg, '
            || 'SYSTIMESTAMP, :usr, SYSTIMESTAMP, :usr2 '
            || 'FROM ' || l_ext_tbl;
        EXECUTE IMMEDIATE l_ins_sql
            USING p_instance_id, p_correlation_id, p_object_name,
                  C_STAGE_STAGED, 'LWS_C2FO_REV_LOAD', 'LWS_C2FO_REV_LOAD';
        o_rows_loaded := SQL%ROWCOUNT;
        COMMIT;

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        o_status  := 'SUCCESS';
        o_message := 'Loaded ' || o_rows_loaded || ' reversal rows from ' || p_object_name
                     || ' into LWS_C2FO_REVERSAL_DATA (instance ' || p_instance_id || ')';

        -- Archive the reversal drop (data + control) best-effort after the commit.
        -- The two files are a matched pair that differ only by the word 'request'
        -- vs 'control', keeping the same trailing date/time stamp, e.g.
        --   data    = lowes_reversal_request_20261106_141311.csv
        --   control = lowes_reversal_control_20261106_141311.csv
        -- so derive the control name by swapping that single token, not by splicing.
        l_ctl_name := REGEXP_REPLACE(p_object_name, 'request', 'control', 1, 1, 'i');
        l_arch_stamp := TO_CHAR(SYSTIMESTAMP, 'HH24MISS');
        l_csv_arch := REGEXP_REPLACE(p_object_name, '\.([^.]+)$', '_' || l_arch_stamp || '.\1', 1, 1, 'i');
        l_ctl_arch := REGEXP_REPLACE(l_ctl_name,   '\.([^.]+)$', '_' || l_arch_stamp || '.\1', 1, 1, 'i');

        IF g_archive_bucket IS NOT NULL THEN
            BEGIN
                DBMS_CLOUD.MOVE_OBJECT(
                    source_credential_name => g_ob_credential,
                    source_object_uri      => object_uri(p_bucket_name, p_folder_path, p_object_name),
                    target_object_uri      => object_uri(g_archive_bucket, g_archive_folder, l_csv_arch)
                );
                o_message := o_message || '; archived ' || p_object_name || ' as ' || l_csv_arch;
            EXCEPTION
                WHEN OTHERS THEN
                    o_message := o_message || '; WARNING archive failed for ' || p_object_name
                                 || ' (' || SUBSTR(SQLERRM, 1, 150) || ') - source left in place';
            END;

            BEGIN
                DBMS_CLOUD.MOVE_OBJECT(
                    source_credential_name => g_ob_credential,
                    source_object_uri      => object_uri(p_bucket_name, p_folder_path, l_ctl_name),
                    target_object_uri      => object_uri(g_archive_bucket, g_archive_folder, l_ctl_arch)
                );
                o_message := o_message || '; archived ' || l_ctl_name || ' as ' || l_ctl_arch;
            EXCEPTION
                WHEN OTHERS THEN
                    o_message := o_message || '; WARNING archive failed for ' || l_ctl_name
                                 || ' (' || SUBSTR(SQLERRM, 1, 150) || ') - source left in place';
            END;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            o_rows_loaded := 0;
            o_status  := 'ERROR';
            o_message := SUBSTR('load_reversal_file: ' || SQLERRM
                         || ' | file_uri=' || l_url
                         || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
    END load_reversal_file;

    --------------------------------------------------------------------------
    -- 1. Resolve each 'N' reversal row to its award (VOUCHER_ID + VOUCHER_LINE_ID).
    --    One MERGE stamps the resolved refs + the ORIG_* restore schedule from the
    --    matched award and sets STAGE='RESOLVED'; REV_REQUIRED='N' for income=0 rows.
    --    A second pass stamps terminal 'E' + ack Error on rows that matched no award
    --    or whose matched award is already REVERSED (idempotency, BR#8).
    --
    --    Award match (BR#4): the award VOUCHER_ID/VOUCHER_LINE_ID equal the reversal
    --    file's. An award may appear in several batches (re-award), so pick the most
    --    recent SUCCESSFUL, not-yet-reversed award row (record_status='Y',
    --    reversed_flag='N') by CREATION_DATE. That is the live award the reversal undoes.
    --------------------------------------------------------------------------
    PROCEDURE validate_reversals (
        p_instance_id   IN  VARCHAR2,
        p_ignore_hold   IN  VARCHAR2 DEFAULT 'N',
        o_resolved      OUT NUMBER,
        o_errored       OUT NUMBER,
        o_offset_req    OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_ignore_hold CONSTANT VARCHAR2(1) := NVL(UPPER(p_ignore_hold), 'N');
    BEGIN
        o_status := 'SUCCESS';

        -- (a) RESOLVE: match to the latest live (processed, not-reversed) award row.
        MERGE INTO lws_c2fo_reversal_data r
        USING (
            SELECT a.voucher_id, a.voucher_line_id,
                   a.invoice_id        AS award_invoice_id,
                   a.instance_id       AS award_instance_id,
                   a.erp_invoice_id, a.erp_org_id, a.vendor_id, a.erp_vendor_site_id,
                   a.cm_invoice_id, a.cm_invoice_num, a.income, a.erp_tax_rate,
                   a.currency, a.source_code, a.terms_id,
                   a.original_due_date,
                   a.orig_first_discount_date,  a.orig_first_discount_amt,
                   a.orig_second_discount_date, a.orig_second_discount_amt,
                   a.orig_third_discount_date,  a.orig_third_discount_amt
            FROM   ( SELECT a0.*,
                            ROW_NUMBER() OVER (PARTITION BY a0.voucher_id, a0.voucher_line_id
                                               ORDER BY a0.creation_date DESC) AS rn
                     FROM   lws_c2fo_award_data a0
                     WHERE  a0.record_status = 'Y'
                     AND    NVL(a0.reversed_flag, 'N') = 'N' ) a
            WHERE  a.rn = 1
        ) m
        ON (r.voucher_id = m.voucher_id AND r.voucher_line_id = m.voucher_line_id)
        WHEN MATCHED THEN UPDATE SET
            r.award_invoice_id         = m.award_invoice_id,
            r.award_instance_id        = m.award_instance_id,
            r.erp_invoice_id           = m.erp_invoice_id,
            r.erp_org_id               = m.erp_org_id,
            r.vendor_id                = m.vendor_id,
            r.erp_vendor_site_id       = m.erp_vendor_site_id,
            r.cm_invoice_id            = m.cm_invoice_id,
            r.cm_invoice_num           = m.cm_invoice_num,
            r.income                   = m.income,
            r.erp_tax_rate             = m.erp_tax_rate,
            r.currency                 = m.currency,
            r.source_code              = m.source_code,
            r.terms_id                 = m.terms_id,
            r.restore_due_date         = m.original_due_date,
            r.orig_first_discount_date  = m.orig_first_discount_date,
            r.orig_first_discount_amt   = m.orig_first_discount_amt,
            r.orig_second_discount_date = m.orig_second_discount_date,
            r.orig_second_discount_amt  = m.orig_second_discount_amt,
            r.orig_third_discount_date  = m.orig_third_discount_date,
            r.orig_third_discount_amt   = m.orig_third_discount_amt,
            -- income=0 awards had no CM -> no offset needed, DD restore only.
            r.rev_required             = CASE WHEN NVL(m.income, 0) = 0 THEN 'N' ELSE 'Y' END,
            -- Offset rows enter the two-stage offset leg at RESOLVED (create then
            -- validate promote them). DD-only rows (income=0) have no offset invoice, so
            -- jump straight to OFFSET_VALIDATED - the stage the due-date-restore leg
            -- reads - exactly like the award income=0 -> CM_VALIDATED shortcut.
            r.stage                    = CASE WHEN NVL(m.income, 0) = 0
                                              THEN C_STAGE_OFFSET_VALIDATED
                                              ELSE C_STAGE_RESOLVED END,
            r.last_update_date         = SYSTIMESTAMP
        WHERE  r.record_status = 'N'
        AND    r.stage         = C_STAGE_STAGED;

        -- Error pass: unmatched rows (no live award) are terminal with an Error ack.
        UPDATE lws_c2fo_reversal_data r
        SET    r.record_status = 'E',
               r.stage         = C_ERR_NO_AWARD,
               r.error_code    = C_ERR_NO_AWARD,
               r.error_message = 'No processed, un-reversed award found for voucher_id '
                                 || r.voucher_id || ', line ' || r.voucher_line_id,
               r.ack_status    = C_ACK_ERROR,
               r.ack_message   = 'Award not found or already reversed',
               r.last_update_date = SYSTIMESTAMP
        WHERE  r.instance_id   = p_instance_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_STAGED;

        -- (b) VALIDATE live Fusion state of the just-RESOLVED rows. Fail = terminal 'E'
        --     at C_ERR_VALIDATION with an Error ack. Three gates, OR-combined so the
        --     message names the first that applies:
        --       * NOT PAID (always): the invoice is paid in part or full. Keyed off the
        --         INVOICE-level ap_invoices_all.payment_status_flag (the award's paid
        --         signal), NOT the per-installment schedule flag.
        --       * INVOICE HOLD (unless p_ignore_hold='Y'): unreleased hold on the invoice.
        --       * VENDOR/SITE HOLD (unless p_ignore_hold='Y'): the site holds payments.
        UPDATE lws_c2fo_reversal_data r
        SET    r.record_status    = 'E',
               r.stage            = C_ERR_VALIDATION,
               r.error_code       = C_ERR_VALIDATION,
               r.error_message    =
                   CASE
                     WHEN EXISTS (SELECT 1 FROM ap_invoices_all aia
                                  WHERE aia.invoice_id = r.erp_invoice_id
                                  AND   NVL(aia.payment_status_flag,'N') <> 'N')
                       THEN 'Invoice already paid (ap_invoices_all.payment_status_flag <> N); due date not reset'
                     WHEN l_ignore_hold = 'N'
                          AND EXISTS (SELECT 1 FROM ap_holds_all aha
                                      WHERE aha.invoice_id = r.erp_invoice_id
                                      AND   aha.release_lookup_code IS NULL)
                       THEN 'Invoice has an unreleased hold'
                     ELSE 'Supplier site holds payments'
                   END,
               r.ack_status       = C_ACK_ERROR,
               r.ack_message      =
                   CASE
                     WHEN EXISTS (SELECT 1 FROM ap_invoices_all aia
                                  WHERE aia.invoice_id = r.erp_invoice_id
                                  AND   NVL(aia.payment_status_flag,'N') <> 'N')
                       THEN 'Invoice already paid'
                     WHEN l_ignore_hold = 'N'
                          AND EXISTS (SELECT 1 FROM ap_holds_all aha
                                      WHERE aha.invoice_id = r.erp_invoice_id
                                      AND   aha.release_lookup_code IS NULL)
                       THEN 'Invoice on hold'
                     ELSE 'Supplier site on hold'
                   END,
               r.last_update_date = SYSTIMESTAMP
        WHERE  r.instance_id   = p_instance_id
        AND    r.record_status = 'N'
        -- Validate BOTH the just-resolved offset rows (RESOLVED) AND the DD-only rows
        -- that the resolve pass pushed straight to OFFSET_VALIDATED: a paid/held DD-only
        -- row must be blocked too.
        AND    r.stage         IN (C_STAGE_RESOLVED, C_STAGE_OFFSET_VALIDATED)
        AND    (
                 -- paid gate (always on). Authoritative paid signal is the INVOICE-level
                 -- ap_invoices_all.payment_status_flag ('N' never paid, 'Y' fully paid,
                 -- 'P' partially paid) - the flag the bridge package updates - NOT the
                 -- per-installment schedule flag. Block anything not 'N' (paid or part-paid).
                 EXISTS (SELECT 1 FROM ap_invoices_all aia
                         WHERE aia.invoice_id = r.erp_invoice_id
                         AND   NVL(aia.payment_status_flag,'N') <> 'N')
                 -- hold gates (skipped when p_ignore_hold='Y')
                 OR ( l_ignore_hold = 'N'
                      AND ( EXISTS (SELECT 1 FROM ap_holds_all aha
                                    WHERE aha.invoice_id = r.erp_invoice_id
                                    AND   aha.release_lookup_code IS NULL)
                            OR EXISTS (SELECT 1 FROM lws_custom_c2fo_sa.lws_poz_supplier_sites_all_m site
                                       WHERE site.vendor_site_id = r.erp_vendor_site_id
                                       AND   ( NVL(site.hold_all_payments_flag,'N') = 'Y'
                                               OR NVL(site.hold_flag,'N') = 'Y' )) ) )
               );

        SELECT COUNT(*),
               COUNT(CASE WHEN rev_required = 'Y' THEN 1 END)
        INTO   o_resolved, o_offset_req
        FROM   lws_c2fo_reversal_data
        WHERE  instance_id = p_instance_id
        AND    record_status = 'N'
        AND    stage IN (C_STAGE_RESOLVED, C_STAGE_OFFSET_VALIDATED);

        SELECT COUNT(*)
        INTO   o_errored
        FROM   lws_c2fo_reversal_data
        WHERE  instance_id = p_instance_id
        AND    record_status = 'E';

        COMMIT;
        o_message := 'Validated ' || o_resolved || ' reversal rows ('
                     || o_offset_req || ' need an offset), ' || o_errored
                     || ' errored (not found / already reversed / paid / on hold'
                     || CASE WHEN l_ignore_hold = 'Y' THEN ' [holds ignored]' END
                     || ') for instance ' || p_instance_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR('validate_reversals: ' || SQLERRM
                         || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
    END validate_reversals;

    --------------------------------------------------------------------------
    -- 1b. CHUNK the resolved rows (BU + import-source + vendor aware).
    --     Clone of chunk_cm_awards: Import Payables Invoices runs per BU AND per
    --     source, so a chunk must never span two ORG_IDs or two SOURCE_CODEs. The
    --     client additionally requires a chunk to be vendor-specific, so a chunk must
    --     also never span two suppliers (vendor_id) -- identical to chunk_cm_awards.
    --     Sub-chunk within each (erp_org_id, source_code, vendor_id) by the resolved
    --     size, then DENSE_RANK over (erp_org_id, source_code, vendor_id, sub_chunk)
    --     into a running 1..N CHUNK_ID so OIC keeps a simple While 1..N loop and every
    --     CHUNK_ID resolves to exactly one (BU, source, vendor) triple. Chunk BOTH the offset rows
    --     (rev_required='Y', income<>0) and the DD-only rows (rev_required='N',
    --     income=0) into the same chunks -- identical to chunk_cm_awards. The DD-only
    --     rows build no offset FBDI (the FBDI view filters rev_required='Y'), but they
    --     still need a chunk_id so the due-date-restore leg reads them in the SAME
    --     While 1..N loop as the offset rows (single numbering scheme, like awards).
    --------------------------------------------------------------------------
    PROCEDURE chunk_rev_offsets (
        p_instance_id   IN  VARCHAR2,
        p_chunk_size    IN  NUMBER DEFAULT NULL,
        o_chunk_count   OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_size   NUMBER;
        l_merged NUMBER;
    BEGIN
        o_status      := 'SUCCESS';
        o_chunk_count := 0;

        -- Resolve chunk size: explicit arg > config knob (shared INBOUND.CM_CHUNK_SIZE)
        -- > code default. Guard a non-positive knob so CEIL can't divide by zero.
        l_size := NVL(p_chunk_size,
                      TO_NUMBER(cfg('INBOUND', 'CM_CHUNK_SIZE',
                                    TO_CHAR(C_REV_CHUNK_DEFAULT))));
        IF l_size IS NULL OR l_size <= 0 THEN
            l_size := C_REV_CHUNK_DEFAULT;
        END IF;

        MERGE INTO lws_c2fo_reversal_data t
        USING (
            SELECT instance_id, voucher_id, voucher_line_id,
                   DENSE_RANK() OVER (ORDER BY erp_org_id, source_code, vendor_id, sub_chunk) AS new_chunk
            FROM (
                SELECT instance_id, voucher_id, voucher_line_id, erp_org_id, source_code, vendor_id,
                       CEIL(ROW_NUMBER() OVER (PARTITION BY erp_org_id, source_code, vendor_id
                                               ORDER BY voucher_id, voucher_line_id) / l_size) AS sub_chunk
                FROM   lws_c2fo_reversal_data
                WHERE  instance_id   = p_instance_id
                AND    record_status = 'N'
                -- Chunk BOTH the offset rows (RESOLVED) and the DD-only rows that the
                -- resolve pass pushed to OFFSET_VALIDATED, so the due-date-restore leg
                -- loops them in the SAME While 1..N as the offset rows.
                AND    stage         IN (C_STAGE_RESOLVED, C_STAGE_OFFSET_VALIDATED)
            )
        ) c
        ON (t.instance_id = c.instance_id
            AND t.voucher_id = c.voucher_id
            AND t.voucher_line_id = c.voucher_line_id)
        WHEN MATCHED THEN UPDATE SET
            t.chunk_id         = c.new_chunk,
            t.last_update_date = SYSTIMESTAMP;
        l_merged := SQL%ROWCOUNT;

        -- Count DISTINCT chunk ids assigned by THIS run (not MAX), so a stale chunk_id
        -- from a prior run can't inflate the loop bound.
        SELECT COUNT(DISTINCT chunk_id)
        INTO   o_chunk_count
        FROM   lws_c2fo_reversal_data
        WHERE  instance_id   = p_instance_id
        AND    record_status = 'N'
        AND    stage         IN (C_STAGE_RESOLVED, C_STAGE_OFFSET_VALIDATED)
        AND    chunk_id IS NOT NULL;

        COMMIT;
        o_message := 'Chunked ' || l_merged || ' reversal row(s) for instance '
                     || p_instance_id || ' into ' || o_chunk_count
                     || ' chunk(s) of ' || l_size;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status      := 'ERROR';
            o_chunk_count := 0;
            o_message     := SUBSTR(SQLERRM, 1, 4000);
    END chunk_rev_offsets;

    --------------------------------------------------------------------------
    -- 2. WHOLE-CHUNK OFFSET verdict (happy path = one call per chunk). Twin of the
    --    award insert_chunk_cm_verdicts. Inserts one 'OFFSET' verdict per offset-
    --    eligible row in the chunk in one set-based statement: p_status='Y' when OIC's
    --    import confirmed the whole chunk created (no per-record work), or p_status='N'
    --    (+ error stage/message) from the import/validate failure + timeout branches to
    --    terminally fail the chunk. Skips rows that already carry an unprocessed OFFSET
    --    verdict so the bulk MERGE never maps two sources to one target (ORA-30926).
    --------------------------------------------------------------------------
    PROCEDURE insert_chunk_rev_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status   := 'SUCCESS';
        o_inserted := 0;

        IF p_status NOT IN ('Y', 'N') THEN
            o_status  := 'ERROR';
            o_message := 'p_status must be Y or N (got ' || p_status || ')';
            RETURN;
        END IF;

        INSERT INTO lws_ap_c2fo_rev_verdict_load (
            instance_id, voucher_id, voucher_line_id, verdict_kind, status,
            offset_num, message, processed_flag
        )
        SELECT r.instance_id, r.voucher_id, r.voucher_line_id, 'OFFSET', p_status,
               -- on 'Y' pre-fill the expected offset number so the bulk write-back can
               -- stamp OFFSET_INVOICE_NUM without a read-back
               CASE WHEN p_status = 'Y'
                    THEN SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR' END,
               CASE WHEN p_status = 'N'
                    THEN NVL(p_message, 'Offset import/validate failed for chunk') END,
               'N'
        FROM   lws_c2fo_reversal_data r
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        -- This whole-chunk shortcut serves BOTH offset legs: OIC calls it on the create
        -- step (rows at RESOLVED) and again on the validate step (rows now at
        -- OFFSET_CREATED). The downstream annotate promotes by current stage
        -- (RESOLVED->OFFSET_CREATED, OFFSET_CREATED->OFFSET_VALIDATED), so accept either
        -- stage here. (Previously filtered RESOLVED only, so the validate-step call
        -- matched nothing and rows stalled at OFFSET_CREATED. Award twin has no stage
        -- filter at all; the NOT EXISTS guard below still blocks a stacked verdict.)
        AND    r.stage         IN (C_STAGE_RESOLVED, C_STAGE_OFFSET_CREATED)
        AND    r.rev_required  = 'Y'
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_rev_verdict_load vl
                   WHERE  vl.instance_id     = r.instance_id
                   AND    vl.voucher_id      = r.voucher_id
                   AND    vl.voucher_line_id = r.voucher_line_id
                   AND    vl.verdict_kind    = 'OFFSET'
                   AND    vl.processed_flag  = 'N'
               );

        o_inserted := SQL%ROWCOUNT;
        COMMIT;
        o_message := 'Inserted ' || o_inserted || ' OFFSET verdicts (' || p_status
                     || ') for instance ' || p_instance_id || ' chunk ' || p_chunk_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END insert_chunk_rev_verdicts;

    --------------------------------------------------------------------------
    -- 2b. OFFSET read-back diff -> one OFFSET verdict per row (SHORTFALL path). Clone of
    --    diff_chunk_cm_verdicts. OIC paged the created '<CM>-R' invoices into
    --    LWS_AP_C2FO_REV_CREATED_STG for this chunk; LEFT JOIN the chunk's RESOLVED
    --    rows to that staging on offset_invoice_num = INVOICE_NUMBER. Match -> 'Y'
    --    verdict + OFFSET_INVOICE_ID; no match -> 'N' at C_ERR_OFFSET. One verdict per
    --    row into LWS_AP_C2FO_REV_VERDICT_LOAD (verdict_kind 'OFFSET'), consumed by
    --    annotate_reversal_offset_result_bulk. Trailing DELETE clears the chunk's
    --    staging (idempotent re-run).
    --------------------------------------------------------------------------
    PROCEDURE diff_chunk_rev_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_created       OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_created := 0;
        o_missing := 0;

        -- One OFFSET verdict per offset-eligible row in the chunk. Skip rows that
        -- already carry an unprocessed OFFSET verdict (idempotent re-call) so the
        -- bulk MERGE never maps two sources to one target (ORA-30926).
        INSERT INTO lws_ap_c2fo_rev_verdict_load (
            instance_id, voucher_id, voucher_line_id, verdict_kind, status,
            offset_num, message, processed_flag
        )
        SELECT r.instance_id, r.voucher_id, r.voucher_line_id, 'OFFSET',
               CASE WHEN c.invoice_number IS NOT NULL THEN 'Y' ELSE 'N' END,
               c.invoice_number,
               CASE WHEN c.invoice_number IS NULL
                    THEN 'Offset invoice not found in Fusion after import (per-row diff)' END,
               'N'
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_created_stg c
               ON  c.instance_id    = r.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR'
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_RESOLVED
        AND    r.rev_required  = 'Y'
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_rev_verdict_load vl
                   WHERE  vl.instance_id     = r.instance_id
                   AND    vl.voucher_id      = r.voucher_id
                   AND    vl.voucher_line_id = r.voucher_line_id
                   AND    vl.verdict_kind    = 'OFFSET'
                   AND    vl.processed_flag  = 'N'
               );

        SELECT COUNT(CASE WHEN c.invoice_number IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN c.invoice_number IS NULL     THEN 1 END)
        INTO   o_created, o_missing
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_created_stg c
               ON  c.instance_id    = r.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR'
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_RESOLVED
        AND    r.rev_required  = 'Y';

        DELETE FROM lws_ap_c2fo_rev_created_stg
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id;

        COMMIT;
        o_message := 'Diff complete for instance ' || p_instance_id || ' chunk '
                     || p_chunk_id || ': ' || o_created || ' created, '
                     || o_missing || ' missing';
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END diff_chunk_rev_verdicts;

    --------------------------------------------------------------------------
    -- 2c. BULK offset verdict write-back. Consumes the batch's unconsumed 'OFFSET'
    --     verdicts (written by insert_chunk_rev_verdicts or diff_chunk_rev_verdicts)
    --     in one MERGE.
    --------------------------------------------------------------------------
    PROCEDURE annotate_reversal_offset_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        MERGE INTO lws_c2fo_reversal_data r
        USING (
            -- Collapse to ONE source row per reversal row: a reversal row must map to a
            -- single target or the MERGE raises ORA-30926. A failure ('N') always wins
            -- over 'Y'; ties break on the newest verdict.
            SELECT instance_id, voucher_id, voucher_line_id, status, offset_num,
                   http_status, message
            FROM (
                SELECT vl.instance_id, vl.voucher_id, vl.voucher_line_id, vl.status,
                       vl.offset_num, vl.http_status,
                       SUBSTR(LISTAGG(vl.message, ' | ')
                              WITHIN GROUP (ORDER BY vl.verdict_row_id)
                              OVER (PARTITION BY vl.instance_id, vl.voucher_id, vl.voucher_line_id),
                              1, 4000) AS message,
                       ROW_NUMBER() OVER (
                           PARTITION BY vl.instance_id, vl.voucher_id, vl.voucher_line_id
                           ORDER BY CASE WHEN vl.status = 'N' THEN 0 ELSE 1 END,
                                    vl.verdict_row_id DESC
                       ) AS rn
                FROM   lws_ap_c2fo_rev_verdict_load vl
                WHERE  vl.instance_id    = p_instance_id
                AND    vl.verdict_kind   = 'OFFSET'
                AND    vl.processed_flag = 'N'
            )
            WHERE rn = 1
        ) v
        ON (r.instance_id = v.instance_id
            AND r.voucher_id = v.voucher_id
            AND r.voucher_line_id = v.voucher_line_id)
        WHEN MATCHED THEN UPDATE SET
            r.record_status    = CASE WHEN v.status = 'Y' THEN 'N' ELSE 'E' END,
            -- Promote by CURRENT stage: a success verdict on a RESOLVED row confirms the
            -- CREATE leg -> OFFSET_CREATED; on an OFFSET_CREATED row it confirms the
            -- VALIDATE leg -> OFFSET_VALIDATED. One write-back serves both read-back diffs.
            r.stage            = CASE WHEN v.status <> 'Y'                    THEN C_ERR_OFFSET
                                      WHEN r.stage = C_STAGE_RESOLVED         THEN C_STAGE_OFFSET_CREATED
                                      WHEN r.stage = C_STAGE_OFFSET_CREATED   THEN C_STAGE_OFFSET_VALIDATED
                                      ELSE r.stage END,
            r.error_code       = CASE WHEN v.status = 'Y' THEN r.error_code ELSE C_ERR_OFFSET END,
            r.offset_status    = CASE WHEN v.status = 'Y' THEN 'OK' ELSE 'FAILED' END,
            r.offset_invoice_num = CASE WHEN v.status = 'Y'
                                        THEN NVL(v.offset_num, SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR')
                                        ELSE r.offset_invoice_num END,
            r.http_status      = v.http_status,
            r.error_message    = CASE WHEN v.status = 'Y' THEN r.error_message
                                      ELSE SUBSTR(NVL(v.message,
                                           'Offset invoice create/validate failed; credit memo not netted off'), 1, 2000) END,
            r.ack_status       = CASE WHEN v.status = 'Y' THEN r.ack_status ELSE C_ACK_ERROR END,
            r.ack_message      = CASE WHEN v.status = 'Y' THEN r.ack_message
                                      ELSE SUBSTR(NVL(v.message, 'Offset invoice create/validate failed'), 1, 2000) END,
            r.last_update_date = SYSTIMESTAMP
        WHERE r.record_status = 'N';

        o_applied := SQL%ROWCOUNT;

        UPDATE lws_ap_c2fo_rev_verdict_load
        SET    processed_flag = 'Y'
        WHERE  instance_id    = p_instance_id
        AND    verdict_kind   = 'OFFSET'
        AND    processed_flag = 'N';

        COMMIT;
        o_message := 'Applied ' || o_applied || ' offset verdicts for instance ' || p_instance_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_reversal_offset_result_bulk;

    --------------------------------------------------------------------------
    -- 2d. Per-chunk offset verdict write-back. Twin of annotate_cm_result_chunk:
    --     identical to annotate_reversal_offset_result_bulk but scoped to one chunk's
    --     unprocessed 'OFFSET' verdicts, so a per-chunk call stamps ONLY that chunk's
    --     reversal rows. Call inside the chunk loop, before the due-date restore.
    --------------------------------------------------------------------------
    PROCEDURE annotate_reversal_offset_result_chunk (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        MERGE INTO lws_c2fo_reversal_data r
        USING (
            SELECT instance_id, voucher_id, voucher_line_id, status, offset_num,
                   http_status, message
            FROM (
                SELECT vl.instance_id, vl.voucher_id, vl.voucher_line_id, vl.status,
                       vl.offset_num, vl.http_status,
                       SUBSTR(LISTAGG(vl.message, ' | ')
                              WITHIN GROUP (ORDER BY vl.verdict_row_id)
                              OVER (PARTITION BY vl.instance_id, vl.voucher_id, vl.voucher_line_id),
                              1, 4000) AS message,
                       ROW_NUMBER() OVER (
                           PARTITION BY vl.instance_id, vl.voucher_id, vl.voucher_line_id
                           ORDER BY CASE WHEN vl.status = 'N' THEN 0 ELSE 1 END,
                                    vl.verdict_row_id DESC
                       ) AS rn
                FROM   lws_ap_c2fo_rev_verdict_load vl
                JOIN   lws_c2fo_reversal_data d
                       ON  d.instance_id     = vl.instance_id
                       AND d.voucher_id      = vl.voucher_id
                       AND d.voucher_line_id = vl.voucher_line_id
                WHERE  vl.instance_id    = p_instance_id
                AND    vl.verdict_kind   = 'OFFSET'
                AND    vl.processed_flag = 'N'
                AND    d.chunk_id        = p_chunk_id
            )
            WHERE rn = 1
        ) v
        ON (r.instance_id = v.instance_id
            AND r.voucher_id = v.voucher_id
            AND r.voucher_line_id = v.voucher_line_id)
        WHEN MATCHED THEN UPDATE SET
            r.record_status    = CASE WHEN v.status = 'Y' THEN 'N' ELSE 'E' END,
            -- Promote by CURRENT stage: success on RESOLVED -> OFFSET_CREATED (create
            -- confirmed); on OFFSET_CREATED -> OFFSET_VALIDATED (validate confirmed).
            r.stage            = CASE WHEN v.status <> 'Y'                    THEN C_ERR_OFFSET
                                      WHEN r.stage = C_STAGE_RESOLVED         THEN C_STAGE_OFFSET_CREATED
                                      WHEN r.stage = C_STAGE_OFFSET_CREATED   THEN C_STAGE_OFFSET_VALIDATED
                                      ELSE r.stage END,
            r.error_code       = CASE WHEN v.status = 'Y' THEN r.error_code ELSE C_ERR_OFFSET END,
            r.offset_status    = CASE WHEN v.status = 'Y' THEN 'OK' ELSE 'FAILED' END,
            r.offset_invoice_num = CASE WHEN v.status = 'Y'
                                        THEN NVL(v.offset_num, SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR')
                                        ELSE r.offset_invoice_num END,
            r.http_status      = v.http_status,
            r.error_message    = CASE WHEN v.status = 'Y' THEN r.error_message
                                      ELSE SUBSTR(NVL(v.message,
                                           'Offset invoice create/validate failed; credit memo not netted off'), 1, 2000) END,
            r.ack_status       = CASE WHEN v.status = 'Y' THEN r.ack_status ELSE C_ACK_ERROR END,
            r.ack_message      = CASE WHEN v.status = 'Y' THEN r.ack_message
                                      ELSE SUBSTR(NVL(v.message, 'Offset invoice create/validate failed'), 1, 2000) END,
            r.last_update_date = SYSTIMESTAMP
        WHERE r.record_status = 'N';

        o_applied := SQL%ROWCOUNT;

        UPDATE lws_ap_c2fo_rev_verdict_load vl
        SET    vl.processed_flag = 'Y'
        WHERE  vl.instance_id    = p_instance_id
        AND    vl.verdict_kind   = 'OFFSET'
        AND    vl.processed_flag = 'N'
        AND    EXISTS (
                   SELECT 1 FROM lws_c2fo_reversal_data d
                   WHERE  d.instance_id     = vl.instance_id
                   AND    d.voucher_id      = vl.voucher_id
                   AND    d.voucher_line_id = vl.voucher_line_id
                   AND    d.chunk_id        = p_chunk_id
               );

        COMMIT;
        o_message := 'Applied ' || o_applied || ' offset verdicts for instance '
                     || p_instance_id || ' chunk ' || p_chunk_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_reversal_offset_result_chunk;

    --------------------------------------------------------------------------
    -- 2e. OFFSET VALIDATE read-back diff -> one OFFSET verdict per row (the second
    --    Fusion step). Twin of diff_chunk_rev_verdicts for the VALIDATE leg, and of the
    --    award diff_chunk_cm_validate_verdicts. The create diff/verdict already promoted
    --    the chunk's offset rows to OFFSET_CREATED; after the validate job OIC pages the
    --    Fusion "validated offset invoices" into LWS_AP_C2FO_REV_VALIDATED_STG for this
    --    chunk. LEFT JOIN the chunk's OFFSET_CREATED rows to that staging on the offset
    --    number ('<CM>-R') = INVOICE_NUMBER: a match -> 'Y' verdict (validated); no match
    --    -> 'N' at C_ERR_OFFSET (created but not validated -> partial reversal, the stray
    --    offset invoice is already in Fusion). One 'OFFSET' verdict per row into
    --    LWS_AP_C2FO_REV_VERDICT_LOAD, consumed by annotate_reversal_offset_result_bulk /
    --    _chunk, which promote the 'Y' rows OFFSET_CREATED -> OFFSET_VALIDATED. Skips rows
    --    that already carry an unprocessed OFFSET verdict (ORA-30926 guard). The trailing
    --    DELETE clears the chunk's staging rows (idempotent re-run).
    --------------------------------------------------------------------------
    PROCEDURE diff_chunk_rev_validate_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_validated     OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status    := 'SUCCESS';
        o_validated := 0;
        o_missing   := 0;

        INSERT INTO lws_ap_c2fo_rev_verdict_load (
            instance_id, voucher_id, voucher_line_id, verdict_kind, status,
            offset_num, message, processed_flag
        )
        SELECT r.instance_id, r.voucher_id, r.voucher_line_id, 'OFFSET',
               CASE WHEN c.invoice_number IS NOT NULL THEN 'Y' ELSE 'N' END,
               c.invoice_number,
               CASE WHEN c.invoice_number IS NULL
                    THEN 'Offset invoice created but not validated in Fusion (per-row diff)' END,
               'N'
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_validated_stg c
               ON  c.instance_id    = r.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR'
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_OFFSET_CREATED
        AND    r.rev_required  = 'Y'
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_rev_verdict_load vl
                   WHERE  vl.instance_id     = r.instance_id
                   AND    vl.voucher_id      = r.voucher_id
                   AND    vl.voucher_line_id = r.voucher_line_id
                   AND    vl.verdict_kind    = 'OFFSET'
                   AND    vl.processed_flag  = 'N'
               );

        SELECT COUNT(CASE WHEN c.invoice_number IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN c.invoice_number IS NULL     THEN 1 END)
        INTO   o_validated, o_missing
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_validated_stg c
               ON  c.instance_id    = r.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = SUBSTR(r.cm_invoice_num, 1, 48) || '-C2FOR'
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_OFFSET_CREATED
        AND    r.rev_required  = 'Y';

        DELETE FROM lws_ap_c2fo_rev_validated_stg
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id;

        COMMIT;
        o_message := 'Validate diff complete for instance ' || p_instance_id
                     || ' chunk ' || p_chunk_id || ': ' || o_validated
                     || ' validated, ' || o_missing || ' missing';
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END diff_chunk_rev_validate_verdicts;

    --------------------------------------------------------------------------
    -- 3. WHOLE-CHUNK DUE-DATE-restore verdict (happy path = one call per chunk). Twin
    --    of insert_chunk_rev_verdicts for the DD leg. Inserts one 'DD' verdict per row
    --    in the chunk: p_status='Y'/'SKIP' when OIC's installment upsert restored the
    --    whole chunk, or p_status='N' (+ message) on a whole-chunk DD failure. Both the
    --    offset rows (rev_required='Y') AND the DD-only rows (rev_required='N') are
    --    chunked together, so this writes DD verdicts for EVERY row in the chunk.
    --    Consumed by annotate_reversal_dd_result_bulk. Skips rows already carrying an
    --    unprocessed DD verdict (ORA-30926 guard).
    --------------------------------------------------------------------------
    PROCEDURE insert_chunk_rev_dd_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,
        p_http_status   IN  NUMBER   DEFAULT NULL,
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status   := 'SUCCESS';
        o_inserted := 0;

        IF p_status NOT IN ('Y', 'SKIP', 'N') THEN
            o_status  := 'ERROR';
            o_message := 'p_status must be Y, SKIP or N (got ' || p_status || ')';
            RETURN;
        END IF;

        INSERT INTO lws_ap_c2fo_rev_verdict_load (
            instance_id, voucher_id, voucher_line_id, verdict_kind, status,
            http_status, message, processed_flag
        )
        SELECT r.instance_id, r.voucher_id, r.voucher_line_id, 'DD', p_status,
               p_http_status,
               CASE WHEN p_status = 'N'
                    THEN NVL(p_message, 'Due-date restore failed for chunk') END,
               'N'
        FROM   lws_c2fo_reversal_data r
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        -- DD leg runs after the offset invoice is validated. Offset rows reach
        -- OFFSET_VALIDATED via the create+validate diffs; DD-only rows were put there at
        -- resolve time. Both are due for the due-date restore.
        AND    r.stage         = C_STAGE_OFFSET_VALIDATED
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_rev_verdict_load vl
                   WHERE  vl.instance_id     = r.instance_id
                   AND    vl.voucher_id      = r.voucher_id
                   AND    vl.voucher_line_id = r.voucher_line_id
                   AND    vl.verdict_kind    = 'DD'
                   AND    vl.processed_flag  = 'N'
               );

        o_inserted := SQL%ROWCOUNT;
        COMMIT;
        o_message := 'Inserted ' || o_inserted || ' DD verdicts (' || p_status
                     || ') for instance ' || p_instance_id || ' chunk ' || p_chunk_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END insert_chunk_rev_dd_verdicts;

    --------------------------------------------------------------------------
    -- 3b. Per-row DUE-DATE-restore verdict insert (SHORTFALL path). Twin of the award
    --    mark_dd_failures. OIC paged the FAILED (voucher_id, voucher_line_id) for the
    --    chunk into LWS_AP_C2FO_REV_DD_APPLIED_STG (presence = FAILED). Writes one 'DD'
    --    verdict per row in the chunk: a staged match -> 'N'; everything else -> 'Y'.
    --    Skips rows already carrying an unprocessed DD verdict (ORA-30926 guard). Clears
    --    the chunk's staging rows at the end (idempotent re-run).
    --------------------------------------------------------------------------
    PROCEDURE mark_rev_dd_failures (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_failed        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;
        o_failed  := 0;

        INSERT INTO lws_ap_c2fo_rev_verdict_load (
            instance_id, voucher_id, voucher_line_id, verdict_kind, status,
            http_status, message, processed_flag
        )
        SELECT r.instance_id, r.voucher_id, r.voucher_line_id, 'DD',
               CASE WHEN f.voucher_id IS NOT NULL THEN 'N' ELSE 'Y' END,
               f.http_status,
               CASE WHEN f.voucher_id IS NOT NULL
                    THEN NVL(f.message, 'Due-date restore failed (per-row diff)') END,
               'N'
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_dd_applied_stg f
               ON  f.instance_id     = r.instance_id
               AND f.chunk_id        = p_chunk_id
               AND f.voucher_id      = r.voucher_id
               AND f.voucher_line_id = r.voucher_line_id
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_OFFSET_VALIDATED
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_rev_verdict_load vl
                   WHERE  vl.instance_id     = r.instance_id
                   AND    vl.voucher_id      = r.voucher_id
                   AND    vl.voucher_line_id = r.voucher_line_id
                   AND    vl.verdict_kind    = 'DD'
                   AND    vl.processed_flag  = 'N'
               );

        SELECT COUNT(CASE WHEN f.voucher_id IS NULL     THEN 1 END),
               COUNT(CASE WHEN f.voucher_id IS NOT NULL THEN 1 END)
        INTO   o_applied, o_failed
        FROM   lws_c2fo_reversal_data r
        LEFT JOIN lws_ap_c2fo_rev_dd_applied_stg f
               ON  f.instance_id     = r.instance_id
               AND f.chunk_id        = p_chunk_id
               AND f.voucher_id      = r.voucher_id
               AND f.voucher_line_id = r.voucher_line_id
        WHERE  r.instance_id   = p_instance_id
        AND    r.chunk_id      = p_chunk_id
        AND    r.record_status = 'N'
        AND    r.stage         = C_STAGE_OFFSET_VALIDATED;

        DELETE FROM lws_ap_c2fo_rev_dd_applied_stg
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id;

        COMMIT;
        o_message := 'DD failures marked for instance ' || p_instance_id || ' chunk '
                     || p_chunk_id || ': ' || o_applied || ' applied, '
                     || o_failed || ' failed';
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END mark_rev_dd_failures;

    --------------------------------------------------------------------------
    -- Stamp the matched AWARD row REVERSED on a completed reversal row. Keyed by the
    -- award PK (invoice_id, instance_id) carried on the reversal row at resolve time.
    -- Guarded on reversed_flag='N' so a re-stamp is a no-op (idempotency, BR#8).
    --------------------------------------------------------------------------
    PROCEDURE stamp_award_reversed (
        p_award_invoice_id  IN VARCHAR2,
        p_award_instance_id IN VARCHAR2,
        p_reason            IN VARCHAR2
    ) IS
    BEGIN
        IF p_award_invoice_id IS NULL OR p_award_instance_id IS NULL THEN
            RETURN;
        END IF;
        UPDATE lws_c2fo_award_data
        SET    reversed_flag    = 'Y',
               reversed_date    = SYSTIMESTAMP,
               reversed_reason  = SUBSTR(NVL(p_reason, 'C2FO reversal'), 1, 200),
               last_update_date = SYSTIMESTAMP
        WHERE  invoice_id  = p_award_invoice_id
        AND    instance_id = p_award_instance_id
        AND    NVL(reversed_flag, 'N') = 'N';
    END stamp_award_reversed;

    --------------------------------------------------------------------------
    -- 3. DUE-DATE-restore verdict write-back + FINAL CLOSE (single-row).
    --    'Y' => reversal row complete (REVERSED, record_status='Y', ack Success) AND
    --           the award row stamped REVERSED. 'SKIP' => also closes success (the
    --           installment moved on; nothing to restore) with a known-skip ack.
    --    'N' => terminal 'E', C_ERR_DD_RESTORE, ack Error. The offset already
    --           succeeded (DD runs second) so this is a PARTIAL reversal - the award
    --           is NOT flipped, so a corrected re-send can act again (BR#8).
    --------------------------------------------------------------------------
    PROCEDURE annotate_reversal_dd_result (
        p_instance_id    IN  VARCHAR2,
        p_voucher_id     IN  NUMBER,
        p_voucher_line_id IN NUMBER,
        p_dd_ok          IN  VARCHAR2,
        p_http_status    IN  NUMBER   DEFAULT NULL,
        p_error_msg      IN  VARCHAR2 DEFAULT NULL
    ) IS
        l_award_inv  lws_c2fo_reversal_data.award_invoice_id%TYPE;
        l_award_inst lws_c2fo_reversal_data.award_instance_id%TYPE;
        l_reason     lws_c2fo_reversal_data.reversal_reason%TYPE;
    BEGIN
        IF p_dd_ok IN ('Y', 'SKIP') THEN
            UPDATE lws_c2fo_reversal_data
            SET    record_status    = 'Y',
                   stage            = C_STAGE_REVERSED,
                   dd_status        = CASE WHEN p_dd_ok = 'SKIP' THEN 'KNOWN_SKIP' ELSE 'OK' END,
                   http_status      = p_http_status,
                   ack_status       = C_ACK_SUCCESS,
                   ack_message      = CASE WHEN p_dd_ok = 'SKIP'
                                           THEN NVL(p_error_msg, 'Due date already restored / installment moved on')
                                           ELSE 'Reversal complete' END,
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id   = p_instance_id
            AND    voucher_id    = p_voucher_id
            AND    voucher_line_id = p_voucher_line_id
            AND    record_status = 'N'
            RETURNING award_invoice_id, award_instance_id, reversal_reason
            INTO     l_award_inv, l_award_inst, l_reason;

            IF SQL%ROWCOUNT > 0 THEN
                stamp_award_reversed(l_award_inv, l_award_inst, l_reason);
            END IF;
        ELSE
            UPDATE lws_c2fo_reversal_data
            SET    record_status    = 'E',
                   stage            = C_ERR_DD_RESTORE,
                   error_code       = C_ERR_DD_RESTORE,
                   dd_status        = 'FAILED',
                   http_status      = p_http_status,
                   error_message    = SUBSTR(NVL(p_error_msg,
                                        'Due-date restore failed'
                                        || CASE WHEN rev_required = 'Y'
                                                THEN ' (offset already applied - PARTIAL reversal)' END), 1, 2000),
                   ack_status       = C_ACK_ERROR,
                   ack_message      = SUBSTR(NVL(p_error_msg, 'Due-date restore failed'), 1, 2000),
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id   = p_instance_id
            AND    voucher_id    = p_voucher_id
            AND    voucher_line_id = p_voucher_line_id
            AND    record_status = 'N';
        END IF;
        COMMIT;
    END annotate_reversal_dd_result;

    --------------------------------------------------------------------------
    -- 3b. BULK due-date-restore verdict write-back + final close. One MERGE applies
    --     the reversal-row state; a follow-up set-based UPDATE stamps every award row
    --     whose reversal just closed success (reversed_flag='N' guard = idempotent).
    --------------------------------------------------------------------------
    PROCEDURE annotate_reversal_dd_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        MERGE INTO lws_c2fo_reversal_data r
        USING (
            SELECT instance_id, voucher_id, voucher_line_id, status, http_status, message
            FROM   lws_ap_c2fo_rev_verdict_load
            WHERE  instance_id    = p_instance_id
            AND    verdict_kind   = 'DD'
            AND    processed_flag = 'N'
        ) v
        ON (r.instance_id = v.instance_id
            AND r.voucher_id = v.voucher_id
            AND r.voucher_line_id = v.voucher_line_id)
        WHEN MATCHED THEN UPDATE SET
            r.record_status    = CASE WHEN v.status IN ('Y','SKIP') THEN 'Y' ELSE 'E' END,
            r.stage            = CASE WHEN v.status IN ('Y','SKIP') THEN C_STAGE_REVERSED ELSE C_ERR_DD_RESTORE END,
            r.error_code       = CASE WHEN v.status IN ('Y','SKIP') THEN NULL ELSE C_ERR_DD_RESTORE END,
            r.dd_status        = CASE WHEN v.status = 'Y' THEN 'OK'
                                      WHEN v.status = 'SKIP' THEN 'KNOWN_SKIP'
                                      ELSE 'FAILED' END,
            r.http_status      = v.http_status,
            r.error_message    = CASE WHEN v.status IN ('Y','SKIP') THEN r.error_message
                                      ELSE SUBSTR(NVL(v.message, 'Due-date restore failed'
                                           || CASE WHEN r.rev_required = 'Y'
                                                   THEN ' (offset already applied - PARTIAL reversal)' END), 1, 2000) END,
            r.ack_status       = CASE WHEN v.status IN ('Y','SKIP') THEN C_ACK_SUCCESS ELSE C_ACK_ERROR END,
            r.ack_message      = CASE WHEN v.status = 'SKIP'
                                           THEN NVL(v.message, 'Due date already restored / installment moved on')
                                      WHEN v.status = 'Y' THEN 'Reversal complete'
                                      ELSE SUBSTR(NVL(v.message, 'Due-date restore failed'), 1, 2000) END,
            r.last_update_date = SYSTIMESTAMP
        WHERE r.record_status = 'N';

        o_applied := SQL%ROWCOUNT;

        -- Stamp the award rows whose reversal just closed success.
        UPDATE lws_c2fo_award_data a
        SET    a.reversed_flag    = 'Y',
               a.reversed_date    = SYSTIMESTAMP,
               a.reversed_reason  = SUBSTR(
                   (SELECT NVL(r.reversal_reason, 'C2FO reversal')
                    FROM   lws_c2fo_reversal_data r
                    WHERE  r.instance_id = p_instance_id
                    AND    r.award_invoice_id  = a.invoice_id
                    AND    r.award_instance_id = a.instance_id), 1, 200),
               a.last_update_date = SYSTIMESTAMP
        WHERE  NVL(a.reversed_flag, 'N') = 'N'
        AND    EXISTS (
                   SELECT 1 FROM lws_c2fo_reversal_data r
                   WHERE  r.instance_id        = p_instance_id
                   AND    r.award_invoice_id   = a.invoice_id
                   AND    r.award_instance_id  = a.instance_id
                   AND    r.record_status      = 'Y'
                   AND    r.stage              = C_STAGE_REVERSED);

        UPDATE lws_ap_c2fo_rev_verdict_load
        SET    processed_flag = 'Y'
        WHERE  instance_id    = p_instance_id
        AND    verdict_kind   = 'DD'
        AND    processed_flag = 'N';

        COMMIT;
        o_message := 'Applied ' || o_applied || ' due-date-restore verdicts for instance ' || p_instance_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_reversal_dd_result_bulk;

    --------------------------------------------------------------------------
    -- 4. Write the two acknowledgement files to OCI for C2FO.
    --    a) Reversal Ack CSV (12 cols) = the 10 SPEC input fields (company_id,
    --       invoice_id, voucher_id, fiscal_year, original_due_date, transaction_type,
    --       erp_legal_entity, erp_vendor_id, fund_type, reversal_reason) + Status +
    --       Status Message. NOTE voucher_line_id is NOT in the 10-col spec ack layout,
    --       so it is omitted here (it is an input match key only). One row per reversal
    --       row, header row, RFC-4180 quoted.
    --    b) Reversal Ack Control CSV (4 cols) = ack file_name, row_count,
    --       Correlation_ID (echoed from the inbound control), rollup Status =
    --       Complete (all Success) / Error (all Error) / Partial_Complete (mixed).
    --    File names carry the SID / ClientNumber tokens from config (OPEN ISSUE #3).
    --------------------------------------------------------------------------
    PROCEDURE write_reversal_ack (
        p_instance_id    IN  VARCHAR2,
        p_correlation_id IN  VARCHAR2 DEFAULT NULL,
        o_ack_file       OUT VARCHAR2,
        o_ack_control    OUT VARCHAR2,
        o_rollup_status  OUT VARCHAR2,
        o_status         OUT VARCHAR2,
        o_message        OUT VARCHAR2
    ) IS
        l_buf      CLOB;
        l_ctl_buf  CLOB;
        l_line     VARCHAR2(32767);
        l_rows     PLS_INTEGER := 0;
        l_succ     PLS_INTEGER := 0;
        l_err      PLS_INTEGER := 0;
        l_corr     VARCHAR2(240);
        l_blob     BLOB;
        l_dst_off  INTEGER;
        l_src_off  INTEGER;
        l_lang_ctx INTEGER;
        l_warning  INTEGER;
        l_stamp_d  VARCHAR2(8)  := TO_CHAR(SYSDATE, 'YYYYMMDD');
        l_stamp_t  VARCHAR2(15) := TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');

        -- Render a CLOB to a UTF-8 BLOB and PUT it to the ack folder.
        PROCEDURE put_csv (p_clob IN OUT NOCOPY CLOB, p_object IN VARCHAR2) IS
            l_b BLOB;
        BEGIN
            l_dst_off := 1; l_src_off := 1; l_lang_ctx := DBMS_LOB.default_lang_ctx;
            DBMS_LOB.CREATETEMPORARY(l_b, TRUE);
            DBMS_LOB.CONVERTTOBLOB(
                dest_lob => l_b, src_clob => p_clob, amount => DBMS_LOB.LOBMAXSIZE,
                dest_offset => l_dst_off, src_offset => l_src_off,
                blob_csid => NLS_CHARSET_ID('AL32UTF8'),
                lang_context => l_lang_ctx, warning => l_warning);
            DBMS_CLOUD.PUT_OBJECT(
                credential_name => g_ob_credential,
                object_uri      => object_uri(g_ack_bucket, g_ack_folder, p_object),
                contents        => l_b);
            DBMS_LOB.FREETEMPORARY(l_b);
        END put_csv;
    BEGIN
        o_status := 'SUCCESS';

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'write_reversal_ack: mandatory config missing';
            RETURN;
        END IF;

        -- Resolve the correlation id to echo: prefer the argument, else the value
        -- captured on the batch rows at load.
        l_corr := p_correlation_id;
        IF l_corr IS NULL THEN
            BEGIN
                SELECT MAX(correlation_id) INTO l_corr
                FROM   lws_c2fo_reversal_data
                WHERE  instance_id = p_instance_id;
            EXCEPTION WHEN OTHERS THEN l_corr := NULL;
            END;
        END IF;

        -- Ack file names: <client_lower>_reversal_ack[_control]_<SID>_<ClientNo>_<date>[_<time>].csv
        o_ack_file    := 'lowes_reversal_ack_' || g_sid || '_' || g_client_number
                         || '_' || l_stamp_d || '.csv';
        o_ack_control := 'lowes_reversal_ack_control_' || g_sid || '_' || g_client_number
                         || '_' || l_stamp_t || '.csv';

        -- (a) The 12-col per-invoice ack.
        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);
        l_line := 'company_id,invoice_id,voucher_id,fiscal_year,original_due_date,'
                  || 'transaction_type,erp_legal_entity,erp_vendor_id,fund_type,'
                  || 'reversal_reason,Status,Status Message' || CHR(13) || CHR(10);
        DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);

        FOR r IN (SELECT company_id, invoice_id, voucher_id, fiscal_year,
                         original_due_date, transaction_type, erp_legal_entity,
                         erp_vendor_id, fund_type, reversal_reason,
                         NVL(ack_status,
                             CASE WHEN record_status = 'Y' THEN C_ACK_SUCCESS ELSE C_ACK_ERROR END) AS ack_status,
                         ack_message
                  FROM   lws_c2fo_reversal_data
                  WHERE  instance_id = p_instance_id
                  ORDER  BY voucher_id, voucher_line_id) LOOP
            l_line := csv_field(r.company_id) ||','|| csv_field(r.invoice_id) ||','||
                      csv_field(TO_CHAR(r.voucher_id)) ||','|| csv_field(TO_CHAR(r.fiscal_year)) ||','||
                      csv_field(r.original_due_date) ||','|| csv_field(TO_CHAR(r.transaction_type)) ||','||
                      csv_field(r.erp_legal_entity) ||','|| csv_field(TO_CHAR(r.erp_vendor_id)) ||','||
                      csv_field(r.fund_type) ||','|| csv_field(r.reversal_reason) ||','||
                      csv_field(r.ack_status) ||','|| csv_field(r.ack_message)
                      || CHR(13) || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);
            l_rows := l_rows + 1;
            IF r.ack_status = C_ACK_SUCCESS THEN l_succ := l_succ + 1;
            ELSE l_err := l_err + 1; END IF;
        END LOOP;

        put_csv(l_buf, o_ack_file);
        DBMS_LOB.FREETEMPORARY(l_buf);

        -- Rollup status for the control file.
        o_rollup_status := CASE WHEN l_rows = 0            THEN C_ROLL_ERROR
                                WHEN l_err  = 0            THEN C_ROLL_COMPLETE
                                WHEN l_succ = 0            THEN C_ROLL_ERROR
                                ELSE C_ROLL_PARTIAL END;

        -- (b) The 4-col ack control: ack file_name, row_count, Correlation_ID, Status.
        DBMS_LOB.CREATETEMPORARY(l_ctl_buf, TRUE);
        l_line := 'file_name,row_count,Correlation_ID,Status' || CHR(13) || CHR(10);
        DBMS_LOB.WRITEAPPEND(l_ctl_buf, LENGTH(l_line), l_line);
        l_line := csv_field(o_ack_file) ||','|| csv_field(TO_CHAR(l_rows)) ||','||
                  csv_field(l_corr) ||','|| csv_field(o_rollup_status)
                  || CHR(13) || CHR(10);
        DBMS_LOB.WRITEAPPEND(l_ctl_buf, LENGTH(l_line), l_line);

        put_csv(l_ctl_buf, o_ack_control);
        DBMS_LOB.FREETEMPORARY(l_ctl_buf);

        o_message := 'Wrote reversal ack (' || l_rows || ' rows: ' || l_succ || ' Success, '
                     || l_err || ' Error; rollup ' || o_rollup_status || ') to '
                     || o_ack_file || ' + ' || o_ack_control;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR('write_reversal_ack: ' || SQLERRM
                         || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            BEGIN DBMS_LOB.FREETEMPORARY(l_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN DBMS_LOB.FREETEMPORARY(l_ctl_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
    END write_reversal_ack;

END LWS_AP_C2FO_REVERSAL_PKG;
/

