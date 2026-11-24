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
DROP VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_DD_UPSERT_V;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_DD_UPSERT_V AS
SELECT s.invoice_id                                   AS award_key,
       s.erp_invoice_id                               AS invoice_id,
       s.cm_invoice_id                                AS cm_invoice_id,
       s.payment_num                                  AS installment_number,
       s.pay_date                                     AS due_date,
       CASE WHEN s.orig_first_discount_date IS NOT NULL THEN 'Y' ELSE 'N' END
                                                       AS discount_flag,
       -- The upsert MOVES every discount tier that existed at validation to the new
       -- due date (pay_date), so no discount date is ever left AFTER the accelerated
       -- due date (Fusion rejects that). Each tier is emitted as pay_date only when
       -- that tier was populated at validation (orig_*_discount_date); NULL otherwise
       -- -> the element is not sent. Amounts are unchanged (originals stored for
       -- reversal on the award record).
       CASE WHEN s.orig_first_discount_date IS NOT NULL
            THEN s.pay_date END                        AS first_discount_date,
       CASE WHEN s.orig_first_discount_date IS NOT NULL
            THEN round(discount_amount,2)  END                 AS first_discount_amount,
       CASE WHEN s.orig_second_discount_date IS NOT NULL
            THEN s.pay_date END                        AS second_discount_date,
       CASE WHEN s.orig_third_discount_date IS NOT NULL
            THEN s.pay_date END                        AS third_discount_date,
       s.pay_group                                    AS pay_group,
       s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       CEIL(ROW_NUMBER() OVER (PARTITION BY s.instance_id, s.chunk_id
                               ORDER BY s.invoice_id) / 500)
                                                       AS dd_batch_no
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_AWARD_DATA s
WHERE  s.record_status = 'N'
AND    s.cm_status     = 'OK'
AND    s.stage         = 'EP_NEW_CREDIT_MEMO_INVOICE_VALIDATED'
;

-- Failed-upsert tail: awards whose DD upsert failed (DD verdict 'N', unconsumed) and
-- that have a CM to cancel. Integration #3 loops these, cancels each CM, then calls
-- stamp_dd_comp_status before annotate_duedate_result_bulk. See bin c2fo_dd_upsert_view.sql.
-- The OIC cancelCM invoke (Fusion invoices/action/cancelInvoice) identifies the CM by
-- InvoiceNumber + BusinessUnit (name) + Party/Supplier (name) + PartyId (number), so the
-- view carries all four. Supplier name + party id resolve from the mirror
-- LWS_POZ_SUPPLIERS_V (vendor_id -> party_id + vendor_name); LEFT JOIN so a missing
-- supplier row never hides a cancelable CM.
