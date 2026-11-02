-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
-- -------------------------------------------------------------------------------------------------
-- Database Name: mosip_esignet
-- Table Name   : device_sso_session
-- Purpose      : Server-side state for OpenID Connect Native SSO for Mobile Apps 1.0. One row per
--                authentication session that a device_secret is bound to. Revoking a row invalidates
--                every device_secret derived from it, and therefore every Native SSO token exchange.
--
-- Notes
--   * The device_secret itself is NEVER stored: only its SHA-256 digest (secret_hash), which the
--     validator compares against the presented value to detect stale/foreign secrets and rotations.
--   * dpop_jkt is a public JWK thumbprint (cnf.jkt) of the device key, not key material.
--   * This table is created by db/esignet-device_sso_session.sql in this repository and by
--     db_upgrade_script/mosip_esignet/sql/2.0.0_to_2.1.0_upgrade.sql for existing deployments.
-- -------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS device_sso_session (
    session_id       VARCHAR(128) NOT NULL,
    client_id        VARCHAR(256) NOT NULL,
    auth_id          VARCHAR(256) NOT NULL,
    subject_id       VARCHAR(256) NOT NULL,
    acr              VARCHAR(128),
    scopes           VARCHAR(1024) NOT NULL,
    dpop_jkt         VARCHAR(128) NOT NULL,
    secret_hash      VARCHAR(128) NOT NULL,
    session_status   VARCHAR(20)  NOT NULL,
    cr_dtimes        TIMESTAMPTZ  NOT NULL,
    upd_dtimes       TIMESTAMPTZ,
    expiry_dtimes    TIMESTAMPTZ  NOT NULL,
    revoked_dtimes   TIMESTAMPTZ,
    CONSTRAINT pk_device_sso_session_id PRIMARY KEY (session_id),
    CONSTRAINT chk_device_sso_session_status
        CHECK (session_status IN ('ACTIVE', 'REVOKED', 'EXPIRED'))
);

-- Listing a user's sessions (identity dashboard, "sign out everywhere").
CREATE INDEX IF NOT EXISTS idx_dss_subject_status
    ON device_sso_session (subject_id, session_status);

-- Listing the sessions of an application (admin console, per-app session counts).
CREATE INDEX IF NOT EXISTS idx_dss_client_status
    ON device_sso_session (client_id, session_status);

-- Expiry sweeps: find ACTIVE rows that are past expiry without scanning the table.
CREATE INDEX IF NOT EXISTS idx_dss_status_expiry_partial
    ON device_sso_session (expiry_dtimes)
    WHERE session_status = 'ACTIVE';

-- Housekeeping: a deployment should run, daily:
--   UPDATE device_sso_session SET session_status = 'EXPIRED', upd_dtimes = now()
--    WHERE session_status = 'ACTIVE' AND expiry_dtimes <= now();
--   DELETE FROM device_sso_session WHERE expiry_dtimes < now() - INTERVAL '90 days';
-- eSignet also expires rows opportunistically on each device_secret validation.

COMMENT ON TABLE device_sso_session IS
    'Native SSO device sessions (OpenID Connect Native SSO for Mobile Apps 1.0)';
COMMENT ON COLUMN device_sso_session.secret_hash IS
    'base64url(SHA-256(device_secret)); the secret value itself is never persisted';
COMMENT ON COLUMN device_sso_session.dpop_jkt IS
    'cnf.jkt of the device DPoP key the secret is bound to (public thumbprint, not key material)';
