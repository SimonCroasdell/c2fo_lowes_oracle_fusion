--------------------------------------------------------------------------------
-- C2FO bridging views  (Fusion-named, over the LWS_-prefixed mirror tables)
--------------------------------------------------------------------------------
-- Purpose : expose the LWS_CUSTOM_C2FO_SA mirror under the Fusion object names that
--           LWS_OB_EXTRACT_ATP_PKG's cursors reference, so the package compiles
--           and runs UNCHANGED after the mirror tables were renamed LWS_<object>.
--
-- Why views (not direct table refs in the package):
--   * Portability - the extract package is generic across clients/pods; only these
--     views change per client. The package body stays identical.
--   * Single home for the C2FO business trim (open / approved / not-cancelled /
--     not-on-hold / future-due) and for any type casting, reused by both the
--     outbound extract and inbound award validation.
--
-- Casting note:
--   The mirror in c2fo_staging_ddl.sql is ALREADY typed (NUMBER/DATE/VARCHAR2), so
--   most columns are straight passthrough. Where a column originates from the
--   client's VARCHAR2(4000) LWS_C2FO_*_STG landing tables (if a view is later
--   re-pointed at those), use the CONVERSION-ERROR-TOLERANT casts shown here so a
--   single dirty value NULLS OUT instead of failing the whole extract query:
--       TO_NUMBER(x DEFAULT NULL ON CONVERSION ERROR)
--       TO_DATE  (x DEFAULT NULL ON CONVERSION ERROR, 'YYYY-MM-DD"T"HH24:MI:SS')
--   (requires 12.2+/19c; ATP supports it.)
--
-- Trim placement:
--   Only the *entity-level* trims that are always valid for C2FO live in the views
--   (e.g. enabled suppliers, active contact points). The invoice-specific runtime
--   filters (date-range params, future-due) stay in the package cursor because they
--   are parameterised per run. Keeping run-variant logic out of the views avoids
--   baking a point-in-time SYSDATE assumption into a compiled view.
--
-- Naming : view name = Fusion object name; source = LWS_CUSTOM_C2FO_SA.LWS_<object>.
--------------------------------------------------------------------------------

--==============================================================================
-- AP: PAYABLES
--==============================================================================

DROP VIEW LWS_CUSTOM_C2FO_SA.AP_INVOICES_ALL;
CREATE OR REPLACE VIEW LWS_CUSTOM_C2FO_SA.AP_INVOICES_ALL AS
SELECT * FROM LWS_CUSTOM_C2FO_SA.LWS_AP_INVOICES_ALL;

