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

DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_PMT_INSTR_USES_ALL;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_IBY_PMT_INSTR_USES_ALL (
    INSTRUMENT_PAYMENT_USE_ID   NUMBER(18)      NOT NULL,
    EXT_PMT_PARTY_ID            NUMBER(18),
    INSTRUMENT_ID               NUMBER(18),
    INSTRUMENT_TYPE             VARCHAR2(30),
    PRIMARY_FLAG                VARCHAR2(1),
    PAYMENT_FLOW                VARCHAR2(30),
    ORDER_OF_PREFERENCE         NUMBER,
    START_DATE                  DATE,
    END_DATE                    DATE,
    CREATION_DATE               DATE,
    LAST_UPDATE_DATE            DATE,
    CONSTRAINT PK_IBY_PMT_INSTR_USES PRIMARY KEY (INSTRUMENT_PAYMENT_USE_ID)
);
CREATE INDEX IDX_IBY_PIU_EXTPARTY   ON LWS_CUSTOM_C2FO_SA.LWS_IBY_PMT_INSTR_USES_ALL (EXT_PMT_PARTY_ID);
CREATE INDEX IDX_IBY_PIU_INSTRUMENT ON LWS_CUSTOM_C2FO_SA.LWS_IBY_PMT_INSTR_USES_ALL (INSTRUMENT_ID);


