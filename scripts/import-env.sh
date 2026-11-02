#!/usr/bin/env bash
# Copy the .env files from an older extraction into this one, so that upgrading the code does not mean
# retyping the SMTP password and the API keys.
#
#   scripts/import-env.sh ~/Downloads/esignet
#
# It never prints a secret in full, and it refuses to overwrite a .env that already has values unless
# you pass --force.
set -euo pipefail

OLD="${1:-}"
FORCE="${2:-}"
if [ -z "$OLD" ] || [ ! -d "$OLD" ]; then
  echo "usage: scripts/import-env.sh <path to the OLD mosip-decode folder> [--force]" >&2
  echo "   eg: scripts/import-env.sh ~/Downloads/esignet/mosip-decode" >&2
  exit 1
fi

NEW="$(cd "$(dirname "$0")/.." && pwd)"
imported=0

for rel in services/platform/.env services/native-sso-demo/.env; do
  src="$OLD/$rel"
  dst="$NEW/$rel"
  if [ ! -f "$src" ]; then
    echo "skip  $rel (not found in $OLD)"
    continue
  fi
  if [ -f "$dst" ] && [ "$FORCE" != "--force" ] && grep -qE '^[A-Z_]+=.+' "$dst"; then
    echo "skip  $rel (already configured here — pass --force to overwrite)"
    continue
  fi
  cp "$src" "$dst"
  echo "copied $rel"
  imported=$((imported + 1))
done

echo
echo "summary (secrets masked):"
for rel in services/platform/.env services/native-sso-demo/.env; do
  f="$NEW/$rel"
  [ -f "$f" ] || continue
  echo "  $rel"
  grep -E '^(PLATFORM_SMTP_HOST|PLATFORM_SMTP_PORT|PLATFORM_SMTP_USERNAME|PLATFORM_SMTP_FROM|PLATFORM_API_KEY|SSO_PLATFORM_API_KEY|SSO_LAB_OTP)=' "$f" \
    | sed -E 's/=(.{0,4}).*/=\1***/' | sed 's/^/    /'
  if grep -q '^PLATFORM_SMTP_PASSWORD=' "$f"; then
    len=$(grep '^PLATFORM_SMTP_PASSWORD=' "$f" | head -1 | cut -d= -f2- | tr -d '"' | wc -c | tr -d ' ')
    echo "    PLATFORM_SMTP_PASSWORD=*** ($((len - 1)) chars)"
  fi
done

echo
if [ "$imported" -eq 0 ]; then
  echo "Nothing was copied. Check the path, or use --force."
  exit 2
fi
echo "done. Start the services:"
echo "  cd services/platform       && set -a && . ./.env && set +a && go run ./cmd/platform"
echo "  cd services/native-sso-demo && set -a && . ./.env && set +a && go run ."
