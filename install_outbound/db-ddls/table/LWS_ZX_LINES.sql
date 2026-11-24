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

--==============================================================================
-- AP: PAYABLES
--==============================================================================

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_ZX_LINES;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_ZX_LINES (
    TAX_LINE_ID                 NUMBER(18)      NOT NULL,
    APPLICATION_ID              NUMBER(18),
    TRX_ID                      NUMBER(18),
    TRX_LINE_ID                 NUMBER(18),
    TAX_RATE_CODE               VARCHAR2(150),
    PERCENTAGE_RATE             NUMBER,
    TAX_REGIME_CODE             VARCHAR2(30),
    TAX                         VARCHAR2(30),
    TAX_AMT                     NUMBER,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_ZX_LINES PRIMARY KEY (TAX_LINE_ID)
);
CREATE INDEX IDX_ZX_LINES_TRX ON LWS_CUSTOM_C2FO_SA.LWS_ZX_LINES (TRX_ID, APPLICATION_ID);

--==============================================================================
-- IBY: PAYMENTS / BANK MODEL
-- (bank-detail-only columns intentionally held pending bank_details extract)
--==============================================================================

