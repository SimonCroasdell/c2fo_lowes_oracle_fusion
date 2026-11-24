CREATE OR REPLACE PACKAGE BODY lws_c2fo_bridge_pkg AS

    -- Mirror schema owner. Change here if the mirror is relocated.
    c_mirror CONSTANT VARCHAR2(30) := 'LWS_CUSTOM_C2FO_SA';

    ----------------------------------------------------------------------------
    -- SAFE CAST HELPERS
    -- A bad value lands NULL rather than failing the whole set-based MERGE,
    -- matching the loader's conversionerrors=store_null tolerance. BICC emits
    -- ISO timestamps ('YYYY-MM-DD"T"HH24:MI:SS[.FF][Z]'); we try that first,
    -- then a bare date. VERIFY the actual literal from a sample _STG row - if
    -- BICC is configured with a different date mask these helpers silently NULL
    -- every date, which is the single most likely source of a bad load.
    ----------------------------------------------------------------------------
    FUNCTION to_num_safe (p IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN TO_NUMBER(p DEFAULT NULL ON CONVERSION ERROR);
    END to_num_safe;

    FUNCTION to_date_safe (p IN VARCHAR2) RETURN DATE IS
        l_d DATE;
    BEGIN
        IF p IS NULL THEN
            RETURN NULL;
        END IF;
        -- ISO with 'T' separator (BICC default)
        l_d := TO_DATE(SUBSTR(p, 1, 19) DEFAULT NULL ON CONVERSION ERROR,
                       'YYYY-MM-DD"T"HH24:MI:SS');
        IF l_d IS NOT NULL THEN
            RETURN l_d;
        END IF;
        -- bare date
        RETURN TO_DATE(SUBSTR(p, 1, 10) DEFAULT NULL ON CONVERSION ERROR,
                       'YYYY-MM-DD');
    END to_date_safe;

    ----------------------------------------------------------------------------
    -- 1. AP_INVOICES_ALL
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_invoices_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(INVOICE_ID)              AS invoice_id,
                   INVOICE_NUM                          AS invoice_num,
                   INVOICE_TYPE_LOOKUP_CODE             AS invoice_type_lookup_code,
                   to_date_safe(INVOICE_DATE)           AS invoice_date,
                   to_num_safe(VENDOR_ID)               AS vendor_id,
                   to_num_safe(VENDOR_SITE_ID)          AS vendor_site_id,
                   to_num_safe(INVOICE_AMOUNT)          AS invoice_amount,
                   INVOICE_CURRENCY_CODE                AS invoice_currency_code,
                   PAYMENT_CURRENCY_CODE                AS payment_currency_code,
                   to_num_safe(PAYMENT_CROSS_RATE)      AS payment_cross_rate,
                   to_num_safe(AMOUNT_PAID)             AS amount_paid,
                   to_num_safe(TOTAL_TAX_AMOUNT)        AS total_tax_amount,
                   DESCRIPTION                          AS description,
                   SOURCE                               AS source,
                   to_num_safe(TERMS_ID)                AS terms_id,
                   to_date_safe(TERMS_DATE)             AS terms_date,
                   to_date_safe(GL_DATE)                AS gl_date,
                   to_num_safe(ORG_ID)                  AS org_id,
                   to_num_safe(PO_HEADER_ID)            AS po_header_id,
                   PAYMENT_STATUS_FLAG                  AS payment_status_flag,
                   APPROVAL_STATUS                      AS approval_status,
                   WFAPPROVAL_STATUS                    AS wfapproval_status,
                   PAY_GROUP_LOOKUP_CODE                AS pay_group_lookup_code,
                   PAYMENT_METHOD_CODE                  AS payment_method_code,
                   to_date_safe(CANCELLED_DATE)         AS cancelled_date,
                   CUST_REGISTRATION_NUMBER             AS cust_registration_number,
                   to_num_safe(REMIT_TO_SUPPLIER_ID)    AS remit_to_supplier_id,
                   to_num_safe(EXCHANGE_RATE)           AS exchange_rate,
                   EXCHANGE_RATE_TYPE                   AS exchange_rate_type,
                   to_date_safe(EXCHANGE_DATE)          AS exchange_date,
                   ATTRIBUTE_CATEGORY                   AS attribute_category,
                   ATTRIBUTE1, ATTRIBUTE2, ATTRIBUTE3, ATTRIBUTE4, ATTRIBUTE5,
                   ATTRIBUTE6, ATTRIBUTE7, ATTRIBUTE8, ATTRIBUTE9, ATTRIBUTE10,
                   ATTRIBUTE11, ATTRIBUTE12, ATTRIBUTE13, ATTRIBUTE14, ATTRIBUTE15,
                   to_date_safe(CREATION_DATE)          AS creation_date,
                   CREATED_BY                           AS created_by,
                   to_date_safe(LAST_UPDATE_DATE)       AS last_update_date,
                   LAST_UPDATED_BY                      AS last_updated_by,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(INVOICE_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_INV_HEADERS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  INVOICE_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.INVOICE_ID = s.invoice_id)
        WHEN MATCHED THEN UPDATE SET
            t.INVOICE_NUM = s.invoice_num, t.INVOICE_TYPE_LOOKUP_CODE = s.invoice_type_lookup_code,
            t.INVOICE_DATE = s.invoice_date, t.VENDOR_ID = s.vendor_id, t.VENDOR_SITE_ID = s.vendor_site_id,
            t.INVOICE_AMOUNT = s.invoice_amount, t.INVOICE_CURRENCY_CODE = s.invoice_currency_code,
            t.PAYMENT_CURRENCY_CODE = s.payment_currency_code, t.PAYMENT_CROSS_RATE = s.payment_cross_rate,
            t.AMOUNT_PAID = s.amount_paid, t.TOTAL_TAX_AMOUNT = s.total_tax_amount, t.DESCRIPTION = s.description,
            t.SOURCE = s.source, t.TERMS_ID = s.terms_id, t.TERMS_DATE = s.terms_date, t.GL_DATE = s.gl_date,
            t.ORG_ID = s.org_id, t.PO_HEADER_ID = s.po_header_id, t.PAYMENT_STATUS_FLAG = s.payment_status_flag,
            t.APPROVAL_STATUS = s.approval_status, t.WFAPPROVAL_STATUS = s.wfapproval_status,
            t.PAY_GROUP_LOOKUP_CODE = s.pay_group_lookup_code,
            t.PAYMENT_METHOD_CODE = s.payment_method_code, t.CANCELLED_DATE = s.cancelled_date,
            t.CUST_REGISTRATION_NUMBER = s.cust_registration_number, t.REMIT_TO_SUPPLIER_ID = s.remit_to_supplier_id,
            t.EXCHANGE_RATE = s.exchange_rate, t.EXCHANGE_RATE_TYPE = s.exchange_rate_type, t.EXCHANGE_DATE = s.exchange_date,
            t.ATTRIBUTE_CATEGORY = s.attribute_category,
            t.ATTRIBUTE1 = s.ATTRIBUTE1, t.ATTRIBUTE2 = s.ATTRIBUTE2, t.ATTRIBUTE3 = s.ATTRIBUTE3,
            t.ATTRIBUTE4 = s.ATTRIBUTE4, t.ATTRIBUTE5 = s.ATTRIBUTE5, t.ATTRIBUTE6 = s.ATTRIBUTE6,
            t.ATTRIBUTE7 = s.ATTRIBUTE7, t.ATTRIBUTE8 = s.ATTRIBUTE8, t.ATTRIBUTE9 = s.ATTRIBUTE9,
            t.ATTRIBUTE10 = s.ATTRIBUTE10, t.ATTRIBUTE11 = s.ATTRIBUTE11, t.ATTRIBUTE12 = s.ATTRIBUTE12,
            t.ATTRIBUTE13 = s.ATTRIBUTE13, t.ATTRIBUTE14 = s.ATTRIBUTE14, t.ATTRIBUTE15 = s.ATTRIBUTE15,
            t.CREATION_DATE = s.creation_date, t.CREATED_BY = s.created_by,
            t.LAST_UPDATE_DATE = s.last_update_date, t.LAST_UPDATED_BY = s.last_updated_by
        WHEN NOT MATCHED THEN INSERT (
            t.INVOICE_ID, t.INVOICE_NUM, t.INVOICE_TYPE_LOOKUP_CODE, t.INVOICE_DATE, t.VENDOR_ID, t.VENDOR_SITE_ID,
            t.INVOICE_AMOUNT, t.INVOICE_CURRENCY_CODE, t.PAYMENT_CURRENCY_CODE, t.PAYMENT_CROSS_RATE, t.AMOUNT_PAID,
            t.TOTAL_TAX_AMOUNT, t.DESCRIPTION, t.SOURCE, t.TERMS_ID, t.TERMS_DATE, t.GL_DATE, t.ORG_ID, t.PO_HEADER_ID,
            t.PAYMENT_STATUS_FLAG, t.APPROVAL_STATUS, t.WFAPPROVAL_STATUS, t.PAY_GROUP_LOOKUP_CODE, t.PAYMENT_METHOD_CODE, t.CANCELLED_DATE,
            t.CUST_REGISTRATION_NUMBER, t.REMIT_TO_SUPPLIER_ID, t.EXCHANGE_RATE, t.EXCHANGE_RATE_TYPE, t.EXCHANGE_DATE,
            t.ATTRIBUTE_CATEGORY, t.ATTRIBUTE1, t.ATTRIBUTE2, t.ATTRIBUTE3, t.ATTRIBUTE4, t.ATTRIBUTE5, t.ATTRIBUTE6,
            t.ATTRIBUTE7, t.ATTRIBUTE8, t.ATTRIBUTE9, t.ATTRIBUTE10, t.ATTRIBUTE11, t.ATTRIBUTE12, t.ATTRIBUTE13,
            t.ATTRIBUTE14, t.ATTRIBUTE15, t.CREATION_DATE, t.CREATED_BY, t.LAST_UPDATE_DATE, t.LAST_UPDATED_BY
        ) VALUES (
            s.invoice_id, s.invoice_num, s.invoice_type_lookup_code, s.invoice_date, s.vendor_id, s.vendor_site_id,
            s.invoice_amount, s.invoice_currency_code, s.payment_currency_code, s.payment_cross_rate, s.amount_paid,
            s.total_tax_amount, s.description, s.source, s.terms_id, s.terms_date, s.gl_date, s.org_id, s.po_header_id,
            s.payment_status_flag, s.approval_status, s.wfapproval_status, s.pay_group_lookup_code, s.payment_method_code, s.cancelled_date,
            s.cust_registration_number, s.remit_to_supplier_id, s.exchange_rate, s.exchange_rate_type, s.exchange_date,
            s.attribute_category, s.ATTRIBUTE1, s.ATTRIBUTE2, s.ATTRIBUTE3, s.ATTRIBUTE4, s.ATTRIBUTE5, s.ATTRIBUTE6,
            s.ATTRIBUTE7, s.ATTRIBUTE8, s.ATTRIBUTE9, s.ATTRIBUTE10, s.ATTRIBUTE11, s.ATTRIBUTE12, s.ATTRIBUTE13,
            s.ATTRIBUTE14, s.ATTRIBUTE15, s.creation_date, s.created_by, s.last_update_date, s.last_updated_by
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        -- STG rows are now in the mirror; delete the rows we just consumed so the next
        -- incremental load starts clean and stale PKs don't linger. DELETE (not TRUNCATE)
        -- so it stays in the same transaction as the MERGE - a later bridge failure rolls
        -- this back too, and the single COMMIT lives in bridge_all_proc. ERROR rows are
        -- preserved (they were never bridged) for inspection.
        DELETE FROM LWS_C2FO_AP_INV_HEADERS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_invoices_proc;

    ----------------------------------------------------------------------------
    -- 2. AP_INVOICE_LINES_ALL  (PK INVOICE_ID, LINE_NUMBER)
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_inv_lines_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_LINES_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(INVOICE_ID)        AS invoice_id,
                   to_num_safe(LINE_NUMBER)       AS line_number,
                   LINE_TYPE_LOOKUP_CODE          AS line_type_lookup_code,
                   to_num_safe(AMOUNT)            AS amount,
                   to_num_safe(ORG_ID)            AS org_id,
                   DESCRIPTION                    AS description,
                   to_date_safe(CREATION_DATE)    AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE) AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(INVOICE_ID), to_num_safe(LINE_NUMBER)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_INV_LINES_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  INVOICE_ID IS NOT NULL AND LINE_NUMBER IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.INVOICE_ID = s.invoice_id AND t.LINE_NUMBER = s.line_number)
        WHEN MATCHED THEN UPDATE SET
            t.LINE_TYPE_LOOKUP_CODE = s.line_type_lookup_code, t.AMOUNT = s.amount, t.ORG_ID = s.org_id,
            t.DESCRIPTION = s.description, t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.INVOICE_ID, t.LINE_NUMBER, t.LINE_TYPE_LOOKUP_CODE, t.AMOUNT, t.ORG_ID, t.DESCRIPTION,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.invoice_id, s.line_number, s.line_type_lookup_code, s.amount, s.org_id, s.description,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_INV_LINES_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_inv_lines_proc;

    ----------------------------------------------------------------------------
    -- 3. AP_INVOICE_DISTRIBUTIONS_ALL  (PK INVOICE_DISTRIBUTION_ID)
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_inv_dists_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_DISTRIBUTIONS_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(INVOICE_DISTRIBUTION_ID) AS invoice_distribution_id,
                   to_num_safe(INVOICE_ID)              AS invoice_id,
                   to_num_safe(INVOICE_LINE_NUMBER)     AS invoice_line_number,
                   to_num_safe(DISTRIBUTION_LINE_NUMBER) AS distribution_line_number,
                   LINE_TYPE_LOOKUP_CODE                AS line_type_lookup_code,
                   to_num_safe(AMOUNT)                  AS amount,
                   to_num_safe(ORG_ID)                  AS org_id,
                   to_date_safe(CREATION_DATE)          AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)       AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(INVOICE_DISTRIBUTION_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_INV_DISTS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  INVOICE_DISTRIBUTION_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.INVOICE_DISTRIBUTION_ID = s.invoice_distribution_id)
        WHEN MATCHED THEN UPDATE SET
            t.INVOICE_ID = s.invoice_id, t.INVOICE_LINE_NUMBER = s.invoice_line_number,
            t.DISTRIBUTION_LINE_NUMBER = s.distribution_line_number, t.LINE_TYPE_LOOKUP_CODE = s.line_type_lookup_code,
            t.AMOUNT = s.amount, t.ORG_ID = s.org_id, t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.INVOICE_DISTRIBUTION_ID, t.INVOICE_ID, t.INVOICE_LINE_NUMBER, t.DISTRIBUTION_LINE_NUMBER,
            t.LINE_TYPE_LOOKUP_CODE, t.AMOUNT, t.ORG_ID, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.invoice_distribution_id, s.invoice_id, s.invoice_line_number, s.distribution_line_number,
            s.line_type_lookup_code, s.amount, s.org_id, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_INV_DISTS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_inv_dists_proc;

    ----------------------------------------------------------------------------
    -- 4. AP_PAYMENT_SCHEDULES_ALL  (PK INVOICE_ID, PAYMENT_NUM)
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_pay_scheds_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_PAYMENT_SCHEDULES_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(INVOICE_ID)                 AS invoice_id,
                   to_num_safe(PAYMENT_NUM)                AS payment_num,
                   to_date_safe(DUE_DATE)                  AS due_date,
                   to_num_safe(GROSS_AMOUNT)               AS gross_amount,
                   to_num_safe(AMOUNT_REMAINING)           AS amount_remaining,
                   to_date_safe(DISCOUNT_DATE)             AS discount_date,
                   to_date_safe(SECOND_DISCOUNT_DATE)      AS second_discount_date,
                   to_date_safe(THIRD_DISCOUNT_DATE)       AS third_discount_date,
                   to_num_safe(DISCOUNT_AMOUNT_AVAILABLE)  AS discount_amount_available,
                   to_num_safe(SECOND_DISC_AMT_AVAILABLE)  AS second_disc_amt_available,
                   to_num_safe(THIRD_DISC_AMT_AVAILABLE)   AS third_disc_amt_available,
                   PAYMENT_STATUS_FLAG                     AS payment_status_flag,
                   PAYMENT_METHOD_CODE                     AS payment_method_code,
                   REMIT_TO_SUPPLIER_NAME                  AS remit_to_supplier_name,
                   to_num_safe(REMIT_TO_SUPPLIER_ID)       AS remit_to_supplier_id,
                   REMITTANCE_MESSAGE1                     AS remittance_message1,
                   REMITTANCE_MESSAGE2                     AS remittance_message2,
                   REMITTANCE_MESSAGE3                     AS remittance_message3,
                   HOLD_FLAG                               AS hold_flag,
                   to_date_safe(CREATION_DATE)             AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)          AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(INVOICE_ID), to_num_safe(PAYMENT_NUM)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_PAY_SCHEDS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  INVOICE_ID IS NOT NULL AND PAYMENT_NUM IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.INVOICE_ID = s.invoice_id AND t.PAYMENT_NUM = s.payment_num)
        WHEN MATCHED THEN UPDATE SET
            t.DUE_DATE = s.due_date, t.GROSS_AMOUNT = s.gross_amount, t.AMOUNT_REMAINING = s.amount_remaining,
            t.DISCOUNT_DATE = s.discount_date, t.SECOND_DISCOUNT_DATE = s.second_discount_date,
            t.THIRD_DISCOUNT_DATE = s.third_discount_date, t.DISCOUNT_AMOUNT_AVAILABLE = s.discount_amount_available,
            t.SECOND_DISC_AMT_AVAILABLE = s.second_disc_amt_available, t.THIRD_DISC_AMT_AVAILABLE = s.third_disc_amt_available,
            t.PAYMENT_STATUS_FLAG = s.payment_status_flag, t.PAYMENT_METHOD_CODE = s.payment_method_code,
            t.REMIT_TO_SUPPLIER_NAME = s.remit_to_supplier_name, t.REMIT_TO_SUPPLIER_ID = s.remit_to_supplier_id,
            t.REMITTANCE_MESSAGE1 = s.remittance_message1, t.REMITTANCE_MESSAGE2 = s.remittance_message2,
            t.REMITTANCE_MESSAGE3 = s.remittance_message3, t.HOLD_FLAG = s.hold_flag,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.INVOICE_ID, t.PAYMENT_NUM, t.DUE_DATE, t.GROSS_AMOUNT, t.AMOUNT_REMAINING, t.DISCOUNT_DATE,
            t.SECOND_DISCOUNT_DATE, t.THIRD_DISCOUNT_DATE, t.DISCOUNT_AMOUNT_AVAILABLE, t.SECOND_DISC_AMT_AVAILABLE,
            t.THIRD_DISC_AMT_AVAILABLE, t.PAYMENT_STATUS_FLAG, t.PAYMENT_METHOD_CODE, t.REMIT_TO_SUPPLIER_NAME,
            t.REMIT_TO_SUPPLIER_ID, t.REMITTANCE_MESSAGE1, t.REMITTANCE_MESSAGE2, t.REMITTANCE_MESSAGE3, t.HOLD_FLAG,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.invoice_id, s.payment_num, s.due_date, s.gross_amount, s.amount_remaining, s.discount_date,
            s.second_discount_date, s.third_discount_date, s.discount_amount_available, s.second_disc_amt_available,
            s.third_disc_amt_available, s.payment_status_flag, s.payment_method_code, s.remit_to_supplier_name,
            s.remit_to_supplier_id, s.remittance_message1, s.remittance_message2, s.remittance_message3, s.hold_flag,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_PAY_SCHEDS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_pay_scheds_proc;

    ----------------------------------------------------------------------------
    -- 4a. AP_TERMS_TL  (PK TERM_ID, LANGUAGE)
    -- Source = LWS_C2FO_AP_TERM_TRANSLATIONS_STG (PaymentTermHeaderTranslation-
    -- ExtractPVO, entity group AP_PAYMENT_TERMS). The outbound invoice + org
    -- extracts INNER JOIN ap_terms_tl on (term_id, language='US'); an empty mirror
    -- drops EVERY invoice, so this bridge is a hard prerequisite for a non-empty
    -- outbound. 1:1 column match; no derivation. SOURCE_LANG carried through so a
    -- consumer can tell base-language rows from translations.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_terms_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_TERMS_TL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(TERM_ID)           AS term_id,
                   LANGUAGE                        AS language,
                   NAME                            AS name,
                   DESCRIPTION                     AS description,
                   SOURCE_LANG                     AS source_lang,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(TERM_ID), LANGUAGE
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_TERM_TRANSLATIONS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  TERM_ID IS NOT NULL AND LANGUAGE IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.TERM_ID = s.term_id AND t.LANGUAGE = s.language)
        WHEN MATCHED THEN UPDATE SET
            t.NAME = s.name, t.DESCRIPTION = s.description, t.SOURCE_LANG = s.source_lang,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.TERM_ID, t.LANGUAGE, t.NAME, t.DESCRIPTION, t.SOURCE_LANG,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.term_id, s.language, s.name, s.description, s.source_lang,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_TERM_TRANSLATIONS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_terms_proc;

    ----------------------------------------------------------------------------
    -- 4b2. HR_ALL_ORGANIZATION_UNITS  (PK ORGANIZATION_ID)  [sourced from BU]
    -- Source = LWS_C2FO_BUSINESS_UNITS_STG (BusinessUnitExtractPVO, entity group
    -- FUN_BUSINESS_UNIT). There is NO HR org-units PVO in the offering; in Fusion
    -- AP the invoice org_id IS the business-unit id, and the outbound INNER JOINs
    -- hr_all_organization_units.organization_id = aia.org_id, so the BU rows ARE
    -- the org units the extract needs. ORGANIZATION_ID<-BU_ID, NAME<-BU_NAME,
    -- effective dates carried through. LOCATION_ID has no BU source -> left NULL,
    -- so the invoice buyer_address (LEFT JOIN hr_locations_all) renders blank until
    -- HR_LOCATIONS_ALL is plumbed (Phase 2). Empty mirror here = zero invoices, so
    -- this is a hard prerequisite alongside bridge_ap_terms_proc.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_bu_org_units_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_HR_ALL_ORGANIZATION_UNITS t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(BU_ID)             AS organization_id,
                   BU_NAME                         AS name,
                   CAST(NULL AS NUMBER)            AS location_id,   -- no BU source
                   to_date_safe(DATE_FROM)         AS date_from,
                   to_date_safe(DATE_TO)           AS date_to,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(BU_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_BUSINESS_UNITS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  BU_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.ORGANIZATION_ID = s.organization_id)
        WHEN MATCHED THEN UPDATE SET
            t.NAME = s.name, t.DATE_FROM = s.date_from, t.DATE_TO = s.date_to,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
            -- LOCATION_ID intentionally NOT updated (no BU source; preserve any
            -- value a future HR_LOCATIONS plumbing might set another way)
        WHEN NOT MATCHED THEN INSERT (
            t.ORGANIZATION_ID, t.NAME, t.LOCATION_ID, t.DATE_FROM, t.DATE_TO,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.organization_id, s.name, s.location_id, s.date_from, s.date_to,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_BUSINESS_UNITS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_bu_org_units_proc;

    ----------------------------------------------------------------------------
    -- 4b. HZ_PARTIES  (PK PARTY_ID)
    -- Source = LWS_C2FO_HZ_PARTIES_STG (PartyExtractPVO). Supplies PARTY_NAME for
    -- the supplier bridge's VENDOR_NAME (proc 5 joins this mirror on PARTY_ID) and
    -- PERSON_FIRST/LAST_NAME for the outbound user file. MUST run BEFORE
    -- bridge_suppliers_proc so the mirror is populated when suppliers reads it.
    -- GAP (BICC selection): the extract carries only PARTY_ID, PARTY_NAME,
    -- PERSON_FIRST_NAME, PERSON_LAST_NAME, STATUS. PARTY_NUMBER, PARTY_TYPE,
    -- PERSON_TITLE, CREATION_DATE, LAST_UPDATE_DATE are NOT ticked in the PVO ->
    -- they land NULL. Add them to the PartyExtractPVO selection + re-extract if the
    -- user file needs title, or the mirror needs a real LAST_UPDATE_DATE watermark.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_parties_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_HZ_PARTIES t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(PARTY_ID)           AS party_id,
                   PARTY_NUMBER                    AS party_number,
                   PARTY_NAME                      AS party_name,
                   PARTY_TYPE                      AS party_type,
                   PERSON_FIRST_NAME               AS person_first_name,
                   PERSON_LAST_NAME                AS person_last_name,
                   PERSON_TITLE                    AS person_title,
                   STATUS                          AS status,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(PARTY_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_HZ_PARTIES_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  PARTY_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.PARTY_ID = s.party_id)
        WHEN MATCHED THEN UPDATE SET
            t.PARTY_NUMBER = s.party_number, t.PARTY_NAME = s.party_name,
            t.PARTY_TYPE = s.party_type, t.PERSON_FIRST_NAME = s.person_first_name,
            t.PERSON_LAST_NAME = s.person_last_name, t.PERSON_TITLE = s.person_title,
            t.STATUS = s.status, t.CREATION_DATE = s.creation_date,
            t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.PARTY_ID, t.PARTY_NUMBER, t.PARTY_NAME, t.PARTY_TYPE, t.PERSON_FIRST_NAME,
            t.PERSON_LAST_NAME, t.PERSON_TITLE, t.STATUS, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.party_id, s.party_number, s.party_name, s.party_type, s.person_first_name,
            s.person_last_name, s.person_title, s.status, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        -- Do NOT delete LWS_C2FO_HZ_PARTIES_STG here: bridge_suppliers_proc runs next
        -- and reads PARTY_NAME from the TYPED mirror (already populated above), so the
        -- STG is no longer needed by suppliers. But other consumers (user file sourcing)
        -- may want parties too; the mirror is the store, so clear STG to keep the next
        -- incremental clean, consistent with the other bridges.
        DELETE FROM LWS_C2FO_HZ_PARTIES_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_parties_proc;

    ----------------------------------------------------------------------------
    -- 5. POZ_SUPPLIERS_V  (PK VENDOR_ID)
    -- VENDOR_NAME is sourced from the TYPED LWS_HZ_PARTIES mirror (populated by
    -- bridge_parties_proc, which runs just before this) via a scalar subquery on
    -- PARTY_ID. The SupplierExtractPVO.VendorName attribute comes back NULL in the
    -- BICC extract, so SUPPLIERS_STG.VENDOR_NAME is unreliable; the HZ_PARTIES
    -- PARTY_NAME is the authoritative source. NVL falls back to any STG value.
    -- GAP remaining: _STG has no ENABLED_FLAG column -> left NULL. Downstream must
    -- NOT rely on ENABLED_FLAG from this mirror (qualify on START/END_DATE_ACTIVE).
    ----------------------------------------------------------------------------
    PROCEDURE bridge_suppliers_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(VENDOR_ID)          AS vendor_id,
                   to_num_safe(PARTY_ID)           AS party_id,
                   NVL(
                     (SELECT p.PARTY_NAME
                        FROM LWS_CUSTOM_C2FO_SA.LWS_HZ_PARTIES p
                       WHERE p.PARTY_ID = to_num_safe(sup.PARTY_ID)),
                     sup.VENDOR_NAME
                   )                               AS vendor_name,
                   SEGMENT1                        AS segment1,
                   VENDOR_TYPE_LOOKUP_CODE         AS vendor_type_lookup_code,
                   CAST(NULL AS VARCHAR2(1))       AS enabled_flag,         -- GAP: not in _STG
                   to_date_safe(START_DATE_ACTIVE) AS start_date_active,
                   to_date_safe(END_DATE_ACTIVE)   AS end_date_active,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   -- descriptive flexfield attributes, carried 1:1 (text, no typing)
                   ATTRIBUTE1  AS attribute1,  ATTRIBUTE2  AS attribute2,
                   ATTRIBUTE3  AS attribute3,  ATTRIBUTE4  AS attribute4,
                   ATTRIBUTE5  AS attribute5,  ATTRIBUTE6  AS attribute6,
                   ATTRIBUTE7  AS attribute7,  ATTRIBUTE8  AS attribute8,
                   ATTRIBUTE9  AS attribute9,  ATTRIBUTE10 AS attribute10,
                   ATTRIBUTE11 AS attribute11, ATTRIBUTE12 AS attribute12,
                   ATTRIBUTE13 AS attribute13, ATTRIBUTE14 AS attribute14,
                   ATTRIBUTE15 AS attribute15, ATTRIBUTE16 AS attribute16,
                   ATTRIBUTE17 AS attribute17, ATTRIBUTE18 AS attribute18,
                   ATTRIBUTE19 AS attribute19, ATTRIBUTE20 AS attribute20
                   ,ROW_NUMBER() OVER (PARTITION BY to_num_safe(sup.VENDOR_ID)
                                       ORDER BY to_date_safe(sup.LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_SUPPLIERS_STG sup
            WHERE  NVL(sup.RECORD_STATUS,'x') <> 'ERROR'
              AND  sup.VENDOR_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.VENDOR_ID = s.vendor_id)
        WHEN MATCHED THEN UPDATE SET
            t.PARTY_ID = s.party_id, t.VENDOR_NAME = s.vendor_name, t.SEGMENT1 = s.segment1,
            t.VENDOR_TYPE_LOOKUP_CODE = s.vendor_type_lookup_code,
            t.START_DATE_ACTIVE = s.start_date_active, t.END_DATE_ACTIVE = s.end_date_active,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date,
            t.ATTRIBUTE1  = s.attribute1,  t.ATTRIBUTE2  = s.attribute2,
            t.ATTRIBUTE3  = s.attribute3,  t.ATTRIBUTE4  = s.attribute4,
            t.ATTRIBUTE5  = s.attribute5,  t.ATTRIBUTE6  = s.attribute6,
            t.ATTRIBUTE7  = s.attribute7,  t.ATTRIBUTE8  = s.attribute8,
            t.ATTRIBUTE9  = s.attribute9,  t.ATTRIBUTE10 = s.attribute10,
            t.ATTRIBUTE11 = s.attribute11, t.ATTRIBUTE12 = s.attribute12,
            t.ATTRIBUTE13 = s.attribute13, t.ATTRIBUTE14 = s.attribute14,
            t.ATTRIBUTE15 = s.attribute15, t.ATTRIBUTE16 = s.attribute16,
            t.ATTRIBUTE17 = s.attribute17, t.ATTRIBUTE18 = s.attribute18,
            t.ATTRIBUTE19 = s.attribute19, t.ATTRIBUTE20 = s.attribute20
            -- ENABLED_FLAG intentionally NOT updated (no _STG source)
        WHEN NOT MATCHED THEN INSERT (
            t.VENDOR_ID, t.PARTY_ID, t.VENDOR_NAME, t.SEGMENT1, t.VENDOR_TYPE_LOOKUP_CODE, t.ENABLED_FLAG,
            t.START_DATE_ACTIVE, t.END_DATE_ACTIVE, t.CREATION_DATE, t.LAST_UPDATE_DATE,
            t.ATTRIBUTE1,  t.ATTRIBUTE2,  t.ATTRIBUTE3,  t.ATTRIBUTE4,  t.ATTRIBUTE5,
            t.ATTRIBUTE6,  t.ATTRIBUTE7,  t.ATTRIBUTE8,  t.ATTRIBUTE9,  t.ATTRIBUTE10,
            t.ATTRIBUTE11, t.ATTRIBUTE12, t.ATTRIBUTE13, t.ATTRIBUTE14, t.ATTRIBUTE15,
            t.ATTRIBUTE16, t.ATTRIBUTE17, t.ATTRIBUTE18, t.ATTRIBUTE19, t.ATTRIBUTE20
        ) VALUES (
            s.vendor_id, s.party_id, s.vendor_name, s.segment1, s.vendor_type_lookup_code, s.enabled_flag,
            s.start_date_active, s.end_date_active, s.creation_date, s.last_update_date,
            s.attribute1,  s.attribute2,  s.attribute3,  s.attribute4,  s.attribute5,
            s.attribute6,  s.attribute7,  s.attribute8,  s.attribute9,  s.attribute10,
            s.attribute11, s.attribute12, s.attribute13, s.attribute14, s.attribute15,
            s.attribute16, s.attribute17, s.attribute18, s.attribute19, s.attribute20
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_SUPPLIERS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_suppliers_proc;

    ----------------------------------------------------------------------------
    -- 6. HZ_CONTACT_POINTS  (PK CONTACT_POINT_ID)
    ----------------------------------------------------------------------------
    PROCEDURE bridge_contact_points_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_HZ_CONTACT_POINTS t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(CONTACT_POINT_ID)   AS contact_point_id,
                   CONTACT_POINT_TYPE              AS contact_point_type,
                   OWNER_TABLE_NAME                AS owner_table_name,
                   to_num_safe(OWNER_TABLE_ID)     AS owner_table_id,
                   STATUS                          AS status,
                   PRIMARY_FLAG                    AS primary_flag,
                   EMAIL_ADDRESS                   AS email_address,
                   PHONE_COUNTRY_CODE              AS phone_country_code,
                   PHONE_AREA_CODE                 AS phone_area_code,
                   PHONE_NUMBER                    AS phone_number,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(CONTACT_POINT_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_CONTACT_POINTS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  CONTACT_POINT_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.CONTACT_POINT_ID = s.contact_point_id)
        WHEN MATCHED THEN UPDATE SET
            t.CONTACT_POINT_TYPE = s.contact_point_type, t.OWNER_TABLE_NAME = s.owner_table_name,
            t.OWNER_TABLE_ID = s.owner_table_id, t.STATUS = s.status, t.PRIMARY_FLAG = s.primary_flag,
            t.EMAIL_ADDRESS = s.email_address, t.PHONE_COUNTRY_CODE = s.phone_country_code,
            t.PHONE_AREA_CODE = s.phone_area_code, t.PHONE_NUMBER = s.phone_number,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.CONTACT_POINT_ID, t.CONTACT_POINT_TYPE, t.OWNER_TABLE_NAME, t.OWNER_TABLE_ID, t.STATUS, t.PRIMARY_FLAG,
            t.EMAIL_ADDRESS, t.PHONE_COUNTRY_CODE, t.PHONE_AREA_CODE, t.PHONE_NUMBER, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.contact_point_id, s.contact_point_type, s.owner_table_name, s.owner_table_id, s.status, s.primary_flag,
            s.email_address, s.phone_country_code, s.phone_area_code, s.phone_number, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_CONTACT_POINTS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_contact_points_proc;

    ----------------------------------------------------------------------------
    -- 7. HZ_RELATIONSHIPS  (PK RELATIONSHIP_ID)
    -- Sourced from the RelationshipExtractPVO feed (LWS_C2FO_RELATIONSHIPS_STG),
    -- which carries the real SUBJECT_ID/OBJECT_ID/*_TABLE_NAME/RELATIONSHIP_CODE
    -- the outbound USER file needs (join rel.object_id = supplier party_id,
    -- contact.party_id = rel.subject_id). The previous version sourced
    -- LWS_C2FO_ORG_CONTACTS_STG, which lacked subject/object, so every user row
    -- was dropped. Key the mirror on the logical RELATIONSHIP_ID; the extract's
    -- RelationshipCode='CONTACT_OF' filter yields one directional row per id.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_relationships_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_HZ_RELATIONSHIPS t
        USING (
            -- The mirror PK is RELATIONSHIP_ID alone, but a logical relationship has
            -- TWO directional rows in HZ_RELATIONSHIPS sharing one RELATIONSHIP_ID.
            -- If the BICC extract is NOT filtered to RelationshipCode='CONTACT_OF',
            -- both directions land and collide on the PK (ORA-00001). Guard here so
            -- the bridge is correct regardless of the extract filter: keep only the
            -- CONTACT_OF direction (object=supplier party, subject=contact party)
            -- and, defensively, pick exactly one row per RELATIONSHIP_ID.
            SELECT relationship_id, subject_id, subject_table_name,
                   object_id, object_table_name, relationship_code, relationship_type,
                   status, start_date, end_date, creation_date, last_update_date
            FROM (
                SELECT to_num_safe(RELATIONSHIP_ID)   AS relationship_id,
                       to_num_safe(SUBJECT_ID)        AS subject_id,
                       SUBJECT_TABLE_NAME             AS subject_table_name,
                       to_num_safe(OBJECT_ID)         AS object_id,
                       OBJECT_TABLE_NAME              AS object_table_name,
                       RELATIONSHIP_CODE              AS relationship_code,
                       RELATIONSHIP_TYPE              AS relationship_type,
                       STATUS                         AS status,
                       to_date_safe(START_DATE)       AS start_date,
                       to_date_safe(END_DATE)         AS end_date,
                       to_date_safe(CREATION_DATE)    AS creation_date,
                       to_date_safe(LAST_UPDATE_DATE) AS last_update_date,
                       ROW_NUMBER() OVER (
                           PARTITION BY to_num_safe(RELATIONSHIP_ID)
                           ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST
                       ) AS rn
                FROM   LWS_C2FO_RELATIONSHIPS_STG
                WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
                  AND  RELATIONSHIP_ID IS NOT NULL
                  AND  RELATIONSHIP_CODE = 'CONTACT_OF'
            )
            WHERE rn = 1
        ) s
        ON (t.RELATIONSHIP_ID = s.relationship_id)
        WHEN MATCHED THEN UPDATE SET
            t.SUBJECT_ID = s.subject_id, t.SUBJECT_TABLE_NAME = s.subject_table_name,
            t.OBJECT_ID = s.object_id, t.OBJECT_TABLE_NAME = s.object_table_name,
            t.RELATIONSHIP_CODE = s.relationship_code, t.RELATIONSHIP_TYPE = s.relationship_type,
            t.STATUS = s.status, t.START_DATE = s.start_date, t.END_DATE = s.end_date,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.RELATIONSHIP_ID, t.SUBJECT_ID, t.SUBJECT_TABLE_NAME, t.OBJECT_ID, t.OBJECT_TABLE_NAME,
            t.RELATIONSHIP_CODE, t.RELATIONSHIP_TYPE, t.STATUS, t.START_DATE, t.END_DATE,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.relationship_id, s.subject_id, s.subject_table_name, s.object_id, s.object_table_name,
            s.relationship_code, s.relationship_type, s.status, s.start_date, s.end_date,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_RELATIONSHIPS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_relationships_proc;

    ----------------------------------------------------------------------------
    -- 8. PO_HEADERS_ALL  (PK PO_HEADER_ID). mirror ORG_ID <- _STG PRC_BU_ID.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_po_headers_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_PO_HEADERS_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(PO_HEADER_ID)       AS po_header_id,
                   SEGMENT1                        AS segment1,
                   TYPE_LOOKUP_CODE                AS type_lookup_code,
                   to_num_safe(VENDOR_ID)          AS vendor_id,
                   to_num_safe(VENDOR_SITE_ID)     AS vendor_site_id,
                   to_num_safe(TERMS_ID)           AS terms_id,
                   CURRENCY_CODE                   AS currency_code,
                   to_num_safe(PRC_BU_ID)          AS org_id,          -- Fusion renamed org -> prc_bu
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(PO_HEADER_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_PO_HEADERS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  PO_HEADER_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.PO_HEADER_ID = s.po_header_id)
        WHEN MATCHED THEN UPDATE SET
            t.SEGMENT1 = s.segment1, t.TYPE_LOOKUP_CODE = s.type_lookup_code, t.VENDOR_ID = s.vendor_id,
            t.VENDOR_SITE_ID = s.vendor_site_id, t.TERMS_ID = s.terms_id, t.CURRENCY_CODE = s.currency_code,
            t.ORG_ID = s.org_id, t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.PO_HEADER_ID, t.SEGMENT1, t.TYPE_LOOKUP_CODE, t.VENDOR_ID, t.VENDOR_SITE_ID, t.TERMS_ID,
            t.CURRENCY_CODE, t.ORG_ID, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.po_header_id, s.segment1, s.type_lookup_code, s.vendor_id, s.vendor_site_id, s.terms_id,
            s.currency_code, s.org_id, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_PO_HEADERS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_po_headers_proc;

    ----------------------------------------------------------------------------
    -- 9. POZ_SUPPLIER_SITES_ALL_M  (PK VENDOR_SITE_ID). mirror ORG_ID <- PRC_BU_ID.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_supplier_sites_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(VENDOR_SITE_ID)     AS vendor_site_id,
                   to_num_safe(VENDOR_ID)          AS vendor_id,
                   VENDOR_SITE_CODE                AS vendor_site_code,
                   to_num_safe(PRC_BU_ID)          AS org_id,          -- Fusion renamed org -> prc_bu
                   to_num_safe(PARTY_SITE_ID)      AS party_site_id,
                   to_num_safe(LOCATION_ID)        AS location_id,
                   to_num_safe(TERMS_ID)           AS terms_id,
                   PAY_GROUP_LOOKUP_CODE           AS pay_group_lookup_code,
                   HOLD_ALL_PAYMENTS_FLAG          AS hold_all_payments_flag,
                   HOLD_FLAG                       AS hold_flag,
                   to_date_safe(INACTIVE_DATE)     AS inactive_date,
                   to_date_safe(CREATION_DATE)     AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)  AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(VENDOR_SITE_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_SUPPLIER_SITES_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  VENDOR_SITE_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.VENDOR_SITE_ID = s.vendor_site_id)
        WHEN MATCHED THEN UPDATE SET
            t.VENDOR_ID = s.vendor_id, t.VENDOR_SITE_CODE = s.vendor_site_code, t.ORG_ID = s.org_id,
            t.PARTY_SITE_ID = s.party_site_id, t.LOCATION_ID = s.location_id, t.TERMS_ID = s.terms_id,
            t.PAY_GROUP_LOOKUP_CODE = s.pay_group_lookup_code, t.HOLD_ALL_PAYMENTS_FLAG = s.hold_all_payments_flag,
            t.HOLD_FLAG = s.hold_flag, t.INACTIVE_DATE = s.inactive_date, t.CREATION_DATE = s.creation_date,
            t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.VENDOR_SITE_ID, t.VENDOR_ID, t.VENDOR_SITE_CODE, t.ORG_ID, t.PARTY_SITE_ID, t.LOCATION_ID, t.TERMS_ID,
            t.PAY_GROUP_LOOKUP_CODE, t.HOLD_ALL_PAYMENTS_FLAG, t.HOLD_FLAG, t.INACTIVE_DATE, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.vendor_site_id, s.vendor_id, s.vendor_site_code, s.org_id, s.party_site_id, s.location_id, s.terms_id,
            s.pay_group_lookup_code, s.hold_all_payments_flag, s.hold_flag, s.inactive_date, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        -- This bridge is the sole reader of SUPPLIER_SITES_STG (the address bridge
        -- now derives VENDOR_ID from the persistent mirror, not this landing table),
        -- so drain it here after the sites MERGE.
        DELETE FROM LWS_C2FO_SUPPLIER_SITES_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_supplier_sites_proc;

    PROCEDURE bridge_supplier_tp_pmt_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_POZ_SUP_THIRDPARTY_PAYMENT_REL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(TPP_RELATIONSHIP_ID)   AS tpp_relationship_id,
                   to_num_safe(VENDOR_SITE_ID)        AS vendor_site_id,
                   to_num_safe(REMIT_TO_SUPPLIER_ID)  AS remit_to_supplier_id,
                   to_num_safe(REMIT_TO_ADDRESS_ID)   AS remit_to_address_id,
                   DEFAULT_RELATIONSHIP_FLAG          AS default_relationship_flag,
                   DESCRIPTION                        AS description,
                   to_date_safe(FROM_DATE)            AS from_date,
                   to_date_safe(TO_DATE)              AS to_date,
                   to_num_safe(OBJECT_VERSION_NUMBER) AS object_version_number,
                   CREATED_BY                         AS created_by,
                   to_date_safe(CREATION_DATE)        AS creation_date,
                   LAST_UPDATED_BY                    AS last_updated_by,
                   LAST_UPDATE_LOGIN                  AS last_update_login,
                   to_date_safe(LAST_UPDATE_DATE)     AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(TPP_RELATIONSHIP_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_SUPPLIER_TP_PMT_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  TPP_RELATIONSHIP_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.TPP_RELATIONSHIP_ID = s.tpp_relationship_id)
        WHEN MATCHED THEN UPDATE SET
            t.VENDOR_SITE_ID = s.vendor_site_id, t.REMIT_TO_SUPPLIER_ID = s.remit_to_supplier_id,
            t.REMIT_TO_ADDRESS_ID = s.remit_to_address_id, t.DEFAULT_RELATIONSHIP_FLAG = s.default_relationship_flag,
            t.DESCRIPTION = s.description, t.FROM_DATE = s.from_date, t.TO_DATE = s.to_date,
            t.OBJECT_VERSION_NUMBER = s.object_version_number, t.CREATED_BY = s.created_by,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATED_BY = s.last_updated_by,
            t.LAST_UPDATE_LOGIN = s.last_update_login, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.TPP_RELATIONSHIP_ID, t.VENDOR_SITE_ID, t.REMIT_TO_SUPPLIER_ID, t.REMIT_TO_ADDRESS_ID,
            t.DEFAULT_RELATIONSHIP_FLAG, t.DESCRIPTION, t.FROM_DATE, t.TO_DATE, t.OBJECT_VERSION_NUMBER,
            t.CREATED_BY, t.CREATION_DATE, t.LAST_UPDATED_BY, t.LAST_UPDATE_LOGIN, t.LAST_UPDATE_DATE
        ) VALUES (
            s.tpp_relationship_id, s.vendor_site_id, s.remit_to_supplier_id, s.remit_to_address_id,
            s.default_relationship_flag, s.description, s.from_date, s.to_date, s.object_version_number,
            s.created_by, s.creation_date, s.last_updated_by, s.last_update_login, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        -- Sole reader of this landing table: drain consumed rows after the MERGE.
        DELETE FROM LWS_C2FO_SUPPLIER_TP_PMT_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_supplier_tp_pmt_proc;

    ----------------------------------------------------------------------------
    -- 10. POZ_SUPPLIER_ADDRESS_V  (no real PK; upsert on PARTY_SITE_ID+VENDOR_ID)
    -- The address _STG has NO VENDOR_ID -> derive it by joining the sites _STG on
    -- PARTY_SITE_ID. Must run AFTER bridge_supplier_sites_proc has loaded sites.
    -- Address parts map: LocationAddress1..4/City/State/Province/PostalCode/Country;
    -- PartySiteName -> ADDRESS_NAME. VENDOR_ADDRESS_ID has no source (NULL).
    ----------------------------------------------------------------------------
    PROCEDURE bridge_supp_site_addr_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_ADDRESS_V t
        USING (
          SELECT q.* FROM (
            -- Strip embedded NBSP (U+00A0) from every address text column. The BICC
            -- extract pads some values (seen on POSTAL_CODE: '28690' + 38x NBSP) which
            -- overflows the byte-semantics mirror columns (ORA-12899). Use UNISTR('\00A0')
            -- NOT CHR(160): in an AL32UTF8 DB, CHR(160) is the single byte 0xA0, not the
            -- valid 2-byte UTF-8 encoding (c2 a0) of the codepoint, so CHR(160) matches
            -- nothing. TRIM cleans leading/trailing regular spaces.
            SELECT to_num_safe(a.PARTY_SITE_ID)     AS party_site_id,
                   st.vendor_id                     AS vendor_id,
                   TRIM(REPLACE(a.PARTY_SITE_NAME, UNISTR('\00A0'), '')) AS address_name,
                   TRIM(REPLACE(a.ADDRESS1,     UNISTR('\00A0'), '')) AS address1,
                   TRIM(REPLACE(a.ADDRESS2,     UNISTR('\00A0'), '')) AS address2,
                   TRIM(REPLACE(a.ADDRESS3,     UNISTR('\00A0'), '')) AS address3,
                   TRIM(REPLACE(a.ADDRESS4,     UNISTR('\00A0'), '')) AS address4,
                   TRIM(REPLACE(a.CITY,         UNISTR('\00A0'), '')) AS city,
                   TRIM(REPLACE(a.STATE,        UNISTR('\00A0'), '')) AS state,
                   TRIM(REPLACE(a.PROVINCE,     UNISTR('\00A0'), '')) AS province,
                   TRIM(REPLACE(a.POSTAL_CODE,  UNISTR('\00A0'), '')) AS postal_code,
                   TRIM(REPLACE(a.COUNTRY,      UNISTR('\00A0'), '')) AS country,
                   to_date_safe(a.CREATION_DATE)    AS creation_date,
                   to_date_safe(a.LAST_UPDATE_DATE) AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(a.PARTY_SITE_ID), st.vendor_id
                                      ORDER BY to_date_safe(a.LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_SUPP_SITE_ADDR_STG a
            -- Derive vendor_id from the PERSISTENT typed mirror, not the transient
            -- SUPPLIER_SITES_STG landing table. Sites arrive on their own incremental
            -- cycle (often empty when an address delta lands), and the bridge clears
            -- SITES_STG after each run, so joining STG stranded every address with a
            -- null vendor_id. The mirror holds the full site->vendor map persistently.
            -- Aggregate to one vendor_id per party_site_id (a party site can back more
            -- than one vendor site) so the MERGE source stays key-stable.
            JOIN   ( SELECT PARTY_SITE_ID, MIN(VENDOR_ID) AS vendor_id
                     FROM   LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIER_SITES_ALL_M
                     WHERE  PARTY_SITE_ID IS NOT NULL
                     GROUP  BY PARTY_SITE_ID ) st
                   ON st.PARTY_SITE_ID = to_num_safe(a.PARTY_SITE_ID)
            WHERE  NVL(a.RECORD_STATUS,'x') <> 'ERROR'
              AND  a.PARTY_SITE_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.PARTY_SITE_ID = s.party_site_id AND t.VENDOR_ID = s.vendor_id)
        WHEN MATCHED THEN UPDATE SET
            t.ADDRESS_NAME = s.address_name, t.ADDRESS1 = s.address1, t.ADDRESS2 = s.address2,
            t.ADDRESS3 = s.address3, t.ADDRESS4 = s.address4, t.CITY = s.city, t.STATE = s.state,
            t.PROVINCE = s.province, t.POSTAL_CODE = s.postal_code, t.COUNTRY = s.country,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.VENDOR_ID, t.PARTY_SITE_ID, t.ADDRESS_NAME, t.ADDRESS1, t.ADDRESS2, t.ADDRESS3, t.ADDRESS4,
            t.CITY, t.STATE, t.PROVINCE, t.POSTAL_CODE, t.COUNTRY, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.vendor_id, s.party_site_id, s.address_name, s.address1, s.address2, s.address3, s.address4,
            s.city, s.state, s.province, s.postal_code, s.country, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        -- This proc consumed only SUPP_SITE_ADDR_STG (vendor_id now comes from the
        -- persistent mirror POZ_SUPPLIER_SITES_ALL_M, not SUPPLIER_SITES_STG), so
        -- clear only the address landing table. SUPPLIER_SITES_STG is owned/cleared
        -- by the sites bridge (bridge_supplier_sites_proc).
        DELETE FROM LWS_C2FO_SUPP_SITE_ADDR_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_supp_site_addr_proc;

    ----------------------------------------------------------------------------
    -- 11. AP_INVOICE_PAYMENTS_ALL  (PK INVOICE_PAYMENT_ID)
    -- Source = LWS_C2FO_AP_INV_PAYMENTS_STG (PaidDisbursementScheduleExtractPVO,
    -- entity group AP_INV_PAYMENTS). Feeds the C2FO feedback outbound: links the
    -- invoice to its payment(s) and, via CHECK_ID, to AP_CHECKS_ALL. 1:1 column
    -- match; no derivation.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_inv_payments_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(INVOICE_PAYMENT_ID)  AS invoice_payment_id,
                   to_num_safe(INVOICE_ID)          AS invoice_id,
                   to_num_safe(CHECK_ID)            AS check_id,
                   to_date_safe(ACCOUNTING_DATE)    AS accounting_date,
                   to_num_safe(AMOUNT)              AS amount,
                   to_num_safe(PAYMENT_NUM)         AS payment_num,
                   REVERSAL_FLAG                    AS reversal_flag,
                   to_date_safe(CREATION_DATE)      AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)   AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(INVOICE_PAYMENT_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_INV_PAYMENTS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  INVOICE_PAYMENT_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.INVOICE_PAYMENT_ID = s.invoice_payment_id)
        WHEN MATCHED THEN UPDATE SET
            t.INVOICE_ID = s.invoice_id, t.CHECK_ID = s.check_id, t.ACCOUNTING_DATE = s.accounting_date,
            t.AMOUNT = s.amount, t.PAYMENT_NUM = s.payment_num, t.REVERSAL_FLAG = s.reversal_flag,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.INVOICE_PAYMENT_ID, t.INVOICE_ID, t.CHECK_ID, t.ACCOUNTING_DATE, t.AMOUNT,
            t.PAYMENT_NUM, t.REVERSAL_FLAG, t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.invoice_payment_id, s.invoice_id, s.check_id, s.accounting_date, s.amount,
            s.payment_num, s.reversal_flag, s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_INV_PAYMENTS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_inv_payments_proc;

    ----------------------------------------------------------------------------
    -- Post-merge derivation: PAYMENT_STATUS_FLAG on LWS_AP_INVOICES_ALL
    -- Not a _STG bridge - both inputs are already-typed mirror tables. Sums the
    -- net paid amount per invoice from LWS_AP_INVOICE_PAYMENTS_ALL and sets:
    --   'Y' fully paid, 'P' partially paid, 'N' unpaid (Fusion convention).
    -- Reversals net out: reversal rows (REVERSAL_FLAG='Y') carry a negative AMOUNT
    -- in Fusion, so a plain SUM(AMOUNT) already yields the net. Invoices with no
    -- payment rows fall to the NVL(...,0) = 0 branch -> 'N'. Comparison uses a
    -- small rounding tolerance so float residue on a full payment still reads 'Y'.
    -- Only invoices whose derived flag differs from the stored value are updated.
    ----------------------------------------------------------------------------
    PROCEDURE derive_payment_status_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL t
        USING (
            SELECT i.INVOICE_ID,
                   CASE
                     WHEN NVL(p.net_paid,0) = 0 THEN 'N'
                     WHEN NVL(p.net_paid,0) >= NVL(i.INVOICE_AMOUNT,0) - 0.01 THEN 'Y'
                     ELSE 'P'
                   END AS new_flag
            FROM   LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL i
            LEFT JOIN (
                   SELECT INVOICE_ID, SUM(AMOUNT) AS net_paid
                   FROM   LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICE_PAYMENTS_ALL
                   GROUP  BY INVOICE_ID
            ) p ON p.INVOICE_ID = i.INVOICE_ID
        ) s
        ON (t.INVOICE_ID = s.INVOICE_ID)
        WHEN MATCHED THEN UPDATE SET t.PAYMENT_STATUS_FLAG = s.new_flag
            WHERE NVL(t.PAYMENT_STATUS_FLAG,'~') <> s.new_flag;
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END derive_payment_status_proc;

    ----------------------------------------------------------------------------
    -- 12. AP_CHECKS_ALL  (PK CHECK_ID)
    -- Source = LWS_C2FO_AP_CHECKS_STG (DisbursementHeaderExtractPVO, entity group
    -- AP_CHECKS). Carries the payment detail the feedback file reads (check_number,
    -- status_lookup_code, future_pay_due_date, currency). This is the extractable
    -- payment source; IBY_PAYMENTS_ALL has no Extract PVO and is not bridged.
    -- 1:1 column match; no derivation.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_ap_checks_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_AP_CHECKS_ALL t
        USING (
          SELECT q.* FROM (
            SELECT to_num_safe(CHECK_ID)            AS check_id,
                   to_num_safe(PAYMENT_ID)          AS payment_id,
                   CHECK_NUMBER                     AS check_number,
                   to_date_safe(CHECK_DATE)         AS check_date,
                   to_num_safe(AMOUNT)              AS amount,
                   STATUS_LOOKUP_CODE               AS status_lookup_code,
                   to_date_safe(FUTURE_PAY_DUE_DATE) AS future_pay_due_date,
                   CURRENCY_CODE                    AS currency_code,
                   to_num_safe(VENDOR_ID)           AS vendor_id,
                   to_num_safe(VENDOR_SITE_ID)      AS vendor_site_id,
                   to_num_safe(ORG_ID)              AS org_id,
                   to_date_safe(CREATION_DATE)      AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)   AS last_update_date,
                   ROW_NUMBER() OVER (PARTITION BY to_num_safe(CHECK_ID)
                                      ORDER BY to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_AP_CHECKS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  CHECK_ID IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.CHECK_ID = s.check_id)
        WHEN MATCHED THEN UPDATE SET
            t.PAYMENT_ID = s.payment_id, t.CHECK_NUMBER = s.check_number, t.CHECK_DATE = s.check_date,
            t.AMOUNT = s.amount, t.STATUS_LOOKUP_CODE = s.status_lookup_code,
            t.FUTURE_PAY_DUE_DATE = s.future_pay_due_date, t.CURRENCY_CODE = s.currency_code,
            t.VENDOR_ID = s.vendor_id, t.VENDOR_SITE_ID = s.vendor_site_id, t.ORG_ID = s.org_id,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.CHECK_ID, t.PAYMENT_ID, t.CHECK_NUMBER, t.CHECK_DATE, t.AMOUNT, t.STATUS_LOOKUP_CODE,
            t.FUTURE_PAY_DUE_DATE, t.CURRENCY_CODE, t.VENDOR_ID, t.VENDOR_SITE_ID, t.ORG_ID,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.check_id, s.payment_id, s.check_number, s.check_date, s.amount, s.status_lookup_code,
            s.future_pay_due_date, s.currency_code, s.vendor_id, s.vendor_site_id, s.org_id,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_AP_CHECKS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_ap_checks_proc;

    ----------------------------------------------------------------------------
    -- 13. FND_LOOKUP_VALUES_VL  (PK LOOKUP_TYPE, LOOKUP_CODE)
    -- Source = LWS_C2FO_FND_LOOKUPS_STG (LookupValuesTLExtractPVO, entity group
    -- FND_LOOKUPS, BICC-filtered to LookupType='SOURCE'). Supplies the invoice-
    -- source DISPLAY NAME (MEANING) that the REST POST /invoices offset create
    -- needs. The _TL grain is one row per (LOOKUP_TYPE,LOOKUP_CODE,LANGUAGE); the
    -- mirror PK drops LANGUAGE, so keep the base-language ('US') row, falling back
    -- to the newest row if 'US' is absent. Only MEANING/DESCRIPTION/dates are set;
    -- ENABLED_FLAG and the active-date columns are left as-is (NULL for these
    -- bridged rows) because the _TL PVO does not carry them - the enabled+active-
    -- dated bridging view reads NULL as enabled/always-active. This MERGE only ever
    -- sees SOURCE rows, so it never disturbs the hand-seeded C2FO scope lookups
    -- (different LOOKUP_TYPEs) that coexist in the same table.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_fnd_lookups_proc (p_rows OUT NUMBER, p_err OUT VARCHAR2) IS
    BEGIN
        MERGE INTO LWS_CUSTOM_C2FO_SA.LWS_FND_LOOKUP_VALUES_VL t
        USING (
          SELECT q.* FROM (
            SELECT LOOKUP_TYPE                      AS lookup_type,
                   LOOKUP_CODE                      AS lookup_code,
                   MEANING                          AS meaning,
                   DESCRIPTION                      AS description,
                   to_date_safe(CREATION_DATE)      AS creation_date,
                   to_date_safe(LAST_UPDATE_DATE)   AS last_update_date,
                   ROW_NUMBER() OVER (
                       PARTITION BY LOOKUP_TYPE, LOOKUP_CODE
                       ORDER BY CASE WHEN LANGUAGE = 'US' THEN 0 ELSE 1 END,
                                to_date_safe(LAST_UPDATE_DATE) DESC NULLS LAST) AS rn
            FROM   LWS_C2FO_FND_LOOKUPS_STG
            WHERE  NVL(RECORD_STATUS,'x') <> 'ERROR'
              AND  LOOKUP_TYPE IS NOT NULL
              AND  LOOKUP_CODE IS NOT NULL
          ) q WHERE q.rn = 1
        ) s
        ON (t.LOOKUP_TYPE = s.lookup_type AND t.LOOKUP_CODE = s.lookup_code)
        WHEN MATCHED THEN UPDATE SET
            t.MEANING = s.meaning, t.DESCRIPTION = s.description,
            t.CREATION_DATE = s.creation_date, t.LAST_UPDATE_DATE = s.last_update_date
        WHEN NOT MATCHED THEN INSERT (
            t.LOOKUP_TYPE, t.LOOKUP_CODE, t.MEANING, t.DESCRIPTION,
            t.CREATION_DATE, t.LAST_UPDATE_DATE
        ) VALUES (
            s.lookup_type, s.lookup_code, s.meaning, s.description,
            s.creation_date, s.last_update_date
        );
        p_rows := SQL%ROWCOUNT;
        p_err  := NULL;
        DELETE FROM LWS_C2FO_FND_LOOKUPS_STG WHERE NVL(RECORD_STATUS,'x') <> 'ERROR';
    EXCEPTION WHEN OTHERS THEN
        p_rows := 0; p_err := SQLERRM;
    END bridge_fnd_lookups_proc;

    ----------------------------------------------------------------------------
    -- DRIVER: run all 16 bridges in dependency order, log per-entity, commit
    -- once at the end. A per-entity failure is logged and flips o_status to
    -- ERROR but does NOT abort the remaining entities (independent upserts;
    -- idempotent re-run recovers). Dependency order: headers before lines/
    -- dists/scheds; parties before suppliers (VENDOR_NAME lookup); suppliers +
    -- sites before the address (address joins sites). Terms + BU->org-units are
    -- independent (no cross-entity dependency) and run early.
    ----------------------------------------------------------------------------
    PROCEDURE bridge_all_proc (
        p_instance_id  IN  VARCHAR2 DEFAULT NULL,
        p_truncate_all IN  VARCHAR2 DEFAULT 'N',
        o_status       OUT VARCHAR2,
        o_message      OUT VARCHAR2
    ) IS
        l_rows   NUMBER;
        l_err    VARCHAR2(4000);
        l_fail   NUMBER := 0;

        -- All STG landing tables, for the optional space-reclaim truncate.
        TYPE t_tab IS TABLE OF VARCHAR2(128);
        l_stg t_tab := t_tab(
            'LWS_C2FO_AP_INV_HEADERS_STG', 'LWS_C2FO_AP_INV_LINES_STG',
            'LWS_C2FO_AP_INV_DISTS_STG',   'LWS_C2FO_AP_PAY_SCHEDS_STG',
            'LWS_C2FO_AP_TERM_TRANSLATIONS_STG', 'LWS_C2FO_BUSINESS_UNITS_STG',
            'LWS_C2FO_HZ_PARTIES_STG',     'LWS_C2FO_SUPPLIERS_STG',
            'LWS_C2FO_CONTACT_POINTS_STG',
            'LWS_C2FO_ORG_CONTACTS_STG',   'LWS_C2FO_PO_HEADERS_STG',
            'LWS_C2FO_SUPPLIER_SITES_STG', 'LWS_C2FO_SUPP_SITE_ADDR_STG',
            'LWS_C2FO_SUPPLIER_TP_PMT_STG',
            'LWS_C2FO_RELATIONSHIPS_STG',
            'LWS_C2FO_AP_INV_PAYMENTS_STG', 'LWS_C2FO_AP_CHECKS_STG',
            'LWS_C2FO_FND_LOOKUPS_STG');

        PROCEDURE run_one (p_name IN VARCHAR2, p_r IN NUMBER, p_e IN VARCHAR2) IS
        BEGIN
            IF p_e IS NULL THEN
                lws_c2fo_common_pkg.log_process_stage_proc(
                    p_instance_id => p_instance_id, p_status => 'SUCCESS',
                    p_message => p_name || ' merged ' || p_r || ' rows',
                    p_entity_group => p_name, p_stage_name => 'BRIDGE_TO_MIRROR');
            ELSE
                l_fail := l_fail + 1;
                lws_c2fo_common_pkg.log_process_stage_proc(
                    p_instance_id => p_instance_id, p_status => 'ERROR',
                    p_message => p_name || ' FAILED: ' || p_e,
                    p_entity_group => p_name, p_stage_name => 'BRIDGE_TO_MIRROR');
            END IF;
        END run_one;
    BEGIN
        bridge_ap_invoices_proc(l_rows, l_err);      run_one('AP_INVOICES',      l_rows, l_err);
        bridge_ap_inv_lines_proc(l_rows, l_err);     run_one('AP_INVOICE_LINES', l_rows, l_err);
        bridge_ap_inv_dists_proc(l_rows, l_err);     run_one('AP_INV_DISTS',     l_rows, l_err);
        bridge_ap_pay_scheds_proc(l_rows, l_err);    run_one('AP_PAY_SCHEDS',    l_rows, l_err);
        bridge_ap_terms_proc(l_rows, l_err);         run_one('AP_TERMS',         l_rows, l_err);
        bridge_bu_org_units_proc(l_rows, l_err);     run_one('BU_ORG_UNITS',     l_rows, l_err);
        bridge_parties_proc(l_rows, l_err);          run_one('PARTIES',          l_rows, l_err);
        bridge_suppliers_proc(l_rows, l_err);        run_one('SUPPLIERS',        l_rows, l_err);
        bridge_contact_points_proc(l_rows, l_err);   run_one('CONTACT_POINTS',   l_rows, l_err);
        bridge_relationships_proc(l_rows, l_err);    run_one('RELATIONSHIPS',    l_rows, l_err);
        bridge_po_headers_proc(l_rows, l_err);       run_one('PO_HEADERS',       l_rows, l_err);
        bridge_supplier_sites_proc(l_rows, l_err);   run_one('SUPPLIER_SITES',   l_rows, l_err);
        bridge_supp_site_addr_proc(l_rows, l_err);   run_one('SUPPLIER_SITE_ADDRESS', l_rows, l_err);
        bridge_supplier_tp_pmt_proc(l_rows, l_err);  run_one('SUPPLIER_TP_PAYMENT', l_rows, l_err);
        bridge_ap_inv_payments_proc(l_rows, l_err);  run_one('AP_INV_PAYMENTS',   l_rows, l_err);
        bridge_ap_checks_proc(l_rows, l_err);        run_one('AP_CHECKS',         l_rows, l_err);
        bridge_fnd_lookups_proc(l_rows, l_err);      run_one('FND_LOOKUPS',       l_rows, l_err);

        -- Post-merge derivation: needs AP_INVOICES + AP_INV_PAYMENTS mirrors loaded above.
        derive_payment_status_proc(l_rows, l_err);   run_one('PAYMENT_STATUS',    l_rows, l_err);

        IF l_fail = 0 THEN
            COMMIT;
            -- Optional space reclaim: only when EVERY bridge succeeded (so no STG rows
            -- are still needed for a re-run) and the caller asked for it. TRUNCATE's
            -- implicit commit is harmless here - the merges are already committed above.
            IF p_truncate_all = 'Y' THEN
                FOR i IN 1..l_stg.COUNT LOOP
                    EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || l_stg(i);
                END LOOP;
            END IF;
            o_status  := 'SUCCESS';
            o_message := 'All 17 bridges + payment-status derivation completed.'
                      || CASE WHEN p_truncate_all = 'Y' THEN ' STG tables truncated.' END;
        ELSE
            -- keep the successful upserts; failures are re-runnable (idempotent).
            -- STG is NOT truncated on any failure - the un-bridged rows must survive.
            COMMIT;
            o_status  := 'ERROR';
            o_message := l_fail || ' of 18 bridge steps failed - see LWS_C2FO_PROCESS_STAGE_LOG.';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        o_status  := 'ERROR';
        o_message := 'bridge_all_proc fatal: ' || SQLERRM;
    END bridge_all_proc;

END lws_c2fo_bridge_pkg;
/
