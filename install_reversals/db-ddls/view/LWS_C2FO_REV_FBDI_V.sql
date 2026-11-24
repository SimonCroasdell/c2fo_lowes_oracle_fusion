--============================================================================
-- LWS_C2FO_REV_FBDI_V  -- offsetting-invoice FBDI build view (OIC "Run a SQL" src)
------------------------------------------------------------------------------
-- Purpose: the SIGN-FLIPPED TWIN of LWS_C2FO_CM_FBDI_V. Where the award flow
--   emits a NEGATIVE CREDIT memo, the reversal emits a POSITIVE STANDARD invoice
--   that nets the credit memo back to zero. The OIC reversal process integration
--   (LWS_C2FO_REVERSAL_PROCESS, offset step) reads NAMED/TYPED columns from this
--   view via a "Run a SQL Statement" invoke and renders them to the Import
--   Payables Invoices FBDI, exactly as the award CM import does.
--
-- Contract (same row shape as LWS_C2FO_CM_FBDI_V): one row per offset-eligible
--   reversal row = one invoice header + one line. Amounts are POSITIVE (debit the
--   expense back). Invoice_Type = 'STANDARD' (NOT 'CREDIT'; and NOT a Fusion debit
--   memo, which is itself negative and would not offset). Number = <CM number>-R
--   (CM number truncated to 48 chars so the 2-char '-R' suffix fits Fusion's 50).
--
-- OIC usage:
--   SELECT * FROM LWS_CUSTOM_C2FO_SA.LWS_C2FO_REV_FBDI_V
--    WHERE instance_id = :p_instance_id AND chunk_id = :p_chunk_id;
--   GROUP_ID = INSTANCE_ID (the FBDI import group). CHUNK_ID sub-divides the run so a
--   single Import Payables Invoices never spans two BUs or two sources and no one
--   import carries all N rows - the exact clone of the award CM FBDI path (chunking is
--   required at scale: thousands of reversals cannot go through one import). chunk ids
--   are assigned by chunk_rev_offsets; OIC loops chunk 1..N.
--
-- Scope: offset-eligible = REV_REQUIRED='Y' (income<>0, so a CM existed to offset)
--   AND the row is RESOLVED (STAGE='RESOLVED', RECORD_STATUS='N'). income=0 reversal
--   rows (REV_REQUIRED='N') never had a CM and must NOT reach this view - they get a
--   due-date restore only. This also makes the row count the offset-eligible count,
--   which the offset verdict step compares against created invoices.
--
-- Accounting parity with the CM: SAME supplier (name/number + site code), SAME BU,
--   SAME currency, SAME payment terms and the SAME header DFFs (copied 1:1 off the
--   original invoice, as the CM did), so Fusion books the offset against the same
--   accounts and the net is exactly zero. The grossed header / net line split is the
--   mirror of the CM view: header = +ABS(income)*(1+tax), line = +ABS(income).
--============================================================================
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_REV_FBDI_V AS
SELECT s.instance_id                    AS instance_id,   -- filter/key (= FBDI GROUP_ID)
       s.chunk_id                       AS chunk_id,      -- filter (per-BU/source chunk)
       -- FBDI file-local numeric key tying the header record to its line record(s)
       -- WITHIN one import file. Unique per (instance, chunk) = one import file.
       ROW_NUMBER() OVER (PARTITION BY s.instance_id, s.chunk_id
                          ORDER BY s.voucher_id, s.voucher_line_id) AS file_line_id,
       s.instance_id                    AS group_id,      -- FBDI GROUP_ID
       s.source_code                    AS invoice_source,   -- ORIGINAL invoice source (same source as the CM)
       -- Reversal number = CM number + '-C2FOR'. Fusion AP invoice number maxes at 50
       -- chars and CM_INVOICE_NUM is up to 50, so the base is truncated to 48 before the
       -- '-C2FOR' suffix. This SUBSTR(...,1,48)||'-C2FOR' expression MUST stay byte-
       -- identical in diff_chunk_rev_verdicts and annotate_reversal_offset_result_bulk,
       -- which match/stamp on the same number -- any drift orphans the read-back diff.
       SUBSTR(s.cm_invoice_num, 1, 48) || '-C2FOR' AS invoice_num,
       'STANDARD'                       AS invoice_type_lookup_code,  -- positive STANDARD (offsets the credit)
       s.erp_org_id                     AS org_id,        -- FBDI property-file ORG_ID (numeric)
       s.erp_legal_entity               AS business_unit, -- BU/org (reversal file col 8); Load Interface resolves org_id
       -- FBDI resolves the supplier by NAME/NUMBER + SITE CODE. Resolve them off the
       -- award's resolved supplier id (same joins the CM FBDI view uses).
       sup.vendor_name                  AS supplier_name,     -- FBDI Supplier_Name
       sup.segment1                     AS supplier_number,   -- FBDI Supplier_Number
       ss.vendor_site_code              AS supplier_site,     -- FBDI Supplier_Site (code)
       s.vendor_id                      AS vendor_id,         -- raw id (not for the file)
       -- Offset amount is tax-INCLUSIVE and POSITIVE: gross ABS(income) up by the tax
       -- rate (the exact mirror of the CM header, which was negated). income is stored
       -- signed on the award; ABS() makes the offset positive regardless of its sign.
       ROUND(ABS(s.income) , 2) AS invoice_amount,
       s.currency                       AS invoice_currency_code,
       -- Invoice date = today (the offset is created now). ISO -> FBDI YYYY/MM/DD.
       TO_CHAR(TRUNC(SYSDATE), 'YYYY/MM/DD') AS invoice_date,
       -- Payment method copied 1:1 off the ORIGINAL invoice so the offset pays by the
       -- same method the original/CM used (the award CM view sources this from the run
       -- log; reversal has no run log, and the original invoice is the right source
       -- since the offset mirrors the original's accounting).
       aia.payment_method_code          AS payment_method_code,
       s.terms_id                       AS terms_id,         -- raw id (reference only)
       -- FBDI Import Payables Invoices resolves payment terms by NAME, not the numeric
       -- term_id. Resolve the name off the mirror AP_TERMS_TL (language 'US', the
       -- project-wide convention used by the outbound extracts). LEFT JOIN so a missing
       -- term row never hides an offset; OIC maps TERMS_NAME to the FBDI Terms field.
       trm.name                         AS terms_name,
       -- original-invoice header DFFs, copied 1:1 onto the offset (as the CM carried them)
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
       -- single line: POSITIVE net amount (income only; Fusion adds the tax to balance
       -- against the grossed header). Mirror of the CM line, un-negated.
       1                                AS line_number,
       'ITEM'                           AS line_type_lookup_code,
       ROUND(ABS(s.income), 2)          AS line_amount,
       'C2FO Invoice to offset discount credit memo (award reversal)' AS description,
       s.voucher_id                     AS voucher_id,    -- reversal match key (reference / verdict)
       s.voucher_line_id                AS voucher_line_id
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA s
JOIN   LWS_CUSTOM_C2FO_SA.AP_INVOICES_ALL aia
                                    ON aia.invoice_id = s.erp_invoice_id
LEFT   JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V sup
                                    ON sup.vendor_id = s.vendor_id
LEFT   JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M ss
                                    ON ss.vendor_site_id = s.erp_vendor_site_id
LEFT   JOIN LWS_CUSTOM_C2FO_SA.LWS_AP_TERMS_TL trm
                                    ON trm.term_id = s.terms_id
                                    AND trm.language = 'US'
WHERE  s.record_status = 'N'
AND    s.stage         = 'RESOLVED'
-- Offset only where the award had non-zero income (a CM exists to net off). income=0
-- reversal rows get a due-date restore only and must NOT reach the offset FBDI.
AND    s.rev_required  = 'Y'
AND    NVL(s.income, 0) <> 0;
