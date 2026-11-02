-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- eSignet 2.0.0 -> 2.1.0: OpenID Connect Native SSO support (device secrets and device SSO sessions).
--
-- Native SSO lets a family of mobile applications share one authentication: the first application
-- performs the normal authorization-code flow with scope `device_sso` and receives a device secret
-- together with its ID token; a second application presents that ID token plus the device secret to the
-- token endpoint (RFC 8693 token exchange) and receives its own tokens without a new authentication.
--
-- The upgrade is additive: one new table, its indexes and one client entitlement. No existing column is
-- altered or dropped, so a 2.0.0 deployment keeps working unchanged if the feature stays unused.

\c mosip_esignet

-- ---------------------------------------------------------------------------------------------------
-- device secret sessions
--
-- One row per successful authorization-code exchange that minted a device secret. The secret itself is
-- never stored: only its SHA-256 digest (secret_hash), which is what the token-exchange handler compares
-- against. A row is the session (`sid`) to which the secret's `ds_hash` binding refers, and revoking it
-- invalidates the secret and every refresh token of the session.
-- ---------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS esignet.device_sso_session (
    session_id      VARCHAR(128) NOT NULL,
    client_id       VARCHAR(255) NOT NULL,
    auth_id         VARCHAR(128) NOT NULL,
    subject_id      VARCHAR(255) NOT NULL,
    acr             VARCHAR(64),
    scopes          VARCHAR(1024),
    dpop_jkt        VARCHAR(128),
    secret_hash     VARCHAR(128) NOT NULL,
    session_status  VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE',
    cr_by           VARCHAR(256) NOT NULL,
    cr_dtimes       TIMESTAMP    NOT NULL DEFAULT now(),
    upd_by          VARCHAR(256),
    upd_dtimes      TIMESTAMP,
    expiry_dtimes   TIMESTAMP    NOT NULL,
    revoked_dtimes  TIMESTAMP,
    CONSTRAINT pk_dss_session_id PRIMARY KEY (session_id),
    CONSTRAINT chk_dss_session_status
        CHECK (session_status IN ('ACTIVE', 'REVOKED', 'EXPIRED'))
);

COMMENT ON TABLE esignet.device_sso_session IS
    'OpenID Connect Native SSO sessions. Stores the SHA-256 digest of the device secret, never the secret.';

-- Subject lookups: "my sessions" in an application, and cross-application sign-out for one user.
CREATE INDEX IF NOT EXISTS idx_dss_subject_status
    ON esignet.device_sso_session (subject_id, session_status, expiry_dtimes);

-- Client lookups: an administrator reviewing one relying party's sessions.
CREATE INDEX IF NOT EXISTS idx_dss_client_status
    ON esignet.device_sso_session (client_id, session_status, expiry_dtimes);

-- Housekeeping: expire-stale sweeps and partial index for the hot "active and not yet expired" query.
CREATE INDEX IF NOT EXISTS idx_dss_status_expiry_partial
    ON esignet.device_sso_session (expiry_dtimes)
    WHERE session_status = 'ACTIVE';

-- ---------------------------------------------------------------------------------------------------
-- Client entitlement
--
-- `device_sso` is a scope the relying party must be allowed to request. It is not a new column: eSignet
-- already carries per-client scope entitlement in client_detail.additional_config, and the identity
-- provider reads it through shared.AllowedAuthorizationScopes(). Existing clients therefore keep exactly
-- their current entitlement, and Native SSO is opt-in per client.
--
-- Example (run per onboarding client, not as part of this migration):
--   UPDATE esignet.client_detail
--      SET additional_config = jsonb_set(
--              COALESCE(additional_config, '{}'::jsonb),
--              '{allowed_authorization_scopes}',
--              '["openid","profile","email","device_sso"]'::jsonb)
--    WHERE id = '<client_id>';
--
-- Clients that must not accept an authentication shared by an application with a different relying
-- party leave `require_same_relying_party` at its default (true, see
-- esignet.device_sso.require_same_relying_party); an explicit allow-list can be declared with
-- additional_config.native_sso_allowed_clients.
-- ---------------------------------------------------------------------------------------------------

INSERT INTO esignet.key_policy_def(APP_ID, KEY_VALIDITY_DURATION, PRE_EXPIRE_DAYS, ACCESS_ALLOWED,
                                   IS_ACTIVE, CR_BY, CR_DTIMES)
VALUES ('DEVICE_SECRET_ENCRYPT', 365, 30, 'NA', true, 'mosipadmin', now())
ON CONFLICT (APP_ID) DO NOTHING;
