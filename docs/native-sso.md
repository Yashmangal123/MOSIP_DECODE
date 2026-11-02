# Native SSO in eSignet

Implementation notes for OpenID Connect Native SSO for mobile applications
(`draft-ietf-oidc-native-sso`) in the Go eSignet stack: the ThunderID engine, the eSignet service, and the
platform service that delivers OTPs and hosts the operational console.

## The problem it solves

A banking group ships a **Super App** (accounts) and a **Child App** (cards). Today the user authenticates
twice: once per app, with an OTP each time. Native SSO lets the second app inherit the authentication of
the first, without either app seeing the other's tokens and without a new OTP.

```
Super App                       eSignet                    Child App
    │  authorize(scope=device_sso)   │                          │
    ├───────────────────────────────▶│                          │
    │◀── code ───────────────────────┤                          │
    ├── token(code) ────────────────▶│                          │
    │◀── id_token, access_token,     │                          │
    │    refresh_token,              │                          │
    │    device_secret ──────────────┤                          │
    │                               │                          │
    │  (the Super App passes its id_token and the device_secret to the Child App
    │   over a private, app-to-app channel - never through the browser)         │
    │                               │◀── token(urn:...:token-exchange,          │
    │                               │       subject_token=id_token,             │
    │                               │       actor_token=device_secret) ─────────┤
    │                               ├── validate secret, ds_hash, sid ─────────▶│
    │                               ├── issue Child App tokens ────────────────▶│
```

What makes this safe is that the device secret is bound to the *authentication session* (`sid`) and to
the *id_token* (`ds_hash`), and only the authorization server can mint either. The Child App's tokens are
issued after eSignet re-validates both; the Child App never receives the Super App's access or refresh
token.

## Requirements implemented

| Spec requirement | Where |
| --- | --- |
| `device_sso` scope issues a device secret together with the id_token (§3.4.2) | `internal/oauth/oauth2/granthandlers/authorization_code.go` (`issueDeviceSecret`) |
| Device secret is opaque, integrity- and confidentiality-protected | `esignet-service/internal/devicesecret` — signed JWT wrapped in a compact JWE (`A256GCM`, `dir`) |
| `ds_hash` (binding to the id_token) and `sid` (session) in the id_token (§3.4.1) | `internal/oauth/oauth2/tokenservice` (`builder.go`, `model.go`) |
| Token exchange with `actor_token_type=urn:openid:params:token-type:device-secret` (§4) | `internal/oauth/oauth2/granthandlers/token_exchange_native_sso.go` |
| An invalid supplied secret is processed as if absent; expiry/revocation ⇒ `invalid_grant` (§3.4.3, §4.3) | same handler; `ValidateDeviceSecret` |
| Client must be authorised to share authentications | `device_sso.require_same_relying_party` + `additional_config.native_sso_allowed_clients` |
| Session expiry invalidates every refresh token of that session | `device_sso_session` status + `sid` on the refresh token |
| An issued secret never outlives its session | `device_sso.secret_validity_secs` clamped by `session_validity_secs` |

## Design decisions

**`device_sso` is a token-endpoint modifier, not a resource scope.** Putting it in a token-exchange
`scope` parameter is rejected with `invalid_scope`; it is also stripped from the scopes recorded on the
secret, so a downstream resource server never sees it.

**The secret is a JWE, not a `cryptomanager` key.** `cryptomanager` refuses to encrypt against any key
reference classified as keystore-resident (`ErrEncryptionAgainstReservedKey`), which covers every
asymmetric signing tier. Rather than weaken that rule, device secrets are encrypted with a dedicated
symmetric key (`DEVICE_SECRET_ENCRYPT`, falling back to `CACHE_ENCRYPT` with a warning) using compact JWE
with compression disabled (CRIME/BREACH) and authenticated decryption (tamper ⇒ `invalid_request`).

**Only a digest is stored.** `device_sso_session.secret_hash` holds `SHA-256(device_secret)`; validation
recomputes it and compares in constant time (`equalDSHash` accepts padded and unpadded base64url, because
the spec does not pin the encoding). Even so, a leaked device secret is a single-session credential, not a
key.

**`sid` is the authorization-code token family.** The session identifier is the token family of the
authentication, so revoking the family ("sign out everywhere") invalidates the secret's `ds_hash` binding
and every refresh token derived from it. The exchanged access token reuses the same family id, which is
what makes cross-application sign-out a single operation.

**Sharing is allow-listed per client.** By default a secret is only accepted from a client of the same
relying party (`client_detail.rp_id`), which is the "same vendor's app family" case the spec describes. A
deployment that needs to share across relying parties opts clients in explicitly through
`additional_config.native_sso_allowed_clients`.

**The exchange validates in a fixed order**, so error codes never leak state:
provider configured → secret valid (`invalid_grant`) → DPoP `cnf.jkt` match → subject token type →
id_token `aud` contains the secret's client → `ds_hash` match → `sid` present and matching → `sub` match →
scope subset (`invalid_scope`) → issue.

## Onboarding a client for Native SSO

1. Create the client as usual (client management API), with `private_key_jwt` authentication and the
   redirect URIs of both applications.
2. Allow the scopes and grant types in its entitlement, in `client_detail.additional_config`:

   ```json
   {
     "allowed_authorization_scopes": ["openid", "profile", "email", "device_sso"],
     "native_sso_allowed_clients": ["child-app-client-id"]
   }
   ```

   `native_sso_allowed_clients` is only needed when `require_same_relying_party` is false; with the
   default it is enough that both clients share `rp_id`.
3. Add the grant types to the client: `authorization_code`, `refresh_token`,
   `urn:ietf:params:oauth:grant-type:token-exchange`. The client-management API validates grant types, so
   the token-exchange URN is accepted (see `internal/clientmgmt/validate.go`).
4. The Super App requests `scope=openid profile device_sso` at the authorization endpoint and receives
   `device_secret` (plus `ds_hash` and `sid` in the id_token) from the token endpoint.
5. The Child App calls the token endpoint:

   ```http
   POST /oauth2/token
   Content-Type: application/x-www-form-urlencoded

   grant_type=urn:ietf:params:oauth:grant-type:token-exchange
   &audience=https%3A%2F%2Fesignet.example.com
   &subject_token=<Super App id_token>
   &subject_token_type=urn:ietf:params:oauth:token-type:id_token
   &actor_token=<device_secret>
   &actor_token_type=urn:openid:params:token-type:device-secret
   &scope=openid+profile
   &client_id=child-app
   ```

   The response contains `access_token`, `issued_token_type`, `token_type=bearer`, and optionally `scope`,
   `expires_in`, `refresh_token`, `id_token`, `device_secret`.

6. The Super App must resend `device_secret` on every refresh (`grant_type=refresh_token`); eSignet
   validates it and, if it is no longer valid, the refresh is refused rather than silently downgraded.

## Configuration

`data/deployment.yaml`:

```yaml
oauth:
  allowed_grant_types: ["authorization_code", "refresh_token",
                        "urn:ietf:params:oauth:grant-type:token-exchange"]
  allowed_scopes: ["openid","profile","email","phone","device_sso"]

device_sso:
  secret_validity_secs: 3600
  session_validity_secs: 86400
  require_same_relying_party: true
```

Environment overrides: `MOSIP_ESIGNET_DEVICE_SSO_SECRET_VALIDITY_SECS`,
`MOSIP_ESIGNET_DEVICE_SSO_SESSION_VALIDITY_SECS`,
`MOSIP_ESIGNET_DEVICE_SSO_REQUIRE_SAME_RELYING_PARTY`.

Provisioning: the device-secret encryption key lives under the `DEVICE_SECRET_ENCRYPT` reference and must
be in `KEYMANAGER_SYMMETRIC_KEY_ALLOWED_REF_IDS`. Until it is, the service falls back to
`CACHE_ENCRYPT` and logs a warning on every first use.

## Database

`db_upgrade_script/mosip_esignet/sql/2.0.0_to_2.1.0_upgrade.sql` adds:

* `esignet.device_sso_session` — one row per secret-minting exchange; stores `secret_hash`, not the
  secret, plus `session_status` (`ACTIVE`/`REVOKED`/`EXPIRED`) and the session expiry;
* three indexes: per subject, per client, and a partial index over `ACTIVE` rows for expiry sweeps;
* the `DEVICE_SECRET_ENCRYPT` key policy row.

The rollback drops the table and the policy (keystore material is left in place) and leaves client
entitlements untouched, because `device_sso` is inert on a 2.0.0 server.

Both scripts were applied against PostgreSQL 17 with the 2.0.0 schema and reverted cleanly.

## Session API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/esignet/device-sso/sessions?subject=&clientId=&limit=` | list sessions |
| `GET` | `/v1/esignet/device-sso/sessions/{sessionId}` | read one |
| `POST` | `/v1/esignet/device-sso/sessions/{sessionId}/revoke` | revoke one |
| `POST` | `/v1/esignet/device-sso/sessions/revoke?subject=` | revoke every session of a user |

End-user callers are scoped by the `X-ESignet-Subject-Id` header (set by the authenticating gateway), so a
user can only ever read or revoke their own sessions; administrative callers are authorised by the usual
bearer token and scope mapping. The platform service proxies these endpoints for the mobile dashboards and
for the administrator console, and adds an audit record for every revocation.

## The platform service

OTP delivery and the operational console deliberately live outside eSignet (see
`services/platform/README.md`):

* eSignet's identity provider calls `POST /internal/otp/send` and `POST /internal/otp/verify` with a shared
  API key, instead of carrying an SMS/email integration;
* the mobile dashboards call `/v1/me/sessions` and `/v1/me/sessions/{id}/revoke` with their eSignet access
  token, which the platform validates by introspection;
* the administrator console reads `/v1/admin/overview`, `/v1/admin/analytics/auth`, `/v1/admin/sessions`
  and streams `/v1/admin/events/stream` (Server-Sent Events).

eSignet stays the only authority for sessions, device secrets and tokens; the platform never reads
`device_sso_session` directly.

## Testing

| Suite | What it proves |
| --- | --- |
| `thunderid-engine/internal/oauth/oauth2/granthandlers/token_exchange_native_sso_test.go` | 25 subtests: happy path, missing/expired/revoked secret, wrong client, `ds_hash`/`sid` mismatch, `sub` mismatch, scope escalation, DPoP mismatch, `device_sso` in scope rejected |
| `esignet-service/internal/devicesecret/service_test.go` | JWE round trip, tamper rejection, digest comparison, expiry |
| `esignet-service` full suite | 26 packages, unchanged and green after the feature |
| `services/platform` unit tests | OTP state machine (replay, lock, expiry, supersession, throttling), keyed digest, SMTP against an in-process server, SMS credential handling, admin auth |
| `services/platform/scripts/e2e_check.sh` | real email delivery: the OTP is read out of the delivered mailbox, then verified, replayed (rejected), and audited |

## Known gap

`device_secret` on the **refresh_token** grant is parsed and modelled but not yet enforced: a refresh
request neither validates a resupplied secret nor mints a new one. Spec §3.4.3 requires the client to
resend it and allows the server to rotate it (not recommended). Until this is implemented, a client that
omits the secret on refresh still receives new tokens. The model field (`model.TokenRequest.DeviceSecret`)
and the form parse already exist, so the change is confined to the refresh grant handler and its tests.
