cat > start.sh <<'SCRIPT'
#!/usr/bin/env bash
# start.sh — start the site (platform + Native SSO demo). Ctrl-C stops both.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"

search_root() { # search_root <marker> <root>
  local marker="$1" root="$2" f
  [ -d "$root" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -q -- "$marker" "$f" 2>/dev/null; then dirname "$f"; return 0; fi
  done <<EOF
$(find "$root" -maxdepth 6 \( -name node_modules -o -name .git -o -name vendor \) -prune -o \
        -type f \( -name .env -o -name .env.example \) -print 2>/dev/null | sort)
EOF
  return 1
}

locate() { # locate <marker>
  local marker="$1" root found
  for root in "$HERE" "$(dirname "$HERE")" "$PWD" "$(dirname "$PWD")"; do
    if found="$(search_root "$marker" "$root")"; then printf '%s\n' "$found"; return 0; fi
  done
  return 1
}

PLATFORM_DIR="$(locate PLATFORM_SMTP_HOST)" || { echo "platform service not found (looked from $HERE)"; exit 1; }
DEMO_DIR="$(locate SSO_PLATFORM_URL)" || { echo "demo service not found (looked from $HERE)"; exit 1; }

get() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
set_key() { if grep -q "^$2=" "$1" 2>/dev/null; then sed -i.bak "s|^$2=.*|$2=$3|" "$1" && rm -f "$1.bak"; else printf '%s=%s\n' "$2" "$3" >>"$1"; fi; }

for dir in "$PLATFORM_DIR" "$DEMO_DIR"; do
  if [ ! -f "$dir/.env" ]; then
    if [ -f "$dir/.env.example" ]; then cp "$dir/.env.example" "$dir/.env"; echo "created $dir/.env from .env.example — fill in the mail settings, then run again"
    else echo "no .env in $dir"; exit 1; fi
  fi
done

case "$(get SSO_CLIENT_SECRET "$DEMO_DIR/.env")" in
  ""|CHANGE_ME*|CHANGEME*) set_key "$DEMO_DIR/.env" SSO_CLIENT_SECRET "$(openssl rand -hex 24 2>/dev/null || echo demo-$RANDOM$RANDOM$(date +%s))";;
esac
[ -z "$(get SSO_PLATFORM_API_KEY "$DEMO_DIR/.env")" ] && set_key "$DEMO_DIR/.env" SSO_PLATFORM_API_KEY "$(get PLATFORM_API_KEY "$PLATFORM_DIR/.env")"

PPORT="$(get PLATFORM_PORT "$PLATFORM_DIR/.env")"; PPORT="${PLATFORM_PORT:-${PPORT:-8090}}"
DPORT="$(get SSO_ADDR "$DEMO_DIR/.env")";        DPORT="${SSO_ADDR:-$DPORT}"; DPORT="${DPORT#:}"; DPORT="${DPORT:-8091}"
PURL="http://127.0.0.1:$PPORT"

command -v go >/dev/null 2>&1 || { echo "Go is not installed: https://go.dev/dl/"; exit 1; }

for port in "$PPORT" "$DPORT"; do
  command -v lsof >/dev/null 2>&1 || break
  ids="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)"
  [ -n "$ids" ] && { echo "port $port is busy — stopping it"; kill $ids 2>/dev/null; sleep 1; }
done

LOG="${TMPDIR:-/tmp}/esignet-platform.log"
echo "platform dir : $PLATFORM_DIR"
echo "demo dir     : $DEMO_DIR"
echo "starting the platform on :$PPORT"
( cd "$PLATFORM_DIR" && set -a && . ./.env && set +a && nohup go run ./cmd/platform >"$LOG" 2>&1 & echo $! >"${TMPDIR:-/tmp}/esignet-platform.pid" )

for _ in $(seq 1 120); do curl -fsS --max-time 2 "$PURL/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 "$PURL/health" >/dev/null 2>&1 || { echo "platform failed. Last lines of $LOG:"; tail -n 20 "$LOG"; exit 1; }
echo "platform UP  -> http://localhost:$PPORT/console"

trap 'echo; ids="$(command -v lsof >/dev/null 2>&1 && lsof -nP -tiTCP:"'$PPORT'" -sTCP:LISTEN 2>/dev/null|sort -u)"; [ -n "$ids" ] && kill $ids 2>/dev/null; exit 0' INT TERM

echo "site UP      -> http://localhost:$DPORT"
cd "$DEMO_DIR" && set -a && . ./.env && set +a
export SSO_PLATFORM_URL="${SSO_PLATFORM_URL:-$PURL}"
export SSO_PLATFORM_API_KEY="${SSO_PLATFORM_API_KEY:-$(get PLATFORM_API_KEY "$PLATFORM_DIR/.env")}"
exec go run .
SCRIPT
chmod +x start.sh && ./start.sh
