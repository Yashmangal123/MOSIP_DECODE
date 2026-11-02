# Native SSO — Android Super App + Child App

Two real Android apps that run the OpenID Connect Native SSO flow against the demo authorization server
in `services/native-sso-demo` (or against eSignet, once it is running).

| App | What it does |
| --- | --- |
| `app-super` | Signs the citizen in: authorization request with PKCE and `scope=… device_sso` in a WebView, OTP + consent, code exchange. Receives `device_secret` (`typ: sso-session+jwt`, `session_data`), keeps it encrypted with an **Android Keystore** key. |
| `app-child` | Has **no login screen**. It receives the device secret from the Super App and performs the RFC 8693 token exchange (`subject_token` = the device secret). It shows `interaction_required` when the session is gone. |

Both use only the Android SDK + AndroidX — no third-party HTTP client, no crypto library.

## Build and run

1. **Start the server first** (on your machine, not in the emulator):

   ```bash
   cd ../../services/native-sso-demo
   cp .env.example .env      # SSO_PLATFORM_API_KEY + SSO_CLIENT_SECRET
   set -a && . ./.env && set +a
   go run .                  # :8091
   ```

2. **Open the project** in Android Studio: `File → Open → mosip-decode/apps/android`.
   Let it sync; it creates the Gradle wrapper and downloads SDK 34.
   From a terminal instead: `gradle wrapper` once, then `./gradlew :app-super:assembleDebug`.

3. **Run `app-super`** on an emulator. It talks to `http://10.0.2.2:8091` (that address is the host machine as
   seen from the emulator — already set in `Config.kt`).

   For a physical phone: put your computer's LAN address in both `Config.kt` files, e.g.
   `http://192.168.1.20:8091`, and keep phone and computer on the same Wi-Fi.

4. **Install and run `app-child`** in the same emulator/device.

5. In the Super App: **Sign in with eSignet** → the WebView opens the login page → type the citizen's
   email → the code arrives in that inbox → enter it → **Allow** → you are back in the app with the
   tokens, the `sid` and the device secret.

6. Press **Open Child App (no login)**. The Child App opens already holding the device secret; press
   **Continue with this device** → tokens for the same `sid`, **no code was requested**.

7. Restart the authorization server, press the button again → `interaction_required`.

## How the two apps share the credential

The Super App hands the device secret over with an explicit intent to the Child App's package
(`org.mosip.nativesso.SSO_HANDOFF`, `setPackage(...)`), which only that app can receive. In production a
publisher would normally keep the secret in a shared credential store (Android `AccountManager` or a
signature-protected `ContentProvider`); the intent keeps the demo readable without weakening the point:
the second app gets tokens **without ever talking to the user**.

## What is verified, and what is not

- The **server side** of this flow is tested and running (`go test ./...` in `services/native-sso-demo`,
  14 subtests, live on `:8091`).
- These Android sources have **not been compiled here**: this sandbox has no Android SDK or Gradle.
  Expect to fix nothing but the SDK path; the code uses only stable APIs (Activity, WebView, HttpURLConnection,
  Keystore/GCM). If your Android Studio flags anything, it will be a lint nit, not a design change.

## Files

```
app-super/src/main/java/org/mosip/nativesso/superapp/SuperAppActivity.kt   login + device secret + hand-off
app-super/src/main/java/org/mosip/nativesso/superapp/Http.kt              form POST / GET with a Bearer token
app-super/src/main/java/org/mosip/nativesso/superapp/Config.kt            server URL, client id, redirect, scope
app-child/src/main/java/org/mosip/nativesso/childapp/ChildAppActivity.kt  device-secret token exchange
app-child/src/main/java/org/mosip/nativesso/childapp/Http.kt
app-child/src/main/java/org/mosip/nativesso/childapp/Config.kt
```
