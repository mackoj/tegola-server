#!/usr/bin/env bash
# A development server on this machine in one command, its log in the terminal (README "Run it", D-28).
#   scripts/run.sh            # the real sources, with the keys in .env.local
#   scripts/run.sh --mock     # mock mode: mocks/catalogue.json and made-up releases; no keys, no network
#   scripts/run.sh --quiet    # requests and warnings only, without each lookup's debug lines
# The first run writes .env.local (git-ignored): a debug token for the app, the app id, and the source keys to fill
# in. The log also goes to build/server.log. Ctrl-C stops the server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MOCK=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --mock) MOCK=1 ;;
    --quiet) QUIET=1 ;;
    -h | --help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg (scripts/run.sh --help)" >&2
      exit 64
      ;;
  esac
done

# On the Mac, Xcode's toolchain (CLAUDE.md); elsewhere the swift on PATH.
if command -v xcrun >/dev/null 2>&1; then SWIFT=(xcrun swift); else SWIFT=(swift); fi

SOURCE_VARS=(TEGOLA_MUSICBRAINZ_CONTACT TEGOLA_IGDB_CLIENT_ID TEGOLA_IGDB_CLIENT_SECRET TEGOLA_SCREENSCRAPER_DEV_ID
  TEGOLA_SCREENSCRAPER_DEV_PASSWORD TEGOLA_SCREENSCRAPER_USER TEGOLA_SCREENSCRAPER_PASSWORD TEGOLA_BGG_TOKEN
  TEGOLA_WIKIDATA_CONTACT)

ENV_FILE="$ROOT/.env.local"
if [[ ! -f "$ENV_FILE" ]]; then
  (umask 077 && : >"$ENV_FILE")
  cat >"$ENV_FILE" <<EOF
# Development settings for scripts/run.sh. Git-ignored: never commit this file.

# The app's development build sends this as X-Tegola-Debug-Token (a simulator has no App Attest).
TEGOLA_DEBUG_TOKEN=$(openssl rand -hex 24)
# <Team ID>.<bundle id>, which a real device's App Attest key is checked against: put the real Team ID here to test
# on a device.
TEGOLA_APP_ID=ABCDE12345.fr.macko.tegola
# TEGOLA_PORT=8080
# TEGOLA_HOST=0.0.0.0   # to reach it from a device on the same network (default 127.0.0.1)
# TEGOLA_DATABASE_URL=  # unset: keys and challenges in memory, forgotten at each restart
# TEGOLA_MOCKS=         # another mock catalogue for --mock (default mocks/catalogue.json)

# Lookup sources, ignored with --mock. deploy/env.example says where each key comes from.
TEGOLA_MUSICBRAINZ_CONTACT=
TEGOLA_IGDB_CLIENT_ID=
TEGOLA_IGDB_CLIENT_SECRET=
TEGOLA_SCREENSCRAPER_DEV_ID=
TEGOLA_SCREENSCRAPER_DEV_PASSWORD=
TEGOLA_SCREENSCRAPER_USER=
TEGOLA_SCREENSCRAPER_PASSWORD=
TEGOLA_BGG_TOKEN=
TEGOLA_WIKIDATA_CONTACT=
EOF
  echo "Wrote .env.local: a new debug token, and empty source keys to fill in."
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Always a development server: production refuses the debug token and the mocks, and needs a database.
export TEGOLA_ENVIRONMENT=development
if [[ $QUIET == 1 ]]; then export LOG_LEVEL=info; else export LOG_LEVEL="${LOG_LEVEL:-debug}"; fi
if [[ $MOCK == 1 ]]; then
  export TEGOLA_MOCKS="${TEGOLA_MOCKS:-$ROOT/mocks/catalogue.json}"
  for name in "${SOURCE_VARS[@]}"; do unset "$name"; done
  SOURCES="mock: $TEGOLA_MOCKS"
else
  unset TEGOLA_MOCKS
  on=()
  for name in "${SOURCE_VARS[@]}"; do
    if [[ -n "${!name:-}" ]]; then on+=("$name"); fi
  done
  if [[ ${#on[@]} -eq 0 ]]; then
    SOURCES="none (lookups answer \"no match\": fill in .env.local, or run with --mock)"
  else
    SOURCES="from .env.local"
  fi
fi

HOST="${TEGOLA_HOST:-127.0.0.1}"
PORT="${TEGOLA_PORT:-8080}"
if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is in use (another server?). Stop it, or set TEGOLA_PORT in .env.local." >&2
  exit 1
fi

echo "Building…"
"${SWIFT[@]}" build --product tegola-server
BIN="$("${SWIFT[@]}" build --show-bin-path)/tegola-server"

URL="http://$([[ $HOST == 0.0.0.0 ]] && echo 127.0.0.1 || echo "$HOST"):$PORT/v1"
# What the app's Debug build reads from its Xcode scheme (tegola D-73). On all interfaces, a device on the same
# network reaches this Mac by its address.
APP_URL="$URL"
if [[ $HOST == 0.0.0.0 ]]; then
  LAN=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$LAN" ]]; then APP_URL="http://$LAN:$PORT/v1"; fi
fi
TOKEN_HEADER="X-Tegola-Debug-Token: ${TEGOLA_DEBUG_TOKEN:-}"
mkdir -p build
LOG="$ROOT/build/server.log"
cat <<EOF

tegola-server, development, on $URL
  sources   $SOURCES
  health    curl -s $URL/health
  barcode   curl -s -H "$TOKEN_HEADER" $URL/types/music/barcodes/724385522925
  words     curl -s -H "$TOKEN_HEADER" -H 'Content-Type: application/json' \\
              -d '{"title":"ok computer"}' $URL/types/music/identify
EOF
if [[ $MOCK == 1 ]]; then
  cat <<EOF
  mocks     barcode 0000000000000 or the title "unavailable": 503; 1111111111111 or "nothing": no match;
            2222222222222 or "slow": 4 s. Anything else is made up (mocks/README.md).
EOF
fi
cat <<EOF
  app       Xcode › Edit Scheme › Run › Environment Variables:
              TEGOLA_LOOKUP_URL=$APP_URL
              TEGOLA_DEBUG_TOKEN=${TEGOLA_DEBUG_TOKEN:-}
  log       below, and in build/server.log (LOG_LEVEL=$LOG_LEVEL)
  stop      Ctrl-C

EOF

echo "--- $(date '+%Y-%m-%d %H:%M:%S') scripts/run.sh $* ---" >>"$LOG"
# Colours by level on a terminal. The pipe's readers ignore Ctrl-C, so the server's last lines still get through.
if [[ -t 1 ]]; then
  "$BIN" 2>&1 | (
    trap '' INT
    tee -a "$LOG" | awk '
      BEGIN { dim = "\033[2m"; yellow = "\033[33m"; red = "\033[31m"; cyan = "\033[36m"; reset = "\033[0m" }
      {
        colour = ""
        if ($2 == "trace" || $2 == "debug") colour = dim
        else if ($2 == "notice") colour = cyan
        else if ($2 == "warning") colour = yellow
        else if ($2 == "error" || $2 == "critical") colour = red
        print colour $0 (colour == "" ? "" : reset)
        fflush()
      }'
  )
else
  "$BIN" 2>&1 | (
    trap '' INT
    tee -a "$LOG"
  )
fi
