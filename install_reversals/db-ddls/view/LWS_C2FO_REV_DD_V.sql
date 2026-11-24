--------------------------------------------------------------------------------
-- LWS_C2FO_REV_DD_V  -- due-date RESTORE read view (OIC "Run a SQL Statement" src)
------------------------------------------------------------------------------
-- Purpose: the INVERSE of LWS_C2FO_DD_UPSERT_V. The award flow accelerates the
--   installment to PAY_DATE and moves every discount tier to that pay date. The
--   reversal puts the installment BACK: DueDate = the pre-acceleration
--   RESTORE_DUE_DATE (= award ORIGINAL_DUE_DATE), and the discount tiers back to
--   their stored ORIG_* dates/amounts. OIC (LWS_C2FO_REVERSAL_PROCESS, due-date
--   step) reads this and issues the invoiceInstallments batch upsert; the DB sends
--   no REST (client ruling).
-- Grain  : one row per reversal row whose offset half has completed (OFFSET_STATUS
--   ='OK') PLUS the income=0 rows (REV_REQUIRED='N') that skip the offset entirely.
--   This all-or-nothing gate mirrors the award flow (build_duedate_set reads only
--   CM-done rows): the due date is restored only after the offset that undoes the CM
--   has succeeded, so a failed offset never leaves a dangling schedule change.
-- Loop   : OIC passes INSTANCE_ID + CHUNK_ID and reads one chunk at a time, the SAME
--   While 1..N chunk loop as the offset leg -- chunk_rev_offsets chunks ALL eligible
--   rows (income=0 included), so DD-only rows carry a chunk_id and appear here under
--   their chunk, exactly like the award DD-upsert view. Within a chunk, DD_BATCH_NO
--   numbers rows in blocks of 500 (the adf.batch per-call limit).
-- Gate   : stage='OFFSET_VALIDATED' -- the end of the two-stage offset leg. Offset rows
--   reach it after their offset invoice is CREATED then VALIDATED; income=0 DD-only rows
--   are put there at resolve time (they have no offset). The due date is restored only
--   after the offset that undoes the CM has fully validated, so a failed/half-done
--   offset never leaves a dangling schedule change.
-- Columns mirror LWS_C2FO_DD_UPSERT_V's payload so the OIC mapping is the same, but
--   each discount tier emits its ORIGINAL date/amount (restore) rather than pay_date:
--   award_key           - the reversal row's natural key (voucher_id|voucher_line_id),
--                         passed back to annotate_reversal_dd_result
--   invoice_id          - resolved Fusion AP invoice id (upsert target)
--   installment_number  - voucher_line_id (= payment_num, the invoiceInstallments key)
--   due_date            - RESTORE_DUE_DATE (the pre-acceleration due date to put back)
--   first/second/third_discount_date  - the stored ORIG_* dates (NULL => tier not sent)
--   first/second/third_discount_amount - the stored ORIG_* amounts
--------------------------------------------------------------------------------
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.LWS_C2FO_REV_DD_V AS
SELECT s.voucher_id || '|' || s.voucher_line_id       AS award_key,
       s.erp_invoice_id                               AS invoice_id,
       s.voucher_line_id                              AS installment_number,
       s.restore_due_date                             AS due_date,
       CASE WHEN s.orig_first_discount_date IS NOT NULL THEN 'Y' ELSE 'N' END
                                                       AS discount_flag,
       -- Restore each tier to its ORIGINAL date/amount, emitted only when that tier
       -- existed before acceleration (orig_*_discount_date NOT NULL); NULL otherwise
       -- so the element is not sent. This is the exact inverse of the award upsert,
       -- which moved every tier to pay_date.
       s.orig_first_discount_date                     AS first_discount_date,
       s.orig_first_discount_amt                      AS first_discount_amount,
       s.orig_second_discount_date                    AS second_discount_date,
       s.orig_second_discount_amt                     AS second_discount_amount,
       s.orig_third_discount_date                     AS third_discount_date,
       s.orig_third_discount_amt                      AS third_discount_amount,
       s.instance_id                                  AS instance_id,
       s.chunk_id                                     AS chunk_id,
       s.voucher_id                                   AS voucher_id,
       s.voucher_line_id                              AS voucher_line_id,
       CEIL(ROW_NUMBER() OVER (PARTITION BY s.instance_id, s.chunk_id
                               ORDER BY s.voucher_id, s.voucher_line_id) / 500)
                                                       AS dd_batch_no
FROM   LWS_CUSTOM_C2FO_SA.LWS_C2FO_REVERSAL_DATA s
WHERE  s.record_status = 'N'
AND    s.stage         = 'OFFSET_VALIDATED'
-- All-or-nothing per invoice (same gate as the award flow): restore the due date
-- only where the offset half is done. OFFSET_VALIDATED already implies the offset
-- succeeded for income<>0 rows; OFFSET_STATUS='OK' is kept as a defensive double-check.
-- income=0 rows (REV_REQUIRED='N') skip the offset and are DD-restore only.
AND    (s.rev_required = 'N' OR s.offset_status = 'OK')
ORDER  BY s.voucher_id, s.voucher_line_id;
