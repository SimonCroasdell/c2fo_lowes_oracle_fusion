create or replace PACKAGE BODY                    LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_AWARD_PKG AS

    -- Record of truth = LWS_C2FO_AWARD_DATA (the full 74-column award landing
    -- table). One award = the composite INVOICE_ID (ORG_ID|INVOICE_ID|PAYMENT_NUM|
    -- INVOICE_NUM); the batch = INSTANCE_ID (the OIC loader run id). award progress columns on AWARD_DATA:
    --   RECORD_STATUS  N/Y/E    (was staging PROCESS_FLAG)
    --   STAGE                    (was PROCESS_STAGE)
    --   ERROR_CODE / ERROR_MESSAGE
    -- Resolved identity filled at validation: ERP_INVOICE_ID / ERP_ORG_ID /
    -- PAYMENT_NUM / VENDOR_ID / DISCOUNT_AMOUNT / CM_INVOICE_NUM.
    -- File date columns (ORIGINAL_DUE_DATE, PAY_DATE) are VARCHAR2(25) ISO strings;
    -- compare against the DATE-typed mirror via TO_DATE(... ON CONVERSION ERROR).

    g_schema        CONSTANT VARCHAR2(30) := 'LWS_CUSTOM_C2FO_SA';

    -- ISO date mask the award file lands in (PAY_DATE / ORIGINAL_DUE_DATE).
    C_DATE_FMT      CONSTANT VARCHAR2(20) := 'YYYY-MM-DD';

    -- Fallback CM FBDI import chunk size when neither the p_chunk_size arg nor the
    -- INBOUND.CM_CHUNK_SIZE config  is set.
    C_CM_CHUNK_DEFAULT  CONSTANT NUMBER := 50000;

    g_log_bucket    VARCHAR2(200);
    g_log_folder    VARCHAR2(200);
    g_error_bucket    VARCHAR2(200);
    g_error_folder    VARCHAR2(200);
    g_archive_bucket  VARCHAR2(200);
    g_archive_folder  VARCHAR2(200);
    g_ob_credential   VARCHAR2(200);
    g_ob_namespace    VARCHAR2(200);
    g_ob_uri          VARCHAR2(500);

    --------------------------------------------------------------------------
    -- Key/value config reader. One row per setting in LWS_C2FO_CONFIG, keyed by
    -- (CONFIG_GROUP, CONFIG_KEY). Returns the value, or p_default when the row is
    -- absent/disabled. If the row is MANDATORY_FLAG='Y' and resolves to NULL, it
    -- raises so load_config fails with a precise message. Adding a new parameter
    -- is an INSERT into LWS_C2FO_CONFIG, not a code or schema change.
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
                RAISE_APPLICATION_ERROR(-20050,
                    'Missing mandatory config: ' || p_group || '.' || p_key);
            END IF;
            RETURN p_default;
        END IF;
        RETURN l_val;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN p_default;   -- key not defined at all: treat as optional
    END cfg;

    --------------------------------------------------------------------------
    -- Config loader. Populates the package globals from LWS_C2FO_CONFIG 
    --------------------------------------------------------------------------
    FUNCTION load_config RETURN BOOLEAN IS
    BEGIN
        -- COMMON: obj-storage triple shared by all flows.
        g_ob_credential  := cfg('COMMON', 'OBJ_STORAGE_CREDENTIALS');
        g_ob_namespace   := cfg('COMMON', 'OBJ_STORAGE_NAMESPACE');
        g_ob_uri         := cfg('COMMON', 'OBJ_URI');
        -- INBOUND: log-file buckets only 
        g_log_bucket   := cfg('INBOUND', 'LOG_BUCKET');
        g_log_folder   := cfg('INBOUND', 'LOG_FOLDER');
        -- INBOUND: error-file buckets only 
        g_error_bucket   := cfg('INBOUND', 'ERROR_BUCKET');
        g_error_folder   := cfg('INBOUND', 'ERROR_FOLDER');
        -- INBOUND: archive bucket the award file is moved to after a successful load.
        -- Collected from config (mandatory row) - no hardcoded bucket in the package.
        g_archive_bucket := cfg('INBOUND', 'ARCHIVE_BUCKET');
        g_archive_folder := cfg('INBOUND', 'ARCHIVE_FOLDER');
        RETURN TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END load_config;

    --------------------------------------------------------------------------
    -- RFC 4180 CSV field escaping (same rule as the outbound package).
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
    -- Object-storage URI builder (mirrors the outbound package helper).
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
    -- 0. Bulk award-file loader (see spec). DBMS_CLOUD external table over the CSV
    --    object, then a single set-based INSERT ... SELECT into LWS_C2FO_AWARD_DATA.
    --    The file's 74 columns are named 1:1 with the table's file columns, so the
    --    external-table column_list doubles as the insert column list (no field_list
    --    remap needed). ATTRIBUTE1..5 (custom_name(s)) are NOT in the external table 
    --------------------------------------------------------------------------
    PROCEDURE load_award_file (
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_object_name   IN  VARCHAR2,
        p_instance_id   IN  VARCHAR2,
        o_rows_loaded   OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_url        VARCHAR2(2000);
        l_ext_tbl    VARCHAR2(60);
        l_ext_sql    VARCHAR2(4000);
        l_ins_sql    VARCHAR2(8000);
        -- Sibling files in the same drop, archived alongside the award CSV. The PDF
        -- shares the award base name with a .pdf extension; the control file inserts
        -- '_control' before the trailing date/extension
        -- (lowes_award_20260925.csv -> lowes_award_control_20260925.csv).
        l_pdf_name   VARCHAR2(240);
        l_ctl_name   VARCHAR2(240);
        -- Archive target names: the source name with an archive-time stamp appended
        -- before the extension, so several drops in one day never collide/overwrite
        -- in the archive bucket. All three siblings share one l_arch_stamp.
        l_arch_stamp VARCHAR2(16);
        l_csv_arch   VARCHAR2(240);
        l_pdf_arch   VARCHAR2(240);
        l_ctl_arch   VARCHAR2(240);
        -- The 74 award-file columns, in file/header order.
        C_FILE_COLS  CONSTANT VARCHAR2(4000) :=
            'COMPANY_ID, COMPANY_NAME, DIVISION_ID, INVOICE_ID, ORIGINAL_AMOUNT, '
         || 'CURRENCY, ORIGINAL_DUE_DATE, TRANSACTION_TYPE, ORIGINAL_INVOICE_TRANSACTION_DATE, '
         || 'VOUCHER_ID, VOUCHER_LINE_ID, FISCAL_YEAR, DISCOUNT_PERCENTAGE, INCOME, '
         || 'DISCOUNTED_INVOICE_AMOUNT, PAY_DATE, OFFER_APR_AMOUNT, COVERS_ADJUSTMENT, '
         || 'ADJUSTED_INVOICE_AMOUNT, ADJ_INVOICE_ID, SURVIVING_INVOICE_ID, '
         || 'SURVIVING_INVOICE_DUE_DATE, SUPPLIER_ADDRESS_1, SUPPLIER_ADDRESS_2, '
         || 'SUPPLIER_CITY, SUPPLIER_STATE, SUPPLIER_POSTAL_CODE, SUPPLIER_COUNTRY, '
         || 'SUPPLIER_TAX_ID, SEQUENTIAL_DOCUMENT_NUMBER, BUYER_NAME, BUYER_ADDRESS, '
         || 'BUYER_TAX_ID, ORIGINAL_AMOUNT_GROSSVAT, ORIGINAL_AMOUNT_NETVAT, '
         || 'VAT_TO_BE_DISCOUNTED, ORIGINAL_VAT, AWARDED_VAT, VAT_REDUCTION, '
         || 'ORIGINAL_VAT_PERCENTAGE, DISCOUNT_REASON_CODE, LOCAL_CURRENCY_KEY, '
         || 'LOCAL_CURRENCY_RATE, LOCAL_CURRENCY_ORIGINAL_INV_AMOUNT, LOCAL_CURRENCY_INCOME, '
         || 'LOCAL_CURRENCY_NET_AWARD_AMOUNT, LOCAL_CURRENCY_ORIGINAL_VAT, '
         || 'LOCAL_CURRENCY_AWARDED_VAT, LOCAL_CURRENCY_VAT_REDUCTION, MARKET_TYPE, '
         || 'PO_ID, FUND_TYPE, ERP_LEGAL_ENTITY, ERP_REFERENCE_NUMBER, ERP_VENDOR_ID, '
         || 'ERP_TAX_CODE, ERP_PAYMENT_TERM, ERP_BASELINE_DATE, ERP_NET_DUE_DATE, '
         || 'ERP_INVOICE_AMOUNT, ERP_DISCOUNT_BASE_AMOUNT, ERP_CASH_DISC_AMOUNT, '
         || 'ERP_PAYEE, ERP_VENDOR_SITE_ID, ERP_VENDOR_SITE_CODE, ERP_INVOICE_NUM, '
         || 'ERP_PAY_GROUP, ERP_SUP_PAY_PRIORITY, ERP_TAX_RATE, ERP_DOC_TYPE, '
         || 'ERP_BUSINESS_UNIT, ERP_SUPPLIER_NUMBER, ERP_PURPOSE_OF_PAYMENT, ERP_BURST_ID';
        -- CREATE_EXTERNAL_TABLE.column_list needs "name type" pairs, not bare names.
        -- Derive a typed list from C_FILE_COLS: every external-table column read as
        -- VARCHAR2(4000) text (real types live on the target table); the INSERT below
        -- still uses the bare-name C_FILE_COLS for positional name-match.
        l_col_list_typed VARCHAR2(8000);
    BEGIN
        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'load_award_file: mandatory config missing (COMMON obj-storage triple)';
            RETURN;
        END IF;

        l_col_list_typed := REGEXP_REPLACE(C_FILE_COLS,
                                '([A-Za-z0-9_]+)', '\1 VARCHAR2(4000)');

        l_url := object_uri(p_bucket_name, p_folder_path, p_object_name);
        -- Session-unique external table name (a run may load only one award file,
        -- but keep it collision-free across concurrent loader runs).
        l_ext_tbl := 'LWS_AWARD_EXT_' || TO_CHAR(SYS_CONTEXT('USERENV','SID'));

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        -- CSV over the object: header row skipped, comma-delimited, UTF-8, blanks as
        -- NULL. rejectlimit 0 = any malformed row fails the whole load (fail fast so
        -- the OIC count-match never passes on a partially-loaded file). No compression
        -- (plain .csv, per the confirmed file convention).
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

        -- One set-based insert. File columns copy across by matching name; the run/
        -- audit/state columns are stamped literally. Resolved keys + CM/DD outcome +
        -- ATTRIBUTE1..5 are intentionally left to their column defaults (NULL).
        l_ins_sql := 'INSERT INTO ' || g_schema || '.LWS_C2FO_AWARD_DATA ('
            || C_FILE_COLS
            || ', INSTANCE_ID, FILE_NAME, SOURCE_CODE, RECORD_STATUS, STAGE, '
            || 'CREATION_DATE, CREATED_BY, LAST_UPDATE_DATE, LAST_UPDATED_BY) '
            || 'SELECT ' || C_FILE_COLS
            || ', :inst, :fname, :src, ''N'', :stg, '
            || 'SYSTIMESTAMP, :usr, SYSTIMESTAMP, :usr2 '
            || 'FROM ' || l_ext_tbl;
        EXECUTE IMMEDIATE l_ins_sql
            USING p_instance_id, p_object_name, 'C2FO_INBOUND',
                  C_STAGE_STAGED, 'LWS_C2FO_LOAD', 'LWS_C2FO_LOAD';
        o_rows_loaded := SQL%ROWCOUNT;
        COMMIT;

        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        o_status  := 'SUCCESS';
        o_message := 'Loaded ' || o_rows_loaded || ' award rows from ' || p_object_name
                     || ' into LWS_C2FO_AWARD_DATA (instance ' || p_instance_id || ')';

        -- Archive the whole award drop only after the load has committed:
        l_pdf_name := REGEXP_REPLACE(p_object_name, '\.csv$', '.pdf', 1, 1, 'i');
        l_ctl_name := REGEXP_REPLACE(p_object_name, '(_[0-9]+)?\.csv$', '_control\1.csv', 1, 1, 'i');

        -- Archive target names: insert '_<HH24MISS>' before the extension. One stamp
        -- for all three so a drop's files stay grouped (e.g. lowes_award_20260925.csv
        -- -> lowes_award_20260925_142357.csv).
        l_arch_stamp := TO_CHAR(SYSTIMESTAMP, 'HH24MISS');
        l_csv_arch := REGEXP_REPLACE(p_object_name, '\.([^.]+)$', '_' || l_arch_stamp || '.\1', 1, 1, 'i');
        l_pdf_arch := REGEXP_REPLACE(l_pdf_name,   '\.([^.]+)$', '_' || l_arch_stamp || '.\1', 1, 1, 'i');
        l_ctl_arch := REGEXP_REPLACE(l_ctl_name,   '\.([^.]+)$', '_' || l_arch_stamp || '.\1', 1, 1, 'i');

        BEGIN
            DBMS_CLOUD.MOVE_OBJECT(
                source_credential_name => g_ob_credential,
                source_object_uri      => object_uri(p_bucket_name, p_folder_path, p_object_name),
                target_object_uri      => object_uri(g_archive_bucket, g_archive_folder, l_csv_arch)
            );
            o_message := o_message || '; archived ' || p_object_name || ' to '
                         || g_archive_bucket || ' as ' || l_csv_arch;
        EXCEPTION
            WHEN OTHERS THEN
                o_message := o_message || '; WARNING archive failed for ' || p_object_name
                             || ' (' || SUBSTR(SQLERRM, 1, 150) || ') - source file left in place';
        END;

        BEGIN
            DBMS_CLOUD.MOVE_OBJECT(
                source_credential_name => g_ob_credential,
                source_object_uri      => object_uri(p_bucket_name, p_folder_path, l_pdf_name),
                target_object_uri      => object_uri(g_archive_bucket, g_archive_folder, l_pdf_arch)
            );
            o_message := o_message || '; archived ' || l_pdf_name || ' as ' || l_pdf_arch;
        EXCEPTION
            WHEN OTHERS THEN
                o_message := o_message || '; WARNING archive failed for ' || l_pdf_name
                             || ' (' || SUBSTR(SQLERRM, 1, 150) || ') - source file left in place';
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
                             || ' (' || SUBSTR(SQLERRM, 1, 150) || ') - source file left in place';
        END;
    EXCEPTION
        WHEN OTHERS THEN
            o_rows_loaded := 0;
            o_status  := 'ERROR';
            o_message := SUBSTR('load_award_file: ' || SQLERRM
                         || ' | file_uri=' || l_url
                         || ' | ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE ' || l_ext_tbl;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
    END load_award_file;

    --------------------------------------------------------------------------
    -- Deterministic CM invoice number (BR#5/BR#8): the awarded invoice's number
    -- (AWARD_DATA.ERP_INVOICE_NUM) with a '-C2FO' suffix. INVOICE_NUM is 50 chars
    -- max in Fusion, so the original is trimmed to 44 before appending '-C2FO' +
    -- an optional single re-award digit (see below).
    -- NOTE: ERP_INVOICE_NUM is
    -- the invoice number, not the per-installment key, so two awards on different
    -- payment_num of the same invoice would build the same CM number. That is not
    -- expected here (one invoice = one award), but if multi-installment awards ever
    -- arrive this must fold PAYMENT_NUM into the number to stay unique.
    -- NB: this function is DOCUMENTATION-ONLY and cannot be embedded in SQL
    -- (PLS-00231). It renders only the FIRST-award number. The LIVE number is
    -- computed in validate_batch, which appends a re-award index n (0 -> '-C2FO',
    -- n>=1 -> '-C2FOn') so a reversed-then-re-awarded invoice gets a fresh CM
    -- number that does not collide with the reversed original. Base trimmed to 44
    -- there so '-C2FO' + one digit still fits INVOICE_NUM(50).
    --------------------------------------------------------------------------
    FUNCTION cm_invoice_num_fun (p_invoice_num IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(p_invoice_num, 1, 44) || '-C2FO';
    END cm_invoice_num_fun;

    --------------------------------------------------------------------------
    -- Stamp a single award row as errored (terminal, BR#10). Keyed by the award's
    -- composite (invoice_id, instance_id).
    --------------------------------------------------------------------------
    PROCEDURE flag_error (
        p_invoice_id   IN VARCHAR2,
        p_instance_id  IN VARCHAR2,
        p_stage        IN VARCHAR2,
        p_msg          IN VARCHAR2
    ) IS
    BEGIN
        UPDATE lws_c2fo_award_data
        SET    record_status    = 'E',
               stage            = p_stage,
               error_code       = p_stage,
               error_message    = SUBSTR(p_msg, 1, 2000),
               last_update_date = SYSTIMESTAMP
        WHERE  invoice_id  = p_invoice_id
        AND    instance_id = p_instance_id;
    END flag_error;

    --------------------------------------------------------------------------
    -- Normalize a comma-separated exclusion list (from LWS_C2FO_CONFIG) into a
    -- delimiter-wrapped, trimmed token string so a set-membership test can be done
    -- purely in SQL (no collection type). Returns e.g. ',EMPLOYEE,TAX AUTHORITY,'.
    -- A value V is "in the list" when INSTR(<wrapped>, ',' || TRIM(V) || ',') > 0.
    -- NULL/blank input returns NULL (caller treats NULL as "exclude none"). This is
    -- a verbatim copy of LWS_OB_EXTRACT_ATP_PKG.list_wrap so inbound re-checks match
    -- the outbound extract's exclusion semantics exactly.
    --------------------------------------------------------------------------
    FUNCTION list_wrap (p_csv IN VARCHAR2) RETURN VARCHAR2 IS
        l_out  VARCHAR2(32767);
        l_tok  VARCHAR2(4000);
        l_pos  PLS_INTEGER := 1;
        l_next PLS_INTEGER;
    BEGIN
        IF p_csv IS NULL OR TRIM(p_csv) IS NULL THEN
            RETURN NULL;
        END IF;
        l_out := ',';
        LOOP
            l_next := INSTR(p_csv, ',', l_pos);
            IF l_next = 0 THEN
                l_tok := TRIM(SUBSTR(p_csv, l_pos));
                IF l_tok IS NOT NULL THEN l_out := l_out || l_tok || ','; END IF;
                EXIT;
            ELSE
                l_tok := TRIM(SUBSTR(p_csv, l_pos, l_next - l_pos));
                IF l_tok IS NOT NULL THEN l_out := l_out || l_tok || ','; END IF;
                l_pos := l_next + 1;
            END IF;
        END LOOP;
        IF l_out = ',' THEN RETURN NULL; END IF;   -- all elements blank => no restriction
        RETURN l_out;
    END list_wrap;

    --====================================================================
    -- VALIDATION
    --   For each row of the new batch, validate eligibility against the mirror
    --   via the bridging views and stamp the state machine. 
    --====================================================================
    PROCEDURE validate_batch (
        p_instance_id      IN  VARCHAR2,
        p_activity_type    IN  VARCHAR2,
        p_update_pay_group IN  VARCHAR2 DEFAULT 'N',
        o_validated        OUT NUMBER,
        o_errored          OUT NUMBER
    ) IS
        -- SET-BASED validation (rewritten for 20K-100K award batches). Each
        -- eligibility gate is ONE UPDATE over the whole batch instead of a
        -- single-row check per award. Gates run in the SAME ORDER as the former
        -- row-by-row loop and every gate is guarded by record_status='N', so a row
        -- already failed by an earlier gate is skipped by every later gate - this
        -- reproduces the former first-fail-wins CONTINUE behaviour exactly,
        -- including which C_ERR_* code a multi-fail row receives.
        --
        -- The former loop resolved each award against ap_invoices_all and
        -- ap_payment_schedules_all one row at a time (and summed the supplier
        -- net-debit position per award - a 3.2M-row scan EACH time). Here those
        -- resolved values are materialised ONCE into LWS_C2FO_AWARD_VALWORK by a
        -- single INSERT..SELECT, the net-debit position is computed ONCE per
        -- (vendor_id, org_id, currency), and every gate + the final PASS stamp
        -- read the work table. One COMMIT at the end (whole batch, one pass).
        --
        -- The award file carries the AP invoice id and target installment in
        -- dedicated columns: VOUCHER_ID = ap_invoices_all.invoice_id, and
        -- VOUCHER_LINE_ID = ap_payment_schedules_all.payment_num.
        --
        -- BEHAVIOUR CHANGE (deliberate, agreed): the invoice resolve now joins on
        -- (invoice_id, invoice_num) only - NOT vendor_site_id. A genuine site
        -- mismatch therefore reports C_ERR_SITE_MISMATCH at the dedicated gate,
        -- instead of being masked as C_ERR_INV_NOT_FOUND by the old 3-key resolve.
        l_vt_wrap     VARCHAR2(32767) := list_wrap(cfg('INBOUND','EXCL_VENDOR_TYPES'));
        l_pt_wrap     VARCHAR2(32767) := list_wrap(cfg('INBOUND','EXCL_PAYMENT_TERMS'));
        l_pg_wrap     VARCHAR2(32767) := list_wrap(cfg('INBOUND','EXCL_PAY_GROUPS'));
        l_prepass     NUMBER := 0;
    BEGIN
        o_validated := 0;
        o_errored   := 0;

        --------------------------------------------------------------------
        -- SUPPLIER-LEVEL PRE-PASS. A supplier that changed status
        -- after its invoices were offered to C2FO makes ALL its awards ineligible.
        -- Four conditions, each its own UPDATE so every reject carries its own code
        -- + the offending value. Rows flagged here update to 'E' and the c_rows cursor
        -- (record_status='N') never sees them, so the per-row loop below is not
        -- re-running these supplier-wide tests per award. 
        --------------------------------------------------------------------
        -- 1. Factoring: any ACTIVE site in the third-party payment relationship.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_FACTORING, error_code=C_ERR_FACTORING,
               error_message='Supplier has a factoring relationship',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (
                 SELECT 1 FROM ap_invoices_all aia
                 WHERE aia.invoice_id     = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                 AND   aia.invoice_num    = d.erp_invoice_num
                 AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)
                 AND   EXISTS (
                         SELECT 1 FROM poz_sup_thirdparty_payment_rel tpp
                         JOIN   poz_supplier_sites_all_m s_tpp ON s_tpp.vendor_site_id = tpp.vendor_site_id
                         WHERE  s_tpp.vendor_id = aia.vendor_id
                         AND    (s_tpp.inactive_date IS NULL OR s_tpp.inactive_date > TRUNC(SYSDATE))));
        l_prepass := l_prepass + SQL%ROWCOUNT;

        -- 2. Assigned to a factor (supplier attribute6 = 'Y').
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_ASSIGNED_FACTOR, error_code=C_ERR_ASSIGNED_FACTOR,
               error_message='Supplier is assigned to a factor',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (
                 SELECT 1 FROM ap_invoices_all aia
                 JOIN   poz_suppliers_v sv ON sv.vendor_id = aia.vendor_id
                 WHERE aia.invoice_id     = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                 AND   aia.invoice_num    = d.erp_invoice_num
                 AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)
                 AND   NVL(sv.attribute6,'N') = 'Y');
        l_prepass := l_prepass + SQL%ROWCOUNT;

        -- 3. Excluded vendor type (INBOUND.EXCL_VENDOR_TYPES). Skipped when unset.
        IF l_vt_wrap IS NOT NULL THEN
            UPDATE lws_c2fo_award_data d
            SET    record_status='E', stage=C_ERR_VENDOR_TYPE, error_code=C_ERR_VENDOR_TYPE,
                   error_message='Supplier type is excluded ('
                       || (SELECT MAX(sv.vendor_type_lookup_code) FROM ap_invoices_all aia
                           JOIN poz_suppliers_v sv ON sv.vendor_id=aia.vendor_id
                           WHERE aia.invoice_id = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                           AND   aia.invoice_num = d.erp_invoice_num
                           AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)) || ')',
                   last_update_date=SYSTIMESTAMP
            WHERE  d.instance_id=p_instance_id AND d.record_status='N'
            AND    EXISTS (
                     SELECT 1 FROM ap_invoices_all aia
                     JOIN   poz_suppliers_v sv ON sv.vendor_id = aia.vendor_id
                     WHERE aia.invoice_id     = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   aia.invoice_num    = d.erp_invoice_num
                     AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   INSTR(l_vt_wrap, ',' || TRIM(sv.vendor_type_lookup_code) || ',') > 0);
            l_prepass := l_prepass + SQL%ROWCOUNT;
        END IF;

        -- 4. Excluded payment term on ANY active site (INBOUND.EXCL_PAYMENT_TERMS).
        --    Supplier-wide, matching outbound. Skipped when unset.
        IF l_pt_wrap IS NOT NULL THEN
            UPDATE lws_c2fo_award_data d
            SET    record_status='E', stage=C_ERR_PAYMENT_TERM, error_code=C_ERR_PAYMENT_TERM,
                   error_message='Supplier payment term is excluded',
                   last_update_date=SYSTIMESTAMP
            WHERE  d.instance_id=p_instance_id AND d.record_status='N'
            AND    EXISTS (
                     SELECT 1 FROM ap_invoices_all aia
                     WHERE aia.invoice_id     = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   aia.invoice_num    = d.erp_invoice_num
                     AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   EXISTS (
                             SELECT 1 FROM poz_supplier_sites_all_m s_pt
                             JOIN   ap_terms_tl t_pt ON t_pt.term_id = s_pt.terms_id AND t_pt.language='US'
                             WHERE  s_pt.vendor_id = aia.vendor_id
                             AND    (s_pt.inactive_date IS NULL OR s_pt.inactive_date > TRUNC(SYSDATE))
                             AND    INSTR(l_pt_wrap, ',' || TRIM(t_pt.name) || ',') > 0));
            l_prepass := l_prepass + SQL%ROWCOUNT;
        END IF;

        -- 5. Excluded pay group on ANY active supplier site's DEFAULT pay group
        --    (INBOUND.EXCL_PAY_GROUPS).
        IF l_pg_wrap IS NOT NULL THEN
            UPDATE lws_c2fo_award_data d
            SET    record_status='E', stage=C_ERR_PAY_GROUP, error_code=C_ERR_PAY_GROUP,
                   error_message='Supplier pay group is excluded',
                   last_update_date=SYSTIMESTAMP
            WHERE  d.instance_id=p_instance_id AND d.record_status='N'
            AND    EXISTS (
                     SELECT 1 FROM ap_invoices_all aia
                     WHERE aia.invoice_id     = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   aia.invoice_num    = d.erp_invoice_num
                     AND   aia.vendor_site_id = TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)
                     AND   EXISTS (
                             SELECT 1 FROM poz_supplier_sites_all_m s_pg
                             WHERE  s_pg.vendor_id = aia.vendor_id
                             AND    (s_pg.inactive_date IS NULL OR s_pg.inactive_date > TRUNC(SYSDATE))
                             AND    INSTR(l_pg_wrap, ',' || TRIM(s_pg.pay_group_lookup_code) || ',') > 0));
            l_prepass := l_prepass + SQL%ROWCOUNT;
        END IF;

        o_errored := o_errored + l_prepass;

        --==================================================================
        -- POPULATE THE WORK TABLE. One INSERT resolves every still-'N' award
        -- against the mirror.
        --   Invoice join: (invoice_id, invoice_num) only - site compared later
        --   (see BEHAVIOUR CHANGE note). invoice_id is the PK so the join is
        --   single-row. INV_ID NULL => invoice not found.
        --   Installment LEFT JOIN uses the SAME 3-condition filter the old loop
        --   used (invoice_id + payment_num=voucher_line_id + payment_status_flag
        --   ='N'); INST_FOUND flags a match, so "no unpaid named instalment"
        --   lands as INST_FOUND IS NULL - caught by the INST_NOT_FOUND gate,
        --   identical to the old NO_DATA_FOUND branch.
        --==================================================================
        DELETE FROM lws_c2fo_award_valwork;

        INSERT INTO lws_c2fo_award_valwork (
            invoice_id, instance_id, inv_id, org_id, vendor_id, site_id, source_code,
            approval_status, wfapproval_status, cancelled_date, inv_type, inv_date,
            terms_date, pay_group, pay_term, payment_status,
            pay_num, disc_avail, inst_due, disc1_date, disc2_date, disc3_date,
            disc2_amt, disc3_amt, sched_hold, amt_remain, inst_found, income, tax_rate)
        SELECT d.invoice_id, d.instance_id,
               aia.invoice_id, aia.org_id, aia.vendor_id, aia.vendor_site_id, aia.source,
               aia.approval_status, aia.wfapproval_status, aia.cancelled_date,
               aia.invoice_type_lookup_code, aia.invoice_date,
               NVL(aia.terms_date, aia.invoice_date), aia.pay_group_lookup_code,
               (SELECT t.name FROM ap_terms_tl t
                 WHERE t.term_id = aia.terms_id AND t.language = 'US'),
               aia.payment_status_flag,
               apsa.payment_num, apsa.discount_amount_available, apsa.due_date,
               apsa.discount_date, apsa.second_discount_date, apsa.third_discount_date,
               apsa.second_disc_amt_available, apsa.third_disc_amt_available,
               NVL(apsa.hold_flag,'N'), NVL(apsa.amount_remaining, 0),
               CASE WHEN apsa.invoice_id IS NOT NULL THEN 'Y' END,
               d.income, d.erp_tax_rate
        FROM   lws_c2fo_award_data d
        LEFT JOIN ap_invoices_all aia
               ON aia.invoice_id  = TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR)
              AND aia.invoice_num = d.erp_invoice_num
        LEFT JOIN ap_payment_schedules_all apsa
               ON apsa.invoice_id = aia.invoice_id
              AND apsa.payment_num = TO_NUMBER(d.voucher_line_id DEFAULT NULL ON CONVERSION ERROR)
              AND apsa.payment_status_flag = 'N'
        WHERE  d.instance_id = p_instance_id
        AND    d.record_status = 'N';

        -- RE-AWARD NUMBERING: count of this invoice_id's prior TERMINAL awards
        -- (record_status='Y', any instance). Each consumed a CM number.
        UPDATE lws_c2fo_award_valwork w
        SET    w.reaward_n = (SELECT COUNT(*) FROM lws_c2fo_award_data d
                              WHERE d.invoice_id = w.invoice_id
                              AND   d.record_status = 'Y');

        -- CM number for THIS award: base trimmed to 44 so '-C2FO' + one digit still
        -- fits INVOICE_NUM(50). n=0 -> '-C2FO'; n>=1 -> '-C2FOn'.
        UPDATE lws_c2fo_award_valwork w
        SET    w.cm_num = (SELECT SUBSTR(d.erp_invoice_num,1,44) || '-C2FO'
                                  || CASE WHEN w.reaward_n = 0 THEN '' ELSE TO_CHAR(w.reaward_n) END
                           FROM   lws_c2fo_award_data d
                           WHERE  d.invoice_id = w.invoice_id AND d.instance_id = w.instance_id);

        -- NET-DEBIT POSITION, computed ONCE PER DISTINCT (vendor_id, org_id,
        -- currency) - NOT once per award. The supplier balance depends only on
        -- that triple, and a 100K-award batch spans only a few hundred suppliers,
        -- so the heavy signed-balance aggregate runs a few hundred times (one row
        -- per distinct combo) instead of 100K times. The net-debit gate then joins
        -- each award to its precomputed balance here.
        --
        -- Only non-null triples are materialised: the key is NOT NULL, and a null
        -- in any part could never match an open AP doc, so its balance is
        -- effectively 0 (not in debit) - the gate's join simply finds no row and
        -- the award passes, identical to the old per-award SUM-over-no-rows = 0.
        -- Same signed sum and same open-item / cancelled / prepayment /
        -- unreleased-hold filters as the former per-award scan.
        DELETE FROM lws_c2fo_netdebit_work;

        INSERT INTO lws_c2fo_netdebit_work (vendor_id, org_id, currency, net_balance)
        WITH combos AS (
            SELECT DISTINCT w.vendor_id, w.org_id, d.currency
            FROM   lws_c2fo_award_valwork w
            JOIN   lws_c2fo_award_data d
                   ON d.invoice_id = w.invoice_id AND d.instance_id = w.instance_id
            WHERE  w.vendor_id IS NOT NULL
            AND    w.org_id    IS NOT NULL
            AND    d.currency  IS NOT NULL
        )
        SELECT c.vendor_id, c.org_id, c.currency,
               NVL(SUM(
                   CASE aia.invoice_type_lookup_code
                        WHEN 'CREDIT' THEN -1
                        WHEN 'DEBIT'  THEN -1
                        ELSE 1
                   END * apsa.amount_remaining), 0)
        FROM   combos c
        LEFT JOIN ap_invoices_all aia
               ON aia.vendor_id = c.vendor_id
              AND aia.org_id    = c.org_id
              AND aia.invoice_currency_code = c.currency
              AND aia.cancelled_date IS NULL
              AND aia.invoice_type_lookup_code <> 'PREPAYMENT'
              AND NOT EXISTS (SELECT 1 FROM ap_holds_all h
                              WHERE h.invoice_id = aia.invoice_id
                              AND   h.release_lookup_code IS NULL)
        LEFT JOIN ap_payment_schedules_all apsa
               ON apsa.invoice_id = aia.invoice_id
              AND apsa.payment_status_flag <> 'Y'
        GROUP BY c.vendor_id, c.org_id, c.currency;

        --==================================================================
        -- GATES. Each is one UPDATE of lws_c2fo_award_data, guarded by
        -- record_status='N', joined one-to-one to the work table. ORDER IS
        -- IDENTICAL to the former loop; the 'N' guard gives first-fail-wins.
        --==================================================================

        -- Gate 1: voucher id not a numeric invoice id.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_VOUCHER_BAD, error_code=C_ERR_VOUCHER_BAD,
               error_message='Award voucher id is not a valid invoice number',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    TO_NUMBER(d.voucher_id DEFAULT NULL ON CONVERSION ERROR) IS NULL;
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 2: duplicate - live (un-reversed) prior success in another batch.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_DUPLICATE, error_code=C_ERR_DUPLICATE,
               error_message='Award already processed successfully in a prior batch',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_data p
                       WHERE p.invoice_id = d.invoice_id
                       AND   p.instance_id <> d.instance_id
                       AND   p.record_status = 'Y'
                       AND   NVL(p.reversed_flag,'N') = 'N');
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 3: re-award but the most recent prior success is NOT reversed.
        -- reaward_n>0 AND latest prior 'Y' row reversed_flag<>'Y'.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_DUPLICATE, error_code=C_ERR_DUPLICATE,
               error_message='Prior award not reversed - cannot re-award',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.reaward_n > 0)
        AND    NVL((SELECT p.reversed_flag FROM lws_c2fo_award_data p
                    WHERE p.invoice_id = d.invoice_id
                    AND   p.record_status = 'Y'
                    AND   p.last_update_date =
                          (SELECT MAX(p2.last_update_date) FROM lws_c2fo_award_data p2
                           WHERE p2.invoice_id = d.invoice_id AND p2.record_status='Y')
                    AND   ROWNUM = 1), 'N') <> 'Y';
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 4: original invoice not found (INV_ID NULL after the resolve).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_INV_NOT_FOUND, error_code=C_ERR_INV_NOT_FOUND,
               error_message='Invoice not found in finance system',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.inv_id IS NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 5: vendor-site mismatch. Award site null, resolved site null, or
        -- unequal. (BEHAVIOUR CHANGE: now reachable - resolve no longer joins site.)
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_SITE_MISMATCH, error_code=C_ERR_SITE_MISMATCH,
               error_message='Award site does not match invoice site ('
                   || NVL(TO_CHAR(TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR)),'null')
                   || ' vs '
                   || NVL((SELECT TO_CHAR(w.site_id) FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id),'null')
                   || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   (TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR) IS NULL
                              OR w.site_id IS NULL
                              OR TO_NUMBER(d.erp_vendor_site_id DEFAULT NULL ON CONVERSION ERROR) <> w.site_id));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 6: invoice cancelled.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_CANCELLED, error_code=C_ERR_CANCELLED,
               error_message='Invoice cancelled', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.cancelled_date IS NOT NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 7: invoice not approved.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_NOT_APPROVED, error_code=C_ERR_NOT_APPROVED,
               error_message='Invoice not approved ('
                   || NVL((SELECT w.approval_status FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id),'null') || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.approval_status NOT IN ('APPROVED','NOT REQUIRED'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 8: invoice workflow approval not complete.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_WF_NOT_APPROVED, error_code=C_ERR_WF_NOT_APPROVED,
               error_message='Invoice workflow approval not complete ('
                   || NVL((SELECT w.wfapproval_status FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id),'null') || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   NVL(w.wfapproval_status,'X') NOT IN ('WFAPPROVED','NOT REQUIRED','MANUALLY APPROVED'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 9: invoice is expense report or prepayment.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_BAD_TYPE, error_code=C_ERR_BAD_TYPE,
               error_message='Invoice is expense report or prepayment ('
                   || (SELECT w.inv_type FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.inv_type IN ('EXPENSE REPORT','PREPAYMENT'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 10: invoice date in the future.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_FUTURE_INV_DATE, error_code=C_ERR_FUTURE_INV_DATE,
               error_message='Invoice date is in the future ('
                   || (SELECT TO_CHAR(w.inv_date,'YYYY-MM-DD') FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.inv_date > TRUNC(SYSDATE));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 11: terms date in the future.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_FUTURE_TERMS, error_code=C_ERR_FUTURE_TERMS,
               error_message='Terms date is in the future ('
                   || (SELECT TO_CHAR(w.terms_date,'YYYY-MM-DD') FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.terms_date > TRUNC(SYSDATE));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 12: invoice already in C2FO pay group (only when p_update_pay_group='Y').
        IF p_update_pay_group = 'Y' THEN
            UPDATE lws_c2fo_award_data d
            SET    record_status='E', stage=C_ERR_ALREADY_C2FO, error_code=C_ERR_ALREADY_C2FO,
                   error_message='Invoice already in C2FO pay group ('
                       || (SELECT w.pay_group FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
                   last_update_date=SYSTIMESTAMP
            WHERE  d.instance_id=p_instance_id AND d.record_status='N'
            AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                           AND   NVL(w.pay_group,'X') IN ('C2FO','C2FO_BANK'));
            o_errored := o_errored + SQL%ROWCOUNT;
        END IF;

        -- Gate 13: invoice already paid.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_PAID, error_code=C_ERR_PAID,
               error_message='Invoice already paid', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   NVL(w.payment_status,'N') <> 'N');
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 14: named instalment not found unpaid (INST_FOUND NULL).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_INST_NOT_FOUND, error_code=C_ERR_INST_NOT_FOUND,
               error_message='Named instalment not found unpaid', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.inst_found IS NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 15: instalment has no remaining amount.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_ZERO_AMOUNT, error_code=C_ERR_ZERO_AMOUNT,
               error_message='Instalment has no remaining amount', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   NVL(w.amt_remain,0) = 0);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 16: instalment on payment hold.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_INST_HOLD, error_code=C_ERR_INST_HOLD,
               error_message='Instalment on payment hold', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.sched_hold = 'Y');
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 17: supplier site on a payment hold (purchasing or hold-all-payments).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_SITE_HOLD, error_code=C_ERR_SITE_HOLD,
               error_message='Supplier site on payment hold', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN poz_supplier_sites_all_m ss ON ss.vendor_site_id = w.site_id
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   (NVL(ss.hold_flag,'N')='Y' OR NVL(ss.hold_all_payments_flag,'N')='Y'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 18: supplier disabled.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_SUPP_DISABLED, error_code=C_ERR_SUPP_DISABLED,
               error_message='Supplier is disabled', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN poz_suppliers_v sv ON sv.vendor_id = w.vendor_id
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   NVL(sv.enabled_flag,'Y') <> 'Y');
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 19: invoice has an unreleased hold.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_INVOICE_HOLD, error_code=C_ERR_INVOICE_HOLD,
               error_message='Invoice has an unreleased hold', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN ap_holds_all aha ON aha.invoice_id = w.inv_id
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   aha.release_lookup_code IS NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 20: invoice pay group excluded (INBOUND.EXCL_PAY_GROUPS). Invoice-level.
        IF l_pg_wrap IS NOT NULL THEN
            UPDATE lws_c2fo_award_data d
            SET    record_status='E', stage=C_ERR_PAY_GROUP, error_code=C_ERR_PAY_GROUP,
                   error_message='Invoice pay group is excluded ('
                       || (SELECT w.pay_group FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
                   last_update_date=SYSTIMESTAMP
            WHERE  d.instance_id=p_instance_id AND d.record_status='N'
            AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                           AND   INSTR(l_pg_wrap, ',' || TRIM(w.pay_group) || ',') > 0);
            o_errored := o_errored + SQL%ROWCOUNT;
        END IF;

        -- Gate 21: invoice pay group is null (excluded, terminal).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_PAY_GROUP, error_code=C_ERR_PAY_GROUP,
               error_message='Invoice pay group is null (excluded)', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   w.pay_group IS NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 22: any ACTIVE supplier site default pay group is null (excluded).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_PAY_GROUP, error_code=C_ERR_PAY_GROUP,
               error_message='Supplier site pay group is null (excluded)', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN poz_supplier_sites_all_m s_pg ON s_pg.vendor_id = w.vendor_id
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   (s_pg.inactive_date IS NULL OR s_pg.inactive_date > TRUNC(SYSDATE))
                       AND   s_pg.pay_group_lookup_code IS NULL);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 23: INVOICE pay group changed since offer (live vs award baseline).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_PG_CHANGED, error_code=C_ERR_PG_CHANGED,
               error_message='Invoice pay group changed since offer (was '
                   || NVL(d.erp_pay_group,'null') || ', now '
                   || NVL((SELECT w.pay_group FROM lws_c2fo_award_valwork w
                           WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id),'null') || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   NVL(TRIM(w.pay_group),'~NULL~') <> NVL(TRIM(d.erp_pay_group),'~NULL~'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 24: SUPPLIER-site default pay group changed since offer (any active
        -- site default differs from the award baseline).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_PG_CHANGED, error_code=C_ERR_PG_CHANGED,
               error_message='Supplier site pay group changed since offer (differs from '
                   || NVL(d.erp_pay_group,'null') || ')', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN poz_supplier_sites_all_m s_pg ON s_pg.vendor_id = w.vendor_id
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   (s_pg.inactive_date IS NULL OR s_pg.inactive_date > TRUNC(SYSDATE))
                       AND   NVL(TRIM(s_pg.pay_group_lookup_code),'~NULL~')
                             <> NVL(TRIM(d.erp_pay_group),'~NULL~'));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 25: award due date does not match the named instalment due date.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_DD_MISMATCH, error_code=C_ERR_DD_MISMATCH,
               error_message='Award due date does not match instalment', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND   (TO_DATE(d.erp_net_due_date DEFAULT NULL ON CONVERSION ERROR,'YYYY-MM-DD') IS NULL
                              OR TO_DATE(d.erp_net_due_date DEFAULT NULL ON CONVERSION ERROR,'YYYY-MM-DD')
                                 <> TRUNC(w.inst_due)));
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 26: a credit memo already exists for this award (by deterministic number).
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_CM_EXISTS, error_code=C_ERR_CM_EXISTS,
               error_message='A credit memo already exists for this award', last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN ap_invoices_all aia ON aia.invoice_num = w.cm_num
                                               AND aia.invoice_type_lookup_code = 'CREDIT'
                       WHERE w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 27: supplier in net debit (signed open balance < 0). The balance was
        -- computed ONCE per distinct (vendor_id, org_id, currency) into
        -- LWS_C2FO_NETDEBIT_WORK; here each award joins to its precomputed row by
        -- its resolved vendor/org (valwork) + award currency (award_data). A combo
        -- with no netdebit row (null key, or no open docs => balance 0) is never
        -- < 0, so the award passes - identical to the old SUM-over-no-rows = 0.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_NET_DEBIT, error_code=C_ERR_NET_DEBIT,
               error_message='Supplier in net debit ('
                   || (SELECT TO_CHAR(nd.net_balance)
                       FROM   lws_c2fo_award_valwork w
                       JOIN   lws_c2fo_netdebit_work nd
                              ON nd.vendor_id = w.vendor_id AND nd.org_id = w.org_id
                             AND nd.currency  = d.currency
                       WHERE  w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id) || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    EXISTS (SELECT 1 FROM lws_c2fo_award_valwork w
                       JOIN   lws_c2fo_netdebit_work nd
                              ON nd.vendor_id = w.vendor_id AND nd.org_id = w.org_id
                             AND nd.currency  = d.currency
                       WHERE  w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id
                       AND    nd.net_balance < 0);
        o_errored := o_errored + SQL%ROWCOUNT;

        -- Gate 28: CM amount imbalance (only when income<>0). header=GROSS,
        -- line=NET, tax computed; reject if rounded header <> rounded net + tax.
        UPDATE lws_c2fo_award_data d
        SET    record_status='E', stage=C_ERR_CM_IMBALANCE, error_code=C_ERR_CM_IMBALANCE,
               error_message='Credit memo amounts do not balance (hdr '
                   || TO_CHAR(ROUND(-d.income * (1 + NVL(d.erp_tax_rate,0)/100), 2))
                   || ' net ' || TO_CHAR(ROUND(-d.income, 2))
                   || ' tax ' || TO_CHAR(ROUND(-d.income * NVL(d.erp_tax_rate,0)/100, 2)) || ')',
               last_update_date=SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N'
        AND    NVL(d.income,0) <> 0
        AND    ROUND(-d.income * (1 + NVL(d.erp_tax_rate,0)/100), 2)
               <> ROUND(-d.income, 2) + ROUND(-d.income * NVL(d.erp_tax_rate,0)/100, 2);
        o_errored := o_errored + SQL%ROWCOUNT;

        --==================================================================
        -- PASS. Every row still 'N' has cleared all gates. Stamp resolved keys +
        -- CM number from the work table, in one UPDATE. record_status stays 'N'
        -- (still in flight). The income=0 stage/cm_status CASE is unchanged.
        --==================================================================
        UPDATE lws_c2fo_award_data d
        SET    (erp_invoice_id, erp_org_id, vendor_id, payment_num, discount_amount,
                orig_first_discount_date, orig_first_discount_amt,
                orig_second_discount_date, orig_second_discount_amt,
                orig_third_discount_date, orig_third_discount_amt,
                cm_invoice_num, source_code)
             = (SELECT w.inv_id, w.org_id, w.vendor_id, w.pay_num, w.disc_avail,
                       TO_CHAR(w.disc1_date,'YYYY-MM-DD'), w.disc_avail,
                       TO_CHAR(w.disc2_date,'YYYY-MM-DD'), w.disc2_amt,
                       TO_CHAR(w.disc3_date,'YYYY-MM-DD'), w.disc3_amt,
                       w.cm_num, w.source_code
                FROM   lws_c2fo_award_valwork w
                WHERE  w.invoice_id=d.invoice_id AND w.instance_id=d.instance_id),
               record_status    = 'N',
               stage            = CASE WHEN NVL(d.income,0)=0
                                       THEN C_STAGE_CM_VALIDATED ELSE C_STAGE_VALIDATED END,
               cm_status        = CASE WHEN NVL(d.income,0)=0 THEN 'OK' ELSE cm_status END,
               error_code       = NULL,
               error_message    = NULL,
               last_update_date = SYSTIMESTAMP
        WHERE  d.instance_id=p_instance_id AND d.record_status='N';
        o_validated := SQL%ROWCOUNT;

        COMMIT;
    END validate_batch;

    --====================================================================
    -- MASTER OIC ENTRY  (ASYNC)
    --   Creates the run-log row, persists the OIC-supplied runtime params, submits
    --   a one-time job that validates the batch, and returns immediately. OIC polls
    --   the run log by run id. At 500K rows OIC never blocks on validation.
    --====================================================================
    PROCEDURE run_inbound (
        p_instance_id       IN  VARCHAR2,
        p_activity_type     IN  VARCHAR2,
        p_source_code       IN  VARCHAR2,
        p_pay_group         IN  VARCHAR2 DEFAULT NULL,
        p_update_pay_group  IN  VARCHAR2 DEFAULT 'N',
        p_cm_payment_method IN  VARCHAR2 DEFAULT NULL,
        o_run_id            OUT NUMBER,
        o_job_name          OUT VARCHAR2,
        o_status            OUT VARCHAR2,
        o_message           OUT VARCHAR2
    ) IS
        l_total   NUMBER;
        l_job     VARCHAR2(128);
        l_plsql   VARCHAR2(1000);
        l_upd_pg  VARCHAR2(1) := CASE WHEN UPPER(NVL(p_update_pay_group, 'N')) = 'Y' THEN 'Y' ELSE 'N' END;
    BEGIN
        o_status := 'SUCCESS';

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'Could not load config from LWS_C2FO_CONFIG (missing mandatory key?)';
            RETURN;
        END IF;

        IF p_activity_type IS NULL THEN
            o_status  := 'ERROR';
            o_message := 'p_activity_type is required (the in-scope award activity gate)';
            RETURN;
        END IF;

        o_run_id := lws_ap_c2fo_award_run_seq.NEXTVAL;

        SELECT COUNT(*) INTO l_total
        FROM   lws_c2fo_award_data
        WHERE  instance_id = p_instance_id;

        -- Persist the OIC-supplied runtime params so the background session
        -- (validation job) reads them back by run id.
        INSERT INTO lws_ap_c2fo_award_run_log (
            run_id, instance_id, total_count, start_time, status,
            activity_type, source_code, pay_group,
            update_pay_group, cm_payment_method
        ) VALUES (
            o_run_id, p_instance_id, l_total, SYSDATE, 'RUNNING',
            p_activity_type, p_source_code,
            CASE WHEN l_upd_pg = 'Y' THEN p_pay_group END,  -- store pay group only when the update is on
            l_upd_pg, p_cm_payment_method
        );
        COMMIT;

        -- Submit the one-time validation job. Instance + run id bound as literals;
        -- the job reads activity type back from the run log (run_validation).
        l_job := 'LWS_C2FO_VAL_' || REGEXP_REPLACE(p_instance_id, '[^A-Za-z0-9_]', '_');
        l_job := SUBSTR(l_job, 1, 116) || '_' || TO_CHAR(o_run_id);
        l_plsql := 'BEGIN LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_AWARD_PKG.run_validation('
                   || '''' || REPLACE(p_instance_id, '''', '''''') || ''', '
                   || TO_CHAR(o_run_id) || '); END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name    => l_job,
            job_type    => 'PLSQL_BLOCK',
            job_action  => l_plsql,
            start_date  => SYSTIMESTAMP,
            enabled     => TRUE,
            auto_drop   => TRUE,
            comments    => 'C2FO inbound validation (one-time, instance ' || p_instance_id || ')'
        );

        UPDATE lws_ap_c2fo_award_run_log
        SET    validate_job_name = l_job
        WHERE  run_id = o_run_id;
        COMMIT;

        o_job_name := l_job;
        o_message  := 'Submitted validation job ' || l_job || ' for ' || l_total
                      || ' rows; poll run_log run_id=' || o_run_id;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            IF o_run_id IS NOT NULL THEN
                UPDATE lws_ap_c2fo_award_run_log
                SET    end_time = SYSDATE, status = 'ERROR', error_message = o_message
                WHERE  run_id = o_run_id;
                COMMIT;
            END IF;
    END run_inbound;

    --====================================================================
    -- VALIDATION BODY  (runs inside the one-time validation job)
    --   Reads the run's persisted activity type, runs the validation core, and
    --   stamps counts + status on the run log for OIC to poll.
    --====================================================================
    PROCEDURE run_validation (
        p_instance_id   IN  VARCHAR2,
        p_run_id        IN  NUMBER
    ) IS
        l_activity   VARCHAR2(200);
        l_upd_pg     VARCHAR2(1);
        l_validated  NUMBER := 0;
        l_errored    NUMBER := 0;
        l_cms_reqd   NUMBER := 0;
        l_errmsg     VARCHAR2(4000);
    BEGIN
        SELECT activity_type, NVL(update_pay_group, 'N')
        INTO   l_activity, l_upd_pg
        FROM   lws_ap_c2fo_award_run_log
        WHERE  run_id = p_run_id;

        validate_batch(p_instance_id, l_activity, l_upd_pg, l_validated, l_errored);

        -- CMs the run must create = validated awards that will actually produce a CM.
        -- A zero-income award passes validation but produces no CM (it only gets a
        -- due-date update via #3), so filter income<>0 to count only real CMs.
        SELECT COUNT(*)
        INTO   l_cms_reqd
        FROM   lws_c2fo_award_data
        WHERE  instance_id   = p_instance_id
        AND    record_status = 'N'
        AND    stage         = C_STAGE_VALIDATED
        AND    NVL(income, 0) <> 0;

        UPDATE lws_ap_c2fo_award_run_log
        SET    validated_count    = l_validated,
               error_count        = l_errored,
               no_of_cms_required = l_cms_reqd,
               end_time           = SYSDATE,
               status             = 'SUCCESS'
        WHERE  run_id = p_run_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            l_errmsg := SUBSTR(SQLERRM, 1, 4000);
            UPDATE lws_ap_c2fo_award_run_log
            SET    end_time = SYSDATE, status = 'ERROR',
                   error_message = l_errmsg
            WHERE  run_id = p_run_id;
            COMMIT;
    END run_validation;

    --====================================================================
    -- FBDI CM SET  (OIC writes the file; GROUP_ID = batch id, BR#1)
    --   Emits one negative CREDIT line per validated award. The
    --   cm_invoice_num was already stamped at validation (BR#5); here we move
    --   the row to EP_INTERFACED and open the cursor.
    --====================================================================
    --====================================================================
    -- CHUNKING pre-step (see spec 1b). Stamps CHUNK_ID 1..N on this instance's
    -- validated, not-yet-interfaced rows so OIC loops the FBDI import one bounded
    -- chunk at a time. Only rows at record_status='N' AND stage=SUCCESSFULLY_VALIDATED
    -- are chunked (rows already flipped to INTERFACED by a prior build are left
    -- alone, so a resumed run re-chunks only the outstanding work). o_chunk_count is
    -- the OIC While-loop bound; 0 => nothing to import.
    --====================================================================
    PROCEDURE chunk_cm_awards (
        p_instance_id   IN  VARCHAR2,
        p_chunk_size    IN  NUMBER DEFAULT NULL,
        o_chunk_count   OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_size    NUMBER;
        l_merged  NUMBER;
    BEGIN
        o_status      := 'SUCCESS';
        o_chunk_count := 0;

        -- Resolve the chunk size: explicit arg > config knob > code default. Guard
        -- against a non-positive knob so the CEIL(.../size) below can never divide by
        -- zero or produce one giant chunk from a bad config value.
        l_size := NVL(p_chunk_size,
                      TO_NUMBER(cfg('INBOUND', 'CM_CHUNK_SIZE',
                                    TO_CHAR(C_CM_CHUNK_DEFAULT))));
        IF l_size IS NULL OR l_size <= 0 THEN
            l_size := C_CM_CHUNK_DEFAULT;
        END IF;

        -- APXIIMPT (Import Payables Invoices) runs per business unit AND per import
        -- source: the FBDI property file carries argument2 = ORG_ID and argument8 =
        -- Import Source, and the CM must be imported under the ORIGINAL invoice's
        -- source. So a single chunk must never span two BUs OR two sources. The client
        -- additionally requires a chunk to be vendor-specific, so a chunk must also
        -- never span two suppliers (vendor_id, the same column the CM FBDI build keys
        -- off). Sub-chunk WITHIN each (BU, source, vendor) group (ROW_NUMBER PARTITION
        -- BY erp_org_id, source_code, vendor_id), then collapse each distinct
        -- (org_id, source, vendor, sub-chunk) tuple into one running CHUNK_ID via
        -- DENSE_RANK so OIC keeps its simple While 1..N loop and every CHUNK_ID
        -- resolves to exactly one (BU, source, vendor) triple.
        MERGE INTO lws_c2fo_award_data t
        USING (
            -- A window function cannot be nested inside another window function's
            -- ORDER BY (ORA-30483), so compute the per-(BU,source,vendor) sub-chunk in
            -- the inner block, then DENSE_RANK over
            -- (erp_org_id, source_code, vendor_id, sub_chunk) in the outer.
            -- Chunk both CM-bound rows (SUCCESSFULLY_VALIDATED, income<>0) and the
            -- DD-only rows (EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED, income=0). DD-only
            -- rows never build a CM (the CM build view filters income<>0), but they
            -- still need a chunk_id so Integration #3 reads them in its While 1..N
            -- loop; grouping them into the same (BU, source, vendor) chunks means #3's
            -- loop bound is unchanged.
            SELECT invoice_id, instance_id,
                   DENSE_RANK() OVER (ORDER BY erp_org_id, source_code, vendor_id, sub_chunk) AS new_chunk
            FROM (
                SELECT invoice_id, instance_id, erp_org_id, source_code, vendor_id,
                       CEIL(ROW_NUMBER() OVER (PARTITION BY erp_org_id, source_code, vendor_id
                                               ORDER BY invoice_id) / l_size) AS sub_chunk
                FROM   lws_c2fo_award_data
                WHERE  instance_id   = p_instance_id
                AND    record_status = 'N'
                AND    stage         IN (C_STAGE_VALIDATED, C_STAGE_CM_VALIDATED)
            )
        ) c
        ON (t.instance_id = c.instance_id AND t.invoice_id = c.invoice_id)
        WHEN MATCHED THEN UPDATE SET
            t.chunk_id         = c.new_chunk,
            t.last_update_date = SYSTIMESTAMP;
        l_merged := SQL%ROWCOUNT;

        -- Count DISTINCT chunk ids assigned by THIS merge, not MAX(chunk_id): a stale
        -- chunk_id left on a row from a prior run (now filtered out) must not inflate
        -- the count OIC loops over. If this run chunked nothing, the count is 0.
        SELECT COUNT(DISTINCT chunk_id)
        INTO   o_chunk_count
        FROM   lws_c2fo_award_data
        WHERE  instance_id   = p_instance_id
        AND    record_status = 'N'
        AND    stage         IN (C_STAGE_VALIDATED, C_STAGE_CM_VALIDATED)
        AND    chunk_id IS NOT NULL;

        COMMIT;
        o_message := 'Chunked ' || l_merged || ' award(s) for instance '
                     || p_instance_id || ' into ' || o_chunk_count
                     || ' chunk(s) of ' || l_size;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status      := 'ERROR';
            o_chunk_count := 0;
            o_message     := SUBSTR(SQLERRM, 1, 4000);
    END chunk_cm_awards;

    --====================================================================
    -- PER-CHUNK IDENTITY (see spec 1c). A chunk = exactly one (org_id, source,
    -- vendor_id) triple, so every row in it shares one supplier number. Return
    -- that number (+ BU + source + vendor_id) so OIC can query Fusion for THIS
    -- chunk's created CMs by SupplierNumber instead of the coarse creation-date
    -- proxy. MAX() collapses the chunk's (identical) values to one scalar and is
    -- NULL-safe: a chunk id with no rows yields all-NULL -> o_status 'EMPTY'.
    -- ERP_SUPPLIER_NUMBER is returned verbatim (outbound value; no zero padding).
    --
    -- Filter matches chunk_cm_awards EXACTLY (record_status='N' AND stage IN
    -- VALIDATED, CM_VALIDATED), so the getter sees the same population the chunker
    -- assigned chunk_ids to. Call it at the TOP of OIC's chunk loop, BEFORE
    -- build_fbdi_cm_set flips income<>0 rows to INTERFACED - at that point the rows
    -- are still where the chunker left them. Read-only; no COMMIT.
    --====================================================================
    PROCEDURE get_chunk_identity (
        p_instance_id     IN  VARCHAR2,
        p_chunk_id        IN  NUMBER,
        o_supplier_number OUT VARCHAR2,
        o_vendor_id       OUT NUMBER,
        o_org_id          OUT NUMBER,
        o_source_code     OUT VARCHAR2,
        o_status          OUT VARCHAR2,
        o_message         OUT VARCHAR2
    ) IS
        l_rows NUMBER;
    BEGIN
        SELECT COUNT(*),
               MAX(erp_supplier_number),
               MAX(vendor_id),
               MAX(erp_org_id),
               MAX(source_code)
        INTO   l_rows,
               o_supplier_number, o_vendor_id, o_org_id, o_source_code
        FROM   lws_c2fo_award_data
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id
        AND    record_status = 'N'
        AND    stage IN (C_STAGE_VALIDATED, C_STAGE_CM_VALIDATED);

        IF l_rows = 0 THEN
            o_status  := 'EMPTY';
            o_message := 'No rows for instance ' || p_instance_id
                         || ' chunk ' || p_chunk_id;
        ELSE
            o_status  := 'SUCCESS';
            o_message := 'Chunk ' || p_chunk_id || ' supplier_number='
                         || NVL(o_supplier_number, 'null')
                         || ' org_id=' || NVL(TO_CHAR(o_org_id), 'null')
                         || ' source=' || NVL(o_source_code, 'null')
                         || ' (' || l_rows || ' row(s))';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END get_chunk_identity;

    PROCEDURE build_fbdi_cm_set (
        p_instance_id   IN  VARCHAR2,
        p_run_id        IN  NUMBER,
        p_source_code   IN  VARCHAR2 DEFAULT NULL,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_cursor        OUT SYS_REFCURSOR
    ) IS
        l_source_code    VARCHAR2(30);
        l_pay_group      VARCHAR2(30);
        l_upd_pg         VARCHAR2(1);
        l_payment_method VARCHAR2(100);
    BEGIN
        IF NOT load_config THEN
            RAISE_APPLICATION_ERROR(-20010, 'Could not load config');
        END IF;

        -- Runtime params come from OIC (persisted on the run log at run_inbound time).
        -- Prefer the explicit p_source_code; else the persisted value. Pay group is
        -- carried on the CM header only when the pay-group update is on (BR#16); the
        -- payment method comes from the OIC CM_PAYMENT_METHOD lookup (BR#16).
        SELECT NVL(p_source_code, source_code), pay_group,
               NVL(update_pay_group, 'N'), cm_payment_method
        INTO   l_source_code, l_pay_group, l_upd_pg, l_payment_method
        FROM   lws_ap_c2fo_award_run_log
        WHERE  run_id = p_run_id;

        -- When the pay-group update is off, do not stamp a pay group on the CM either.
        IF l_upd_pg <> 'Y' THEN
            l_pay_group := NULL;
        END IF;

        UPDATE lws_c2fo_award_data
        SET    stage            = C_STAGE_INTERFACED,
               last_update_date = SYSTIMESTAMP
        WHERE  instance_id = p_instance_id
        AND    record_status = 'N'
        AND    stage = C_STAGE_VALIDATED
        AND    (p_chunk_id IS NULL OR chunk_id = p_chunk_id);
        COMMIT;

        -- One row per FBDI CM. Amounts are negative (credit). GROUP_ID lets OIC
        -- key the whole import set to this run. Distribution grain = single
        -- primary expense account (Open Issue #5). pay_group may be null => FBDI
        -- leaves the CM's pay group at its default.
        -- The CM header carries ALL populated original-invoice header DFF segments
        -- (ATTRIBUTE_CATEGORY + ATTRIBUTE1..15), copied verbatim from the mirror
        -- invoice via the join on the resolved erp_invoice_id (BR#17). A null
        -- segment stays null. Invoice date = pay_date (ISO string) reformatted for FBDI.
        OPEN o_cursor FOR
            SELECT p_instance_id                    AS group_id,
                   l_source_code                    AS invoice_source,
                   s.cm_invoice_num                 AS invoice_num,
                   'CREDIT'                          AS invoice_type_lookup_code,
                   s.erp_org_id                     AS org_id,
                   s.vendor_id                      AS vendor_id,
                   s.erp_vendor_site_id             AS vendor_site_id,
                   -s.cm_invoice_amount             AS invoice_amount,
                   s.currency                       AS invoice_currency_code,
                   TO_CHAR(TO_DATE(s.pay_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'),
                           'YYYY/MM/DD')            AS invoice_date,
                   l_pay_group                      AS pay_group,
                   l_payment_method                 AS payment_method_code,
                   s.terms_id                       AS terms_id,
                   -- original-invoice header DFFs (BR#17), copied 1:1 onto the CM
                   aia.attribute_category           AS attribute_category,
                   aia.attribute1                   AS attribute1,
                   aia.attribute2                   AS attribute2,
                   aia.attribute3                   AS attribute3,
                   aia.attribute4                   AS attribute4,
                   aia.attribute5                   AS attribute5,
                   aia.attribute6                   AS attribute6,
                   aia.attribute7                   AS attribute7,
                   aia.attribute8                   AS attribute8,
                   aia.attribute9                   AS attribute9,
                   aia.attribute10                  AS attribute10,
                   aia.attribute11                  AS attribute11,
                   aia.attribute12                  AS attribute12,
                   aia.attribute13                  AS attribute13,
                   aia.attribute14                  AS attribute14,
                   aia.attribute15                  AS attribute15,
                   -- single line: negative amount, expense account
                   1                                AS line_number,
                   'ITEM'                            AS line_type_lookup_code,
                   -s.cm_invoice_line_amount        AS line_amount,
                   s.expense_ccid                   AS dist_code_combination_id,
                   s.liability_ccid                 AS liability_ccid,
                   s.invoice_id                     AS award_key
            FROM   lws_c2fo_award_data s
            JOIN   ap_invoices_all aia ON aia.invoice_id = s.erp_invoice_id
            WHERE  s.instance_id = p_instance_id
            AND    s.record_status = 'N'
            AND    s.stage = C_STAGE_INTERFACED
            AND    (p_chunk_id IS NULL OR s.chunk_id = p_chunk_id)
            ORDER  BY s.invoice_id;
    END build_fbdi_cm_set;

    --====================================================================
    -- FLIP a chunk to EP_INTERFACED (see spec 2b). OIC calls this AFTER the
    -- chunk's FBDI import is confirmed, so a half-built chunk stays VALIDATED and
    -- is rebuilt on a resumed run. Only VALIDATED rows move (idempotent re-call).
    --====================================================================
    PROCEDURE flip_chunk_to_interfaced (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_flipped       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_flipped := 0;

        UPDATE lws_c2fo_award_data
        SET    stage            = C_STAGE_INTERFACED,
               last_update_date = SYSTIMESTAMP
        WHERE  instance_id   = p_instance_id
        AND    record_status = 'N'
        AND    stage         = C_STAGE_VALIDATED
        AND    (p_chunk_id IS NULL OR chunk_id = p_chunk_id);
        o_flipped := SQL%ROWCOUNT;
        COMMIT;

        o_message := 'Flipped ' || o_flipped || ' award(s) to '
                     || C_STAGE_INTERFACED || ' for instance ' || p_instance_id
                     || CASE WHEN p_chunk_id IS NULL THEN ' (all chunks)'
                             ELSE ' chunk ' || p_chunk_id END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_flipped := 0;
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END flip_chunk_to_interfaced;

    --====================================================================
    -- DUE-DATE-SENT FLIP  (Integration #3 calls after a chunk's upsert succeeds)
    --   Advances the chunk's created+validated CM rows
    --   (EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED) to EP_DUE_DATE_UPSERT_SENT so a
    --   re-read of LWS_C2FO_DD_UPSERT_V for that chunk is a no-op. Not terminal -
    --   annotate_duedate_result_bulk stamps the final Y/E from the DD verdicts.
    --   Only CM-good rows move (idempotent re-call). p_chunk_id NULL => whole run.
    --====================================================================
    PROCEDURE flip_chunk_duedates_sent (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER DEFAULT NULL,
        o_flipped       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_flipped := 0;

        UPDATE lws_c2fo_award_data
        SET    stage            = C_STAGE_DD_SENT,
               last_update_date = SYSTIMESTAMP
        WHERE  instance_id   = p_instance_id
        AND    record_status = 'N'
        AND    cm_status     = 'OK'
        AND    stage         = C_STAGE_CM_VALIDATED
        AND    (p_chunk_id IS NULL OR chunk_id = p_chunk_id);
        o_flipped := SQL%ROWCOUNT;
        COMMIT;

        o_message := 'Flipped ' || o_flipped || ' award(s) to '
                     || C_STAGE_DD_SENT || ' for instance ' || p_instance_id
                     || CASE WHEN p_chunk_id IS NULL THEN ' (all chunks)'
                             ELSE ' chunk ' || p_chunk_id END;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_flipped := 0;
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END flip_chunk_duedates_sent;

    --====================================================================
    -- CM RESULT WRITE-BACK  (OIC calls per CM after import + Validate job)
    --====================================================================
    PROCEDURE annotate_cm_result (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_cm_invoice_id IN  NUMBER,
        p_cm_ok         IN  VARCHAR2,
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,
        p_error_msg     IN  VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        IF p_cm_ok = 'Y' THEN
            -- Single-call path = combined create+validate confirmation, so 'Y' lands at
            -- the fully-validated stage. If it is called after the create read-back has
            -- already set CM_CREATED, that still resolves to CM_VALIDATED here.
            UPDATE lws_c2fo_award_data
            SET    cm_invoice_id    = p_cm_invoice_id,
                   cm_status        = 'OK',
                   stage            = C_STAGE_CM_VALIDATED,
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id = p_instance_id
            AND    invoice_id  = p_invoice_id
            AND    record_status = 'N';
        ELSE
            -- CM half failed: terminal, NO due-date PATCH will be issued (BR#11b).
            UPDATE lws_c2fo_award_data
            SET    cm_invoice_id    = p_cm_invoice_id,
                   cm_status        = 'FAILED',
                   record_status    = 'E',
                   stage            = NVL(p_error_stage, C_ERR_IMPORT),
                   error_code       = NVL(p_error_stage, C_ERR_IMPORT),
                   error_message    = SUBSTR(p_error_msg, 1, 2000),
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id = p_instance_id
            AND    invoice_id  = p_invoice_id
            AND    record_status = 'N';
        END IF;
        COMMIT;
    END annotate_cm_result;

    --====================================================================
    -- BULK CM RESULT WRITE-BACK  (the volume path, 300-500K)
    --   Consumes every unprocessed 'CM' verdict for the batch from
    --   LWS_AP_C2FO_VERDICT_LOAD in ONE set-based MERGE. Serves BOTH CM read-backs:
    --   STATUS='Y' promotes by the award's current stage (just-created -> CM_CREATED;
    --   already CM_CREATED -> CM_VALIDATED); STATUS='N' -> terminal 'E' at the reported
    --   error_stage (import on the create leg, C_ERR_CM_REVAL on the validate leg;
    --   defaults to import). Only rows still at record_status 'N' are touched. The load
    --   rows consumed are marked PROCESSED_FLAG='Y' so a re-run is a no-op.
    --====================================================================
    PROCEDURE annotate_cm_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        -- Collapse to ONE source row per award: an award must map to a single target
        -- rowid or the MERGE raises ORA-30926. A failure ('N') always wins over 'Y' so
        -- a real failure is never masked by a stale success; ties break on the newest
        -- verdict. Every message for the award is concatenated so no detail is lost.
        MERGE INTO lws_c2fo_award_data s
        USING (
            SELECT instance_id, invoice_id, status, cm_invoice_id, error_stage, message
            FROM (
                SELECT instance_id, invoice_id, status, cm_invoice_id, error_stage,
                       SUBSTR(LISTAGG(message, ' | ')
                              WITHIN GROUP (ORDER BY verdict_row_id)
                              OVER (PARTITION BY instance_id, invoice_id),
                              1, 2000) AS message,
                       ROW_NUMBER() OVER (
                           PARTITION BY instance_id, invoice_id
                           ORDER BY CASE WHEN status = 'N' THEN 0 ELSE 1 END,
                                    verdict_row_id DESC
                       ) AS rn
                FROM   lws_ap_c2fo_verdict_load
                WHERE  instance_id  = p_instance_id
                AND    verdict_kind = 'CM'
                AND    processed_flag = 'N'
            )
            WHERE rn = 1
        ) v
        ON (s.instance_id = v.instance_id AND s.invoice_id = v.invoice_id)
        WHEN MATCHED THEN UPDATE SET
            s.cm_invoice_id     = v.cm_invoice_id,
            s.cm_status         = CASE WHEN v.status = 'Y' THEN 'OK' ELSE 'FAILED' END,
            s.record_status     = CASE WHEN v.status = 'Y' THEN 'N'  ELSE 'E' END,
            -- Promote by the award's CURRENT stage so one shared write-back serves both
            -- CM read-backs: a 'Y' on a freshly-created CM (stage VALIDATED) advances to
            -- CM_CREATED; a 'Y' on an already-created CM (stage CM_CREATED, from the
            -- validate read-back) advances to CM_VALIDATED. income=0 rows are already
            -- CM_VALIDATED at validate_batch and never pass through here.
            s.stage             = CASE
                                       WHEN v.status = 'Y' AND s.stage = C_STAGE_CM_CREATED
                                            THEN C_STAGE_CM_VALIDATED
                                       WHEN v.status = 'Y'
                                            THEN C_STAGE_CM_CREATED
                                       ELSE NVL(v.error_stage, C_ERR_IMPORT) END,
            s.error_code        = CASE WHEN v.status = 'Y'
                                       THEN NULL ELSE NVL(v.error_stage, C_ERR_IMPORT) END,
            s.error_message     = CASE WHEN v.status = 'Y'
                                       THEN NULL ELSE SUBSTR(v.message, 1, 2000) END,
            s.last_update_date  = SYSTIMESTAMP
        WHERE s.record_status = 'N';   -- only un-terminated awards, matches per-award guard

        o_applied := SQL%ROWCOUNT;

        UPDATE lws_ap_c2fo_verdict_load
        SET    processed_flag = 'Y'
        WHERE  instance_id  = p_instance_id
        AND    verdict_kind = 'CM'
        AND    processed_flag = 'N';

        COMMIT;
        o_message := 'Applied ' || o_applied || ' CM verdicts for instance ' || p_instance_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_cm_result_bulk;

    --====================================================================
    -- annotate_cm_result_chunk
    --   Per-chunk twin of annotate_cm_result_bulk. Scopes the MERGE and the
    --   PROCESSED_FLAG update to ONE chunk so a per-chunk call stamps only that
    --   chunk's awards (chunk_id lives on lws_c2fo_award_data, so the verdict rows
    --   are restricted to the chunk by joining back to the award table). Every other
    --   detail (state stamped, record_status='N' guard, PROCESSED_FLAG='Y' no-op) is
    --   identical to the bulk proc.
    --====================================================================
    PROCEDURE annotate_cm_result_chunk (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        -- Collapse to ONE source row per award: an award must map to a single target
        -- rowid or the MERGE raises ORA-30926. A failure ('N') always wins over 'Y' so
        -- a real failure is never masked by a stale success; ties break on the newest
        -- verdict. Every message for the award is concatenated so no detail is lost.
        MERGE INTO lws_c2fo_award_data s
        USING (
            SELECT instance_id, invoice_id, status, cm_invoice_id, error_stage, message
            FROM (
                SELECT vl.instance_id, vl.invoice_id, vl.status,
                       vl.cm_invoice_id, vl.error_stage,
                       SUBSTR(LISTAGG(vl.message, ' | ')
                              WITHIN GROUP (ORDER BY vl.verdict_row_id)
                              OVER (PARTITION BY vl.instance_id, vl.invoice_id),
                              1, 2000) AS message,
                       ROW_NUMBER() OVER (
                           PARTITION BY vl.instance_id, vl.invoice_id
                           ORDER BY CASE WHEN vl.status = 'N' THEN 0 ELSE 1 END,
                                    vl.verdict_row_id DESC
                       ) AS rn
                FROM   lws_ap_c2fo_verdict_load vl
                JOIN   lws_c2fo_award_data a
                       ON  a.instance_id = vl.instance_id
                       AND a.invoice_id  = vl.invoice_id
                WHERE  vl.instance_id   = p_instance_id
                AND    vl.verdict_kind  = 'CM'
                AND    vl.processed_flag = 'N'
                AND    a.chunk_id       = p_chunk_id
            )
            WHERE rn = 1
        ) v
        ON (s.instance_id = v.instance_id AND s.invoice_id = v.invoice_id)
        WHEN MATCHED THEN UPDATE SET
            s.cm_invoice_id     = v.cm_invoice_id,
            s.cm_status         = CASE WHEN v.status = 'Y' THEN 'OK' ELSE 'FAILED' END,
            s.record_status     = CASE WHEN v.status = 'Y' THEN 'N'  ELSE 'E' END,
            -- Promote by the award's CURRENT stage so one shared write-back serves both
            -- CM read-backs: a 'Y' on a freshly-created CM (stage VALIDATED) advances to
            -- CM_CREATED; a 'Y' on an already-created CM (stage CM_CREATED, from the
            -- validate read-back) advances to CM_VALIDATED. income=0 rows are already
            -- CM_VALIDATED at validate_batch and never pass through here.
            s.stage             = CASE
                                       WHEN v.status = 'Y' AND s.stage = C_STAGE_CM_CREATED
                                            THEN C_STAGE_CM_VALIDATED
                                       WHEN v.status = 'Y'
                                            THEN C_STAGE_CM_CREATED
                                       ELSE NVL(v.error_stage, C_ERR_IMPORT) END,
            s.error_code        = CASE WHEN v.status = 'Y'
                                       THEN NULL ELSE NVL(v.error_stage, C_ERR_IMPORT) END,
            s.error_message     = CASE WHEN v.status = 'Y'
                                       THEN NULL ELSE SUBSTR(v.message, 1, 2000) END,
            s.last_update_date  = SYSTIMESTAMP
        WHERE s.record_status = 'N';

        o_applied := SQL%ROWCOUNT;

        UPDATE lws_ap_c2fo_verdict_load vl
        SET    vl.processed_flag = 'Y'
        WHERE  vl.instance_id   = p_instance_id
        AND    vl.verdict_kind  = 'CM'
        AND    vl.processed_flag = 'N'
        AND    EXISTS (
                   SELECT 1
                   FROM   lws_c2fo_award_data a
                   WHERE  a.instance_id = vl.instance_id
                   AND    a.invoice_id  = vl.invoice_id
                   AND    a.chunk_id    = p_chunk_id
               );

        COMMIT;
        o_message := 'Applied ' || o_applied || ' CM verdicts for instance '
                     || p_instance_id || ' chunk ' || p_chunk_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_cm_result_chunk;

    --====================================================================
    -- CHUNK CM VERDICT INSERT  (happy path = one call per chunk)
    --   Inserts one 'CM' verdict per award in the chunk in a single set-based
    --   statement. OIC calls with p_status='Y' when the count check confirms the
    --   whole chunk was created (no per-record work), or p_status='N' from the
    --   import/validate failure + timeout branches to terminally fail the chunk.
    --   RUN_ID is audit-only: the latest run for the instance. VERDICT_ROW_ID is
    --   defaulted from the sequence on the table, so it is not set here.
    --====================================================================
    PROCEDURE insert_chunk_cm_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        p_status        IN  VARCHAR2,
        p_error_stage   IN  VARCHAR2 DEFAULT NULL,
        p_message       IN  VARCHAR2 DEFAULT NULL,
        o_inserted      OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_run_id NUMBER;
    BEGIN
        o_status   := 'SUCCESS';
        o_inserted := 0;

        IF p_status NOT IN ('Y', 'N') THEN
            o_status  := 'ERROR';
            o_message := 'p_status must be Y or N (got ' || p_status || ')';
            RETURN;
        END IF;

        BEGIN
            SELECT MAX(run_id) INTO l_run_id
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN l_run_id := NULL;
        END;

        -- One CM verdict per award: skip awards that already carry an unprocessed CM
        -- verdict (a prior happy-path 'Y', a diff row, or a re-invoked fail call).
        -- Stacking a second row would make the write-back MERGE map two source rows to
        -- one target award and raise ORA-30926.
        INSERT INTO lws_ap_c2fo_verdict_load (
            instance_id, run_id, invoice_id, verdict_kind, status,
            error_stage, message, processed_flag
        )
        SELECT d.instance_id, l_run_id, d.invoice_id, 'CM', p_status,
               CASE WHEN p_status = 'N' THEN NVL(p_error_stage, C_ERR_IMPORT) END,
               p_message, 'N'
        FROM   lws_c2fo_award_data d
        WHERE  d.instance_id = p_instance_id
        AND    d.chunk_id    = p_chunk_id
        AND    d.record_status = 'N'
        AND    NVL(d.income, 0) <> 0  -- zero income awards are already at validated and need to stay there to be due date updated
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   lws_ap_c2fo_verdict_load vl
                   WHERE  vl.instance_id    = d.instance_id
                   AND    vl.invoice_id     = d.invoice_id
                   AND    vl.verdict_kind   = 'CM'
                   AND    vl.processed_flag = 'N'
               );

        o_inserted := SQL%ROWCOUNT;
        COMMIT;
        o_message := 'Inserted ' || o_inserted || ' CM verdicts (' || p_status
                     || ') for instance ' || p_instance_id || ' chunk ' || p_chunk_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END insert_chunk_cm_verdicts;

    --====================================================================
    -- PER-ROW CM-CREATION DIFF  (shortfall path, paged)
    --   OIC has paged the Fusion "created CMs" list into LWS_AP_C2FO_CM_CREATED_STG
    --   for this chunk. LEFT JOIN the chunk's sent awards to that staging on
    --   cm_invoice_num = InvoiceNumber: a match -> 'Y' verdict + CM_INVOICE_ID; no
    --   match -> 'N' verdict at C_ERR_IMPORT. One 'CM' verdict per award, consumed by
    --   annotate_cm_result_bulk after the loop. The trailing DELETE clears this
    --   chunk's staging rows (idempotent re-run).
    --====================================================================
    PROCEDURE diff_chunk_cm_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_created       OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_run_id NUMBER;
    BEGIN
        o_status  := 'SUCCESS';
        o_created := 0;
        o_missing := 0;

        BEGIN
            SELECT MAX(run_id) INTO l_run_id
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN l_run_id := NULL;
        END;

        INSERT INTO lws_ap_c2fo_verdict_load (
            instance_id, run_id, invoice_id, verdict_kind, status,
            cm_invoice_id, error_stage, message, processed_flag
        )
        SELECT a.instance_id, l_run_id, a.invoice_id, 'CM',
               CASE WHEN c.invoice_number IS NOT NULL THEN 'Y' ELSE 'N' END,
               c.cm_invoice_id,
               CASE WHEN c.invoice_number IS NULL THEN C_ERR_IMPORT END,
               CASE WHEN c.invoice_number IS NULL
                    THEN 'CM not found in Fusion after import (per-row diff)' END,
               'N'
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_cm_created_stg c
               ON  c.instance_id    = a.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = a.cm_invoice_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.stage         = C_STAGE_VALIDATED;

        SELECT COUNT(CASE WHEN c.invoice_number IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN c.invoice_number IS NULL     THEN 1 END)
        INTO   o_created, o_missing
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_cm_created_stg c
               ON  c.instance_id    = a.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = a.cm_invoice_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.stage         = C_STAGE_VALIDATED;

        DELETE FROM lws_ap_c2fo_cm_created_stg
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
    END diff_chunk_cm_verdicts;

    --====================================================================
    -- PER-ROW CM-VALIDATION DIFF  (validate shortfall path, paged)
    --   Twin of diff_chunk_cm_verdicts for the VALIDATE leg. OIC has paged the Fusion
    --   "validated CMs" list into LWS_AP_C2FO_CM_VALIDATED_STG for this chunk. LEFT JOIN
    --   the chunk's CREATED-but-unvalidated awards (record_status='N', cm_status='OK',
    --   stage=C_STAGE_CM_CREATED) to that staging on cm_invoice_num = InvoiceNumber: a
    --   match -> 'Y' verdict (CM validated) and the award is promoted to
    --   C_STAGE_CM_VALIDATED; no match -> 'N' verdict at C_ERR_CM_REVAL (the CM was
    --   created but did not validate). One 'CM' verdict per award, consumed by
    --   annotate_cm_result_chunk/_bulk which stamps the N rows record_status='E'/
    --   cm_status='FAILED' and promotes the Y rows CM_CREATED -> CM_VALIDATED. The
    --   trailing DELETE clears this chunk's staging rows (idempotent re-run). Only the
    --   genuinely-unvalidated row(s) carry 'N', so compensation (CM offset) targets just
    --   the bad CM, not the whole chunk.
    --====================================================================
    PROCEDURE diff_chunk_cm_validate_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_validated     OUT NUMBER,
        o_missing       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_run_id NUMBER;
    BEGIN
        o_status    := 'SUCCESS';
        o_validated := 0;
        o_missing   := 0;

        BEGIN
            SELECT MAX(run_id) INTO l_run_id
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN l_run_id := NULL;
        END;

        INSERT INTO lws_ap_c2fo_verdict_load (
            instance_id, run_id, invoice_id, verdict_kind, status,
            cm_invoice_id, error_stage, message, processed_flag
        )
        SELECT a.instance_id, l_run_id, a.invoice_id, 'CM',
               CASE WHEN c.invoice_number IS NOT NULL THEN 'Y' ELSE 'N' END,
               a.cm_invoice_id,
               CASE WHEN c.invoice_number IS NULL THEN C_ERR_CM_REVAL END,
               CASE WHEN c.invoice_number IS NULL
                    THEN 'CM created but not validated in Fusion (per-row diff)' END,
               'N'
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_cm_validated_stg c
               ON  c.instance_id    = a.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = a.cm_invoice_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage         = C_STAGE_CM_CREATED;

        SELECT COUNT(CASE WHEN c.invoice_number IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN c.invoice_number IS NULL     THEN 1 END)
        INTO   o_validated, o_missing
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_cm_validated_stg c
               ON  c.instance_id    = a.instance_id
               AND c.chunk_id       = p_chunk_id
               AND c.invoice_number = a.cm_invoice_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage         = C_STAGE_CM_CREATED;

        DELETE FROM lws_ap_c2fo_cm_validated_stg
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
    END diff_chunk_cm_validate_verdicts;

    --====================================================================
    -- PER-ROW DUE-DATE VERDICTS  (diff intended vs applied due dates)
    --   The due-date batch upsert is partial-success (good installments apply, bad
    --   ones do not) and the per-part response is hard to read in the OIC mapper. So
    --   OIC re-queries Fusion for the chunk's installment due dates and stages them in
    --   LWS_AP_C2FO_DD_APPLIED_STG; this proc compares each DD-sent award's INTENDED
    --   pay_date against the APPLIED_DUE_DATE Fusion returned. Match (same calendar
    --   day) -> DD verdict 'Y'. Mismatch or no staged row -> 'N', comp_status left
    --   NULL (the OIC cancel step stamps COMPENSATED/FAILED on the N rows before
    --   annotate_duedate_result_bulk consumes them). One 'DD' verdict per award.
    --   Filters both C_STAGE_CM_VALIDATED and C_STAGE_DD_SENT so it is correct whether
    --   or not flip_chunk_duedates_sent has already run. Clears the chunk's staging
    --   rows. Mirrors diff_chunk_cm_verdicts.
    --====================================================================
    PROCEDURE diff_chunk_dd_verdicts (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_failed        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_run_id NUMBER;
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;
        o_failed  := 0;

        BEGIN
            SELECT MAX(run_id) INTO l_run_id
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN l_run_id := NULL;
        END;

        INSERT INTO lws_ap_c2fo_verdict_load (
            instance_id, run_id, invoice_id, verdict_kind, status,
            error_stage, message, processed_flag
        )
        SELECT a.instance_id, l_run_id, a.invoice_id, 'DD',
               CASE WHEN d.invoice_id IS NOT NULL THEN 'Y' ELSE 'N' END,
               CASE WHEN d.invoice_id IS NULL THEN C_ERR_ORIG_DD END,
               CASE WHEN d.invoice_id IS NULL
                    THEN 'Due date not applied in Fusion after upsert (per-row diff)' END,
               'N'
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_dd_applied_stg d
               ON  d.instance_id        = a.instance_id
               AND d.chunk_id           = p_chunk_id
               AND d.invoice_id         = a.erp_invoice_id
               AND d.installment_number = a.payment_num
               AND TRUNC(TO_DATE(d.applied_due_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'))
                 = TRUNC(TO_DATE(a.pay_date         DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'))
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage        IN (C_STAGE_CM_VALIDATED, C_STAGE_DD_SENT);

        SELECT COUNT(CASE WHEN d.invoice_id IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN d.invoice_id IS NULL     THEN 1 END)
        INTO   o_applied, o_failed
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_dd_applied_stg d
               ON  d.instance_id        = a.instance_id
               AND d.chunk_id           = p_chunk_id
               AND d.invoice_id         = a.erp_invoice_id
               AND d.installment_number = a.payment_num
               AND TRUNC(TO_DATE(d.applied_due_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'))
                 = TRUNC(TO_DATE(a.pay_date         DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'))
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage        IN (C_STAGE_CM_VALIDATED, C_STAGE_DD_SENT);

        DELETE FROM lws_ap_c2fo_dd_applied_stg
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id;

        COMMIT;
        o_message := 'DD diff complete for instance ' || p_instance_id || ' chunk '
                     || p_chunk_id || ': ' || o_applied || ' applied, '
                     || o_failed || ' failed';
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END diff_chunk_dd_verdicts;

    --====================================================================
    -- MARK DD FAILURES  (response-driven path, the current #3 flow)
    --   OIC has bulk-inserted the FAILED Fusion InvoiceIds (adf.batch parts with
    --   httpStatus >= 400) into LWS_AP_C2FO_DD_APPLIED_STG for this chunk. Here a
    --   staged (erp_invoice_id, payment_num) match means the installment FAILED -> 'N';
    --   every other DD-sent award in the chunk applied -> 'Y'. Writes one 'DD' verdict
    --   per award, then clears the chunk's staging rows. Guarded against stacking a
    --   second unprocessed DD verdict so a re-run is idempotent.
    --====================================================================
    PROCEDURE mark_dd_failures (
        p_instance_id   IN  VARCHAR2,
        p_chunk_id      IN  NUMBER,
        o_applied       OUT NUMBER,
        o_failed        OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_run_id NUMBER;
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;
        o_failed  := 0;

        BEGIN
            SELECT MAX(run_id) INTO l_run_id
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN l_run_id := NULL;
        END;

        INSERT INTO lws_ap_c2fo_verdict_load (
            instance_id, run_id, invoice_id, verdict_kind, status,
            error_stage, message, processed_flag
        )
        SELECT a.instance_id, l_run_id, a.invoice_id, 'DD',
               CASE WHEN d.invoice_id IS NOT NULL THEN 'N' ELSE 'Y' END,
               CASE WHEN d.invoice_id IS NOT NULL THEN C_ERR_ORIG_DD END,
               CASE WHEN d.invoice_id IS NOT NULL
                    THEN 'Due date upsert rejected by Fusion (adf.batch part httpStatus >= 400)' END,
               'N'
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_dd_applied_stg d
               ON  d.instance_id        = a.instance_id
               AND d.chunk_id           = p_chunk_id
               AND d.invoice_id         = a.erp_invoice_id
               AND d.installment_number = a.payment_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage        IN (C_STAGE_CM_VALIDATED, C_STAGE_DD_SENT)
        AND    NOT EXISTS (
                   SELECT 1 FROM lws_ap_c2fo_verdict_load v
                   WHERE  v.instance_id    = a.instance_id
                   AND    v.invoice_id     = a.invoice_id
                   AND    v.verdict_kind   = 'DD'
                   AND    v.processed_flag = 'N');

        SELECT COUNT(CASE WHEN d.invoice_id IS NULL     THEN 1 END),
               COUNT(CASE WHEN d.invoice_id IS NOT NULL THEN 1 END)
        INTO   o_applied, o_failed
        FROM   lws_c2fo_award_data a
        LEFT JOIN lws_ap_c2fo_dd_applied_stg d
               ON  d.instance_id        = a.instance_id
               AND d.chunk_id           = p_chunk_id
               AND d.invoice_id         = a.erp_invoice_id
               AND d.installment_number = a.payment_num
        WHERE  a.instance_id   = p_instance_id
        AND    a.chunk_id      = p_chunk_id
        AND    a.record_status = 'N'
        AND    a.cm_status     = 'OK'
        AND    a.stage        IN (C_STAGE_CM_VALIDATED, C_STAGE_DD_SENT);

        DELETE FROM lws_ap_c2fo_dd_applied_stg
        WHERE  instance_id = p_instance_id
        AND    chunk_id    = p_chunk_id;

        COMMIT;
        o_message := 'DD mark complete for instance ' || p_instance_id || ' chunk '
                     || p_chunk_id || ': ' || o_applied || ' applied, '
                     || o_failed || ' failed';
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END mark_dd_failures;

    --====================================================================
    -- STAMP DD CANCEL OUTCOME  (per failed award, from the OIC cancel loop)
    --   Sets COMP_STATUS on the award's unconsumed DD 'N' verdict so
    --   annotate_duedate_result_bulk lands it: 'COMPENSATED' -> C_ERR_ORIG_DD
    --   (CM cancelled, invoice back at original due date), 'FAILED' ->
    --   C_ERR_COMPENSATION (CM stranded, needs a human). No COMMIT of other work.
    --====================================================================
    PROCEDURE stamp_dd_comp_status (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_comp_status   IN  VARCHAR2
    ) IS
    BEGIN
        UPDATE lws_ap_c2fo_verdict_load
        SET    comp_status = p_comp_status
        WHERE  instance_id    = p_instance_id
        AND    invoice_id     = p_invoice_id
        AND    verdict_kind   = 'DD'
        AND    status         = 'N'
        AND    processed_flag = 'N';
        COMMIT;
    END stamp_dd_comp_status;

    --====================================================================
    -- STAMP CM-OFFSET OUTCOME  (per failed award, from the shared offset child)
    --   Sets COMP_STATUS on the award's unconsumed FAILED verdict so the matching
    --   annotate_*_result_bulk lands it: 'COMPENSATED' -> C_ERR_ORIG_DD (CM offset
    --   by a new positive STANDARD invoice), 'FAILED' -> C_ERR_COMPENSATION (CM
    --   stranded, needs a human). Stamps EITHER verdict kind ('CM' from #2's
    --   validation-fail, 'DD' from #3's upsert-fail) - the caller only knows the
    --   award key. No COMMIT of other work.
    --====================================================================
    PROCEDURE update_offset_status (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_offset_status IN  VARCHAR2
    ) IS
    BEGIN
        -- 1. Stamp the offset outcome on the award's unconsumed failure verdict.
        UPDATE lws_ap_c2fo_verdict_load
        SET    comp_status = p_offset_status
        WHERE  instance_id    = p_instance_id
        AND    invoice_id     = p_invoice_id
        AND    verdict_kind   IN ('CM', 'DD')
        AND    status         = 'N'
        AND    processed_flag = 'N';

        -- 2. Close the award here (not in annotate). annotate_duedate_result_bulk now
        --    deliberately SKIPS CM-bearing DD failures while comp_status IS NULL, so the
        --    offset step is what finalises them: COMPENSATED -> C_ERR_ORIG_DD (CM backed
        --    out, invoice at original due date), FAILED -> C_ERR_COMPENSATION (CM stranded,
        --    needs a human). Mirrors annotate's failure branch.
        UPDATE lws_c2fo_award_data s
        SET    s.record_status    = 'E',
               s.dd_status         = 'FAILED',
               s.stage             = CASE WHEN p_offset_status = 'COMPENSATED'
                                          THEN C_ERR_ORIG_DD ELSE C_ERR_COMPENSATION END,
               s.error_code        = CASE WHEN p_offset_status = 'COMPENSATED'
                                          THEN C_ERR_ORIG_DD ELSE C_ERR_COMPENSATION END,
               s.error_message     = CASE WHEN p_offset_status = 'COMPENSATED'
                                          THEN 'Due-date update failed; credit memo offset by a new STANDARD invoice'
                                          ELSE 'Due-date update failed AND offset invoice could not be created' END,
               s.last_update_date  = SYSTIMESTAMP
        WHERE  s.instance_id   = p_instance_id
        AND    s.invoice_id    = p_invoice_id
        AND    s.record_status = 'N';

        -- 3. Consume the verdict so a re-run is a no-op and annotate won't revisit it.
        UPDATE lws_ap_c2fo_verdict_load
        SET    processed_flag = 'Y'
        WHERE  instance_id    = p_instance_id
        AND    invoice_id     = p_invoice_id
        AND    verdict_kind   IN ('CM', 'DD')
        AND    status         = 'N'
        AND    processed_flag = 'N';

        COMMIT;
    END update_offset_status;

    -- build_duedate_set removed: the due-date read is the view LWS_C2FO_DD_UPSERT_V,
    -- read directly by OIC "Run a SQL Statement". The stage flip the procedure used to
    -- do (EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED -> EP_INTERFACED) is handled by
    -- flip_chunk_duedates_sent after a chunk's upsert.

    --====================================================================
    -- DUE-DATE RESULT WRITE-BACK  (OIC calls per award after its REST call)
    --   OIC owns the due-date REST (and, on failure, the compensating
    --   cancelInvoice/debit-memo call) and reports the outcome here. The DB only
    --   stamps the state machine - it makes no REST call.
    --     p_dd_ok='Y'    -> award complete (SUCCESSFULLY_PROCESSED).
    --     p_dd_ok='SKIP' -> AP-810830 known skip (installment paid in the gap).
    --     p_dd_ok='N'    -> due-date update failed; p_comp_status carries OIC's
    --                       compensation result: 'COMPENSATED' (CM backed out ->
    --                       terminal C_ERR_ORIG_DD) or 'FAILED' (CM could not be
    --                       backed out -> terminal C_ERR_COMPENSATION, fatal).
    --====================================================================
    PROCEDURE annotate_duedate_result (
        p_instance_id   IN  VARCHAR2,
        p_invoice_id    IN  VARCHAR2,
        p_dd_ok         IN  VARCHAR2,
        p_http_status   IN  NUMBER   DEFAULT NULL,
        p_comp_status   IN  VARCHAR2 DEFAULT NULL,
        p_error_msg     IN  VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        IF p_dd_ok = 'Y' THEN
            -- A zero-income award had its due date updated but never had a CM, so it
            -- closes in the distinct terminal PROCESSED_NO_CM rather than SUCCESSFULLY_PROCESSED.
            UPDATE lws_c2fo_award_data
            SET    record_status    = 'Y',
                   stage            = CASE WHEN NVL(income, 0) = 0
                                          THEN C_STAGE_PROC_NO_CM
                                          ELSE C_STAGE_PROCESSED END,
                   dd_status        = 'OK',
                   http_status      = p_http_status,
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id = p_instance_id
            AND    invoice_id  = p_invoice_id
            AND    record_status = 'N';

        ELSIF p_dd_ok = 'SKIP' THEN
            -- Installment paid between extract and write-back (AP-810830). The
            -- acceleration did not apply; the award is closed as a known skip.
            UPDATE lws_c2fo_award_data
            SET    record_status    = 'Y',
                   stage            = CASE WHEN NVL(income, 0) = 0
                                          THEN C_STAGE_PROC_NO_CM
                                          ELSE C_STAGE_PROCESSED END,
                   dd_status        = 'KNOWN_SKIP',
                   http_status      = p_http_status,
                   error_message    = NVL(p_error_msg, 'AP-810830 known skip (installment paid)'),
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id = p_instance_id
            AND    invoice_id  = p_invoice_id
            AND    record_status = 'N';

        ELSE
            -- Due-date update failed (terminal).
            --   income=0 (no CM ever existed): there is nothing to cancel or reverse,
            --     so this is simply a due-date update failure on the original invoice.
            --     Close as C_ERR_ORIG_DD regardless of p_comp_status (which carries no
            --     meaning here - OIC does not attempt any CM cancel/reverse for these).
            --   income<>0 (a CM was created): OIC either cancelled the CM (immediate)
            --     or reversed it with an offsetting positive invoice; p_comp_status
            --     ='COMPENSATED' means the CM was undone -> C_ERR_ORIG_DD (invoice back
            --     at its original due date). Anything else means the CM could not be
            --     undone and is stranded -> C_ERR_COMPENSATION (fatal, needs a human).
            UPDATE lws_c2fo_award_data
            SET    record_status    = 'E',
                   stage            = CASE
                                          WHEN NVL(income, 0) = 0 THEN C_ERR_ORIG_DD
                                          WHEN p_comp_status = 'COMPENSATED' THEN C_ERR_ORIG_DD
                                          ELSE C_ERR_COMPENSATION
                                      END,
                   error_code       = CASE
                                          WHEN NVL(income, 0) = 0 THEN C_ERR_ORIG_DD
                                          WHEN p_comp_status = 'COMPENSATED' THEN C_ERR_ORIG_DD
                                          ELSE C_ERR_COMPENSATION
                                      END,
                   dd_status        = 'FAILED',
                   http_status      = p_http_status,
                   error_message    = SUBSTR(
                       NVL(p_error_msg,
                           CASE
                               WHEN NVL(income, 0) = 0
                                    THEN 'Due-date update failed (no credit memo - due-date update only)'
                               WHEN p_comp_status = 'COMPENSATED'
                                    THEN 'Due-date update failed; credit memo cancelled/reversed'
                               ELSE 'Due-date update failed AND credit memo could not be cancelled/reversed'
                           END),
                       1, 2000),
                   last_update_date = SYSTIMESTAMP
            WHERE  instance_id = p_instance_id
            AND    invoice_id  = p_invoice_id
            AND    record_status = 'N';
        END IF;
        COMMIT;
    END annotate_duedate_result;

    --====================================================================
    -- BULK DUE-DATE RESULT WRITE-BACK  (the volume path, 300-500K)
    --   Consumes every unprocessed 'DD' verdict for the batch from
    --   LWS_AP_C2FO_VERDICT_LOAD in ONE set-based MERGE. Stamps identical state to
    --   the per-award annotate_duedate_result:
    --     STATUS='Y'    -> record_status='Y', SUCCESSFULLY_PROCESSED, dd_status='OK'
    --     STATUS='SKIP' -> record_status='Y', SUCCESSFULLY_PROCESSED, dd_status
    --                      ='KNOWN_SKIP' (AP-810830 installment paid in the gap)
    --     STATUS='N'    -> terminal 'E': C_ERR_ORIG_DD when comp_status='COMPENSATED'
    --                      else C_ERR_COMPENSATION (fatal, CM could not be backed out)
    --   Only rows still at record_status 'N' are touched. Consumed load rows are
    --   marked PROCESSED_FLAG='Y' so a re-run is a no-op.
    --====================================================================
    PROCEDURE annotate_duedate_result_bulk (
        p_instance_id   IN  VARCHAR2,
        o_applied       OUT NUMBER,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
    BEGIN
        o_status  := 'SUCCESS';
        o_applied := 0;

        MERGE INTO lws_c2fo_award_data s
        USING (
            SELECT instance_id, invoice_id, status, http_status, comp_status, message
            FROM   lws_ap_c2fo_verdict_load
            WHERE  instance_id  = p_instance_id
            AND    verdict_kind = 'DD'
            AND    processed_flag = 'N'
        ) v
        ON (s.instance_id = v.instance_id AND s.invoice_id = v.invoice_id)
        WHEN MATCHED THEN UPDATE SET
            s.record_status     = CASE WHEN v.status IN ('Y','SKIP') THEN 'Y' ELSE 'E' END,
            -- On failure: income=0 rows never had a CM, so nothing to cancel/reverse -
            -- close as a plain due-date update failure (C_ERR_ORIG_DD) regardless of
            -- comp_status. income<>0 rows branch on comp_status as before: COMPENSATED
            -- (CM cancelled/reversed) -> C_ERR_ORIG_DD, else stranded -> C_ERR_COMPENSATION.
            s.stage             = CASE
                                      WHEN v.status IN ('Y','SKIP')
                                           THEN CASE WHEN NVL(s.income, 0) = 0
                                                     THEN C_STAGE_PROC_NO_CM
                                                     ELSE C_STAGE_PROCESSED END
                                      WHEN NVL(s.income, 0) = 0 THEN C_ERR_ORIG_DD
                                      WHEN v.comp_status = 'COMPENSATED' THEN C_ERR_ORIG_DD
                                      ELSE C_ERR_COMPENSATION
                                   END,
            s.error_code        = CASE
                                      WHEN v.status IN ('Y','SKIP') THEN NULL
                                      WHEN NVL(s.income, 0) = 0 THEN C_ERR_ORIG_DD
                                      WHEN v.comp_status = 'COMPENSATED' THEN C_ERR_ORIG_DD
                                      ELSE C_ERR_COMPENSATION
                                   END,
            s.dd_status         = CASE
                                      WHEN v.status = 'Y'    THEN 'OK'
                                      WHEN v.status = 'SKIP' THEN 'KNOWN_SKIP'
                                      ELSE 'FAILED'
                                   END,
            s.http_status       = v.http_status,
            s.error_message     = CASE
                                      WHEN v.status = 'Y' THEN s.error_message  -- leave as-is on success
                                      WHEN v.status = 'SKIP'
                                           THEN NVL(v.message, 'AP-810830 known skip (installment paid)')
                                      ELSE SUBSTR(
                                           NVL(v.message,
                                               CASE
                                                   WHEN NVL(s.income, 0) = 0
                                                        THEN 'Due-date update failed (no credit memo - due-date update only)'
                                                   WHEN v.comp_status = 'COMPENSATED'
                                                        THEN 'Due-date update failed; credit memo cancelled/reversed'
                                                   ELSE 'Due-date update failed AND credit memo could not be cancelled/reversed' END),
                                           1, 2000)
                                   END,
            s.last_update_date  = SYSTIMESTAMP
        WHERE s.record_status = 'N'
        -- Do NOT close a CM-bearing due-date FAILURE until the offset invoice has
        -- run and stamped comp_status. The offset child is async: if annotate closed
        -- these now (comp_status still NULL) they would land COMPENSATION_FAILED and
        -- vanish from LWS_C2FO_CM_OFFSET_V before the offset could act. update_offset_status
        -- closes them once it stamps the outcome. Successes, known-skips and income=0
        -- (no CM to offset) still close here.
        AND NOT (v.status = 'N'
                 AND NVL(s.income, 0) <> 0
                 AND v.comp_status IS NULL);

        o_applied := SQL%ROWCOUNT;

        -- Consume ONLY the verdicts annotate actually closed. Leave the awaiting-offset
        -- rows (CM-bearing DD failures with no comp_status yet) at processed_flag='N' so
        -- the offset view still returns them; update_offset_status consumes them later.
        UPDATE lws_ap_c2fo_verdict_load vl
        SET    processed_flag = 'Y'
        WHERE  vl.instance_id  = p_instance_id
        AND    vl.verdict_kind = 'DD'
        AND    vl.processed_flag = 'N'
        AND    NOT (vl.status = 'N'
                    AND vl.comp_status IS NULL
                    AND EXISTS (SELECT 1 FROM lws_c2fo_award_data s
                                WHERE s.instance_id = vl.instance_id
                                AND   s.invoice_id  = vl.invoice_id
                                AND   NVL(s.income, 0) <> 0));

        -- Re-stamp END_TIME so the run log reflects true end-to-end duration.
        -- run_validation sets END_TIME when validation finishes; the due-date
        -- write-back is the final inbound step, so advance END_TIME here to the
        -- moment the last verdicts are applied. No reruns, so one row per instance.
        UPDATE lws_ap_c2fo_award_run_log
        SET    end_time = SYSDATE
        WHERE  instance_id = p_instance_id;

        COMMIT;
        o_message := 'Applied ' || o_applied || ' due-date verdicts for instance ' || p_instance_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
    END annotate_duedate_result_bulk;

    --====================================================================
    -- ERROR FILE WRITER  (batch 'E' rows -> RFC 4180 CSV -> OCI)
    --====================================================================
    PROCEDURE write_error_file (
        p_instance_id   IN  VARCHAR2,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_buf      CLOB;
        l_line     VARCHAR2(32767);
        l_rows     PLS_INTEGER := 0;
        l_obj_name VARCHAR2(200);
        l_blob     BLOB;
        l_dst_off  INTEGER := 1;
        l_src_off  INTEGER := 1;
        l_lang_ctx INTEGER := DBMS_LOB.default_lang_ctx;
        l_warning  INTEGER;
        l_stamp    VARCHAR2(8) := TO_CHAR(TRUNC(SYSDATE), 'YYYYMMDD');
    BEGIN
        o_status := 'SUCCESS';

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'Could not load config';
            RETURN;
        END IF;

        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);
        l_line := 'invoice_id,erp_invoice_num,stage,error_code,error_message,'
                  || 'erp_invoice_id,payment_num,cm_invoice_num,instance_id' || CHR(13) || CHR(10);
        DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);

        FOR r IN (SELECT invoice_id, erp_invoice_num, stage, error_code, error_message,
                         erp_invoice_id, payment_num, cm_invoice_num, instance_id
                  FROM   lws_c2fo_award_data
                  WHERE  instance_id = p_instance_id
                  AND    record_status = 'E'
                  ORDER  BY invoice_id) LOOP
            l_line := csv_field(r.invoice_id) ||','|| csv_field(r.erp_invoice_num) ||','||
                      csv_field(r.stage) ||','|| csv_field(r.error_code) ||','||
                      csv_field(r.error_message) ||','||
                      csv_field(TO_CHAR(r.erp_invoice_id)) ||','|| csv_field(TO_CHAR(r.payment_num)) ||','||
                      csv_field(r.cm_invoice_num) ||','|| csv_field(r.instance_id)
                      || CHR(13) || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);
            l_rows := l_rows + 1;
        END LOOP;

        l_obj_name := 'c2fo_award_errors_' || REGEXP_REPLACE(p_instance_id, '[^A-Za-z0-9_]', '_')
                      || '_' || l_stamp || '.csv';

        DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob     => l_blob,
            src_clob     => l_buf,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => l_dst_off,
            src_offset   => l_src_off,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => l_lang_ctx,
            warning      => l_warning
        );

        DBMS_CLOUD.PUT_OBJECT(
            credential_name => g_ob_credential,
            object_uri      => object_uri(g_error_bucket, g_error_folder, l_obj_name),
            contents        => l_blob
        );

        DBMS_LOB.FREETEMPORARY(l_blob);
        DBMS_LOB.FREETEMPORARY(l_buf);

        o_message := 'Wrote ' || l_rows || ' error rows to ' || l_obj_name;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            BEGIN DBMS_LOB.FREETEMPORARY(l_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN DBMS_LOB.FREETEMPORARY(l_blob); EXCEPTION WHEN OTHERS THEN NULL; END;
    END write_error_file;

   --====================================================================
    -- 7b. RUN LOG FILE  (C2FO-INBOUND-LOG, human/client audience)
    --   A structured section log (not the flat error CSV): Header counts + timing
    --   from LWS_AP_C2FO_AWARD_RUN_LOG, a short Prechecks block of facts we can
    --   truthfully assert, Overall Status, then one Error Line per record_status='E'
    --   award keyed by the composite INVOICE_ID. Written to the same OCI error
    --   bucket/folder as write_error_file; o_object_name is handed back so OIC can
    --   link it from the ErrorHandler service call. Separate step, separate object.
    --====================================================================
    PROCEDURE write_run_log_file (
        p_instance_id   IN  VARCHAR2,
        o_bucket        OUT VARCHAR2,
        o_object_path   OUT VARCHAR2,
        o_error_link    OUT VARCHAR2,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_buf      CLOB;
        l_obj_name VARCHAR2(200);
        l_err_rows PLS_INTEGER := 0;
        l_blob     BLOB;
        l_dst_off  INTEGER := 1;
        l_src_off  INTEGER := 1;
        l_lang_ctx INTEGER := DBMS_LOB.default_lang_ctx;
        l_warning  INTEGER;
        l_stamp    VARCHAR2(15) := TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
        l_total    NUMBER;
        l_processed NUMBER;
        l_errors   NUMBER;
        l_start    DATE;
        l_end      DATE;
        l_rstatus  VARCHAR2(20);
        l_secs     VARCHAR2(40);
        l_overall  VARCHAR2(10);
        l_succ_cnt NUMBER;
        l_ep_amt   NUMBER;
        l_disc_amt NUMBER;
		-- Variable for Out Parameter of write_error_records_csv_file 
        l_write_error_rec_status   VARCHAR2 (100);
        l_write_error_rec_message  VARCHAR2 (4000);

        -- append one line (adds CRLF) to the buffer
        PROCEDURE put (p_text IN VARCHAR2) IS
            l_l VARCHAR2(32767) := p_text || CHR(13) || CHR(10);
        BEGIN
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_l), l_l);
        END put;
    BEGIN
        o_status := 'SUCCESS';

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'Could not load config';
            RETURN;
        END IF;

        -- Run-level facts: latest run for this instance (highest RUN_ID).
        BEGIN
            SELECT total_count, processed_count, error_count, start_time, end_time, status
            INTO   l_total, l_processed, l_errors, l_start, l_end, l_rstatus
            FROM   lws_ap_c2fo_award_run_log
            WHERE  instance_id = p_instance_id
            AND    run_id = (SELECT MAX(run_id) FROM lws_ap_c2fo_award_run_log
                             WHERE instance_id = p_instance_id);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_total := NULL; l_processed := NULL; l_errors := NULL;
                l_start := NULL; l_end := NULL; l_rstatus := NULL;
        END;

        -- Fall back to a live count of 'E' rows if the run log has no error tally.
        IF l_errors IS NULL THEN
            SELECT COUNT(*) INTO l_errors
            FROM   lws_c2fo_award_data
            WHERE  instance_id = p_instance_id AND record_status = 'E';
        END IF;

        -- Success totals: count + money on the awards that completed (record_status='Y').
        -- Early-payment amount = DISCOUNTED_INVOICE_AMOUNT (what was paid early);
        -- discount earned = INCOME (the C2FO discount currency amount).
        SELECT COUNT(*), NVL(SUM(discounted_invoice_amount), 0), NVL(SUM(income), 0)
        INTO   l_succ_cnt, l_ep_amt, l_disc_amt
        FROM   lws_c2fo_award_data
        WHERE  instance_id = p_instance_id AND record_status = 'Y';

        IF l_end IS NOT NULL AND l_start IS NOT NULL THEN
            l_secs := TO_CHAR(ROUND((l_end - l_start) * 86400, 2));
        END IF;

        -- Overall status: Fail if any error row, else the run status (Success default).
        l_overall := CASE
                        WHEN NVL(l_errors, 0) > 0 THEN 'Fail'
                        WHEN l_rstatus IN ('ERROR', 'FATAL') THEN 'Fail'
                        ELSE 'Success'
                     END;

        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);

        -- ---- Header section (SAP-only rows dropped; Fusion-relevant kept) ----
        put('Header,' || csv_field('Log Type') || ',' || csv_field('C2FO - INBOUND LOG'));
        put('Header,' || csv_field('ERP') || ',' || csv_field('Oracle Fusion Payables'));
        put('Header,' || csv_field('Instance Name') || ',' || csv_field(p_instance_id));
        put('Header,' || csv_field('Date of Execution') || ','
            || csv_field(TO_CHAR(NVL(l_start, SYSDATE), 'YYYY/MM/DD')));
        put('Header,' || csv_field('Time of Execution') || ','
            || csv_field(TO_CHAR(NVL(l_start, SYSDATE), 'HH24:MI:SS')));
        put('Header,' || csv_field('Execution time in seconds') || ',' || csv_field(l_secs));
        put('Header,' || csv_field('Record count') || ',' || csv_field(TO_CHAR(l_total)));
        put('Header,' || csv_field('Records Processed Correctly') || ','
            || csv_field(TO_CHAR(l_processed)));
        put('Header,' || csv_field('Records with Errors') || ',' || csv_field(TO_CHAR(l_errors)));

        -- ---- Prechecks (facts we can truthfully assert from the run) ----
        IF l_total IS NOT NULL THEN
            put('Prechecks,' || csv_field('Prechecks') || ','
                || csv_field('Award file loaded successfully.'));
            put('Prechecks,' || csv_field('Prechecks') || ','
                || csv_field(l_total || ' records found in the award file.'));
            put('Prechecks,' || csv_field('Prechecks') || ','
                || csv_field('Validation completed with status ' || NVL(l_rstatus, 'UNKNOWN') || '.'));
        END IF;

        -- ---- Overall status ----
        put('Status,' || csv_field('Overall Status') || ',' || csv_field(l_overall));

        -- ---- Summary section: successful-award totals ----
        put('Summary,' || csv_field('Awards Successful') || ',' || csv_field(TO_CHAR(l_succ_cnt)));
        put('Summary,' || csv_field('Early Payment Amount') || ',' || csv_field(TO_CHAR(l_ep_amt)));
        put('Summary,' || csv_field('Discount Earned') || ',' || csv_field(TO_CHAR(l_disc_amt)));

        -- ---- Error Line section: one row per failed award, keyed by composite id ----
        FOR r IN (SELECT invoice_id, error_message
                  FROM   lws_c2fo_award_data
                  WHERE  instance_id = p_instance_id
                  AND    record_status = 'E'
                  ORDER  BY invoice_id) LOOP
            put('Error Line,' || csv_field(r.invoice_id) || ',' || csv_field(r.error_message));
            l_err_rows := l_err_rows + 1;
        END LOOP;

        l_obj_name := 'c2fo_inbound_log_'
                      || REGEXP_REPLACE(p_instance_id, '[^A-Za-z0-9_]', '_')
                      || '_' || l_stamp || '.csv';

        DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob     => l_blob,
            src_clob     => l_buf,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => l_dst_off,
            src_offset   => l_src_off,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => l_lang_ctx,
            warning      => l_warning
        );

        DBMS_CLOUD.PUT_OBJECT(
            credential_name => g_ob_credential,
            object_uri      => object_uri(g_error_bucket, g_error_folder, l_obj_name),
            contents        => l_blob
        );

        DBMS_LOB.FREETEMPORARY(l_blob);
        DBMS_LOB.FREETEMPORARY(l_buf);

        -- Hand back the pieces the ErrorHandler link needs. The service's link is
        -- '<bucket>;<object_path>;' (NOT a URL) - it builds the clickable link from
        -- bucket + path itself. object_path = folder/object (folder omitted if unset).
        o_bucket      := g_error_bucket;
        o_object_path := CASE WHEN g_error_folder IS NOT NULL
                              THEN g_error_folder || '/' || l_obj_name
                              ELSE l_obj_name END;
        o_error_link  := o_bucket || ';' || o_object_path || ';';

        o_message := 'Wrote run log (' || l_err_rows || ' error lines) to ' || o_error_link;
		
		write_error_records_csv_file ( p_instance_id => p_instance_id,
                                       o_status      => l_write_error_rec_status,
                                       o_message     => l_write_error_rec_message );
		o_message := o_message || substr(l_write_error_rec_message,1,(4000- length (o_message))) ; 
		
        IF l_write_error_rec_status = 'ERROR' then
            o_status  := 'ERROR';		
        END IF; 									   
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            BEGIN DBMS_LOB.FREETEMPORARY(l_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN DBMS_LOB.FREETEMPORARY(l_blob); EXCEPTION WHEN OTHERS THEN NULL; END;
    END write_run_log_file;

    --====================================================================
    -- AWARD-HISTORY PURGE  (BR#12 - separate, scheduled; never part of a run)
    --   Removes award rows older than the retention window, keyed on CREATION_DATE:
    --     CREATION_DATE < SYSTIMESTAMP - NUMTOYMINTERVAL(months,'MONTH')
    --   and RECORD_STATUS <> 'N' (never purge an in-flight row, even if aged). The
    --   window is INBOUND / AWARD_RETENTION_MONTHS from config (p_override_months
    --   wins if supplied). Deletes in bounded chunks with a commit per chunk so a
    --   500K purge never holds one giant transaction. Aged 'N' rows are counted
    --   and reported (o_aged_inflight) for investigation - NOT deleted.
    --====================================================================
    PROCEDURE purge_award_history (
        p_override_months IN  NUMBER   DEFAULT NULL,
        p_commit_batch    IN  NUMBER   DEFAULT 10000,
        o_deleted         OUT NUMBER,
        o_aged_inflight   OUT NUMBER,
        o_status          OUT VARCHAR2,
        o_message         OUT VARCHAR2
    ) IS
        C_DEFAULT_MONTHS CONSTANT NUMBER := 24;   -- used only if config unset AND no override
        l_months     NUMBER;
        l_cutoff     TIMESTAMP;
        l_batch      PLS_INTEGER;
        l_chunk      PLS_INTEGER;
    BEGIN
        o_status        := 'SUCCESS';
        o_deleted       := 0;
        o_aged_inflight := 0;

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'Could not load config from LWS_C2FO_CONFIG';
            RETURN;
        END IF;

        -- Resolve the retention window: explicit override, else the config key,
        -- else the code default. Guard against a non-positive value (would purge
        -- everything / future-date the cutoff).
        l_months := NVL(p_override_months,
                        TO_NUMBER(cfg('INBOUND', 'AWARD_RETENTION_MONTHS',
                                      TO_CHAR(C_DEFAULT_MONTHS))));
        IF l_months IS NULL OR l_months <= 0 THEN
            o_status  := 'ERROR';
            o_message := 'Invalid retention window (' || l_months || ' months); refusing to purge';
            RETURN;
        END IF;

        l_batch := GREATEST(NVL(p_commit_batch, 10000), 1);
        l_cutoff := SYSTIMESTAMP - NUMTOYMINTERVAL(l_months, 'MONTH');

        -- Surface aged in-flight rows (aged but still 'N'): reported, never purged.
        SELECT COUNT(*)
        INTO   o_aged_inflight
        FROM   lws_c2fo_award_data
        WHERE  creation_date < l_cutoff
        AND    record_status = 'N';

        -- Bounded-batch delete: only completed rows ('Y'/'E') past the window.
        LOOP
            DELETE FROM lws_c2fo_award_data
            WHERE  creation_date < l_cutoff
            AND    record_status <> 'N'
            AND    ROWNUM <= l_batch;
            l_chunk := SQL%ROWCOUNT;
            o_deleted := o_deleted + l_chunk;
            COMMIT;
            EXIT WHEN l_chunk = 0;
        END LOOP;

        o_message := 'Purged ' || o_deleted || ' award rows older than ' || l_months
                     || ' months (cutoff ' || TO_CHAR(l_cutoff, 'YYYY-MM-DD') || '); '
                     || o_aged_inflight || ' aged in-flight row(s) retained for investigation';
    EXCEPTION
        WHEN OTHERS THEN
            -- committed chunks stand; report where we stopped.
            o_status  := 'ERROR';
            o_message := 'Purge failed after ' || o_deleted || ' rows: ' || SUBSTR(SQLERRM, 1, 3900);
    END purge_award_history;

    --====================================================================
    -- 9. Render the batch'srecord_status NOT IN ('SUCCESSFULLY_PROCESSED','PROCESSED_NO_CM')  rows 
    -- to an RFC-4180 CSV and write it  to the OCI OUTBOUND error bucket/folder for return to C2FO.
    --====================================================================
    PROCEDURE write_error_records_csv_file (
        p_instance_id   IN  VARCHAR2,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_buf      CLOB;
        l_line     VARCHAR2(32767);
        l_rows     PLS_INTEGER := 0;
        l_obj_name VARCHAR2(200);
        l_blob     BLOB;
        l_dst_off  INTEGER := 1;
        l_src_off  INTEGER := 1;
        l_lang_ctx INTEGER := DBMS_LOB.default_lang_ctx;
        l_warning  INTEGER;
        l_stamp    VARCHAR2(8) := TO_CHAR(TRUNC(SYSDATE), 'YYYYMMDD');
    BEGIN
        o_status := 'SUCCESS';

        IF NOT load_config THEN
            o_status  := 'ERROR';
            o_message := 'Could not load config';
            RETURN;
        END IF;

        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);
        l_line := 'company_id, company_name, division_id, invoice_id, original_amount, currency, original_due_date, transaction_type, original_invoice_transaction_date, voucher_id, voucher_line_id, fiscal_year, discount_percentage, income, discounted_invoice_amount, pay_date,,'
                  || 'offer_apr_amount, covers_adjustment, adjusted_invoice_amount, adj_invoice_id, surviving_invoice_id, surviving_invoice_due_date, supplier_address_1, supplier_address_2, supplier_city, supplier_state, supplier_postal_code, supplier_country, supplier_tax_id, sequential_document_number,,'
                  || 'buyer_name, buyer_address, buyer_tax_id, original_amount_grossvat, original_amount_netvat, vat_to_be_discounted, original_vat, awarded_vat, vat_reduction, original_vat_percentage, discount_reason_code, local_currency_key, local_currency_rate, local_currency_original_inv_amount, local_currency_income, local_currency_net_award_amount, local_currency_original_vat,,'
                  || 'local_currency_awarded_vat, local_currency_vat_reduction, market_type, po_id, fund_type, erp_legal_entity, erp_reference_number, erp_vendor_id, erp_tax_code, erp_payment_term, erp_baseline_date, erp_net_due_date, erp_invoice_amount, erp_discount_base_amount,,'
                  || 'erp_cash_disc_amount, erp_payee, erp_vendor_site_id, erp_vendor_site_code, erp_invoice_num, erp_pay_group, erp_sup_pay_priority, erp_tax_rate, erp_doc_type, erp_business_unit, erp_supplier_number, erp_purpose_of_payment, erp_burst_id' || CHR(13) || CHR(10);
        DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);

        FOR r IN (SELECT company_id, company_name, division_id, invoice_id, original_amount,
                                        currency, original_due_date, transaction_type, original_invoice_transaction_date, voucher_id,
                                        voucher_line_id, fiscal_year, discount_percentage, income, discounted_invoice_amount,
                                        pay_date, offer_apr_amount, covers_adjustment, adjusted_invoice_amount, adj_invoice_id,
                                        surviving_invoice_id, surviving_invoice_due_date, supplier_address_1, supplier_address_2,
                                        supplier_city, supplier_state, supplier_postal_code, supplier_country, supplier_tax_id,
                                        sequential_document_number, buyer_name, buyer_address, buyer_tax_id, original_amount_grossvat,
                                        original_amount_netvat, vat_to_be_discounted, original_vat, awarded_vat, vat_reduction,
                                        original_vat_percentage, discount_reason_code, local_currency_key, local_currency_rate,
                                        local_currency_original_inv_amount, local_currency_income, local_currency_net_award_amount,
                                        local_currency_original_vat, local_currency_awarded_vat, local_currency_vat_reduction,
                                        market_type, po_id, fund_type, erp_legal_entity, erp_reference_number, erp_vendor_id,
                                        erp_tax_code, erp_payment_term, erp_baseline_date, erp_net_due_date, erp_invoice_amount,
                                        erp_discount_base_amount, erp_cash_disc_amount, erp_payee, erp_vendor_site_id, erp_vendor_site_code,
                                        erp_invoice_num, erp_pay_group, erp_sup_pay_priority, erp_tax_rate, erp_doc_type, erp_business_unit,
                                        erp_supplier_number, erp_purpose_of_payment, erp_burst_id
                        FROM   lws_c2fo_award_data
                        WHERE  instance_id = p_instance_id
                        AND stage NOT IN ('SUCCESSFULLY_PROCESSED','PROCESSED_NO_CM') ) LOOP
            l_line := csv_field(r.company_id) ||','|| csv_field(r.company_name) ||','|| csv_field(r.division_id) ||','|| 
                            csv_field(r.invoice_id) ||','|| csv_field(TO_CHAR(r.original_amount)) ||','|| csv_field(r.currency) ||','|| 
                            csv_field(r.original_due_date) ||','|| csv_field(TO_CHAR(r.transaction_type)) ||','|| csv_field(r.original_invoice_transaction_date) ||','|| 
                            csv_field(TO_CHAR(r.voucher_id)) ||','|| csv_field(TO_CHAR(r.voucher_line_id)) ||','|| 
                            csv_field(TO_CHAR(r.fiscal_year)) ||','|| csv_field(TO_CHAR(r.discount_percentage)) ||','|| 
                            csv_field(TO_CHAR(r.income)) ||','|| csv_field(TO_CHAR(r.discounted_invoice_amount)) ||','|| 
                            csv_field(r.pay_date) ||','|| csv_field(TO_CHAR(r.offer_apr_amount)) ||','|| 
                            csv_field(TO_CHAR(r.covers_adjustment)) ||','|| csv_field(TO_CHAR(r.adjusted_invoice_amount)) ||','|| 
                            csv_field(r.adj_invoice_id) ||','|| csv_field(r.surviving_invoice_id) ||','|| 
                            csv_field(r.surviving_invoice_due_date) ||','|| csv_field(r.supplier_address_1) ||','|| 
                            csv_field(r.supplier_address_2) ||','|| csv_field(r.supplier_city) ||','|| 
                            csv_field(r.supplier_state) ||','|| csv_field(r.supplier_postal_code) ||','|| 
                            csv_field(r.supplier_country) ||','|| csv_field(r.supplier_tax_id) ||','|| 
                            csv_field(r.sequential_document_number) ||','|| csv_field(r.buyer_name) ||','|| 
                            csv_field(r.buyer_address) ||','|| csv_field(r.buyer_tax_id) ||','|| 
                            csv_field(TO_CHAR(r.original_amount_grossvat)) ||','|| csv_field(TO_CHAR(r.original_amount_netvat)) ||','|| 
                            csv_field(TO_CHAR(r.vat_to_be_discounted)) ||','|| csv_field(TO_CHAR(r.original_vat)) ||','|| 
                            csv_field(TO_CHAR(r.awarded_vat)) ||','|| csv_field(TO_CHAR(r.vat_reduction)) ||','|| 
                            csv_field(TO_CHAR(r.original_vat_percentage)) ||','|| csv_field(r.discount_reason_code) ||','|| 
                            csv_field(r.local_currency_key) ||','|| csv_field(TO_CHAR(r.local_currency_rate)) ||','|| 
                            csv_field(TO_CHAR(r.local_currency_original_inv_amount)) ||','|| csv_field(TO_CHAR(r.local_currency_income)) ||','|| 
                            csv_field(TO_CHAR(r.local_currency_net_award_amount)) ||','|| csv_field(TO_CHAR(r.local_currency_original_vat)) ||','|| 
                            csv_field(TO_CHAR(r.local_currency_awarded_vat)) ||','|| csv_field(TO_CHAR(r.local_currency_vat_reduction)) ||','|| 
                            csv_field(r.market_type) ||','|| csv_field(r.po_id) ||','|| csv_field(r.fund_type) ||','|| 
                            csv_field(r.erp_legal_entity) ||','|| csv_field(TO_CHAR(r.erp_reference_number)) ||','|| 
                            csv_field(TO_CHAR(r.erp_vendor_id)) ||','|| csv_field(r.erp_tax_code) ||','|| csv_field(r.erp_payment_term) ||','|| 
                            csv_field(r.erp_baseline_date) ||','|| csv_field(r.erp_net_due_date) ||','|| csv_field(TO_CHAR(r.erp_invoice_amount)) ||','|| 
                            csv_field(TO_CHAR(r.erp_discount_base_amount)) ||','|| csv_field(TO_CHAR(r.erp_cash_disc_amount)) ||','|| 
                            csv_field(r.erp_payee) ||','|| csv_field(TO_CHAR(r.erp_vendor_site_id)) ||','|| 
                            csv_field(r.erp_vendor_site_code) ||','|| csv_field(r.erp_invoice_num) ||','|| 
                            csv_field(r.erp_pay_group) ||','|| csv_field(TO_CHAR(r.erp_sup_pay_priority)) ||','|| 
                            csv_field(TO_CHAR(r.erp_tax_rate)) ||','|| csv_field(r.erp_doc_type) ||','|| csv_field(r.erp_business_unit) ||','|| 
                            csv_field(r.erp_supplier_number) ||','|| csv_field(r.erp_purpose_of_payment) ||','|| csv_field(r.erp_burst_id)
                      || CHR(13) || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line), l_line);
            l_rows := l_rows + 1;
        END LOOP;

        l_obj_name := 'c2fo_award_error_records_' || REGEXP_REPLACE(p_instance_id, '[^A-Za-z0-9_]', '_')
                      || '_' || l_stamp || '.csv';

        DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob     => l_blob,
            src_clob     => l_buf,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => l_dst_off,
            src_offset   => l_src_off,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => l_lang_ctx,
            warning      => l_warning
        );

        DBMS_CLOUD.PUT_OBJECT(
            credential_name => g_ob_credential,
            object_uri      => object_uri(g_log_bucket, g_log_folder, l_obj_name),
            contents        => l_blob
        );

        DBMS_LOB.FREETEMPORARY(l_blob);
        DBMS_LOB.FREETEMPORARY(l_buf);

        o_message := 'Wrote ' || l_rows || ' error rows to ' || l_obj_name;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            BEGIN DBMS_LOB.FREETEMPORARY(l_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN DBMS_LOB.FREETEMPORARY(l_blob); EXCEPTION WHEN OTHERS THEN NULL; END;
    END write_error_records_csv_file;

END LWS_AP_C2FO_AWARD_PKG;