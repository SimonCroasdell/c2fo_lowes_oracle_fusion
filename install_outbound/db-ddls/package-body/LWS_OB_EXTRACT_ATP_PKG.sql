CREATE OR REPLACE PACKAGE BODY LWS_CUSTOM_C2FO_SA.LWS_OB_EXTRACT_ATP_PKG AS

    g_schema        CONSTANT VARCHAR2(30) := 'LWS_CUSTOM_C2FO_SA';
    c_bulk_limit    CONSTANT PLS_INTEGER  := 10000;   -- bulk-collect fetch size
    c_ou_lookup     CONSTANT VARCHAR2(40) := 'XX_ZZZZ_C2FO_OPERATING_UNIT_LT';
    c_inv_type_lkp  CONSTANT VARCHAR2(40) := 'XX_ZZZZ_C2FO_INVOICE_TYPE_LT';

    -- Package-private OCI config, loaded once per write_files_to_bucket call from
    -- the key/value LWS_C2FO_CONFIG table, COMMON group (same table + group the
    -- inbound and common packages read).
    g_ob_credential   VARCHAR2(200);
    g_ob_namespace    VARCHAR2(200);
    g_ob_uri          VARCHAR2(500);

    -- Destination for the current write_files_to_bucket call. 'BUCKET' => OCI object
    -- store (default, unchanged behaviour); 'DIRECTORY' => local ATP directory object
    -- named by g_dest_dir. Set once at the top of write_files_to_bucket.
    g_dest       VARCHAR2(10) := 'BUCKET';
    g_dest_dir   VARCHAR2(128);

    --------------------------------------------------------------------------
    -- Concurrency helper: count runs that would legitimately block a new run,
    -- while self-healing orphans. A blocker is any OTHER row that is RUNNING, or
    -- SUBMITTED with an earlier (lower) run_id than p_self_run_id. A run only
    -- counts as truly active if its DBMS_SCHEDULER job (LWS_OB_RUN_<id>) still
    -- exists; a crashed run (slave terminated, DB bounce) leaves its row stuck
    -- non-terminal with no job, which would otherwise wedge every future submit.
    -- Such orphans are auto-closed to ERROR here (logged, not silent) and do NOT
    -- count. Called from both run_outbound's guard and submit_outbound, so both
    -- entry points clear orphans; returns the number of genuinely-live blockers.
    -- p_self_run_id: this caller's own run_id (excluded from the scan); pass NULL
    -- for a submit that has not reserved a row yet (then all SUBMITTED rows are
    -- considered earlier). Commits (it closes orphan rows).
    --------------------------------------------------------------------------
    FUNCTION sweep_orphan_runs (p_self_run_id IN NUMBER) RETURN NUMBER IS
        l_active     NUMBER := 0;
        l_job_exists NUMBER;
    BEGIN
        FOR r IN (
            SELECT run_id
            FROM   lws_ob_run_log
            WHERE  run_id <> NVL(p_self_run_id, -1)
            AND    ( status = 'RUNNING'
                     OR ( status = 'SUBMITTED'
                          AND run_id < NVL(p_self_run_id, 9.9999999999E125) ) )
        ) LOOP
            SELECT COUNT(*)
            INTO   l_job_exists
            FROM   user_scheduler_jobs
            WHERE  job_name = 'LWS_OB_RUN_' || r.run_id;

            IF l_job_exists > 0 THEN
                l_active := l_active + 1;              -- genuinely live run
            ELSE
                UPDATE lws_ob_run_log
                SET    status = 'ERROR', end_time = SYSDATE,
                       error_message = 'Auto-closed: no DBMS_SCHEDULER job LWS_OB_RUN_'
                                       || r.run_id || ' (crashed/terminated before '
                                       || 'flipping status).'
                WHERE  run_id = r.run_id
                AND    status IN ('RUNNING','SUBMITTED');
            END IF;
        END LOOP;
        COMMIT;
        RETURN l_active;
    END sweep_orphan_runs;

    --------------------------------------------------------------------------
    -- Helper: strip commas and double-quotes from a value (the EBS code did
    -- replace(replace(x,',',''),'"','') on every field). Kept so the staged
    -- values are CSV-safe regardless of how OIC quotes them.
    --------------------------------------------------------------------------
    --------------------------------------------------------------------------
    -- Helper: fmt a DATE as YYYY-MM-DD (matches the Fusion file examples).
    --------------------------------------------------------------------------
    FUNCTION dstr (p_d IN DATE) RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(p_d, 'YYYY-MM-DD');
    END dstr;

    --------------------------------------------------------------------------
    -- Helper: CSV escaping. The extract stores raw ERP values; this is the sole
    -- escaping stage. If a value contains a comma, double-quote, CR, LF, or a
    -- SPACE, wrap it in quotes and double any embedded quote. NULL -> empty field.
    -- Quoting on space (beyond the RFC 4180 minimum) matches the BI Publisher
    -- output C2FO already ingests, so any field with a space (e.g. 'NET 105',
    -- 'US Trade BU', a spaces-only buyer_address) is quoted the same way BIP does.
    --------------------------------------------------------------------------
    FUNCTION csv_field (p_val IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN
            RETURN NULL;
        END IF;
        IF INSTR(p_val, ',') > 0
           OR INSTR(p_val, '"') > 0
           OR INSTR(p_val, ' ') > 0
           OR INSTR(p_val, CHR(13)) > 0
           OR INSTR(p_val, CHR(10)) > 0 THEN
            RETURN '"' || REPLACE(p_val, '"', '""') || '"';
        END IF;
        RETURN p_val;
    END csv_field;

    --------------------------------------------------------------------------
    -- Helper: normalize a comma-separated list into a delimiter-wrapped, trimmed
    -- token string suitable for a set-membership test done entirely in SQL, so
    -- no schema-level collection type is needed. Returns e.g. ',US Trade BU,US
    -- Supply Chain BU,'. A value V is "in the list" when
    --   INSTR(<wrapped list>, ',' || TRIM(V) || ',') > 0.
    -- NULL/blank input returns NULL (caller treats NULL as "no restriction").
    -- Each element is TRIMmed so ' US Trade BU , ...' matches cleanly.
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
        -- l_out is ',' only when every element was blank -> treat as no restriction
        IF l_out = ',' THEN RETURN NULL; END IF;
        RETURN l_out;
    END list_wrap;

    --====================================================================
    -- INVOICE EXTRACT
    -- Grain: one row per AP_PAYMENT_SCHEDULES_ALL installment.
    --====================================================================
    PROCEDURE extract_invoices (
        p_invoice_date_from   IN  DATE,
        p_invoice_date_to     IN  DATE,
        p_pay_due_date_from   IN  DATE,
        p_pay_due_date_to     IN  DATE,
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL, -- exclude invoice payment term NAME list
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL, -- exclude supplier vendor_type_lookup_code list
        p_max_past_years      IN  NUMBER   DEFAULT NULL,
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,  -- include-only supplier segment1 list
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,  -- include-only invoice_num list
        o_count               OUT NUMBER
    ) IS

        -- Delimiter-wrapped scope lists (NULL => no restriction). Built once here
        -- and referenced by the cursor via a SQL INSTR membership test, so the BU
        -- scope is now a runtime parameter instead of the XX_ZZZZ_C2FO_OPERATING_
        -- UNIT_LT lookup, and pay-groups can be excluded per run.
        l_bu_wrap    VARCHAR2(32767) := list_wrap(p_bu_list);
        l_pg_wrap    VARCHAR2(32767) := list_wrap(p_exclude_pay_groups);
        -- Exclude list for invoice payment term name (NULL => exclude none), same
        -- INSTR membership test as l_pg_wrap: a row is dropped when att.name IS in the list.
        l_pt_wrap    VARCHAR2(32767) := list_wrap(p_exclude_payment_terms);
        -- Exclude list for supplier vendor_type_lookup_code (NULL => exclude none),
        -- same INSTR membership test as l_pg_wrap: a row is dropped when its value IS in the list.
        l_vt_wrap    VARCHAR2(32767) := list_wrap(p_exclude_vendor_types);
        -- Include-only scope lists (NULL => no restriction), same INSTR membership
        -- test as l_bu_wrap: a row is kept only when its value is IN the list.
        l_vn_wrap    VARCHAR2(32767) := list_wrap(p_vendor_numbers);   -- sup.segment1
        l_in_wrap    VARCHAR2(32767) := list_wrap(p_invoice_nums);     -- aia.invoice_num

        -- Oldest due_date we still send: SYSDATE minus p_max_past_years years.
        -- NULL / <= 0 => no lower bound (send all past-due installments too).
        l_due_floor  DATE := CASE
                                WHEN p_max_past_years IS NULL OR p_max_past_years <= 0
                                THEN NULL
                                ELSE ADD_MONTHS(SYSDATE, -12 * p_max_past_years)
                             END;

        CURSOR c_inv IS
        SELECT
            aia.invoice_id                                              AS k_invoice_id,
            apsa.payment_num                                            AS k_payment_num,
            -- company_id = org|vendor|site
            aia.org_id || '|' || sup.vendor_id || '|' || site.vendor_site_id AS company_id,
            CAST(NULL AS VARCHAR2(60))                                  AS division_id,
            -- invoice_id = org|voucher_id|payment_num|invoice_num
            aia.org_id || '|' || aia.invoice_id || '|' || apsa.payment_num || '|' || aia.invoice_num AS invoice_id,
            -- amount = discounted net installment amount. The buyer ALWAYS takes the
            -- first-tier cash discount (whatever the pay date, even after the discount
            -- window has passed), so discount_amount_available is subtracted from the
            -- net-of-tax base unconditionally:
            --   amount = amount_remaining - total_tax - discount_amount_available
            TO_CHAR(apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                    - NVL(apsa.discount_amount_available, 0))            AS amount,
            aia.invoice_currency_code                                   AS currency,
            -- payment_due_date = the earliest still-reachable discount date (the buyer
            -- always takes the discount, so we accelerate to its date while the window
            -- is open), stepping first->second->third; once every discount window has
            -- passed (all discount dates < today) it falls back to the net due date.
            dstr(CASE
                    WHEN TRUNC(SYSDATE) <= apsa.discount_date        THEN apsa.discount_date
                    WHEN TRUNC(SYSDATE) <= apsa.second_discount_date THEN apsa.second_discount_date
                    WHEN TRUNC(SYSDATE) <= apsa.third_discount_date  THEN apsa.third_discount_date
                    ELSE apsa.due_date
                 END)                                                   AS payment_due_date,
            DECODE(aia.invoice_type_lookup_code, 'STANDARD', '1',
                   'CREDIT', '2', 'DEBIT', '2', NULL)                   AS transaction_type,
            dstr(aia.invoice_date)                                      AS transaction_date,
            dstr(aia.gl_date)                                           AS posting_date,
            TO_CHAR(aia.invoice_id)                                     AS voucher_id,
            TO_CHAR(apsa.payment_num)                                   AS voucher_line_id,
            CAST(NULL AS VARCHAR2(20))                                  AS fiscal_year,
            aia.terms_id || '|' || att.name || '|' || att.description   AS payment_term,
            aia.payment_method_code                                     AS payment_method,
            CAST(NULL AS VARCHAR2(120))                                 AS adj_invoice_id,
            DECODE(aia.invoice_type_lookup_code, 'CREDIT', aia.description,
                   'DEBIT', aia.description, NULL)                     AS adj_reason_code,
            DECODE(aia.invoice_type_lookup_code, 'CREDIT', NULL,
                   'DEBIT', NULL, aia.description)                     AS description,
            -- vat_amount: tax recomputed on the DISCOUNTED net base (discount is taken
            -- before tax, so it reduces the taxable amount pro-rata at the invoice's
            -- effective rate r = total_tax / invoice_amount). Signed by transaction_type
            -- (positive for invoices type 1, negative for adjustments type 2).
            --   disc_net = amount_remaining - total_tax - discount_amount_available
            --   vat'     = disc_net * r
            TO_CHAR(DECODE(aia.invoice_type_lookup_code, 'CREDIT', -1, 'DEBIT', -1, 1)
                    * (apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                       - NVL(apsa.discount_amount_available, 0))
                    * CASE WHEN NVL(aia.invoice_amount, 0) = 0 THEN 0
                           ELSE NVL(aia.total_tax_amount, 0) / aia.invoice_amount END) AS vat_amount,
            -- gross/net vat, both after discount:
            --   netvat   = disc_net (amount excl tax, discount removed)
            --   grossvat = disc_net + vat' (amount incl the recomputed tax)
            TO_CHAR((apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                     - NVL(apsa.discount_amount_available, 0))
                    * (1 + CASE WHEN NVL(aia.invoice_amount, 0) = 0 THEN 0
                                ELSE NVL(aia.total_tax_amount, 0) / aia.invoice_amount END)) AS amount_grossvat,
            TO_CHAR(apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                    - NVL(apsa.discount_amount_available, 0))           AS amount_netvat,
            CAST(NULL AS VARCHAR2(50))                                  AS vat_to_be_discounted,
            haou.name                                                   AS buyer_name,
            loc.address_line_1 || ' ' || loc.address_line_2 || ' ' || loc.address_line_3
                  || ' ' || loc.town_or_city || ' ' || loc.region_2 || ' '
                  || loc.postal_code || ' ' || loc.country              AS buyer_address,
            reg.registration_number                                    AS buyer_tax_id,
            aia.payment_currency_code                                  AS local_currency_key,
            TO_CHAR(NVL(aia.payment_cross_rate, 1))                    AS local_currency_rate,
            -- local-currency net amount = discounted net base * cross rate
            TO_CHAR((apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                     - NVL(apsa.discount_amount_available, 0)) * NVL(aia.payment_cross_rate, 1)) AS local_currency_original_inv_amount,
            -- local-currency VAT = recomputed discounted tax * cross rate (0 for US)
            TO_CHAR(DECODE(loc.country, 'US', 0,
                    (apsa.amount_remaining - NVL(aia.total_tax_amount, 0)
                     - NVL(apsa.discount_amount_available, 0))
                    * CASE WHEN NVL(aia.invoice_amount, 0) = 0 THEN 0
                           ELSE NVL(aia.total_tax_amount, 0) / aia.invoice_amount END
                    * NVL(aia.payment_cross_rate, 1))) AS local_currency_original_vat,
            CAST(NULL AS VARCHAR2(60))                                 AS market_type,
            CASE WHEN aia.po_header_id IS NOT NULL
                 THEN aia.org_id || '|' || sup.vendor_id || '|' || site.vendor_site_id || '|' || aia.po_header_id
                 ELSE NULL END                                         AS po_id,
            -- missing_bank_details_flag: 'Y' if no active external bank account for the payee party
            CASE WHEN NOT EXISTS (
                    SELECT 1
                    FROM   iby_external_payees_all iep
                    JOIN   iby_pmt_instr_uses_all  ipiu ON ipiu.ext_pmt_party_id = iep.ext_payee_id
                    JOIN   iby_ext_bank_accounts   ieba ON ieba.ext_bank_account_id = ipiu.instrument_id
                    WHERE  iep.payee_party_id = sup.party_id )
                 THEN 'Y' ELSE 'N' END                                 AS missing_bank_details_flag,
            haou.name                                                  AS erp_legal_entity,
            CAST(NULL AS VARCHAR2(50))                                 AS erp_reference_number,
            TO_CHAR(sup.vendor_id)                                     AS erp_vendor_id,
            ( SELECT MAX(zl.tax_rate_code)
              FROM   zx_lines zl
              WHERE  zl.trx_id = aia.invoice_id )                      AS erp_tax_code,
            att.name                                                   AS erp_payment_term,
            att.description                                            AS erp_payment_term_desc,
            po_att.name                                                AS erp_po_payment_term,
            po_att.description                                         AS erp_po_payment_term_desc,
            dstr(aia.terms_date)                                       AS erp_terms_date,
            dstr(apsa.due_date)                                        AS erp_net_due_date,
            TO_CHAR(aia.invoice_amount)                                AS erp_invoice_amount,
            CAST(NULL AS VARCHAR2(50))                                 AS erp_discount_base_amount,
            TO_CHAR(NVL(apsa.discount_amount_available, 0))            AS erp_cash_discount_amount,
            TO_CHAR(aia.remit_to_supplier_id)                          AS erp_payee,
            TO_CHAR(site.vendor_site_id)                               AS erp_vendor_site_id,
            site.vendor_site_code                                      AS erp_vendor_site_code,
            TO_CHAR(aia.invoice_id)                                    AS erp_invoice_id,
            aia.invoice_num                                            AS erp_invoice_num,
            aia.pay_group_lookup_code                                 AS erp_pay_group,
            CAST(NULL AS VARCHAR2(50))                                 AS erp_sup_pay_priority,
            -- erp_tax_rate: tax as a fraction of taxable base (EBS: total_tax / amount_before_cash_disc)
            TO_CHAR(CASE WHEN NVL(aia.invoice_amount, 0) = 0 THEN 0
                         ELSE NVL(aia.total_tax_amount, 0) / aia.invoice_amount END) AS erp_tax_rate,
            aia.invoice_type_lookup_code                              AS erp_doc_type,
            haou.name                                                 AS erp_business_unit,
            sup.segment1                                             AS erp_supplier_number,
            -- erp_purpose_payment: pre-defined purpose code for cross-border bank
            -- payments. No mirror source; client to supply mapping logic. TODO_VERIFY.
            sup.vendor_type_lookup_code                            AS erp_purpose_payment,
            'invoice'                                                AS erp_burst_id
        FROM   ap_invoices_all           aia
        JOIN   ap_payment_schedules_all  apsa ON apsa.invoice_id = aia.invoice_id
        JOIN   poz_suppliers_v           sup  ON sup.vendor_id = aia.vendor_id
        JOIN   poz_supplier_sites_all_m  site ON site.vendor_site_id = aia.vendor_site_id
                                             AND site.vendor_id = sup.vendor_id
        JOIN   ap_terms_tl               att  ON att.term_id = aia.terms_id
                                             AND att.language = 'US'
        JOIN   hr_all_organization_units haou ON haou.organization_id = aia.org_id
        LEFT   JOIN hr_locations_all     loc  ON loc.location_id = haou.location_id
        LEFT   JOIN po_headers_all       poh  ON poh.po_header_id = aia.po_header_id
        LEFT   JOIN ap_terms_tl          po_att ON po_att.term_id = poh.terms_id
                                             AND po_att.language = 'US'
        LEFT   JOIN zx_party_tax_profile ptp  ON ptp.party_id = haou.organization_id  -- TODO_VERIFY buyer LE->party linkage in mirror
        LEFT   JOIN zx_registrations     reg  ON reg.party_tax_profile_id = ptp.party_tax_profile_id
        WHERE  1 = 1
        -- unpaid invoice only (EBS: aia.payment_status_flag='N')
        AND    aia.payment_status_flag = 'N'
        -- approval: APPROVAL_STATUS reproduces AP_INVOICES_PKG.Get_Approval_Status (see header)
        AND    aia.approval_status IN ('APPROVED', 'NOT REQUIRED')
        -- workflow approval: only send invoices the approval workflow has cleared.
        -- Accept-list (not an exclude-list): anything not explicitly workflow-approved
        -- is dropped, so rejected / in-flight / unapproved invoices never go out.
        AND    aia.wfapproval_status IN ('WFAPPROVED', 'NOT REQUIRED', 'MANUALLY APPROVED')
        -- not cancelled
        AND    aia.cancelled_date IS NULL
        -- exclude factoring suppliers via third-party payment relationships:
        -- if ANY active site of this supplier has a row in POZ_SUP_THIRDPARTY_
        -- PAYMENT_REL, the supplier factors its receivables, so NONE of its
        -- invoices (across all its sites) may be offered for acceleration.
        -- Supplier-wide (correlated on sup.vendor_id); only active sites count
        -- (inactive_date null or future) so a long-closed site can't bar forever.
        AND    NOT EXISTS (
                   SELECT 1
                   FROM   poz_sup_thirdparty_payment_rel tpp
                   JOIN   poz_supplier_sites_all_m        s_tpp
                          ON  s_tpp.vendor_site_id = tpp.vendor_site_id
                   WHERE  s_tpp.vendor_id = sup.vendor_id
                   AND    ( s_tpp.inactive_date IS NULL
                            OR s_tpp.inactive_date > TRUNC(SYSDATE) ) )
        -- not a prepayment application
        AND    NVL(aia.pay_group_lookup_code, 'X') <> 'C2FO'
        -- supplier / site not on payment hold (EBS checked sup + site; mirror carries flags on site)
        AND    NVL(site.hold_all_payments_flag, 'N') = 'N'
        AND    NVL(site.hold_flag, 'N') = 'N'
        -- installment not on hold
        AND    NVL(apsa.hold_flag, 'N') = 'N'
        -- installment has value to accelerate (replaces the EBS non-zero-ITEM-line
        -- check; amount_remaining is the installment amount actually emitted as the
        -- file 'amount', so gating on it needs no AP_INVOICE_LINES_ALL feed)
        AND    NVL(apsa.amount_remaining, 0) <> 0
        -- no unreleased holds on the invoice
        AND    NOT EXISTS ( SELECT 1 FROM ap_holds_all aha
                            WHERE  aha.invoice_id = aia.invoice_id
                            AND    aha.release_lookup_code IS NULL )
        -- buyer BU must be in the C2FO scope list passed by OIC (p_bu_list).
        -- NULL list (l_bu_wrap IS NULL) => no BU restriction (all BUs in scope).
        AND    ( l_bu_wrap IS NULL
                 OR INSTR(l_bu_wrap, ',' || haou.name || ',') > 0 )
        -- exclude every invoice of any supplier that has ANY active supplier site whose
        -- PAY_GROUP_LOOKUP_CODE is in the OIC list (p_exclude_pay_groups) -- OR whose
        -- pay group is NULL. NULL list (l_pg_wrap IS NULL) => exclude none.
        -- Supplier-wide (correlated on sup.vendor_id, across all that supplier's sites),
        -- NOT limited to the invoice's own pay group or its own site. Only active sites count
        -- (INACTIVE_DATE null or in the future) so a long-closed site doesn't bar a supplier
        -- forever. A site with a NULL pay group ALWAYS bars the supplier whenever an exclude
        -- list is active (INSTR can't match NULL, so it is tested explicitly). TRIM matches
        -- list_wrap's trimmed tokens. Mirrors the payment-term filter below.
        AND    ( l_pg_wrap IS NULL
                 OR NOT EXISTS (
                        SELECT 1
                        FROM   poz_supplier_sites_all_m  s_pg
                        WHERE  s_pg.vendor_id = sup.vendor_id
                        AND s_pg.vendor_site_id=site.vendor_site_id
                        AND    ( s_pg.inactive_date IS NULL
                                 OR s_pg.inactive_date > TRUNC(SYSDATE) )
                        AND    ( s_pg.pay_group_lookup_code IS NULL
                                 OR INSTR(l_pg_wrap, ',' || TRIM(s_pg.pay_group_lookup_code) || ',') > 0 ) ) )
        -- exclude every invoice of any supplier that has ANY active supplier site whose
        -- payment-term NAME is in the OIC list (p_exclude_payment_terms); NULL => exclude none.
        -- Supplier-wide (correlated on sup.vendor_id, across all that supplier's sites),
        -- NOT limited to the invoice's own term or its own site. Only active sites count
        -- (INACTIVE_DATE null or in the future) so a long-closed site doesn't bar a supplier
        -- forever. TRIM matches list_wrap's trimmed tokens.
        AND  (  ( l_pt_wrap IS NULL
                 OR NOT EXISTS (
                        SELECT 1
                        FROM   poz_supplier_sites_all_m  s_pt
                        JOIN   ap_terms_tl               t_pt
                               ON  t_pt.term_id  = s_pt.terms_id
                               AND t_pt.language = 'US'
                        WHERE  s_pt.vendor_id = sup.vendor_id
                        AND    ( s_pt.inactive_date IS NULL
                                 OR s_pt.inactive_date > TRUNC(SYSDATE) )
                        AND    INSTR(l_pt_wrap, ',' || TRIM(t_pt.name) || ',') > 0 ) ) 
                        -- or the assigned flag on the supplier is set to Y (assigned to a factor)
                        OR sup.attribute6='Y')
        -- exclude supplier vendor types OIC named (p_exclude_vendor_types); NULL => exclude none.
        -- TRIM matches list_wrap's trimmed tokens; a row is dropped when the supplier's
        -- vendor_type_lookup_code IS in the list.
        AND    ( l_vt_wrap IS NULL
                 OR INSTR(l_vt_wrap, ',' || TRIM(sup.vendor_type_lookup_code) || ',') = 0 )
        -- include-only vendor numbers (p_vendor_numbers = supplier segment1);
        -- NULL => all vendors. TRIM matches list_wrap's trimmed tokens.
        AND    ( l_vn_wrap IS NULL
                 OR INSTR(l_vn_wrap, ',' || TRIM(sup.segment1) || ',') > 0 )
        -- include-only invoice numbers (p_invoice_nums); NULL => all invoices.
        AND    ( l_in_wrap IS NULL
                 OR INSTR(l_in_wrap, ',' || TRIM(aia.invoice_num) || ',') > 0 )
        -- invoice type: exclude expense report / prepayment; must be in the C2FO type lookup
        AND    aia.invoice_type_lookup_code NOT IN ('EXPENSE REPORT', 'PREPAYMENT')
        AND    aia.invoice_type_lookup_code IN ( SELECT lookup_code FROM fnd_lookup_values_vl
                                                 WHERE  lookup_type = c_inv_type_lkp
                                                 AND    enabled_flag = 'Y'
                                                 AND    SYSDATE BETWEEN NVL(start_date_active, SYSDATE)
                                                                    AND NVL(end_date_active, SYSDATE) )
        -- date-range params (open-ended when NULL)
        AND    aia.invoice_date BETWEEN NVL(p_invoice_date_from, aia.invoice_date)
                                    AND NVL(p_invoice_date_to,   aia.invoice_date)
        AND    apsa.due_date    BETWEEN NVL(p_pay_due_date_from, apsa.due_date)
                                    AND NVL(p_pay_due_date_to,   apsa.due_date)
        -- Exclude invoices whose invoice_date or terms_date is in the future.
        -- A future terms_date drives a future-anchored due date that the C2FO
        -- due-date upsert cannot write back (Fusion 400s on the upsert), so such
        -- invoices must never be sent out in the first place.
        AND    aia.invoice_date <= TRUNC(SYSDATE)
        AND    NVL(aia.terms_date, aia.invoice_date) <= TRUNC(SYSDATE)
        -- Future-due installments PLUS past-due ones back to the cutoff. The EBS
        -- rule was apsa.due_date > SYSDATE (future only); we now also send overdue
        -- invoices, but bound how far back by p_max_past_years so ancient overdue
        -- rows are excluded. NULL/<=0 => no lower bound (all past-due included).
        AND    (l_due_floor IS NULL OR apsa.due_date > l_due_floor)
        -- TODO_VERIFY: EBS also required assa.pay_site_flag='Y'. POZ_SUPPLIER_SITES_ALL_M
        --   in the mirror has no pay_site_flag column - add it to the mirror + this
        --   filter if pay-site restriction is required.
        ;

        TYPE t_inv_tab IS TABLE OF c_inv%ROWTYPE INDEX BY PLS_INTEGER;
        l_rows  t_inv_tab;
    BEGIN
        o_count := 0;
        OPEN c_inv;
        LOOP
            FETCH c_inv BULK COLLECT INTO l_rows LIMIT c_bulk_limit;
            EXIT WHEN l_rows.COUNT = 0;

            FORALL i IN 1 .. l_rows.COUNT
                INSERT INTO lws_ob_invoice (
                    k_invoice_id, k_payment_num, company_id, division_id, invoice_id,
                    amount, currency, payment_due_date, transaction_type, transaction_date,
                    posting_date, voucher_id, voucher_line_id, fiscal_year, payment_term,
                    payment_method, adj_invoice_id, adj_reason_code, description,
                    vat_amount, amount_grossvat, amount_netvat, vat_to_be_discounted, buyer_name,
                    buyer_address, buyer_tax_id, local_currency_key, local_currency_rate,
                    local_currency_original_inv_amount, local_currency_original_vat,
                    market_type, po_id, missing_bank_details_flag, erp_legal_entity,
                    erp_reference_number, erp_vendor_id, erp_tax_code, erp_payment_term,
                    erp_payment_term_desc, erp_po_payment_term, erp_po_payment_term_desc,
                    erp_terms_date, erp_net_due_date, erp_invoice_amount,
                    erp_discount_base_amount, erp_cash_discount_amount, erp_payee,
                    erp_vendor_site_id, erp_vendor_site_code, erp_invoice_id,
                    erp_invoice_num, erp_pay_group,
                    erp_sup_pay_priority, erp_tax_rate, erp_doc_type, erp_business_unit,
                    erp_supplier_number, erp_purpose_payment, erp_burst_id
                ) VALUES (
                    l_rows(i).k_invoice_id, l_rows(i).k_payment_num, l_rows(i).company_id,
                    l_rows(i).division_id, l_rows(i).invoice_id, l_rows(i).amount,
                    l_rows(i).currency, l_rows(i).payment_due_date, l_rows(i).transaction_type,
                    l_rows(i).transaction_date, l_rows(i).posting_date, l_rows(i).voucher_id,
                    l_rows(i).voucher_line_id, l_rows(i).fiscal_year, l_rows(i).payment_term,
                    l_rows(i).payment_method, l_rows(i).adj_invoice_id, l_rows(i).adj_reason_code,
                    l_rows(i).description, l_rows(i).vat_amount, l_rows(i).amount_grossvat, l_rows(i).amount_netvat,
                    l_rows(i).vat_to_be_discounted, l_rows(i).buyer_name, l_rows(i).buyer_address,
                    l_rows(i).buyer_tax_id, l_rows(i).local_currency_key, l_rows(i).local_currency_rate,
                    l_rows(i).local_currency_original_inv_amount, l_rows(i).local_currency_original_vat,
                    l_rows(i).market_type, l_rows(i).po_id, l_rows(i).missing_bank_details_flag,
                    l_rows(i).erp_legal_entity, l_rows(i).erp_reference_number, l_rows(i).erp_vendor_id,
                    l_rows(i).erp_tax_code, l_rows(i).erp_payment_term, l_rows(i).erp_payment_term_desc,
                    l_rows(i).erp_po_payment_term, l_rows(i).erp_po_payment_term_desc,
                    l_rows(i).erp_terms_date, l_rows(i).erp_net_due_date, l_rows(i).erp_invoice_amount,
                    l_rows(i).erp_discount_base_amount, l_rows(i).erp_cash_discount_amount,
                    l_rows(i).erp_payee, l_rows(i).erp_vendor_site_id, l_rows(i).erp_vendor_site_code,
                    l_rows(i).erp_invoice_id, l_rows(i).erp_invoice_num, l_rows(i).erp_pay_group,
                    l_rows(i).erp_sup_pay_priority, l_rows(i).erp_tax_rate, l_rows(i).erp_doc_type,
                    l_rows(i).erp_business_unit, l_rows(i).erp_supplier_number,
                    l_rows(i).erp_purpose_payment, l_rows(i).erp_burst_id
                );

            o_count := o_count + l_rows.COUNT;
        END LOOP;
        CLOSE c_inv;
        COMMIT;
    END extract_invoices;

    --====================================================================
    -- ORGANIZATION EXTRACT  (one row per supplier site present in invoice out)
    --====================================================================
    PROCEDURE extract_organizations ( o_count OUT NUMBER ) IS
    BEGIN
        INSERT INTO lws_ob_organization (
            k_org_id, k_vendor_id, k_vendor_site_id, k_party_site_id, company_id, company_name,
            address_1, address_2, city, state, postal_code, country,
            reserve_percentage, reserve_amount, reserve_invoice_priority,
            reserve_before_adjustments, tax_id, pan_number, gstin_number,
            bank_acct_country, missing_bank_details, incorporated_country,
            account_group, industry_code, enterprise_type, payment_term,
            payment_term_desc, erp_burst_id
        )
        -- Driven off the DISTINCT company_id (org|vendor|site) actually emitted in
        -- the invoice output, so MOAC multi-BU sites get one org row per BU.
        -- The address is the site's OWN address: join poz_supplier_address_v on the
        -- site's party_site_id (not vendor_id), so each org row carries exactly the
        -- address of the paid site. party_site_id is thus determined by
        -- vendor_site_id, making (org,vendor,site,party_site) unique per row.
        SELECT
            keys.org_id, keys.vendor_id, keys.vendor_site_id, site.party_site_id,
            keys.org_id || '|' || keys.vendor_id || '|' || keys.vendor_site_id,
            sup.vendor_name,
            addr.address1, addr.address2, addr.city,
            addr.state, addr.postal_code, addr.country,
            NULL, NULL, NULL, NULL,
            ( SELECT MAX(reg.registration_number)
              FROM   zx_party_tax_profile ptp
              JOIN   zx_registrations reg ON reg.party_tax_profile_id = ptp.party_tax_profile_id
              WHERE  ptp.party_id = sup.party_id ),
            NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
            att.name, att.description,
            'org'
        FROM   ( SELECT DISTINCT
                     TO_NUMBER(SUBSTR(company_id, 1, INSTR(company_id, '|', 1, 1) - 1))                                  AS org_id,
                     TO_NUMBER(SUBSTR(company_id, INSTR(company_id, '|', 1, 1) + 1,
                                      INSTR(company_id, '|', 1, 2) - INSTR(company_id, '|', 1, 1) - 1))                   AS vendor_id,
                     TO_NUMBER(SUBSTR(company_id, INSTR(company_id, '|', 1, 2) + 1))                                      AS vendor_site_id
                 FROM lws_ob_invoice ) keys
        JOIN   poz_supplier_sites_all_m site ON site.vendor_site_id = keys.vendor_site_id
                                            AND site.vendor_id      = keys.vendor_id
        JOIN   poz_suppliers_v          sup  ON sup.vendor_id = keys.vendor_id
        -- the site's own address (party_site_id on the site). The address view has
        -- no PK and holds exact-duplicate rows per (vendor_id, party_site_id), so
        -- DISTINCT collapses them to one row per key to keep the org grain unique.
        LEFT   JOIN ( SELECT DISTINCT vendor_id, party_site_id,
                             address1, address2, city, state, postal_code, country
                      FROM   poz_supplier_address_v ) addr
                 ON addr.vendor_id     = keys.vendor_id
                AND addr.party_site_id = site.party_site_id
        LEFT   JOIN ap_terms_tl         att  ON att.term_id = site.terms_id AND att.language = 'US';

        o_count := SQL%ROWCOUNT;
        COMMIT;
    END extract_organizations;

    --====================================================================
    -- USER EXTRACT  (supplier contacts for the sites in the invoice output)
    --====================================================================
    PROCEDURE extract_users ( o_count OUT NUMBER ) IS
    BEGIN
        INSERT INTO lws_ob_user (
            k_org_id, k_vendor_id, k_vendor_site_id, k_contact_party_id,
            company_id, division_id,
            email_address, first_name, last_name, title, phone_number,
            address_1, address_2, city, state, postal_code, country, erp_burst_id
        )
        -- Decision 8: drive off the DISTINCT (org_id,vendor_id,vendor_site_id)
        -- keys actually emitted to the ORGANIZATION output, so a multi-BU site
        -- gets one user row per BU. All active/enabled supplier contacts are
        -- emitted (contact.party_id is in the key). email/phone/address are each
        -- collapsed to ONE value via scalar subqueries so contact points /
        -- addresses do not multiply the user rows. The site/address/relationship
        -- joins can still yield >1 row for the same PK tuple, so ROW_NUMBER
        -- collapses to exactly one deterministic row per
        -- (k_org_id, k_vendor_id, k_vendor_site_id, k_contact_party_id).
        SELECT k_org_id, k_vendor_id, k_vendor_site_id, k_contact_party_id,
               company_id, division_id,
               email_address, first_name, last_name, title, phone_number,
               address_1, address_2, city, state, postal_code, country, erp_burst_id
        FROM (
            SELECT
                keys.k_org_id, keys.k_vendor_id, keys.k_vendor_site_id,
                contact.party_id AS k_contact_party_id,
                keys.k_org_id || '|' || keys.k_vendor_id || '|' || keys.k_vendor_site_id AS company_id,
                CAST(NULL AS VARCHAR2(60)) AS division_id,
                -- most recent ACTIVE (status 'A') email: order active points by last
                -- update (then creation, then id) descending and take the first, so
                -- the single emitted value is the latest active one, not MAX(email).
                ( SELECT email_address FROM (
                      SELECT cp.email_address
                      FROM   hz_contact_points cp
                      WHERE  cp.owner_table_name   = 'HZ_PARTIES'
                      AND    cp.owner_table_id     = contact.party_id
                      AND    cp.contact_point_type = 'EMAIL'
                      AND    NVL(cp.status, 'A')   = 'A'
                      ORDER  BY cp.last_update_date DESC NULLS LAST,
                                cp.creation_date    DESC NULLS LAST,
                                cp.contact_point_id DESC )
                  WHERE ROWNUM = 1 ) AS email_address,
                contact.person_first_name AS first_name, contact.person_last_name AS last_name,
                contact.person_title AS title,
                -- most recent ACTIVE (status 'A') phone, same ordering as email.
                ( SELECT phone FROM (
                      SELECT cp.phone_area_code || ' ' || cp.phone_number AS phone
                      FROM   hz_contact_points cp
                      WHERE  cp.owner_table_name   = 'HZ_PARTIES'
                      AND    cp.owner_table_id     = contact.party_id
                      AND    cp.contact_point_type = 'PHONE'
                      AND    NVL(cp.status, 'A')   = 'A'
                      ORDER  BY cp.last_update_date DESC NULLS LAST,
                                cp.creation_date    DESC NULLS LAST,
                                cp.contact_point_id DESC )
                  WHERE ROWNUM = 1 ) AS phone_number,
                addr.address1 AS address_1, addr.address2 AS address_2, addr.city,
                addr.state, addr.postal_code, addr.country,
                'user' AS erp_burst_id,
                ROW_NUMBER() OVER (
                    PARTITION BY keys.k_org_id, keys.k_vendor_id, keys.k_vendor_site_id, contact.party_id
                    ORDER BY addr.party_site_id NULLS LAST ) AS rn
            FROM   ( SELECT DISTINCT k_org_id, k_vendor_id, k_vendor_site_id
                     FROM   lws_ob_organization ) keys
            JOIN   poz_supplier_sites_all_m site    ON site.vendor_id      = keys.k_vendor_id
                                                   AND site.vendor_site_id = keys.k_vendor_site_id
            JOIN   poz_suppliers_v          sup     ON sup.vendor_id = keys.k_vendor_id
            -- supplier-contact relationships (active-status filtering is applied at the
            -- BICC extract, so STATUS is not populated in the mirror and is not tested here)
            JOIN   hz_relationships         rel     ON rel.object_id = sup.party_id
                                                   AND SYSDATE BETWEEN NVL(rel.start_date, SYSDATE) AND NVL(rel.end_date, SYSDATE)
            -- contact party
            JOIN   hz_parties               contact ON contact.party_id = rel.subject_id
                                                   AND contact.person_last_name IS NOT NULL
            -- one address per user, via the site's own party_site_id. The address
            -- view has no PK and holds exact-duplicate rows per (vendor_id,
            -- party_site_id), so DISTINCT collapses them to one row per key.
            LEFT   JOIN ( SELECT DISTINCT vendor_id, party_site_id,
                                 address1, address2, city, state, postal_code, country
                          FROM   poz_supplier_address_v ) addr
                     ON addr.vendor_id     = site.vendor_id
                    AND addr.party_site_id = site.party_site_id
        )
        WHERE rn = 1;

        o_count := SQL%ROWCOUNT;
        COMMIT;
    END extract_users;

    --====================================================================
    -- FEEDBACK EXTRACT
    -- Reports the payment status of AWARDED invoices in the days after award.
    -- Grain: one row per awarded invoice installment.
    -- Driver: LWS_C2FO_AWARD_DATA (the inbound award landing table) filtered to
    --   RECORD_STATUS='Y' - only fully-processed awards, retained across batches.
    --   Its resolved keys (ERP_INVOICE_ID / PAYMENT_NUM) join straight to the original
    --   invoice + installment, and CM_INVOICE_ID gives adjusted_invoice_id with no
    --   invoice_num string surgery. This replaces the BIP report's CM-EXISTS filter
    --   (which the report only used because it had no award table to drive from).
    -- Payments are LEFT-joined (an awarded-but-not-yet-paid invoice still reports,
    --   as status 'Unpaid'). IBY_PAYMENTS_ALL is not in the mirror, so the payment
    --   initiation date/document come from AP_CHECKS_ALL (TODO_VERIFY vs IBY).
    --====================================================================
    PROCEDURE extract_feedback (
        p_report_days IN  NUMBER  DEFAULT NULL,
        o_count       OUT NUMBER
    ) IS
        CURSOR c_fb IS
        SELECT
            aia.invoice_id                                              AS k_invoice_id,
            apsa.payment_num                                            AS k_payment_num,
            aia.org_id || '|' || sup.vendor_id || '|' || site.vendor_site_id AS company_id,
            CAST(NULL AS VARCHAR2(60))                                  AS division_id,
            awd.invoice_id                                              AS invoice_id,
            -- amount = invoice amount net of available discount and tax
            TO_CHAR(NVL(aia.invoice_amount, 0)
                    - NVL(apsa.discount_amount_available, 0)
                    - NVL(aia.total_tax_amount, 0))                     AS amount,
            aia.invoice_currency_code                                   AS currency,
            dstr(apsa.due_date)                                         AS payment_due_date,
            DECODE(aia.invoice_type_lookup_code, 'STANDARD', '1', '2')  AS transaction_type,
            TO_CHAR(aia.invoice_id)                                     AS voucher_id,
            TO_CHAR(aia.invoice_date, 'YYYY')                           AS fiscal_year,
            TO_CHAR(awd.cm_invoice_id)                                  AS adjusted_invoice_id,
            TO_CHAR(NVL(aipa.amount, 0))                                AS expected_amount_paid,
            aia.terms_id || '|' || att.name || '|' || att.description   AS payment_term,
            aia.payment_method_code                                     AS payment_method,
            -- IBY_PAYMENTS_ALL held; take the clearing-document date/number from
            -- AP_CHECKS_ALL instead. TODO_VERIFY against the client's IBY source.
            dstr(aca.check_date)                                        AS payment_initiation_date,
            aca.check_number                                            AS payment_initiation_document,
            DECODE(aia.payment_status_flag, 'N', 'Unpaid', 'Paid')      AS status,
            CAST(NULL AS VARCHAR2(120))                                 AS fund_type,
            CAST(NULL AS VARCHAR2(120))                                 AS fund_partner,
            'feedback'                                                  AS erp_burst_id
        FROM   lws_c2fo_award_data       awd
        JOIN   ap_invoices_all           aia  ON aia.invoice_id = awd.erp_invoice_id
        JOIN   ap_payment_schedules_all  apsa ON apsa.invoice_id = aia.invoice_id
                                             AND apsa.payment_num = awd.payment_num
        JOIN   poz_suppliers_v           sup  ON sup.vendor_id = aia.vendor_id
        JOIN   poz_supplier_sites_all_m  site ON site.vendor_site_id = aia.vendor_site_id
                                             AND site.vendor_id = sup.vendor_id
        JOIN   ap_terms_tl               att  ON att.term_id = aia.terms_id
                                             AND att.language = 'US'
        -- payment detail (may be absent for an awarded-but-unpaid invoice)
        LEFT   JOIN ap_invoice_payments_all aipa ON aipa.invoice_id = aia.invoice_id
        LEFT   JOIN ap_checks_all           aca  ON aca.check_id = aipa.check_id
        -- RECORD_STATUS='Y' is a successfully-processed award (replaces the old
        -- staging table's PROCESS_FLAG); report only completed awards.
        WHERE  awd.record_status = 'Y'
        and awd.reversed_flag='N'
        AND    NVL(aia.invoice_amount, 0) <> 0
        -- approval: APPROVAL_STATUS reproduces AP_INVOICES_PKG.Get_Approval_Status;
        -- the BIP report excluded unapproved states, so keep only approved ones.
        AND    aia.approval_status NOT IN ('NEVER APPROVED', 'NEEDS REAPPROVAL', 'UNAPPROVED')
        -- report window: every award not yet paid (no check_date), plus awards paid
        -- within p_report_days of today. NULL p_report_days => no upper bound (all).
        -- aca.check_date is the only payment date in the mirror (IBY not mirrored).
        AND    ( aca.check_date IS NULL
                 OR p_report_days IS NULL
                 OR aca.check_date >= TRUNC(SYSDATE) - p_report_days )
        ;

        TYPE t_fb_tab IS TABLE OF c_fb%ROWTYPE INDEX BY PLS_INTEGER;
        l_rows  t_fb_tab;
    BEGIN
        o_count := 0;
        OPEN c_fb;
        LOOP
            FETCH c_fb BULK COLLECT INTO l_rows LIMIT c_bulk_limit;
            EXIT WHEN l_rows.COUNT = 0;

            FORALL i IN 1 .. l_rows.COUNT
                INSERT INTO lws_ob_feedback (
                    k_invoice_id, k_payment_num, company_id, division_id, invoice_id,
                    amount, currency, payment_due_date, transaction_type, voucher_id,
                    fiscal_year, adjusted_invoice_id, expected_amount_paid, payment_term,
                    payment_method, payment_initiation_date, payment_initiation_document,
                    status, fund_type, fund_partner, erp_burst_id
                ) VALUES (
                    l_rows(i).k_invoice_id, l_rows(i).k_payment_num, l_rows(i).company_id,
                    l_rows(i).division_id, l_rows(i).invoice_id, l_rows(i).amount,
                    l_rows(i).currency, l_rows(i).payment_due_date, l_rows(i).transaction_type,
                    l_rows(i).voucher_id, l_rows(i).fiscal_year, l_rows(i).adjusted_invoice_id,
                    l_rows(i).expected_amount_paid, l_rows(i).payment_term, l_rows(i).payment_method,
                    l_rows(i).payment_initiation_date, l_rows(i).payment_initiation_document,
                    l_rows(i).status, l_rows(i).fund_type, l_rows(i).fund_partner,
                    l_rows(i).erp_burst_id
                );

            o_count := o_count + l_rows.COUNT;
        END LOOP;
        CLOSE c_fb;
        COMMIT;
    END extract_feedback;

    --====================================================================
    -- PO EXTRACT  (reconstructed from the EBS c_po_data cursor)
    -- DISABLED: the mirror lacks PO_LINES_ALL and several PO_HEADERS_ALL columns
    -- (amount, approved_date, authorization_status, closed_code, ship/receipt,
    -- buyer, warehouse). Re-enable this procedure, its spec declaration, and the
    -- driver call once the mirror is extended and the TODO_VERIFY items resolved.
    --====================================================================
    /*
    PROCEDURE extract_pos (
        p_po_date_from   IN  DATE,
        p_po_date_to     IN  DATE,
        o_count          OUT NUMBER
    ) IS
        l_from  DATE := NVL(p_po_date_from, ADD_MONTHS(SYSDATE, -120));
        l_to    DATE := NVL(p_po_date_to, SYSDATE);
    BEGIN
        INSERT INTO lws_ob_po (
            k_po_header_id, company_id, division_id, po_id, amount, currency,
            create_date, approved_date, ship_date, ship_orig_country, ship_orig_state,
            estimated_arrival_date, actual_arrival_date, supplier_country, company_code,
            warehouse_code, erp_org_id, erp_ponumber, erp_po_header_id, erp_supplier,
            erp_supplier_number, erp_vendor_id, erp_suppliersite, erp_vendor_site_id,
            erp_potype, erp_podate, erp_billto_loc, erp_buyer, erp_authorization_status,
            erp_terms, erp_closed_code, erp_ship_to_location_id, erp_burst_id
        )
        SELECT
            poh.po_header_id,
            site.org_id || '|' || site.vendor_id || '|' || site.vendor_site_id,
            NULL,
            poh.org_id || '|' || sup.vendor_id || '|' || site.vendor_site_id || '|' || poh.po_header_id,
            NULL,                                        -- amount: PO line total not in mirror (po_lines_all not staged) TODO_VERIFY
            poh.currency_code,
            dstr(poh.creation_date),
            NULL,                                        -- approved_date not in PO_HEADERS_ALL mirror TODO_VERIFY
            NULL, NULL, NULL, NULL, NULL,                -- shipment/receipt data (rcv_* not staged) TODO_VERIFY
            addr.country,
            haou.name,
            NULL,                                        -- warehouse_code (ship-to location) TODO_VERIFY
            TO_CHAR(poh.org_id),
            poh.segment1,
            TO_CHAR(poh.po_header_id),
            sup.vendor_name,
            sup.segment1,
            TO_CHAR(poh.vendor_id),
            site.vendor_site_code,
            TO_CHAR(site.vendor_site_id),
            poh.type_lookup_code,
            dstr(poh.creation_date),
            NULL,                                        -- bill-to location TODO_VERIFY
            NULL,                                        -- buyer (agent) not in mirror TODO_VERIFY
            NULL,                                        -- authorization_status not in mirror TODO_VERIFY
            att.name,
            NULL,                                        -- closed_code not in mirror TODO_VERIFY
            NULL,                                        -- ship_to_location_id not in mirror TODO_VERIFY
            'po'
        FROM   po_headers_all           poh
        JOIN   poz_suppliers_v          sup  ON sup.vendor_id = poh.vendor_id
        JOIN   poz_supplier_sites_all_m site ON site.vendor_site_id = poh.vendor_site_id
        LEFT   JOIN hr_all_organization_units haou ON haou.organization_id = poh.org_id
        LEFT   JOIN poz_supplier_address_v addr ON addr.vendor_id = site.vendor_id
                                               AND addr.party_site_id = site.party_site_id
        LEFT   JOIN ap_terms_tl         att  ON att.term_id = poh.terms_id AND att.language = 'US'
        WHERE  poh.type_lookup_code NOT IN ('RFQ', 'QUOTATION')
        AND    poh.org_id IN (
                   SELECT organization_id FROM hr_all_organization_units
                   WHERE  name IN ( SELECT meaning FROM fnd_lookup_values_vl
                                    WHERE  lookup_type = c_ou_lookup
                                    AND    enabled_flag = 'Y'
                                    AND    SYSDATE BETWEEN NVL(start_date_active, SYSDATE)
                                                       AND NVL(end_date_active, SYSDATE) ) )
        AND    poh.creation_date BETWEEN l_from AND l_to;
        -- NOTE: EBS filtered closed_code='OPEN' AND authorization_status='APPROVED'
        -- AND po line total > 0. Those columns/tables are not in the current mirror
        -- (PO_HEADERS_ALL lacks them; PO_LINES_ALL not staged). Flagged TODO_VERIFY
        -- above - extend the mirror + this filter once those are available.

        o_count := SQL%ROWCOUNT;
        COMMIT;
    END extract_pos;
    */

    --====================================================================
    -- FILE WRITER  (replaces the EBS UTL_FILE/FTP output stage)
    -- Reads each LWS_OB_* table, renders CSV (header + data rows), and writes
    -- to the OCI bucket via DBMS_CLOUD.PUT_OBJECT. Splits into numbered parts
    -- (_001, _002, ...) when a file would exceed p_max_mb (uncompressed).
    -- Each written part gets one LWS_OB_CONTROL row; row_count excludes header.
    --====================================================================

    -- Key/value config reader (COMMON group). Returns p_default when the row is
    -- absent/disabled; raises when a MANDATORY_FLAG='Y' row resolves to NULL so
    -- load_ob_config surfaces a precise missing-key error.
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

    FUNCTION load_ob_config RETURN BOOLEAN IS
    BEGIN
        g_ob_credential := cfg('COMMON', 'OBJ_STORAGE_CREDENTIALS');
        g_ob_namespace  := cfg('COMMON', 'OBJ_STORAGE_NAMESPACE');
        g_ob_uri        := cfg('COMMON', 'OBJ_URI');
        RETURN TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN FALSE;
    END load_ob_config;

    FUNCTION ob_object_uri (
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
    END ob_object_uri;

    --------------------------------------------------------------------------
    -- Write one CSV part's BLOB to the current destination. Bucket mode calls
    -- DBMS_CLOUD.PUT_OBJECT exactly as before; directory mode streams the BLOB to
    -- an ATP directory object via UTL_FILE in RAW mode. This is the single sink
    -- every writer path funnels through, so the split/control logic stays intact.
    --------------------------------------------------------------------------
    PROCEDURE emit_object (
        p_bucket_name IN VARCHAR2,
        p_folder_path IN VARCHAR2,
        p_object_name IN VARCHAR2,
        p_blob        IN BLOB
    ) IS
        l_fh      UTL_FILE.FILE_TYPE;
        l_len     INTEGER := DBMS_LOB.GETLENGTH(p_blob);
        l_off     INTEGER := 1;
        l_chunk   CONSTANT INTEGER := 32760;   -- < 32767 UTL_FILE line cap
        l_raw     RAW(32760);
    BEGIN
        IF g_dest = 'DIRECTORY' THEN
            -- open in byte mode so the CRLFs we already embedded are preserved as-is
            l_fh := UTL_FILE.FOPEN(g_dest_dir, p_object_name, 'wb', 32760);
            WHILE l_off <= l_len LOOP
                l_raw := DBMS_LOB.SUBSTR(p_blob, l_chunk, l_off);
                UTL_FILE.PUT_RAW(l_fh, l_raw, TRUE);
                l_off := l_off + l_chunk;
            END LOOP;
            UTL_FILE.FCLOSE(l_fh);
        ELSE
            DBMS_CLOUD.PUT_OBJECT(
                credential_name => g_ob_credential,
                object_uri      => ob_object_uri(p_bucket_name, p_folder_path, p_object_name),
                contents        => p_blob
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN IF UTL_FILE.IS_OPEN(l_fh) THEN UTL_FILE.FCLOSE(l_fh); END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE;
    END emit_object;

    FUNCTION get_local_file (
        p_file_name   IN  VARCHAR2,
        p_directory   IN  VARCHAR2 DEFAULT 'DATA_PUMP_DIR'
    ) RETURN BLOB IS
        l_bfile  BFILE := BFILENAME(p_directory, p_file_name);
        l_blob   BLOB;
        l_dst    INTEGER := 1;
        l_src    INTEGER := 1;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
        DBMS_LOB.FILEOPEN(l_bfile, DBMS_LOB.FILE_READONLY);
        IF DBMS_LOB.GETLENGTH(l_bfile) > 0 THEN
            DBMS_LOB.LOADBLOBFROMFILE(l_blob, l_bfile,
                DBMS_LOB.LOBMAXSIZE, l_dst, l_src);
        END IF;
        DBMS_LOB.FILECLOSE(l_bfile);
        RETURN l_blob;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN IF DBMS_LOB.FILEISOPEN(l_bfile) = 1 THEN DBMS_LOB.FILECLOSE(l_bfile); END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE;
    END get_local_file;

    FUNCTION file_lines (
        p_file_name   IN  VARCHAR2,
        p_directory   IN  VARCHAR2 DEFAULT 'DATA_PUMP_DIR'
    ) RETURN LWS_OB_LINE_TAB PIPELINED IS
        l_fh    UTL_FILE.FILE_TYPE;
        l_line  VARCHAR2(32767);
    BEGIN
        -- read mode with a 32767 line cap so wide CSV rows come back whole
        l_fh := UTL_FILE.FOPEN(p_directory, p_file_name, 'r', 32767);
        LOOP
            BEGIN
                UTL_FILE.GET_LINE(l_fh, l_line);
            EXCEPTION
                WHEN NO_DATA_FOUND THEN EXIT;   -- end of file
            END;
            PIPE ROW (l_line);
        END LOOP;
        UTL_FILE.FCLOSE(l_fh);
        RETURN;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN IF UTL_FILE.IS_OPEN(l_fh) THEN UTL_FILE.FCLOSE(l_fh); END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE;
    END file_lines;

    --------------------------------------------------------------------------
    -- Core generic writer: streams a REF CURSOR's rows into size-bounded CSV
    -- objects. The caller supplies the header line and a cursor whose SELECT
    -- list is ALREADY in file-column order and already csv_field()-escaped and
    -- comma-joined into a single VARCHAR2 per row (l_line). This keeps the
    -- split/flush logic in one place for every entity.
    --------------------------------------------------------------------------
    PROCEDURE write_entity (
        p_entity_base   IN  VARCHAR2,   -- e.g. buyer_invoice_20200817 (no part/ext)
        p_header        IN  VARCHAR2,
        p_cursor        IN  SYS_REFCURSOR,
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2,
        p_max_bytes     IN  NUMBER
    ) IS
        l_line       VARCHAR2(32767);
        l_buf        CLOB;
        l_part       PLS_INTEGER := 0;
        l_data_rows  PLS_INTEGER := 0;   -- data rows in the current part (excl header)
        l_bytes      NUMBER := 0;        -- running byte size of current part incl header
        l_hdr_bytes  NUMBER := LENGTHB(p_header) + 2;   -- header + CRLF
        l_line_bytes NUMBER;
        l_obj_name   VARCHAR2(200);

        -- ATP DBMS_CLOUD.PUT_OBJECT only accepts a BLOB for contents; the CSV is
        -- built as a CLOB, so convert to a UTF-8 (AL32UTF8) BLOB before each write.
        FUNCTION clob_to_blob (p_clob IN CLOB) RETURN BLOB IS
            l_blob      BLOB;
            l_dst_off   INTEGER := 1;
            l_src_off   INTEGER := 1;
            l_lang_ctx  INTEGER := DBMS_LOB.default_lang_ctx;
            l_warning   INTEGER;
        BEGIN
            DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
            DBMS_LOB.CONVERTTOBLOB(
                dest_lob     => l_blob,
                src_clob     => p_clob,
                amount       => DBMS_LOB.LOBMAXSIZE,
                dest_offset  => l_dst_off,
                src_offset   => l_src_off,
                blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
                lang_context => l_lang_ctx,
                warning      => l_warning
            );
            RETURN l_blob;
        END clob_to_blob;

        PROCEDURE flush_part IS
            l_blob  BLOB;
        BEGIN
            IF l_data_rows = 0 THEN
                RETURN;   -- nothing buffered; don't emit an empty part
            END IF;
            l_part := l_part + 1;
            l_obj_name := LOWER(p_entity_base) || '_'
                          || LPAD(TO_CHAR(l_part), 3, '0') || '.csv';
            l_blob := clob_to_blob(l_buf);
            emit_object(p_bucket_name, p_folder_path, l_obj_name, l_blob);
            DBMS_LOB.FREETEMPORARY(l_blob);
            -- control row per physical part; row_count = data rows (excl header)
            INSERT INTO lws_ob_control (file_name, row_count, erp_burst_id)
                VALUES (l_obj_name, TO_CHAR(l_data_rows), 'control');
        END flush_part;

        PROCEDURE start_part IS
        BEGIN
            DBMS_LOB.TRIM(l_buf, 0);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(p_header || CHR(13) || CHR(10)),
                                 p_header || CHR(13) || CHR(10));
            l_bytes     := l_hdr_bytes;
            l_data_rows := 0;
        END start_part;
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);
        start_part;

        LOOP
            FETCH p_cursor INTO l_line;
            EXIT WHEN p_cursor%NOTFOUND;

            l_line_bytes := LENGTHB(l_line) + 2;   -- + CRLF

            -- roll to a new part BEFORE writing this row if it would overflow,
            -- but only if the current part already holds at least one data row
            -- (a single row larger than the limit still gets its own part).
            IF l_data_rows > 0 AND (l_bytes + l_line_bytes) > p_max_bytes THEN
                flush_part;
                start_part;
            END IF;

            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_line || CHR(13) || CHR(10)),
                                 l_line || CHR(13) || CHR(10));
            l_bytes     := l_bytes + l_line_bytes;
            l_data_rows := l_data_rows + 1;
        END LOOP;
        CLOSE p_cursor;

        flush_part;   -- final part

        -- If the entity produced no rows at all, still emit a header-only file so
        -- C2FO's control reconciliation sees the expected file with row_count 0.
        IF l_part = 0 THEN
            l_obj_name := LOWER(p_entity_base) || '_001.csv';
            DBMS_LOB.TRIM(l_buf, 0);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(p_header || CHR(13) || CHR(10)),
                                 p_header || CHR(13) || CHR(10));
            DECLARE
                l_blob  BLOB;
            BEGIN
                l_blob := clob_to_blob(l_buf);
                emit_object(p_bucket_name, p_folder_path, l_obj_name, l_blob);
                DBMS_LOB.FREETEMPORARY(l_blob);
            END;
            INSERT INTO lws_ob_control (file_name, row_count, erp_burst_id)
                VALUES (l_obj_name, '0', 'control');
        END IF;

        DBMS_LOB.FREETEMPORARY(l_buf);
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN IF p_cursor%ISOPEN THEN CLOSE p_cursor; END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
            BEGIN DBMS_LOB.FREETEMPORARY(l_buf); EXCEPTION WHEN OTHERS THEN NULL; END;
            RAISE;
    END write_entity;

    PROCEDURE write_files_to_bucket (
        p_file_prefix   IN  VARCHAR2,
        p_bucket_name   IN  VARCHAR2,
        p_folder_path   IN  VARCHAR2 DEFAULT NULL,
        p_directory     IN  VARCHAR2 DEFAULT NULL,
        p_extract_po    IN  VARCHAR2 DEFAULT 'N',
        p_max_mb        IN  NUMBER   DEFAULT 200,
        o_status        OUT VARCHAR2,
        o_message       OUT VARCHAR2
    ) IS
        l_stamp     VARCHAR2(8) := TO_CHAR(TRUNC(SYSDATE), 'YYYYMMDD');
        l_max_bytes NUMBER := p_max_mb * 1024 * 1024;
        l_cur       SYS_REFCURSOR;
    BEGIN
        o_status := 'SUCCESS';

        -- Pick the destination: a bucket name wins; otherwise a directory means
        -- local-file mode. OCI config is only needed (and only loaded) for a bucket.
        IF p_bucket_name IS NOT NULL THEN
            g_dest     := 'BUCKET';
            IF NOT load_ob_config THEN
                o_status  := 'ERROR';
                o_message := 'Could not load OCI config from LWS_C2FO_CONFIG (COMMON group; missing mandatory key?)';
                RETURN;
            END IF;
        ELSIF p_directory IS NOT NULL THEN
            g_dest     := 'DIRECTORY';
            g_dest_dir := p_directory;
        ELSE
            o_status  := 'ERROR';
            o_message := 'No destination: supply either p_bucket_name or p_directory';
            RETURN;
        END IF;

        -- control table is rebuilt by this writer, so clear any prior rows
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_CONTROL';

        --------------------------------------------------------------- invoice
        OPEN l_cur FOR
            SELECT
                csv_field(company_id) ||','|| csv_field(division_id) ||','||
                csv_field(invoice_id) ||','|| csv_field(amount) ||','||
                csv_field(currency) ||','|| csv_field(payment_due_date) ||','||
                csv_field(transaction_type) ||','|| csv_field(transaction_date) ||','||
                csv_field(posting_date) ||','|| csv_field(voucher_id) ||','||
                csv_field(voucher_line_id) ||','|| csv_field(fiscal_year) ||','||
                csv_field(payment_term) ||','|| csv_field(payment_method) ||','||
                csv_field(adj_invoice_id) ||','|| csv_field(adj_reason_code) ||','||
                csv_field(description) ||','|| csv_field(vat_amount) ||','||
                csv_field(amount_grossvat) ||','|| csv_field(amount_netvat) ||','||
                csv_field(vat_to_be_discounted) ||','|| csv_field(buyer_name) ||','||
                csv_field(buyer_address) ||','|| csv_field(buyer_tax_id) ||','||
                csv_field(local_currency_key) ||','|| csv_field(local_currency_rate) ||','||
                csv_field(local_currency_original_inv_amount) ||','||
                csv_field(local_currency_original_vat) ||','|| csv_field(market_type) ||','||
                csv_field(po_id) ||','|| csv_field(missing_bank_details_flag) ||','||
                csv_field(erp_legal_entity) ||','|| csv_field(erp_reference_number) ||','||
                csv_field(erp_vendor_id) ||','|| csv_field(erp_tax_code) ||','||
                csv_field(erp_payment_term) ||','|| csv_field(erp_payment_term_desc) ||','||
                csv_field(erp_po_payment_term) ||','|| csv_field(erp_po_payment_term_desc) ||','||
                csv_field(erp_terms_date) ||','|| csv_field(erp_net_due_date) ||','||
                csv_field(erp_invoice_amount) ||','|| csv_field(erp_discount_base_amount) ||','||
                csv_field(erp_cash_discount_amount) ||','|| csv_field(erp_payee) ||','||
                csv_field(erp_vendor_site_id) ||','|| csv_field(erp_vendor_site_code) ||','||
                csv_field(erp_invoice_id) ||','|| csv_field(erp_invoice_num) ||','||
                csv_field(erp_pay_group) ||','|| csv_field(erp_sup_pay_priority) ||','||
                csv_field(erp_tax_rate) ||','|| csv_field(erp_doc_type) ||','||
                csv_field(erp_business_unit) ||','|| csv_field(erp_supplier_number) ||','||
                csv_field(erp_purpose_payment) ||','|| csv_field(erp_burst_id)
            FROM   lws_ob_invoice;

        write_entity(
            p_entity_base => p_file_prefix || '_invoice_' || l_stamp,
            p_header      => 'company_id,division_id,invoice_id,amount,currency,'
                           ||'payment_due_date,transaction_type,transaction_date,posting_date,'
                           ||'voucher_id,voucher_line_id,fiscal_year,payment_term,payment_method,'
                           ||'adj_invoice_id,adj_reason_code,description,vat_amount,amount_grossvat,'
                           ||'amount_netvat,vat_to_be_discounted,buyer_name,buyer_address,buyer_tax_id,'
                           ||'local_currency_key,local_currency_rate,local_currency_original_inv_amount,'
                           ||'local_currency_original_vat,market_type,po_id,missing_bank_details_flag,'
                           ||'erp_legal_entity,erp_reference_number,erp_vendor_id,erp_tax_code,'
                           ||'erp_payment_term,erp_payment_term_desc,erp_po_payment_term,'
                           ||'erp_po_payment_term_desc,erp_terms_date,erp_net_due_date,erp_invoice_amount,'
                           ||'erp_discount_base_amount,erp_cash_discount_amount,erp_payee,'
                           ||'erp_vendor_site_id,erp_vendor_site_code,erp_invoice_id,erp_invoice_num,'
                           ||'erp_pay_group,erp_sup_pay_priority,erp_tax_rate,erp_doc_type,'
                           ||'erp_business_unit,erp_supplier_number,erp_purpose_payment,erp_burst_id',
            p_cursor      => l_cur,
            p_bucket_name => p_bucket_name,
            p_folder_path => p_folder_path,
            p_max_bytes   => l_max_bytes
        );

        ----------------------------------------------------------- organization
        OPEN l_cur FOR
            SELECT
                csv_field(company_id) ||','|| csv_field(company_name) ||','||
                csv_field(address_1) ||','|| csv_field(address_2) ||','||
                csv_field(city) ||','|| csv_field(state) ||','||
                csv_field(postal_code) ||','|| csv_field(country) ||','||
                csv_field(reserve_percentage) ||','|| csv_field(reserve_amount) ||','||
                csv_field(reserve_invoice_priority) ||','|| csv_field(reserve_before_adjustments) ||','||
                csv_field(tax_id) ||','|| csv_field(pan_number) ||','||
                csv_field(gstin_number) ||','|| csv_field(bank_acct_country) ||','||
                csv_field(missing_bank_details) ||','|| csv_field(incorporated_country) ||','||
                csv_field(account_group) ||','|| csv_field(industry_code) ||','||
                csv_field(enterprise_type) ||','|| csv_field(payment_term) ||','||
                csv_field(payment_term_desc) ||','|| csv_field(erp_burst_id)
            FROM   lws_ob_organization
            ORDER  BY company_id;

        write_entity(
            p_entity_base => p_file_prefix || '_organization_' || l_stamp,
            p_header      => 'company_id,company_name,address_1,address_2,city,state,postal_code,'
                           ||'country,reserve_percentage,reserve_amount,reserve_invoice_priority,'
                           ||'reserve_before_adjustments,tax_id,pan_number,gstin_number,'
                           ||'bank_acct_country,missing_bank_details,incorporated_country,'
                           ||'account_group,industry_code,enterprise_type,payment_term,'
                           ||'payment_term_desc,erp_burst_id',
            p_cursor      => l_cur,
            p_bucket_name => p_bucket_name,
            p_folder_path => p_folder_path,
            p_max_bytes   => l_max_bytes
        );

        ------------------------------------------------------------------- user
        OPEN l_cur FOR
            SELECT
                csv_field(company_id) ||','|| csv_field(division_id) ||','||
                csv_field(email_address) ||','|| csv_field(first_name) ||','||
                csv_field(last_name) ||','|| csv_field(title) ||','||
                csv_field(phone_number) ||','|| csv_field(address_1) ||','||
                csv_field(address_2) ||','|| csv_field(city) ||','||
                csv_field(state) ||','|| csv_field(postal_code) ||','||
                csv_field(country) ||','|| csv_field(erp_burst_id)
            FROM   lws_ob_user
            ORDER  BY company_id, last_name, first_name;

        write_entity(
            p_entity_base => p_file_prefix || '_user_' || l_stamp,
            p_header      => 'company_id,division_id,email_address,first_name,last_name,title,'
                           ||'phone_number,address_1,address_2,city,state,postal_code,country,'
                           ||'erp_burst_id',
            p_cursor      => l_cur,
            p_bucket_name => p_bucket_name,
            p_folder_path => p_folder_path,
            p_max_bytes   => l_max_bytes
        );

        --------------------------------------------------------------- feedback
        OPEN l_cur FOR
            SELECT
                csv_field(company_id) ||','|| csv_field(division_id) ||','||
                csv_field(invoice_id) ||','|| csv_field(amount) ||','||
                csv_field(currency) ||','|| csv_field(payment_due_date) ||','||
                csv_field(transaction_type) ||','|| csv_field(voucher_id) ||','||
                csv_field(fiscal_year) ||','|| csv_field(adjusted_invoice_id) ||','||
                csv_field(expected_amount_paid) ||','|| csv_field(payment_term) ||','||
                csv_field(payment_method) ||','|| csv_field(payment_initiation_date) ||','||
                csv_field(payment_initiation_document) ||','|| csv_field(status) ||','||
                csv_field(fund_type) ||','|| csv_field(fund_partner) ||','||
                csv_field(erp_burst_id)
            FROM   lws_ob_feedback
            ORDER  BY company_id, invoice_id;

        write_entity(
            p_entity_base => p_file_prefix || '_feedback_' || l_stamp,
            p_header      => 'company_id,division_id,invoice_id,amount,currency,'
                           ||'payment_due_date,transaction_type,voucher_id,fiscal_year,'
                           ||'adjusted_invoice_id,expected_amount_paid,payment_term,'
                           ||'payment_method,payment_initiation_date,payment_initiation_document,'
                           ||'status,fund_type,fund_partner,erp_burst_id',
            p_cursor      => l_cur,
            p_bucket_name => p_bucket_name,
            p_folder_path => p_folder_path,
            p_max_bytes   => l_max_bytes
        );

        ------------------------------------------------------------------- PO (optional)
        -- Emitted only when p_extract_po = 'Y'. PO extract itself is currently
        -- disabled (see extract_pos), so lws_ob_po is empty until re-enabled.
        IF p_extract_po = 'Y' THEN
            OPEN l_cur FOR
                SELECT
                    csv_field(company_id) ||','|| csv_field(division_id) ||','||
                    csv_field(po_id) ||','|| csv_field(amount) ||','||
                    csv_field(currency) ||','|| csv_field(create_date) ||','||
                    csv_field(approved_date) ||','|| csv_field(ship_date) ||','||
                    csv_field(ship_orig_country) ||','|| csv_field(ship_orig_state) ||','||
                    csv_field(estimated_arrival_date) ||','|| csv_field(actual_arrival_date) ||','||
                    csv_field(supplier_country) ||','|| csv_field(company_code) ||','||
                    csv_field(warehouse_code) ||','|| csv_field(erp_org_id) ||','||
                    csv_field(erp_ponumber) ||','|| csv_field(erp_po_header_id) ||','||
                    csv_field(erp_supplier) ||','|| csv_field(erp_supplier_number) ||','||
                    csv_field(erp_vendor_id) ||','|| csv_field(erp_suppliersite) ||','||
                    csv_field(erp_vendor_site_id) ||','|| csv_field(erp_potype) ||','||
                    csv_field(erp_podate) ||','|| csv_field(erp_billto_loc) ||','||
                    csv_field(erp_buyer) ||','|| csv_field(erp_authorization_status) ||','||
                    csv_field(erp_terms) ||','|| csv_field(erp_closed_code) ||','||
                    csv_field(erp_ship_to_location_id) ||','|| csv_field(erp_burst_id)
                FROM   lws_ob_po
                ORDER  BY company_id, po_id;

            write_entity(
                p_entity_base => p_file_prefix || '_purchaseorder_' || l_stamp,
                p_header      => 'company_id,division_id,po_id,amount,currency,created_date,'
                               ||'approved_date,ship_date,ship_orig_country,ship_orig_state,'
                               ||'estimated_arrival_date,actual_arrival_date,supplier_country,'
                               ||'company_code,warehouse_code,erp_org_id,segment1,po_header_id,'
                               ||'vendor_name,erp_supplier_number,erp_vendor_id,erp_suppliersite,'
                               ||'erp_vendor_site_id,erp_potype,erp_podate,erp_billto_loc,erp_buyer,'
                               ||'erp_authorization_status,erp_terms,erp_closed_code,'
                               ||'erp_ship_to_location_id,erp_burst_id',
                p_cursor      => l_cur,
                p_bucket_name => p_bucket_name,
                p_folder_path => p_folder_path,
                p_max_bytes   => l_max_bytes
            );
        END IF;

        --------------------------------------------------------------- control
        -- The control file lists every data file emitted above (name + row_count),
        -- so it must be written AFTER the others and reflect the part rows now in
        -- lws_ob_control. Its own row_count = number of file entries it lists.
        -- EXCLUSION: the feedback file is still written+uploaded, but it is NOT
        -- listed in the control manifest (C2FO reconciles feedback separately), so
        -- the row loop below skips any '*_feedback_*' entry.
        DECLARE
            l_ctrl_line VARCHAR2(32767);
            l_ctrl_buf  CLOB;
            l_ctrl_rows PLS_INTEGER := 0;
            l_ctrl_name VARCHAR2(200) := LOWER(p_file_prefix || '_control_' || l_stamp || '.csv');
        BEGIN
            DBMS_LOB.CREATETEMPORARY(l_ctrl_buf, TRUE);
            l_ctrl_line := 'file_name,row_count' || CHR(13) || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_ctrl_buf, LENGTH(l_ctrl_line), l_ctrl_line);
            FOR rec IN (SELECT file_name, row_count FROM lws_ob_control
                        WHERE  INSTR(LOWER(file_name), '_feedback_') = 0
                        ORDER  BY file_name) LOOP
                l_ctrl_line := csv_field(rec.file_name) ||','|| csv_field(rec.row_count)
                               || CHR(13) || CHR(10);
                DBMS_LOB.WRITEAPPEND(l_ctrl_buf, LENGTH(l_ctrl_line), l_ctrl_line);
                l_ctrl_rows := l_ctrl_rows + 1;
            END LOOP;
            DECLARE
                l_ctrl_blob BLOB;
                l_dst_off   INTEGER := 1;
                l_src_off   INTEGER := 1;
                l_lang_ctx  INTEGER := DBMS_LOB.default_lang_ctx;
                l_warning   INTEGER;
            BEGIN
                DBMS_LOB.CREATETEMPORARY(l_ctrl_blob, TRUE);
                DBMS_LOB.CONVERTTOBLOB(
                    dest_lob     => l_ctrl_blob,
                    src_clob     => l_ctrl_buf,
                    amount       => DBMS_LOB.LOBMAXSIZE,
                    dest_offset  => l_dst_off,
                    src_offset   => l_src_off,
                    blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
                    lang_context => l_lang_ctx,
                    warning      => l_warning
                );
                emit_object(p_bucket_name, p_folder_path, l_ctrl_name, l_ctrl_blob);
                DBMS_LOB.FREETEMPORARY(l_ctrl_blob);
            END;
            DBMS_LOB.FREETEMPORARY(l_ctrl_buf);
            -- record the control file itself in the table too
            INSERT INTO lws_ob_control (file_name, row_count, erp_burst_id)
                VALUES (l_ctrl_name, TO_CHAR(l_ctrl_rows), 'control');
            COMMIT;
        END;

        IF g_dest = 'DIRECTORY' THEN
            o_message := 'Files written to directory ' || g_dest_dir;
        ELSE
            o_message := 'Files written to bucket ' || p_bucket_name
                         || CASE WHEN p_folder_path IS NOT NULL
                                 THEN '/' || p_folder_path END;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            BEGIN IF l_cur%ISOPEN THEN CLOSE l_cur; END IF; EXCEPTION WHEN OTHERS THEN NULL; END;
    END write_files_to_bucket;

    --====================================================================
    -- MASTER DRIVER
    --====================================================================
    PROCEDURE run_outbound (
        p_file_prefix         IN  VARCHAR2,
        p_extract_po          IN  VARCHAR2 DEFAULT 'N',
        p_invoice_date_from   IN  DATE     DEFAULT NULL,
        p_invoice_date_to     IN  DATE     DEFAULT NULL,
        p_pay_due_date_from   IN  DATE     DEFAULT NULL,
        p_pay_due_date_to     IN  DATE     DEFAULT NULL,
        p_po_date_from        IN  DATE     DEFAULT NULL,
        p_po_date_to          IN  DATE     DEFAULT NULL,
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL,  -- exclude invoice payment term NAME list
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL,   -- exclude supplier vendor_type_lookup_code list
        p_max_past_years      IN  NUMBER   DEFAULT NULL,   -- max years of past-due invoices
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,   -- include-only supplier segment1 list
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,   -- include-only invoice_num list
        p_bucket_name         IN  VARCHAR2 DEFAULT NULL,   -- NULL = no bucket (extract only, or local mode)
        p_folder_path         IN  VARCHAR2 DEFAULT NULL,
        p_directory           IN  VARCHAR2 DEFAULT NULL,   -- ATP dir object => local-file mode
        p_max_mb              IN  NUMBER   DEFAULT 200,
        p_feedback_report_days IN NUMBER   DEFAULT NULL,   -- days after payment an award stays in the feedback file
        p_run_id              IN  NUMBER   DEFAULT NULL,
        o_run_id              OUT NUMBER,
        o_status              OUT VARCHAR2,                    -- SUCCESS / ERROR / SKIPPED (another run active)
        o_message             OUT VARCHAR2
    ) IS
        l_inv   NUMBER := 0;
        l_org   NUMBER := 0;
        l_usr   NUMBER := 0;
        l_fb    NUMBER := 0;
        l_po    NUMBER := 0;
        l_wr_status  VARCHAR2(20);
        l_wr_message VARCHAR2(4000);
        -- PO extract disabled (see extract_pos in the body): force off regardless of
        -- p_extract_po until the mirror is extended and extract_pos is re-enabled.
        l_po_yn VARCHAR2(1) := 'N';
        -- Concurrency guard: count OTHER runs already active. All extracts write the
        -- shared LWS_OB_* tables and run_outbound TRUNCATEs them at the start, so two
        -- overlapping runs corrupt each other's output (this is what stopped run 32).
        l_active NUMBER;
    BEGIN
        o_status := 'SUCCESS';

        -- Refuse to start if another run is actually RUNNING, or if an EARLIER-queued
        -- run is still SUBMITTED (lower run_id = submitted first, so it goes first).
        -- Excludes this run's own row. Gating SUBMITTED on "lower run_id only" avoids
        -- two near-simultaneous submits mutually skipping each other - the earlier one
        -- proceeds, the later one waits. sweep_orphan_runs also self-heals crashed
        -- runs (rows stuck non-terminal with no scheduler job) so they never wedge us.
        l_active := sweep_orphan_runs(p_self_run_id => p_run_id);

        IF l_active > 0 THEN
            o_run_id  := p_run_id;
            o_status  := 'SKIPPED';
            o_message := 'Another outbound run is already active (' || l_active
                         || ' SUBMITTED/RUNNING, each with a live scheduler job) - not '
                         || 'started to avoid clobbering the shared LWS_OB_* tables. '
                         || 'Wait for it to finish, then resubmit.';
            -- If this was an async run, close its reserved row so it does not itself
            -- become a stale RUNNING/SUBMITTED row that blocks the next attempt.
            IF p_run_id IS NOT NULL THEN
                UPDATE lws_ob_run_log
                SET    status = 'SKIPPED', end_time = SYSDATE, error_message = o_message
                WHERE  run_id = p_run_id;
                COMMIT;
            END IF;
            RETURN;
        END IF;

        -- submit_outbound already created the SUBMITTED row and passed its run_id;
        -- flip it to RUNNING. A direct synchronous call (p_run_id NULL) allocates one.
        IF p_run_id IS NULL THEN
            o_run_id := lws_ob_run_seq.NEXTVAL;
            INSERT INTO lws_ob_run_log (run_id, file_prefix, po_extracted, start_time, status)
                VALUES (o_run_id, p_file_prefix, l_po_yn, SYSDATE, 'RUNNING');
        ELSE
            o_run_id := p_run_id;
            UPDATE lws_ob_run_log SET status = 'RUNNING', start_time = SYSDATE
            WHERE  run_id = o_run_id;
        END IF;
        COMMIT;

        -- 1. clear last run's output so the tables reflect only this run
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_INVOICE';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_ORGANIZATION';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_USER';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_FEEDBACK';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_PO';
        EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || g_schema || '.LWS_OB_CONTROL';

        -- 2. run the extracts (org/user depend on invoice output being present)
        extract_invoices(p_invoice_date_from, p_invoice_date_to,
                         p_pay_due_date_from, p_pay_due_date_to,
                         p_bu_list, p_exclude_pay_groups, p_exclude_payment_terms,
                         p_exclude_vendor_types,
                         p_max_past_years,
                         p_vendor_numbers, p_invoice_nums, l_inv);
        extract_organizations(l_org);
        extract_users(l_usr);
        -- feedback: payment status of awarded invoices. Independent of the invoice
        -- output (driven off the award table), so order vs org/user does not matter.
        -- p_feedback_report_days bounds how long after payment an award is reported.
        extract_feedback(p_feedback_report_days, l_fb);
        -- PO extract disabled: extract_pos is commented out in the body and
        -- l_po_yn is forced to 'N', so no PO file is produced or counted.
        /*
        IF l_po_yn = 'Y' THEN
            extract_pos(p_po_date_from, p_po_date_to, l_po);
        END IF;
        */

        -- 3. write the CSV files to the OCI bucket (this also builds the control
        --    file, per-part, from the rows it writes). Skipped when no bucket is
        --    supplied, so the extract can still be run standalone for staging.
        IF p_bucket_name IS NOT NULL OR p_directory IS NOT NULL THEN
            write_files_to_bucket(
                p_file_prefix => p_file_prefix,
                p_bucket_name => p_bucket_name,
                p_folder_path => p_folder_path,
                p_directory   => p_directory,
                p_extract_po  => l_po_yn,
                p_max_mb      => p_max_mb,
                o_status      => l_wr_status,
                o_message     => l_wr_message
            );
            IF l_wr_status <> 'SUCCESS' THEN
                RAISE_APPLICATION_ERROR(-20001, 'File write failed: ' || l_wr_message);
            END IF;
        END IF;

        o_message := 'invoice=' || l_inv || ' org=' || l_org
                     || ' user=' || l_usr || ' feedback=' || l_fb || ' po=' || l_po
                     || CASE WHEN p_bucket_name IS NOT NULL OR p_directory IS NOT NULL
                             THEN ' | ' || l_wr_message
                             ELSE ' | files not written (no destination)' END;

        UPDATE lws_ob_run_log
        SET    inv_count = l_inv, org_count = l_org, user_count = l_usr,
               feedback_count = l_fb, po_count = l_po,
               end_time = SYSDATE, status = 'SUCCESS'
        WHERE  run_id = o_run_id;
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            UPDATE lws_ob_run_log
            SET    end_time = SYSDATE, status = 'ERROR', error_message = o_message
            WHERE  run_id = o_run_id;
            COMMIT;
    END run_outbound;

    PROCEDURE submit_outbound (
        p_file_prefix         IN  VARCHAR2,
        p_extract_po          IN  VARCHAR2 DEFAULT 'N',
        p_invoice_date_from   IN  DATE     DEFAULT NULL,
        p_invoice_date_to     IN  DATE     DEFAULT NULL,
        p_pay_due_date_from   IN  DATE     DEFAULT NULL,
        p_pay_due_date_to     IN  DATE     DEFAULT NULL,
        p_po_date_from        IN  DATE     DEFAULT NULL,
        p_po_date_to          IN  DATE     DEFAULT NULL,
        p_bu_list             IN  VARCHAR2 DEFAULT NULL,
        p_exclude_pay_groups  IN  VARCHAR2 DEFAULT NULL,
        p_exclude_payment_terms IN VARCHAR2 DEFAULT NULL,  -- exclude invoice payment term NAME list
        p_exclude_vendor_types IN VARCHAR2 DEFAULT NULL,   -- exclude supplier vendor_type_lookup_code list
        p_max_past_years      IN  NUMBER   DEFAULT NULL,   -- max years of past-due invoices
        p_vendor_numbers      IN  VARCHAR2 DEFAULT NULL,   -- include-only supplier segment1 list
        p_invoice_nums        IN  VARCHAR2 DEFAULT NULL,   -- include-only invoice_num list
        p_bucket_name         IN  VARCHAR2 DEFAULT NULL,
        p_folder_path         IN  VARCHAR2 DEFAULT NULL,
        p_directory           IN  VARCHAR2 DEFAULT NULL,
        p_max_mb              IN  NUMBER   DEFAULT 200,
        p_feedback_report_days IN NUMBER   DEFAULT NULL,   -- days after payment an award stays in the feedback file
        o_run_id              OUT NUMBER,
        o_status              OUT VARCHAR2,
        o_message             OUT VARCHAR2
    ) IS
        l_job_name  VARCHAR2(128);
        l_plsql     VARCHAR2(32767);  -- headroom for the list literals (bu / pay-groups / vendors / invoice_nums)

        -- Render a DATE param as a TO_DATE literal (or NULL) for the job block.
        FUNCTION dlit (p_d IN DATE) RETURN VARCHAR2 IS
        BEGIN
            IF p_d IS NULL THEN RETURN 'NULL'; END IF;
            RETURN 'TO_DATE(''' || TO_CHAR(p_d, 'YYYYMMDDHH24MISS') || ''',''YYYYMMDDHH24MISS'')';
        END dlit;

        -- Render a VARCHAR2 param as a quoted literal (or NULL), quotes doubled.
        FUNCTION slit (p_s IN VARCHAR2) RETURN VARCHAR2 IS
        BEGIN
            IF p_s IS NULL THEN RETURN 'NULL'; END IF;
            RETURN '''' || REPLACE(p_s, '''', '''''') || '''';
        END slit;
    BEGIN
        -- Clear any orphaned runs (rows stuck non-terminal whose scheduler job is gone)
        -- BEFORE creating a new job, so we do not spawn a job that just skips on a stale
        -- blocker. p_self_run_id NULL: we have not reserved our row yet. This does not
        -- prevent submitting alongside a genuinely-live run - run_outbound's guard still
        -- makes the newly-spawned worker skip if a real run is active; this only removes
        -- dead rows so a live run is not shadowed by a crashed one.
        DECLARE
            l_ignored NUMBER;
        BEGIN
            l_ignored := sweep_orphan_runs(p_self_run_id => NULL);
        END;

        -- Reserve the run_id and log it as SUBMITTED up front, so OIC gets an id it
        -- can poll on LWS_OB_RUN_LOG and the worker just flips this same row.
        o_run_id := lws_ob_run_seq.NEXTVAL;
        INSERT INTO lws_ob_run_log (run_id, file_prefix, po_extracted, start_time, status)
            VALUES (o_run_id, p_file_prefix, 'N', SYSDATE, 'SUBMITTED');
        COMMIT;

        l_job_name := 'LWS_OB_RUN_' || o_run_id;

        -- One-time background job. Params are inlined as literals (SET_JOB_ARGUMENT_VALUE
        -- cannot bind NUMBER/DATE argument types cleanly), so file_prefix/folder are
        -- quote-escaped and dates rendered via TO_DATE. The worker takes the reserved
        -- run_id via p_run_id; its OUT params are discarded (anonymous job) - outcome
        -- reaches the operator through the LWS_OB_RUN_LOG row for this run_id.
        l_plsql :=
            'DECLARE v_id NUMBER; v_st VARCHAR2(20); v_msg VARCHAR2(4000); BEGIN '
            || 'LWS_CUSTOM_C2FO_SA.LWS_OB_EXTRACT_ATP_PKG.run_outbound('
            || 'p_file_prefix=>'       || slit(p_file_prefix)
            || ',p_extract_po=>'       || slit(p_extract_po)
            || ',p_invoice_date_from=>'|| dlit(p_invoice_date_from)
            || ',p_invoice_date_to=>'  || dlit(p_invoice_date_to)
            || ',p_pay_due_date_from=>'|| dlit(p_pay_due_date_from)
            || ',p_pay_due_date_to=>'  || dlit(p_pay_due_date_to)
            || ',p_po_date_from=>'     || dlit(p_po_date_from)
            || ',p_po_date_to=>'       || dlit(p_po_date_to)
            || ',p_bu_list=>'          || slit(p_bu_list)
            || ',p_exclude_pay_groups=>' || slit(p_exclude_pay_groups)
            || ',p_exclude_payment_terms=>' || slit(p_exclude_payment_terms)
            || ',p_exclude_vendor_types=>' || slit(p_exclude_vendor_types)
            || ',p_max_past_years=>'   || NVL(TO_CHAR(p_max_past_years), 'NULL')
            || ',p_vendor_numbers=>'   || slit(p_vendor_numbers)
            || ',p_invoice_nums=>'     || slit(p_invoice_nums)
            || ',p_bucket_name=>'      || slit(p_bucket_name)
            || ',p_folder_path=>'      || slit(p_folder_path)
            || ',p_directory=>'        || slit(p_directory)
            || ',p_max_mb=>'           || TO_CHAR(NVL(p_max_mb, 200))
            || ',p_feedback_report_days=>' || NVL(TO_CHAR(p_feedback_report_days), 'NULL')
            || ',p_run_id=>'           || o_run_id
            || ',o_run_id=>v_id, o_status=>v_st, o_message=>v_msg); END;';

        DBMS_SCHEDULER.CREATE_JOB(
            job_name        => l_job_name,
            job_type        => 'PLSQL_BLOCK',
            job_action      => l_plsql,
            start_date      => SYSTIMESTAMP,
            enabled         => TRUE,
            auto_drop       => TRUE,
            comments        => 'C2FO outbound async run ' || o_run_id
        );

        o_status  := 'SUBMITTED';
        o_message := 'Outbound run ' || o_run_id || ' submitted as job ' || l_job_name;
    EXCEPTION
        WHEN OTHERS THEN
            o_status  := 'ERROR';
            o_message := SUBSTR(SQLERRM, 1, 4000);
            IF o_run_id IS NOT NULL THEN
                UPDATE lws_ob_run_log
                SET    status = 'ERROR', end_time = SYSDATE,
                       error_message = 'Submit failed: ' || o_message
                WHERE  run_id = o_run_id;
                COMMIT;
            END IF;
    END submit_outbound;

END LWS_OB_EXTRACT_ATP_PKG;
/
