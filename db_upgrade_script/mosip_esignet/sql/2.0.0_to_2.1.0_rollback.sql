-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- Rollback of 2.0.0 -> 2.1.0 (Native SSO).
--
-- Dropping device_sso_session invalidates every outstanding device secret: a 2.0.0 server has no
-- Native SSO code path, so the tokens already issued remain valid until they expire and a subsequent
-- token exchange is simply an unsupported grant type. Take a backup first if the deployment needs the
-- session history for audit:
--   CREATE TABLE esignet.device_sso_session_bkp_2_1_0 AS TABLE esignet.device_sso_session;

\c mosip_esignet

DROP INDEX IF EXISTS esignet.idx_dss_status_expiry_partial;
DROP INDEX IF EXISTS esignet.idx_dss_client_status;
DROP INDEX IF EXISTS esignet.idx_dss_subject_status;

DROP TABLE IF EXISTS esignet.device_sso_session;

-- The symmetric key policy added by the upgrade is removed last: the key material itself lives in the
-- keystore (SoftHSM/PKCS#12) and is intentionally left in place so a later re-upgrade can reuse it.
DELETE FROM esignet.key_policy_def WHERE APP_ID = 'DEVICE_SECRET_ENCRYPT';

-- Client entitlements are not rolled back: `device_sso` in additional_config is inert on a 2.0.0 server
-- and removing it would lose the operator's onboarding decisions. Remove it explicitly if required:
--   UPDATE esignet.client_detail
--      SET additional_config = additional_config - 'allowed_authorization_scopes'
--    WHERE additional_config->'allowed_authorization_scopes' ? 'device_sso';
