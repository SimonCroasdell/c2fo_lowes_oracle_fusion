--------------------------------------------------------------------------------
-- C2FO ATP Staging Schema - Fusion mirror tables
-- Source: Oracle Fusion Applications 26A (core AP/TCA/IBY/ZX/CE/HR tables)
-- Purpose: BICC landing tables feeding outbound extracts + inbound validation
-- Column scope: query-referenced columns + common business/key columns + DFF attributes
-- Constraints: primary keys + indexes on common join columns (no FKs - loader owns integrity)
-- NOTE: view-sourced entities (_V) are flat landing tables here, not recreated views.
-- NOTE: bank-detail-only columns are intentionally held (see bank_details extract - pending).
-- NOTE: all mirror tables carry the LWS_ prefix; the outbound package reaches them
--       through Fusion-named bridging views (see c2fo_bridging_views.sql).
--------------------------------------------------------------------------------
-- ANONYMOUS PL/SQL BLOCK (runs AFTER table_LWS_POZ_SUPPLIERS_V.sql).
-- For an already-installed mirror: add ATTRIBUTE1-20 if missing (the CREATE TABLE
-- only helps a fresh install). Idempotent - traps ORA-01430 (column exists).
--------------------------------------------------------------------------------
DECLARE
    PROCEDURE add_col (p_col VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE LWS_CUSTOM_C2FO_SA.LWS_POZ_SUPPLIERS_V ADD ('
                          || p_col || ' VARCHAR2(4000))';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -1430 THEN NULL; ELSE RAISE; END IF;
    END;
BEGIN
    FOR i IN 1 .. 20 LOOP
        add_col('ATTRIBUTE' || i);
    END LOOP;
END;
/
