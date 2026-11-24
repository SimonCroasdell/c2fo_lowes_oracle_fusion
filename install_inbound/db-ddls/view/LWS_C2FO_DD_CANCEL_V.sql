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
DROP VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_DD_CANCEL_V;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_DD_CANCEL_V AS
SELECT s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       s.invoice_id                                   AS award_key,
       s.cm_invoice_id                                AS cm_invoice_id,
       s.erp_invoice_id                               AS invoice_id,
       v.verdict_row_id                               AS verdict_row_id,
       s.cm_invoice_num                               AS cm_invoice_num,
       s.erp_business_unit                            AS business_unit,
       sup.party_id                                   AS supplier_party_id,
       sup.vendor_name                                AS supplier_party_name
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA s
JOIN   LWS_CUSTOM_C2FO_SA.LWS_AP_C2FO_VERDICT_LOAD v
       ON  v.instance_id   = s.instance_id
       AND v.invoice_id    = s.invoice_id
       AND v.verdict_kind  = 'DD'
       AND v.status        = 'N'
       AND v.processed_flag = 'N'
LEFT JOIN LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V sup
       ON  sup.vendor_id    = s.erp_vendor_id
WHERE  s.cm_invoice_id IS NOT NULL
ORDER  BY s.invoice_id;


--------------------------------------------------------------------------------
-- CM OFFSET read view (the shared compensation path - replaces CM cancel)
-- Purpose: list the awards whose credit memo must be OFFSET by a new positive
--          STANDARD invoice, because cancelInvoice cannot be used. Feeds the
--          shared child integration LWS_C2FO_CM_OFFSET (per-row REST POST
--          /invoices). Used by TWO callers:
--            * #2 LWS_C2FO_AWARD_PROCESS - a CM was created but FAILED validation
--              (its CM verdict is 'N': the CM physically exists unvalidated).
--            * #3 LWS_C2FO_DUEDATE_UPSERT - the due-date upsert failed for a
--              CM-bearing award (its DD verdict is 'N').
-- Grain  : one row per failed award whose CM needs an offsetting invoice.
-- Join   : LWS_AP_C2FO_VERDICT_LOAD on the award's unconsumed FAILED verdict of
--          EITHER kind (verdict_kind IN ('CM','DD'), status='N', processed_flag='N')
--          - the caller decides which kind it produced; this view serves both.
-- Filter : s.cm_invoice_id IS NOT NULL - only CM-bearing awards can be offset
--          (zero-income DD-only awards never had a CM, nothing to offset).
-- The offsetting invoice is a POSITIVE STANDARD invoice (InvoiceType STANDARD,
-- amount = ABS(income)) that nets the CM's credit to zero. It is NOT a debit
-- memo (a Fusion debit memo is itself negative, same direction as the CM).
-- See bin c2fo_dd_upsert_view.sql for the full column notes.
--------------------------------------------------------------------------------
