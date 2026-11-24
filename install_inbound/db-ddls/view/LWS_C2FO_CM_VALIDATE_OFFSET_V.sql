--------------------------------------------------------------------------------
-- LWS_C2FO_CM_VALIDATE_OFFSET_V
--   The award-process (#2) end-of-run offset source. Twin of LWS_C2FO_CM_OFFSET_V
--   but for the CM-VALIDATION-fail case, and it reads the DURABLE award state
--   directly instead of the verdict table.
--
--   WHY no verdict join: on the validate path the per-row diff
--   (diff_chunk_cm_validate_verdicts) + annotate_cm_result_chunk run inside the
--   chunk loop and, by the time the end-of-run offset child runs, have already
--   closed every non-validated CM to record_status='E', cm_status='FAILED',
--   stage=EP_NEW_CREDIT_MEMO_INVOICE_NEEDS_REVALIDATION_ERROR and consumed its CM
--   verdict (processed_flag='Y'). Reading verdicts here would therefore find
--   nothing (the async-annotate race the DD path had to guard against). Reading the
--   award row instead removes the race entirely: the state is final and durable.
--
--   SELECTS: CM created but not validated =
--       cm_invoice_num IS NOT NULL  (a real CM exists; income<>0)
--       cm_status = 'FAILED'
--       record_status = 'E'
--       stage = EP_NEW_CREDIT_MEMO_INVOICE_NEEDS_REVALIDATION_ERROR  (the validate
--               diff's error stage; EXCLUDES creation failures at
--               EP_INTERFACE_IMPORT_ERROR, which have no Fusion CM to offset)
--   update_validate_offset_status flips a compensated row's stage to
--   EP_CREDIT_MEMO_REVALIDATION_OFFSET so it drops out here (idempotent re-run);
--   a failed offset stays at the revalidation stage and is returned again.
--   Same column list / joins / gross-vs-net split as LWS_C2FO_CM_OFFSET_V so the
--   offset child's mapper is identical regardless of which view feeds it.
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_CM_VALIDATE_OFFSET_V AS
SELECT s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       s.invoice_id                                   AS award_key,
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
AND    s.stage          = 'EP_NEW_CREDIT_MEMO_INVOICE_NEEDS_REVALIDATION_ERROR'
ORDER  BY s.invoice_id;
