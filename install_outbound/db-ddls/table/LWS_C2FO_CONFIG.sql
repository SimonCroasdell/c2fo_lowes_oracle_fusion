--------------------------------------------------------------------------------
-- C2FO shared configuration - key/value (EAV) edition
--------------------------------------------------------------------------------
-- Replaces the wide LWS_C2FO_PROJECT_CONFIG (one long row of columns) with a
-- narrow one-row-per-setting table, so adding a new parameter is an INSERT, not
-- an ALTER TABLE. Shape follows the fnd_lookups / OIC-lookup pattern.
--
-- Scope of what lives here: STATIC PLUMBING only - values that rarely change and
-- are legitimately admin-only (REST base URLs, DBMS_CLOUD credential names, OCI
-- object-storage namespace/URI, buckets, retry/parallel tuning knobs). VOLATILE
-- runtime parameters (business unit, pay group, batch id, activity filters) are
-- NOT stored here; OIC passes them into the package procedures as arguments,
-- where business users can maintain an OIC lookup without DB access.
--
-- Grouping: CONFIG_GROUP separates the three flows plus a COMMON group for
-- values every flow shares (the obj-storage triple). PK is (GROUP, KEY) so the
-- same key name can differ per flow without collision.
--
-- Consumers (all read via each package's cfg()/get accessor):
--   COMMON     -> c2fo_common_pkg.get_project_config_fun, outbound.load_ob_config,
--                 award.load_config (obj-storage triple)
--   INBOUND    -> LWS_AP_C2FO_AWARD_PKG.load_config (REST + buckets + tuning)
--   OUTBOUND   -> reserved (notification topic etc.)
--
-- MANDATORY_FLAG='Y' rows must resolve to a non-null value or load_config fails
-- with a precise "Missing mandatory config: <group>.<key>" message. Optional
-- rows fall back to the default supplied at the cfg() call site.
--
-- NOTE: the seed rows (incl. the per-environment credential/namespace/URI/bucket
-- values prompted for at install time) are a SEPARATE DML file ->
-- 03_dml/dml_LWS_C2FO_CONFIG_seed.sql (run it after this table).
--------------------------------------------------------------------------------

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (
    CONFIG_GROUP    VARCHAR2(30)   NOT NULL,   -- COMMON | INBOUND | OUTBOUND | INGESTION
    CONFIG_KEY      VARCHAR2(100)  NOT NULL,   -- e.g. FUSION_REST_BASE_URL
    CONFIG_VALUE    VARCHAR2(4000),            -- the value (NULL allowed for not-yet-set)
    MANDATORY_FLAG  VARCHAR2(1) DEFAULT 'N' NOT NULL,  -- Y = must be non-null at load
    ENABLED_FLAG    VARCHAR2(1) DEFAULT 'Y' NOT NULL,  -- N = ignored (soft delete)
    DESCRIPTION     VARCHAR2(400),
    CREATED_DATE      TIMESTAMP DEFAULT SYSTIMESTAMP,
    LAST_UPDATED_DATE TIMESTAMP DEFAULT SYSTIMESTAMP,
    CONSTRAINT PK_LWS_C2FO_CONFIG PRIMARY KEY (CONFIG_GROUP, CONFIG_KEY),
    CONSTRAINT CK_LWS_C2FO_CONFIG_MAND CHECK (MANDATORY_FLAG IN ('Y','N')),
    CONSTRAINT CK_LWS_C2FO_CONFIG_ENAB CHECK (ENABLED_FLAG IN ('Y','N'))
);
