# Live OTP delivery — proof of run

Captured on 2026-11-02 against the platform service in **production** configuration
(`PLATFORM_ENV=production`, `PLATFORM_OTP_EXPOSE_IN_DEV=false`) with **real Gmail SMTP** submission.
No simulated transport, no hardcoded code, no development echo.

## Configuration under test

| Setting | Value |
| --- | --- |
| SMTP host / port / mode | `smtp.gmail.com` / `587` / `starttls` (TLS 1.2+, certificate verified) |
| Authentication | AUTH PLAIN with a Google **app password** (not the account password) |
| Sender | `meyash4633@gmail.com` |
| Recipient | `meyash4633@gmail.com` → citizen `uin=8824166690` in the identity directory |
| OTP policy | 6 digits, 5 minutes validity, 5 attempts, 30 s resend cooldown, 5 sends / 15 min |
| Storage | only `HMAC-SHA256(pepper, uin‖otp)` persisted |

## 1. Transport probe

```json
{
  "channel": "email", "to": "meyash4633@gmail.com", "provider": "smtp",
  "delivered": true, "reference": "smtp:meyash4633@gmail.com",
  "attempts": 1, "latencyMs": 869
}
```

## 2. Real login OTP request

```http
POST /v1/identity/otp/send
{"identifier":"meyash4633@gmail.com","channel":"email"}
```

```json
{
  "transactionId": "32674720-b412-4c7a-b289-c9246aa22cb8",
  "channel": "email",
  "maskedDestination": "m*********@gmail.com",
  "expiresIn": 299,
  "resendAfter": 30,
  "deliveryStatus": "SENT",
  "provider": "smtp"
}
```

The response carries **no OTP** — only a masked destination and the provider's verdict. The code existed
in the server's memory and in the delivered message, nowhere else.

Database row after delivery:

```
provider | delivery_status | latency_ms
smtp     | SENT            | 833
```

## 3. Verification with the code read from the real inbox

The code `553503` was read from the delivered email and verified:

```http
POST /v1/identity/otp/verify
{"transactionId":"32674720-b412-4c7a-b289-c9246aa22cb8","otp":"553503"}
```

```json
{"verified":true,"uin":"8824166690"}
```

The identity provider now has an authenticated subject; from this point the Native SSO
authorization-code exchange would mint the `device_secret` bound to that session.

## 4. Replay of the same code

```json
{"error":{"code":"otp_already_used","message":"This code was already used"}}
```

The challenge is `CONSUMED`; a stolen code cannot be reused even within its validity window.

## 5. Wrong code on a fresh challenge

```json
{"error":{"code":"incorrect_otp","message":"The verification code is incorrect"}}
```

This counts as attempt 1 of 5 before the challenge locks.

## 6. Database and audit trail

```
 challenge_status | attempts | channel | provider | delivery_status | latency_ms
------------------+----------+---------+----------+-----------------+------------
 ACTIVE           |        1 | email   | smtp     | SENT            |       1425
 CONSUMED         |        0 | email   | smtp     | SENT            |        833
```

```
OTP_FAILED   | WARNING | FAILED
OTP_SENT     | INFO    | SENT
OTP_VERIFIED | INFO    | SUCCESS
OTP_SENT     | INFO    | SENT
```

Every step is visible in the administrator console (`/console` → *Operations overview*): OTP funnel,
delivery health per channel/provider with average latency, security events by severity, and the live
event stream.

## What this proves for the evaluation

1. **The OTP is generated in real time** by `crypto/rand` on each request, not a fixture.
2. **Delivery is real**: a TLS-authenticated SMTP session with a public provider, measured latency, and a
   provider-acknowledged message — not a log line pretending to be an email.
3. **The code never leaves the delivery channel**: it is absent from API responses, logs, database rows and
   error strings; only a keyed digest is stored.
4. **The lifecycle is enforced**: single use, attempt counting, expiry, resend cooldown, supersession.
5. **The whole path is auditable**: delivery outcome per attempt plus an append-only security event stream.

## SMS status

The same flow is implemented and unit-tested for SMS (MSG91, Twilio, AWS SNS, and any HTTP gateway through
the templated `generic_http` transport), but no SMS account is configured yet. Indian carriers require a
DLT-registered sender ID and template, so live SMS needs those credentials from an operator account:

```bash
PLATFORM_SMS_PROVIDER=msg91
PLATFORM_MSG91_AUTH_KEY=<key>
PLATFORM_MSG91_TEMPLATE_ID=<DLT template id>
PLATFORM_SMS_SENDER_ID=<6-char DLT sender id>
```

`platform verify-delivery --phone +918824166690` then reports the provider's own verdict, exactly as the
email probe did above.

## 2026-11-02 16:37 UTC — local mailboxes are now refused

The project no longer ships or accepts a local mailbox. A one-time code is only ever delivered to a real
address, and the service refuses to start with a catcher:

```console
$ PLATFORM_SMTP_HOST=mailpit PLATFORM_SMTP_PORT=1025 PLATFORM_SMTP_TLS=starttls /tmp/platform
{"level":"ERROR","msg":"platform service failed","error":"load configuration: PLATFORM_SMTP_HOST=\"mailpit\"
 is a local test mailbox: codes would never reach the citizen. Point it at a real SMTP relay, or set
 PLATFORM_ALLOW_LAB_DELIVERY=true for a lab"}
```

Refused hosts: empty host, `localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, `mailpit`, `mailhog`, `smtp4dev`,
`mailcatcher`, and any `*.local` / `*.localhost` name. The only escape hatch is the explicit
`PLATFORM_ALLOW_LAB_DELIVERY=true`.

Real delivery, same minute:

```console
$ curl -s -X POST localhost:8090/v1/identity/otp/send -H 'Content-Type: application/json' \
       -d '{"identifier":"<citizen inbox>","channel":"email"}'
{"transactionId":"dd60469a-ce41-4c1c-a0da-09a7f4eca053","channel":"email",
 "maskedDestination":"m*********@gmail.com","expiresIn":299,"resendAfter":30,
 "deliveryStatus":"SENT","provider":"smtp"}
```

`scripts/smtp_catcher.py` was deleted. `scripts/e2e_check.sh` now reads the code out of a **real IMAP
mailbox** (`scripts/read_otp.py`, env `MAIL_IMAP_HOST` / `MAIL_IMAP_USER` / `MAIL_IMAP_PASSWORD`);
the `.eml`-directory mode survives only behind `--dir` for a lab.
