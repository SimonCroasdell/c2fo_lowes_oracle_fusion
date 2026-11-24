--------------------------------------------------------------------------------
-- C2FO Bridge: client _STG landing tables  ->  typed LWS_* mirror
--------------------------------------------------------------------------------
-- Purpose: the client's BICC framework (LWS_C2FO_COMMON_PKG) lands raw Fusion
--   extracts into LWS_C2FO_*_STG tables (all VARCHAR2(4000)). The outbound
--   package (LWS_OB_EXTRACT_ATP_PKG) + its Fusion-named bridging views read a
--   SEPARATE typed mirror (the LWS_CUSTOM_C2FO_SA.LWS_* tables in
--   c2fo_staging_ddl.sql). This file bridges the two: one typed MERGE per
--   entity that casts the _STG VARCHAR2 columns to the mirror's NUMBER/DATE
--   columns and upserts on the mirror PK.
--
-- Adds (see sections below):
--   1. Two missing landing tables + PVO mapping rows + extract wrappers for the
--      supplier-site and supplier-site-address PVOs (the client framework never
--      shipped these; the data is in the bucket but had nowhere to land).
--   2. LWS_C2FO_BRIDGE_PKG: safe-cast helpers + 15 MERGE procs + bridge_all_proc
--      driver. OIC (or the client's process_bicc_file_proc chain) calls
--      bridge_all_proc AFTER the _STG loads complete.
--   3. Feedback-outbound support: landing tables + mapping + bridges for
--      AP_INVOICE_PAYMENTS_ALL (PaidDisbursementScheduleExtractPVO) and
--      AP_CHECKS_ALL (DisbursementHeaderExtractPVO). IBY_PAYMENTS_ALL has NO BICC
--      Extract PVO in the rel13-26b mapping and is intentionally NOT built here
--      (to be re-sourced separately).
--
-- Conventions:
--   * Client _STG tables carry NO schema prefix (created in the loader schema).
--     The typed mirror is owned by LWS_CUSTOM_C2FO_SA. The bridge package is
--     created unqualified (runs in the loader schema) and references the mirror
--     with the LWS_CUSTOM_C2FO_SA. prefix.
--   * Casts use to_num_safe/to_date_safe: a bad value lands NULL rather than
--     failing the whole MERGE (matches the loader's conversionerrors=store_null
--     tolerance).
--   * _STG columns are the raw Fusion DB column names (snake_case), so they map
--     to the mirror by identical name unless noted.
--
-- KNOWN MAPPING GAPS (documented, not silently dropped):
--   * LWS_POZ_SUPPLIERS_V.VENDOR_NAME: now sourced from SupplierExtractPVO's
--     VendorName attribute. The client's SUPPLIERS_STG shipped without a name
--     column, so Section 1a ALTERs it to add VENDOR_NAME, Section 1b maps
--     SupplierExtractPVO.VendorName -> SUPPLIERS_STG.VENDOR_NAME, and the supplier
--     bridge (proc 5) loads it into the mirror. Requires the BICC SupplierExtractPVO
--     offering to tick the VendorName attribute so the CSV carries it.
--   * LWS_POZ_SUPPLIERS_V.VENDOR_TYPE_LOOKUP_CODE / ENABLED_FLAG: SUPPLIERS_STG has
--     no vendor-type or enabled column; left NULL (qualify on START/END_DATE_ACTIVE
--     instead of ENABLED_FLAG).
--   * ORG_ID columns are sourced from PRC_BU_ID where the _STG lacks ORG_ID
--     (supplier sites, PO headers) - procurement BU stands in for org.
--   * LWS_POZ_SUPPLIER_ADDRESS_V has no VENDOR_ID in its source PVO; derived by
--     joining SUPPLIER_SITES_STG on PARTY_SITE_ID.
--   * LWS_POZ_SUPPLIERS_V.ATTRIBUTE1-20: descriptive flexfield attributes, carried
--     1:1 from SUPPLIERS_STG.ATTRIBUTE1-20 by proc 5 (name-based, held as text).
--     Requires the BICC SupplierExtractPVO offering to tick Attribute1-20 so the
--     CSV carries them (like VendorName). The poz view is SELECT * so they surface
--     automatically. Only ATTRIBUTE1-20 are carried - the ATTRIBUTE_DATE/_NUMBER/
--     _TIMESTAMP and GLOBAL_ATTRIBUTE* families in _STG are not mapped.
--------------------------------------------------------------------------------




-- PaidDisbursementScheduleExtractPVO (AP_INVOICE_PAYMENTS_ALL) landing table.
-- Feeds the C2FO FEEDBACK outbound (awarded + recently-paid invoices): joins the
-- invoice grain to its payment(s) and, via CHECK_ID, to AP_CHECKS_ALL below.
-- Attributes prefixed ApInvoicePaymentsAll* on the Extract PVO.
DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AP_INV_PAYMENTS_STG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_AP_INV_PAYMENTS_STG (
    INVOICE_PAYMENT_ID      VARCHAR2(4000),   -- ApInvoicePaymentsAllInvoicePaymentId (PK)
    INVOICE_ID              VARCHAR2(4000),   -- ApInvoicePaymentsAllInvoiceId
    CHECK_ID                VARCHAR2(4000),   -- ApInvoicePaymentsAllCheckId -> AP_CHECKS_ALL
    ACCOUNTING_DATE         VARCHAR2(4000),   -- ApInvoicePaymentsAllAccountingDate
    AMOUNT                  VARCHAR2(4000),   -- ApInvoicePaymentsAllAmount
    PAYMENT_NUM             VARCHAR2(4000),   -- ApInvoicePaymentsAllPaymentNum
    REVERSAL_FLAG           VARCHAR2(4000),   -- ApInvoicePaymentsAllReversalFlag
    CREATION_DATE           VARCHAR2(4000),   -- ApInvoicePaymentsAllCreationDate
    LAST_UPDATE_DATE        VARCHAR2(4000),   -- ApInvoicePaymentsAllLastUpdateDate (incremental key)
    FILE_NAME               VARCHAR2(500),
    SOURCE_CODE             VARCHAR2(100),
    INSTANCE_ID             VARCHAR2(100),
    RECORD_STATUS           VARCHAR2(30)  DEFAULT 'INPROCESS',
    CREATED_DATE            TIMESTAMP     DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_DATE       TIMESTAMP
);
/
