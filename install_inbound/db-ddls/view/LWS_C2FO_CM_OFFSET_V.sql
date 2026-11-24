--------------------------------------------------------------------------------
-- C2FO Inbound DUE-DATE UPSERT read view (Integration #3 LWS_C2FO_DUEDATE_UPSERT)
-- Purpose: give OIC "Run a SQL Statement" a NAMED/TYPED row set of the awards in
--          one CM chunk whose credit memo has been created AND validated, so #3 can
--          batch-upsert their installment due dates in Fusion.
-- Grain  : one row per awarded installment.
-- Scope  : reads LWS_C2FO_AWARD_DATA directly (NOT the CM view LWS_C2FO_CM_FBDI_V).
--          The CM view filters income<>0 and drops zero-income awards; the due-date
--          update MUST still run for zero-income awards, so this view does NOT
--          filter on income. Zero-income awards reach the filter state below straight
--          from validate_batch (no CM is built; validate stamps them cm_status='OK' +
--          EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED so they are DD-ready), and are chunked
--          alongside the CM rows by chunk_cm_awards, so they appear here normally.
-- Filter : record_status='N' (still in flight) AND cm_status='OK' (CM half done, OR -
--          for a zero-income award - "ready for due-date upsert", set by validate_batch)
--          AND stage=EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED (created+validated, the
--          state annotate_cm_result_bulk leaves a good CM award in, and validate_batch
--          leaves a zero-income award in). OIC passes instance_id + chunk_id so exactly
--          one chunk is read.
-- Re-run : after a chunk's upsert succeeds, Integration #3 calls
--          flip_chunk_duedates_sent (below) to move these rows to EP_INTERFACED, so
--          a re-read of the same chunk returns nothing. The final
--          record_status='Y'/SUCCESSFULLY_PROCESSED stamp comes later from
--          annotate_duedate_result_bulk off the DD verdict rows.
-- Sub-batch: the due-date upsert to Fusion goes ~500 installments per adf.batch
--          call. DD_BATCH_NO numbers the chunk's rows in blocks of C_DD_BATCH_SIZE
--          (500) so OIC reads and upserts one block at a time (no OIC row-slicing).
--          Integration #3 loops DD_BATCH_NO = 1 .. CEIL(rowcount/500). Numbering is
--          stable for a given read because it is ORDER BY invoice_id.
-- Columns mirror build_duedate_set's cursor so the OIC payload mapping is identical:
--   award_key           - composite award PK (INVOICE_ID), = LWS_AP_C2FO_VERDICT_LOAD.INVOICE_ID
--   invoice_id          - resolved Fusion AP invoice id (upsert target)
--   installment_number  - payment_num (the invoiceInstallments upsert key)
--   due_date            - pay_date (new accelerated due date, ISO string)
--   discount_flag       - Y when a discount tier applies (BR#9)
--   first_discount_date - pay_date when a discount applies, else null
--   first_discount_amount - discount_amount when a discount applies, else null
--   pay_group           - OIC-supplied pay group (BR#16); only set when the run
--                         enabled the pay-group update, else null (leave unchanged)
--------------------------------------------------------------------------------
DROP VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_OFFSET_V;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_OFFSET_V AS
SELECT s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       s.invoice_id                                   AS award_key,
       v.verdict_row_id                               AS verdict_row_id,
       v.verdict_kind                                 AS verdict_kind,
       SUBSTR(s.erp_invoice_num, 1, 43) || '-C2FOO'  AS offset_invoice_num,
       src.meaning                                    AS invoice_source,
       s.source_code                                  AS invoice_source_code,
       sup.segment1                                   AS supplier_number,
       sup.vendor_name                                AS supplier_name,
       ss.vendor_site_code                            AS supplier_site,
       s.erp_business_unit                            AS business_unit,
       s.erp_org_id                                   AS org_id,
       s.currency                                     AS invoice_currency,
       ROUND(ABS(s.income), 2)   
                                                       AS offset_amount,
       ROUND(ABS(s.income), 2)                        AS offset_line_amount,
       s.erp_tax_rate                                 AS erp_tax_rate,
       s.cm_invoice_num                               AS cm_invoice_num,
       s.cm_invoice_id                                AS cm_invoice_id,
       -- Same payment terms as the CM, so Fusion derives the SAME due date for
       -- the offset that the CM carried (we match terms, not a hard date).
       s.terms_id                                     AS terms_id,
       -- Carry the SAME original-invoice header DFFs the CM got (BR#17), but only
       -- the subset the business wants on the offset: attributes 1,2,5,6,8,10
       -- (+ category, which gives those attributes their meaning). Same aia join
       -- the CM FBDI view uses (ap_invoices_all on erp_invoice_id).
       aia.attribute_category                         AS attribute_category,
       aia.attribute1                                 AS attribute1,
       aia.attribute2                                 AS attribute2,
       aia.attribute5                                 AS attribute5,
       aia.attribute6                                 AS attribute6,
       aia.attribute8                                 AS attribute8,
       aia.attribute10                                AS attribute10,
       -- Human-readable reason the offset invoice exists.
       'C2FO Invoice to offset discount credit memo where due date update failed'
                                                       AS description
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA s
JOIN   LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_LOAD v
       ON  v.instance_id    = s.instance_id
       AND v.invoice_id     = s.invoice_id
       AND v.verdict_kind   IN ('CM', 'DD')
       AND v.status         = 'N'
       AND v.processed_flag = 'N'
JOIN   LWS_CUSTOM_C2FO_SA.AP_INVOICES_ALL aia
       ON  aia.invoice_id   = s.erp_invoice_id
LEFT JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V sup
       ON  sup.vendor_id    = s.vendor_id
LEFT JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M ss
       ON  ss.vendor_site_id = s.erp_vendor_site_id
-- Resolve the invoice-source DISPLAY NAME the REST POST /invoices create demands.
-- The award stores only the source CODE (ap_invoices_all.source, what FBDI wants);
-- REST wants the lookup MEANING. SOURCE lookups are BICC-mirrored into
-- LWS_FND_LOOKUP_VALUES_VL; join the enabled+active-dated bridging view so a
-- disabled source resolves to NULL rather than a stale name. LEFT JOIN so a
-- missing lookup never hides an award needing an offset (invoice_source just
-- comes back NULL and the create surfaces the AP-810667 for a human to fix).
LEFT JOIN LWS_CUSTOM_C2FO_SA.FND_LOOKUP_VALUES_VL src
       ON  src.lookup_type = 'SOURCE'
       AND src.lookup_code = s.source_code
-- Only offset a CM that was actually CREATED and VALIDATED successfully:
--   cm_status='OK'            -> CM import+validate succeeded (annotate_cm_result p_cm_ok='Y')
--   cm_invoice_num IS NOT NULL -> a CM number exists (income<>0; excludes income=0
--                                 DD-only awards, which get cm_status='OK' forced but
--                                 never have a CM number).
-- The two together = "a real CM exists and validated". We gate on the CM NUMBER, not
-- its Fusion internal id: the id is never captured in this design, so cm_invoice_id is
-- always NULL (still emitted below as a NULL reference col).
WHERE  s.cm_invoice_num IS NOT NULL
and ROUND(ABS(s.income), 2)   <>0
AND    s.cm_status      = 'OK'
--------------------------------------------------------------------------------
-- UNION the award-process (#2) VALIDATION-fail rows so the shared offset child
-- (LWS_C2FO_CM_OFFSET, which reads THIS view by instance_id + chunk_id) offsets
-- both failure types without any change to the child or its SQL. The DD-fail leg
-- above is verdict-driven (CM validated OK, due-date upsert failed). The leg below
-- is award-state-driven (CM created but failed validation: cm_status='FAILED',
-- stage=C_ERR_CM_REVAL, already closed record_status='E'). Columns are aligned:
-- the validate leg has no verdict row, so verdict_row_id=NULL and verdict_kind='CM'.
-- update_offset_status dispatches on the award's own state, so the correct close is
-- applied per row regardless of which leg produced it. Both legs are chunk-scoped,
-- matching the child's per-chunk invocation.
--------------------------------------------------------------------------------
UNION ALL
SELECT s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       s.invoice_id                                   AS award_key,
       CAST(NULL AS NUMBER)                           AS verdict_row_id,
       'CM'                                           AS verdict_kind,
       SUBSTR(s.erp_invoice_num, 1, 43) || '-C2FOO'  AS offset_invoice_num,
       src.meaning                                    AS invoice_source,
       s.source_code                                  AS invoice_source_code,
       sup.segment1                                   AS supplier_number,
       sup.vendor_name                                AS supplier_name,
       ss.vendor_site_code                            AS supplier_site,
       s.erp_business_unit                            AS business_unit,
       s.erp_org_id                                   AS org_id,
       s.currency                                     AS invoice_currency,
       ROUND(ABS(s.income), 2)   
                                                       AS offset_amount,
       ROUND(ABS(s.income), 2)                        AS offset_line_amount,
       s.erp_tax_rate                                 AS erp_tax_rate,
       s.cm_invoice_num                               AS cm_invoice_num,
       s.cm_invoice_id                                AS cm_invoice_id,
       s.terms_id                                     AS terms_id,
       aia.attribute_category                         AS attribute_category,
       aia.attribute1                                 AS attribute1,
       aia.attribute2                                 AS attribute2,
       aia.attribute5                                 AS attribute5,
       aia.attribute6                                 AS attribute6,
       aia.attribute8                                 AS attribute8,
       aia.attribute10                                AS attribute10,
       'C2FO Invoice to offset discount credit memo that failed validation'
                                                       AS description
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA s
JOIN   LWS_CUSTOM_C2FO_SA.AP_INVOICES_ALL aia
       ON  aia.invoice_id   = s.erp_invoice_id
LEFT JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V sup
       ON  sup.vendor_id    = s.vendor_id
LEFT JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M ss
       ON  ss.vendor_site_id = s.erp_vendor_site_id
LEFT JOIN LWS_CUSTOM_C2FO_SA.FND_LOOKUP_VALUES_VL src
       ON  src.lookup_type = 'SOURCE'
       AND src.lookup_code = s.source_code
WHERE  s.cm_invoice_num IS NOT NULL
AND    s.cm_status      = 'FAILED'
AND    s.record_status  = 'E'
AND    s.stage          = 'EP_NEW_CREDIT_MEMO_INVOICE_NEEDS_REVALIDATION_ERROR';
