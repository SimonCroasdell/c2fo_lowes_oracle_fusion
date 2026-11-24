--============================================================================
-- LWS_C2FO_CM_FBDI_V  -- CM FBDI build view (OIC "Run a SQL Statement" source)
------------------------------------------------------------------------------
-- Purpose: expose the credit-memo FBDI header+line row set as a plain SELECT so
--   the OIC ERP inbound integration (LWS_C2FO_AWARD_PROCESS, Stage B) can read
--   NAMED, TYPED columns via a "Run a SQL Statement" invoke. This OIC version's
--   ATP adapter cannot define the row shape of a weak SYS_REFCURSOR OUT param,
--   so build_fbdi_cm_set's cursor could not be mapped; a view solves that.
--
-- Contract (identical row shape to build_fbdi_cm_set's cursor):
--   one row per validated award = one CM header + one CM line (grain = single
--   expense line per award, Open Issue #5). Amounts are NEGATIVE (credit).
--
-- OIC usage (per chunk):
--   SELECT * FROM LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_FBDI_V
--    WHERE instance_id = :p_instance_id
--      AND chunk_id    = :p_chunk_id;
--   Every CHUNK_ID resolves to exactly one BU (chunk_cm_awards is BU-aware), so
--   the FBDI property file's ORG_ID (= ORG_ID column here) is unambiguous.
--
-- State model: this view reads stage = 'SUCCESSFULLY_VALIDATED' (NOT interfaced).
--   The flip to 'EP_INTERFACED' happens AFTER a chunk's import is confirmed, via
--   flip_chunk_to_interfaced(p_instance_id, p_chunk_id) -- so a half-built chunk
--   is never stranded in INTERFACED and a resumed run re-reads it cleanly.
--
-- INVOICE_SOURCE = the ORIGINAL invoice's source (ap_invoices_all.source),
--   stamped onto the award row (SOURCE_CODE) at validation. The CM must be
--   imported under the same source as the invoice it credits, so a chunk never
--   spans two sources (chunk_cm_awards is BU- AND source-aware; every CHUNK_ID
--   resolves to one (BU, source) pair, driving property-file arg2/arg8).
-- Run-log values (pay_group, cm_payment_method) are joined in from
--   LWS_AP_C2FO_AWARD_RUN_LOG by INSTANCE_ID (award rows carry no run_id). The
--   pay group is emitted only when UPDATE_PAY_GROUP = 'Y' (BR#16); else NULL so
--   FBDI leaves the CM's pay group at its default.
--============================================================================
DROP VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_FBDI_V;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_FBDI_V AS
  SELECT s.instance_id                    AS instance_id,   -- filter/key (= FBDI GROUP_ID)
       s.chunk_id                       AS chunk_id,      -- filter (per-BU chunk)
       -- FBDI file-local numeric key: ties the header record to its line
       -- record(s) WITHIN one import file. FBDI Invoice_ID is numeric, so the
       -- string CM number can't be used here. Unique per (instance, chunk) =
       -- unique per FBDI file (one chunk = one file). NOT a Fusion invoice id;
       -- Fusion assigns the real id at import.
       ROW_NUMBER() OVER (PARTITION BY s.instance_id, s.chunk_id
                          ORDER BY s.invoice_id)          AS file_line_id,
       s.instance_id                    AS group_id,      -- FBDI GROUP_ID (BR#1)
       s.source_code                    AS invoice_source,   -- ORIGINAL invoice source (stamped at validation); FBDI import runs per source
       s.cm_invoice_num                 AS invoice_num,   -- deterministic CM number (BR#5)
       'CREDIT'                         AS invoice_type_lookup_code,
       s.erp_org_id                     AS org_id,        -- FBDI property-file ORG_ID (numeric)
       s.erp_business_unit              AS business_unit, -- FBDI header pos 2 (BU name); Load Interface resolves org_id from it
       -- FBDI resolves the supplier by NAME/NUMBER + SITE CODE, not internal ids.
       -- The raw ids are kept for debugging but the file uses these three.
       sup.vendor_name                  AS supplier_name,     -- FBDI Supplier_Name
       sup.segment1                     AS supplier_number,   -- FBDI Supplier_Number
       ss.vendor_site_code              AS supplier_site,     -- FBDI Supplier_Site (code)
       s.vendor_id                      AS vendor_id,         -- raw id (not for the file)
       s.erp_vendor_site_id             AS vendor_site_id,    -- raw id (not for the file)
       -- CM amount is tax-INCLUSIVE: gross up the discount income by the tax rate,
       -- then negate (credit). Mirrors the Mount Sinai model. cm_invoice_amount is
       -- never populated, so income + erp_tax_rate are the authoritative inputs.
       -- erp_tax_rate is a percent (5 = 5%); NVL guards a missing rate (=> net only).
       ROUND(-s.income, 2) AS invoice_amount,
       s.currency                       AS invoice_currency_code,
       TO_CHAR(TO_DATE(s.pay_date DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD'),
               'YYYY/MM/DD')            AS invoice_date,
       CASE WHEN NVL(rl.update_pay_group, 'N') = 'Y'
            THEN rl.pay_group END       AS pay_group,      -- BR#16 gate
       rl.cm_payment_method             AS payment_method_code,
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
       'ITEM'                           AS line_type_lookup_code,
       -- ITEM line is NET (income only), negated. The header Invoice_Amount is
       -- GROSS (income + tax); Fusion adds the tax portion at import so
       -- header = line + tax. Do NOT gross up the line.
       ROUND(-s.income, 2)              AS line_amount,
       s.expense_ccid                   AS dist_code_combination_id,
       s.liability_ccid                 AS liability_ccid,
       s.invoice_id                     AS award_key
FROM   lws_c2fo_award_data s
JOIN   ( -- latest run per instance (instance_id is normally 1:1 with a run, but
         -- guard against a manual re-submit reusing an instance_id)
         SELECT instance_id, pay_group, update_pay_group,
                cm_payment_method
         FROM   ( SELECT rl0.*,
                         ROW_NUMBER() OVER (PARTITION BY instance_id
                                            ORDER BY run_id DESC) AS rn
                  FROM   lws_ap_c2fo_award_run_log rl0 )
         WHERE  rn = 1
       ) rl ON rl.instance_id = s.instance_id
JOIN   ap_invoices_all aia          ON aia.invoice_id = s.erp_invoice_id
LEFT   JOIN lws_poz_suppliers_v sup ON sup.vendor_id = s.vendor_id
LEFT   JOIN lws_poz_supplier_sites_all_m ss
                                    ON ss.vendor_site_id = s.erp_vendor_site_id
WHERE  s.record_status = 'N'
AND    s.stage         = 'SUCCESSFULLY_VALIDATED'
-- A CM is created only where the award has non-zero income (BR#5). Zero-income
-- awards still get a due-date update (Stage D) but no credit memo, so they must
-- NOT reach the CM FBDI file. This also makes the row count the CM-eligible
-- count, which L2 verification compares against created CMs.
AND    NVL(s.income, 0) <> 0;
