--------------------------------------------------------------------------------
-- REVERSAL config seed for LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG.
--
-- The LWS_C2FO_CONFIG TABLE and its COMMON / INBOUND / OUTBOUND rows are OWNED and
-- created by install_outbound (01_ddl/LWS_C2FO_CONFIG.sql + 03_dml/
-- LWS_C2FO_CONFIG_seed.sql). This script inserts ONLY the ADDITIONAL rows the
-- reversal flow needs, under CONFIG_GROUP 'REVERSAL'. It does NOT re-insert the
-- COMMON/INBOUND/OUTBOUND rows (those already exist from the outbound seed; re-
-- inserting them would raise ORA-00001 on PK (CONFIG_GROUP, CONFIG_KEY)).
--
-- Run AFTER install_outbound (which creates + seeds the table). See INSTALL_ORDER.txt.
--
-- Read by LWS_AP_C2FO_REVERSAL_PKG.load_config: the OCI ack return bucket/folder,
-- the archive bucket/folder the reversal drop is moved to after load, and the SID /
-- ClientNumber tokens that go into the ack file names (OPEN ISSUE #3 - confirm the
-- exact token values with C2FO). Volatile runtime values (bucket/folder for pickup,
-- the batch instance id, correlation id) are passed by OIC into the procedures.
--
-- !! PER-ENVIRONMENT VALUES !! ACK_BUCKET, SID and CLIENT_NUMBER are environment /
-- client specific and are PROMPTED FOR at install time (press Enter to take a shown
-- default). Do NOT ship one environment's values to another.
--------------------------------------------------------------------------------
SET DEFINE ON

ACCEPT ack_bucket    CHAR PROMPT 'REVERSAL ack bucket name (reversal ack + ack-control files): '
ACCEPT ack_folder    CHAR PROMPT 'REVERSAL ack folder within that bucket [c2fo/reversal_ack]: ' DEFAULT 'c2fo/reversal_ack'
ACCEPT rev_arch_bkt  CHAR PROMPT 'REVERSAL archive bucket (processed reversal drop moved here; blank = do not archive): ' DEFAULT ''
ACCEPT rev_arch_fldr CHAR PROMPT 'REVERSAL archive folder within that bucket [c2fo/reversal_archive]: ' DEFAULT 'c2fo/reversal_archive'
ACCEPT rev_sid       CHAR PROMPT 'REVERSAL ack file-name SID token: '
ACCEPT rev_client    CHAR PROMPT 'REVERSAL ack file-name ClientNumber token: '

INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'ACK_BUCKET', '&&ack_bucket', 'Y', 'OCI bucket for the reversal acknowledgement return to C2FO');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'ACK_FOLDER', NULLIF('&&ack_folder', ''), 'N', 'Folder within ACK_BUCKET for ack + ack-control files');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'ARCHIVE_BUCKET', NULLIF('&&rev_arch_bkt', ''), 'N', 'OCI bucket the processed reversal drop is moved to (NULL = do not archive)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'ARCHIVE_FOLDER', NULLIF('&&rev_arch_fldr', ''), 'N', 'Folder within ARCHIVE_BUCKET for archived reversal files');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'SID', '&&rev_sid', 'Y', 'SID token for the reversal ack file name (OPEN ISSUE #3)');
INSERT INTO LWS_CUSTOM_C2FO_SA.LWS_C2FO_CONFIG (CONFIG_GROUP, CONFIG_KEY, CONFIG_VALUE, MANDATORY_FLAG, DESCRIPTION)
VALUES ('REVERSAL', 'CLIENT_NUMBER', '&&rev_client', 'Y', 'ClientNumber token for the reversal ack file name (OPEN ISSUE #3)');

COMMIT;

-- Clear the prompted substitution vars (so a re-run re-prompts) and restore DEFINE OFF.
UNDEFINE ack_bucket ack_folder rev_arch_bkt rev_arch_fldr rev_sid rev_client
SET DEFINE OFF
