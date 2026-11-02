# eSignet Native SSO — Identity, OTP and Cross-App Session Demo

A runnable reference project exploring MOSIP eSignet-style authentication and Native Single Sign-On (SSO). It combines an identity/OTP platform, a browser-based Native SSO demonstration, and supporting eSignet / ThunderID engine source and documentation.

> **Scope note:** This repository is a development and learning reference, not an official MOSIP release or a production-ready identity provider. The Native SSO demo is explicitly a reference implementation. Review the security notes and limitations in `docs/upstream-native-sso.md` and `services/native-sso-demo/README.md` before adapting it for real users.

## Run it — two terminal commands

**Requirements:** Docker Desktop (with Docker Compose v2) and Git. Allow Docker to download the PostgreSQL and application images on first run.

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd mosip-decode && ./run.sh
```

The first command clones your repository. The second starts the platform and PostgreSQL containers. On first run, the script creates `services/platform/.env` from the safe example configuration. To send real OTP emails, stop the stack, edit that file with valid SMTP credentials (for Gmail, use an App Password), then run `./run.sh` again.

When the service is ready, open:

- **Admin console:** http://localhost:8090/console
- **Health check:** http://localhost:8090/health

The demo admin credentials are configured in `services/platform/.env.example`. Change them before exposing the service beyond your local machine. Stop the stack with `Ctrl+C`; to stop and remove its containers, run `docker compose -f services/platform/deploy/docker-compose.yml down` from the repository root.

## What is included

| Component | Purpose |
|---|---|
| `services/platform/` | Go identity and OTP platform, PostgreSQL schema/seeds, delivery adapters, API and admin console |
| `services/native-sso-demo/` | Browser demo of login through a Super App and silent continuation in a Child App using Native SSO token exchange |
| `esignet-service/` | eSignet service source and supporting build files |
| `thunderid-engine/` | ThunderID engine source and tests |
| `apps/android/` | Android Super App and Child App demonstration projects |
| `docs/` | Architecture, Native SSO flow, upstream implementation notes and test evidence |
| `db_upgrade_script/` | Database upgrade and rollback scripts |

## Native SSO browser demonstration

The Docker quick start above starts the platform API and admin console on port `8090`. The separate Native SSO demo runs on port `8091` and requires Go to be installed. Follow `services/native-sso-demo/README.md` to configure and start it after the platform is running. That guide also explains the Super App → OTP login → consent → Child App token-exchange flow.

## Configuration and security

- Never commit `.env` files, SMTP passwords, API keys, signing secrets, or real user data.
- Start from the relevant `.env.example` files and replace every `CHANGE_ME` value.
- Use long, unique secrets and rotate any credential that has ever been committed or shared.
- Configure a real SMTP provider to deliver OTPs. A successful local API response is not proof that an email reached the inbox; check provider logs and `docs/live-otp-evidence.md`.
- Do not expose the demo admin console or development credentials to the public internet.

## Tests and further documentation

- Platform service: `services/platform/README.md`
- Native SSO demo and tests: `services/native-sso-demo/README.md`
- API reference: `services/platform/docs/api.md`
- Deployment notes: `services/platform/docs/deploy.md`
- Native SSO architecture: `docs/native-sso.md`
- Upstream implementation notes: `docs/upstream-native-sso.md`
- Problem statement: `../problem_statement.txt`

## Suggested GitHub repository description

`A Go-based eSignet Native SSO reference project with identity and OTP services, PostgreSQL, a browser-based Super App/Child App demo, and Android sample apps.`

Team
Team Name: CODECRAFT

Team Members:
1. Yash Mangal
2. Shubham Kuvad
3. Harsh Lotiya
