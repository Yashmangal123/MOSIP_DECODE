# Native SSO demo — what was run and what it proves

The Native SSO flow is now something you can **click**, not just read about.
`services/native-sso-demo` is a self-contained Go binary (standard library only) that plays both the
authorization server and two native "apps" on one phone.

## Live run on this machine (2026-11-02, 16:12 UTC)

Platform service (identity + e-mail delivery) on `:8090`, demo on `:8091`, production configuration,
no lab flags:

```console
$ curl -s localhost:8091/health
{"issuer":"http://localhost:8091","labMode":false,"sessions":0,"status":"UP","time":"2026-11-02T16:12:48Z"}

$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8091/
200
$ curl -s -o /dev/null -w '%{http_code}\n' 'localhost:8091/app?client=super-app'
200

# a real authorization request (PKCE, scope=openid profile email device_sso)
$ curl -s 'localhost:8091/oauth2/authorize?client_id=super-app&response_type=code&…'
200  → login page rendered, hidden sid = FedXASgopnaeHnBA5IGAPg

# the login page asks the platform to mail a real code
$ curl -s -X POST localhost:8091/oauth2/login \
       -d 'sid=FedXASgopnaeHnBA5IGAPg&step=send&identifier=<citizen inbox>'
200  → “Sent to <b>m*********@gmail.com</b> via smtp”
```

The masked destination and `via smtp` come from the platform service: the code really left the machine
through the configured SMTP provider, and the browser flow continues with that code. No code is ever
generated or displayed by the demo (`SSO_LAB_OTP` is unset).

## The flow, in protocol order

| Step | Endpoint | Result |
| --- | --- | --- |
| 1 | `GET /oauth2/authorize` | login page; PKCE `code_challenge` required |
| 2 | `POST /oauth2/login` (send) | platform `/internal/otp/send` → e-mail |
| 3 | `POST /oauth2/login` (verify) | platform `/internal/otp/verify` → UIN bound to the request |
| 4 | `POST /oauth2/consent` | `302` to `…/app/callback?client=…&code=…&state=…` |
| 5 | `POST /oauth2/token` (`authorization_code`) | `access_token`, `id_token` (with `sid`), `refresh_token`, and because `device_sso` was granted: `device_secret` (a JWT with `typ: sso-session+jwt`), `session_data`, `device_secret_expires_in` |
| 6 | `POST /oauth2/token` (token exchange, `subject_token` = the device secret, `subject_token_type=…:jwt`) | new tokens + refresh token for the **same `sid`**, no user interaction |
| 6b | after revocation | `error=interaction_required` — the expected signal that the app must show a login screen |
| 7 | `GET /oauth2/userinfo` | profile for either token |

## Automated tests (`go test ./... -v`, all passing)

`TestFullNativeSSOFlow`
: end-to-end: authorize → send → verify → consent → code → tokens; asserts the device secret is a JWT with
`typ: sso-session+jwt` carrying exactly one `session_data` entry, that `sid` matches the id token, that a
second app exchanges the secret and keeps the same `sid`, that both access tokens work at `/userinfo`,
and that the refresh token rotates (and the old one stops working).

`TestDeviceSecretRejections`
: an id token presented as a subject token, a garbage token, a wrong `subject_token_type`, an
`actor_token`, a non-access `requested_token_type`, `device_sso` inside an exchange, scope widening, an
unknown client, a tampered signature — each refused with the code the engine would return. Then the
session is revoked and the next exchange answers `interaction_required`.

`TestAuthorizationCodeSingleUseAndPKCE`
: a code can be redeemed once; a wrong `code_verifier` fails.

`TestAuthorizeValidation`
: unknown client, wrong `response_type`, `redirect_uri` mismatch, missing `openid`, disallowed scope,
missing PKCE — each refused with either a 400 page or an OAuth error redirect.

`TestPagesRender`
: landing page, both app screens and `/health` render; no cookies are required.

## What this is not

Signing is HS256 with a shared secret and sessions live in memory, because the demo must run with zero
dependencies. Production eSignet signs with the key manager and delegates the flow to the engine. The
**protocol shape is the engine's own**: `device_sso` granted at the token endpoint, a `device_secret` JWT
with `typ: sso-session+jwt` and `session_data`, redeemed as the `subject_token` of an RFC 8693 exchange,
with `interaction_required` when the session can no longer be used silently. See
`docs/upstream-native-sso.md` for the exact source locations in `thunderid-engine`.
