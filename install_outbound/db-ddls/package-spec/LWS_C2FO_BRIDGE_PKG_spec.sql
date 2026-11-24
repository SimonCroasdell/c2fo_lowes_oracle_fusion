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



--==============================================================================
-- SECTION 2: LWS_C2FO_BRIDGE_PKG
-- Casts the raw VARCHAR2(4000) _STG landing tables into the typed
-- LWS_CUSTOM_C2FO_SA.LWS_* mirror. One MERGE proc per entity + a driver that
-- runs them in dependency order. Created unqualified (loader schema); references
-- the mirror with the LWS_CUSTOM_C2FO_SA. prefix.
--==============================================================================

CREATE OR REPLACE PACKAGE lws_c2fo_bridge_pkg AS

    -- ---- safe-cast helpers ----
    -- Declared in the SPEC (not just the body) because the bridge MERGE statements
    -- call them from SQL; a package function used in SQL must be spec-visible
    -- (else PLS-00231). A bad value lands NULL rather than failing the MERGE.
    FUNCTION to_num_safe  (p IN VARCHAR2) RETURN NUMBER;
    FUNCTION to_date_safe (p IN VARCHAR2) RETURN DATE;

    -- The two supplier-site landing tables (SupplierSiteExtractPVO,
    -- SupplierSiteAddressPVO) are loaded by the uniform BICC pipeline
    -- (process_bicc_file_proc) via their LWS_C2FO_PVO_COLUMN_MAP rows, exactly
    -- like every other entity - no per-entity extract wrappers.

    -- ---- typed bridges (_STG VARCHAR2 -> typed mirror) ----
    -- Each returns rows merged + an error string ('' on success).
    PROCEDURE bridge_ap_invoices_proc      (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_inv_lines_proc     (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_inv_dists_proc     (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_pay_scheds_proc    (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_terms_proc         (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_bu_org_units_proc     (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_parties_proc          (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_suppliers_proc        (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_contact_points_proc   (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_relationships_proc    (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_po_headers_proc       (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_supplier_sites_proc   (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_supp_site_addr_proc   (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_supplier_tp_pmt_proc  (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_inv_payments_proc  (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_ap_checks_proc        (p_rows OUT NUMBER, p_err OUT VARCHAR2);
    PROCEDURE bridge_fnd_lookups_proc      (p_rows OUT NUMBER, p_err OUT VARCHAR2);

    -- ---- post-merge derivation (mirror -> mirror, not _STG-sourced) ----
    -- Recomputes LWS_AP_INVOICES_ALL.PAYMENT_STATUS_FLAG from the net paid amount
    -- in LWS_AP_INVOICE_PAYMENTS_ALL (reversals netted out). Runs in bridge_all_proc
    -- AFTER both the invoice and invoice-payment mirrors are loaded, so the inputs
    -- are present. p_rows = invoices whose flag changed.
    PROCEDURE derive_payment_status_proc   (p_rows OUT NUMBER, p_err OUT VARCHAR2);

    -- ---- driver: run all 17 bridges + payment-status derivation in dependency order ----
    -- p_truncate_all: 'Y' => after ALL bridges succeed, TRUNCATE every STG table to
    -- reclaim space (implicit commit is safe there - nothing left to roll back). 'N'
    -- (default) => rely on the per-bridge DELETE of consumed rows only. STG normally
    -- holds incremental data so the DELETE is cheap; the truncate is an occasional
    -- space-reclaim opt-in.
    PROCEDURE bridge_all_proc (
        p_instance_id  IN  VARCHAR2 DEFAULT NULL,
        p_truncate_all IN  VARCHAR2 DEFAULT 'N',
        o_status       OUT VARCHAR2,
        o_message      OUT VARCHAR2
    );

END lws_c2fo_bridge_pkg;
/


