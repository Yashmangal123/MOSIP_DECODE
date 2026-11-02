# Native SSO in the current engine — what upstream already implements

**Correction to the earlier status in this repository: the engine does not need our patch.**

While re-checking the engine source (fresh clone of `github.com/thunder-id/thunderid`, `backend/`,
2 230 Go files) it turned out that OpenID Connect Native SSO for mobile apps is **already implemented
upstream**. Our earlier `docs/patches/native-sso-engine.patch` was written against an older snapshot and
is now obsolete; see `patches/README.md`.

## Where it lives

| Concern | File | What it does |
| --- | --- | --- |
| Scope | `internal/oauth/oauth2/constants/constants.go` | `ScopeDeviceSSO = "device_sso"`, registered in the scope catalogue |
| Token type | `internal/system/jose/jwt/constants.go` | `TokenTypeDeviceSecret = "sso-session+jwt"` — the `typ` header of a device secret |
| Minting | `internal/oauth/oauth2/tokenservice/builder.go` (`BuildDeviceSecret`) | signs the device secret: `sub`, `iat`, `nbf`, `exp`, `jti`, `aud = issuer`, and `session_data` |
| Session data | `internal/oauth/oauth2/tokenservice/model.go` | `DeviceSecretClaims`, and the `session_data` entries `{flow_identifier, session_handle}` |
| Issued on the code grant | `internal/oauth/oauth2/granthandlers/authorization_code.go:126` | `tokenResponse.DeviceSecret = h.buildDeviceSecret(...)` when the code carried `device_sso` |
| Validation | `internal/oauth/oauth2/tokenservice/validator.go` (`ValidateDeviceSecret`) | verifies signature, `typ`, expiry, and reads the sessions back out |
| Redemption | `internal/oauth/oauth2/granthandlers/token_exchange.go:388` (`handleDeviceSecretGrant`) | a token exchange whose `subject_token` is a device secret resumes the session silently and issues the tokens the code grant would, plus a refresh token |
| Detection | `internal/oauth/oauth2/granthandlers/token_exchange.go:464` (`isDeviceSecretSubjectToken`) | the subject token is a device secret when `subject_token_type` is `…:jwt` and its `typ` header is `sso-session+jwt` |

## The protocol shape upstream implements (and our demo now mirrors)

```
1. GET  /oauth2/authorize        scope=openid … device_sso
2. POST /oauth2/token            grant_type=authorization_code
                                 → access_token, id_token, refresh_token,
                                   device_secret   (JWT, typ "sso-session+jwt")
                                   session_data    [{flow_identifier, session_handle}]
3. POST /oauth2/token            grant_type=urn:ietf:params:oauth:grant-type:token-exchange
                                 subject_token       = <the device_secret itself>
                                 subject_token_type  = urn:ietf:params:oauth:token-type:jwt
                                 requested_token_type= urn:ietf:params:oauth:token-type:access_token
                                 → access_token, id_token, refresh_token for the same session
4. Failure that is *expected*: if the session can no longer be used silently, the answer is
   error=interaction_required — the app then shows a login screen.
```

There is **no `ds_hash` parameter and no separate `device_secret` request parameter**: the secret is a
signed JWT presented *as* the subject token, and the exchange is authorised by that signature plus the
session it names. Any client that presents `actor_token` alongside a device secret is refused.

## Evidence (run on this machine, 2026-11-02)

The engine cannot be built with the default parallelism here (the sandbox has 2 GB of RAM and the
compiler is killed), but it **can** be built and tested serially:

```bash
cd thunderid-engine
export GOMAXPROCS=1 GOGC=40
go test -p 1 ./internal/oauth/oauth2/tokenservice/... ./internal/oauth/oauth2/granthandlers/...
# ok  github.com/thunder-id/thunderid/internal/oauth/oauth2/tokenservice   0.5s
# ok  github.com/thunder-id/thunderid/internal/oauth/oauth2/granthandlers  0.1s   ← Native SSO tests

go test -p 1 ./internal/oauth/...
# 26 packages ok, 0 failures — the whole OAuth2 stack (authz, token, tokenservice, granthandlers,
# revocation, userinfo, dpop, par, logout, ciba, dcr …)

go build -p 1 -o /tmp/thunderid-server ./cmd/server
# succeeded: 61 MB ELF binary, empty build log; `-h` prints the server's flags
```

So the engine is not "unbuildable here" — it is unbuildable *with default parallelism* on a 2 GB machine.
Serial compilation works, which is how the results above were produced.

Those two packages hold the Native SSO tests themselves (`token_exchange_test.go`,
`authorization_code_test.go`, `validator_test.go`, `builder_test.go`), so the device-secret path is
verified against the real source, not just against our demo.

## What this means for the deliverable

* **Recommended path (no patch):** run the engine as it is. `device_sso` works. eSignet only has to allow
  the scope for its clients and keep its own UI. Nothing in `docs/patches/` is needed.
* **Optional path (our patch):** only for a deployment that must mint device secrets inside eSignet's key
  manager instead of the engine's JWT signer — this is what `esignet-service/internal/devicesecret` and
  `pkg/thunderidengine/providers/devicesecret.go` are for. It requires wiring that provider into the token
  builder, which the current patch does for the older snapshot only.
* **The demo** (`services/native-sso-demo`) was rewritten to follow the upstream shape exactly, so what the
  judges click through is the same protocol the engine implements.
