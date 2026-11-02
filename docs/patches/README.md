# Patches — status

## `native-sso-engine.patch` — **obsolete, kept for reference**

2022-line diff against an **older** snapshot of `github.com/thunder-id/thunderid` (`backend/`). It was
written before we discovered that the current engine implements Native SSO natively
(see `../upstream-native-sso.md`). Applying it to today's upstream **breaks the build**, because it
reverts unrelated upstream work (it removes imports such as `internal/system/template`,
`internal/oauth/oauth2/tokenservice` and re-adds older code paths).

Do **not** apply it. It is kept only to document the design we arrived at independently, and for the
optional deployment that must mint device secrets inside eSignet's key manager
(`esignet-service/internal/devicesecret` + `pkg/thunderidengine/providers/devicesecret.go`); that path
needs a fresh port onto current upstream, which is not part of the shipped, verified build.

## What to do instead

Nothing. Use the engine as it ships:

```bash
cd thunderid-engine
GOMAXPROCS=1 GOGC=40 go test -p 1 ./internal/oauth/oauth2/tokenservice/... ./internal/oauth/oauth2/granthandlers/...
```

`device_sso`, `device_secret` (`typ: sso-session+jwt`), `session_data` and the device-secret token
exchange are all implemented upstream and covered by the engine's own tests.
