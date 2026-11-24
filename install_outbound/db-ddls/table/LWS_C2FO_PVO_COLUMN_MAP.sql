DROP TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_PVO_COLUMN_MAP;
CREATE TABLE LWS_CUSTOM_C2FO_SA.LWS_C2FO_PVO_COLUMN_MAP (
    MAP_ID             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ENTITY_GROUP       VARCHAR2(100)  NOT NULL,
    PVO_NAME           VARCHAR2(500)  NOT NULL,
    PVO_COLUMN_NAME    VARCHAR2(200)  NOT NULL,
    STG_TABLE_NAME     VARCHAR2(100)  NOT NULL,
    STG_COLUMN_NAME    VARCHAR2(100)  NOT NULL,
    DB_TABLE           VARCHAR2(100),
    DB_COLUMN          VARCHAR2(100),
    COLUMN_POSITION    NUMBER,
    IS_PK              VARCHAR2(1) DEFAULT 'N',
    IS_INCREMENTAL_KEY VARCHAR2(1) DEFAULT 'N',
    IS_ENABLED         VARCHAR2(1) DEFAULT 'Y'
);
/

--------------------------------------------------------------------------------
-- NOTE: the ~1679 seed rows for this table are a SEPARATE DML file ->
-- 03_dml/dml_LWS_C2FO_PVO_COLUMN_MAP_rows.sql (run it after this table).
--------------------------------------------------------------------------------
