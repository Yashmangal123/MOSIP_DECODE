cat > start.sh <<'SCRIPT'
#!/usr/bin/env bash
# Start the site. No paths hardcoded — drop this file anywhere inside the repo and run it.
# Ctrl-C stops everything.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

# walk up to the repository root (the folder that has services/)
ROOT="$HERE"
while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/services" ]; do ROOT="$(dirname "$ROOT")"; done
[ -d "$ROOT/services" ] || { echo "run me from inside the repository"; exit 1; }

# find a service by a key only its .env knows
find_service() {
  while IFS= read -r f; do grep -q -- "$1" "$f" 2>/dev/null && { dirname "$f"; return 0; }; done <<EOF
$(find "$ROOT" -maxdepth 5 -type f \( -name .env -o -name .env.example \) -not -path '*/.git/*' 2>/dev/null | sort)
EOF
  return 1
}
PLATFORM_DIR="$(find_service PLATFORM_SMTP_HOST)" || { echo "platform service not found"; exit 1; }
DEMO_DIR="$(find_service SSO_PLATFORM_URL)"      || { echo "demo service not found"; exit 1; }

get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
set_key() { if grep -q "^$2=" "$1"; then sed -i.bak "s|^$2=.*|$2=$3|" "$1" && rm -f "$1.bak"; else echo "$2=$3" >>"$1"; fi; }

# .env must exist; otherwise copy the example next to it
for d in "$PLATFORM_DIR" "$DEMO_DIR"; do
  [ -f "$d/.env" ] || cp "$d/.env.example" "$d/.env" || { echo "no .env in $d"; exit 1; }
done

# the demo refuses to start without a signing secret — generate once
case "$(get SSO_CLIENT_SECRET "$DEMO_DIR/.env")" in
  ""|CHANGE_ME*|CHANGEME*) set_key "$DEMO_DIR/.env" SSO_CLIENT_SECRET "$(openssl rand -hex 24 2>/dev/null || echo demo-$RANDOM$RANDOM$RANDOM)";;
esac
[ -z "$(get SSO_PLATFORM_API_KEY "$DEMO_DIR/.env")" ] && \
  set_key "$DEMO_DIR/.env" SSO_PLATFORM_API_KEY "$(get PLATFORM_API_KEY "$PLATFORM_DIR/.env")"

# ports come from configuration, nothing else
PPORT="$(get PLATFORM_PORT "$PLATFORM_DIR/.env")"; PPORT="${PLATFORM_PORT:-${PPORT:-8090}}"
DPORT="$(get SSO_ADDR "$DEMO_DIR/.env")";        DPORT="${SSO_ADDR:-$DPORT}"; DPORT="${DPORT#:}"; DPORT="${DPORT:-8091}"
PURL="http://127.0.0.1:$PPORT"

command -v go >/dev/null 2>&1 || { echo "Go is not glued: https://go.dev/dl/"; exit 1; }

# free the ports if an old run is still holding them
for p in "$PPORT" "$DPORT"; do
  ids="$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null | sort -u)"
  [ -n "$ids" ] && { echo "port $p busy — stopping it"; kill $ids 2>/dev/null; sleep 1; }
done

# platform, background
LOG="$ROOT/.platform.log"
( cd "$PLATFORM_DIR" && set -a && . ./.env && set +a && nohup go run ./cmd/platform >"$LOG" 2>&1 & echo $! >"$ROOT/.platform.pid" )
for _ in $(seq 1 120); do curl -fsS --max-time 2 "$PURL/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 "$PURL/health" >/dev/null 2>&1 || { echo "platform failed:"; tail -n 20 "$LOG"; exit 1; }
echo "platform UP -> http://localhost:$PPORT/console"

# everything stops together
trap 'echo; ids="$(lsof -nP -tiTCP:"'$PPORT'" -sTCP:LISTEN 2>/dev/null|sort -u)"; [ -n "$ids" ] && kill $ids 2>/dev/null; exit 0' INT TERM

# demo, foreground
echo "site UP     -> http://localhost:$DPORT"
cd "$DEMO_DIR" && set -a && . ./.env && set +a
export SSO_PLATFORM_URL="${SSO_PLATFORM_URL:-$PURL}"
export SSO_PLATFORM_API_KEY="${SSO_PLATFORM_API_KEY:-$(get PLATFORM_API_KEY "$PLATFORM_DIR/.env")}"
exec go run .
SCRIPT
chmod +x start.sh && ./start.sh
