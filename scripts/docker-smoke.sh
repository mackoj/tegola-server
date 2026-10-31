#!/usr/bin/env bash
# Builds the image and checks it the way production runs it (docs/DEPLOY.md). Needs Docker with Compose v2.
#   scripts/docker-smoke.sh            # image checks, then the Caddy + server stack on https://localhost
#   scripts/docker-smoke.sh image      # image checks only
# Behind a TLS-intercepting proxy, set DOCKER_PROXY_CA=/path/to/ca.pem (passed as a build secret, never kept).
# Writes build/docker-smoke.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
SUMMARY=build/docker-smoke.md
IMAGE=tegola-server:local
APP_ID=ABCDE12345.fr.macko.tegola
STATUS=0
echo "# Docker smoke ($(date '+%Y-%m-%d %H:%M'))" > "$SUMMARY"
check() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then echo "- ✅ $1" >> "$SUMMARY"
  else echo "- ❌ $1: expected $2, got $3" >> "$SUMMARY"; STATUS=1; fi
}

BUILD_ARGS=(--network host -t "$IMAGE")
for var in HTTPS_PROXY HTTP_PROXY NO_PROXY; do
  [[ -n "${!var:-}" ]] && BUILD_ARGS+=(--build-arg "$var=${!var}")
done
[[ -n "${DOCKER_PROXY_CA:-}" ]] && BUILD_ARGS+=(--secret "id=proxy_ca,src=$DOCKER_PROXY_CA")
if ! docker build -q "${BUILD_ARGS[@]}" . > build/docker-build.log 2>&1; then
  echo "- ❌ build, see build/docker-build.log" >> "$SUMMARY"; cat "$SUMMARY"; exit 1
fi
echo "- ✅ build ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{ printf "%d MB", $1 / 1000000 }'))" >> "$SUMMARY"

# --- The image on its own -------------------------------------------------------------------------------------------
check "runs as uid 10001" "10001:10001" "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
check "no proxy CA left in the image" "absent" \
  "$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -e /run/secrets/proxy_ca && echo present || echo absent')"
docker run --rm "$IMAGE" > /dev/null 2>&1
check "refuses to start without TEGOLA_APP_ID (exit 78)" "78" "$?"
docker run --rm -e TEGOLA_APP_ID=$APP_ID -e TEGOLA_DEBUG_TOKEN=0123456789abcdef0123456789abcdef "$IMAGE" \
  > /dev/null 2>&1
check "refuses a debug token in production (exit 78)" "78" "$?"

cid=$(docker run -d --read-only --cap-drop ALL --security-opt no-new-privileges -p 127.0.0.1:18080:8080 \
  -e TEGOLA_APP_ID=$APP_ID "$IMAGE")
code() { curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "$@"; }
for _ in $(seq 1 30); do [[ "$(code http://127.0.0.1:18080/v1/health)" == 200 ]] && break; sleep 1; done
check "read-only, no capabilities: /v1/health 200" "200" "$(code http://127.0.0.1:18080/v1/health)"
check "unsigned lookup 401" "401" "$(code http://127.0.0.1:18080/v1/types/music/barcodes/0602547817327)"
check "debug token 403 in production" "403" "$(code -H 'X-Tegola-Debug-Token: x' http://127.0.0.1:18080/v1/health)"
docker rm -f "$cid" > /dev/null

# --- The stack: Caddy (TLS) in front --------------------------------------------------------------------------------
if [[ "${1:-}" != "image" ]]; then
  env_file=$(mktemp)
  sed -e "s/^TEGOLA_APP_ID=.*/TEGOLA_APP_ID=$APP_ID/" -e 's/^TEGOLA_DOMAIN=.*/TEGOLA_DOMAIN=localhost/' \
    deploy/env.example > "$env_file"
  compose() { TEGOLA_ENV_FILE="$env_file" docker compose --env-file "$env_file" -p tegola-smoke "$@"; }
  if compose up -d > build/docker-compose.log 2>&1; then
    https() { curl -sk --noproxy '*' --resolve localhost:443:127.0.0.1 "$@"; }
    for _ in $(seq 1 60); do
      [[ "$(https -o /dev/null -w '%{http_code}' https://localhost/v1/health)" == 200 ]] && break; sleep 1
    done
    check "stack: https://localhost/v1/health 200" "200" \
      "$(https -o /dev/null -w '%{http_code}' https://localhost/v1/health)"
    check "stack: HSTS from the server" "1" \
      "$(https -D - -o /dev/null https://localhost/v1/health | grep -ci '^strict-transport-security:')"
    check "stack: no Server header" "0" "$(https -D - -o /dev/null https://localhost/v1/health | grep -ci '^server:')"
    check "stack: unsigned lookup 401" "401" \
      "$(https -o /dev/null -w '%{http_code}' https://localhost/v1/types/music/barcodes/0602547817327)"
    check "stack: nothing outside /v1" "404" "$(https -o /dev/null -w '%{http_code}' https://localhost/admin)"
    check "stack: HTTP redirects to HTTPS" "308" \
      "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1/v1/health -H 'Host: localhost')"
    # `compose port` prints ":0" for a port that isn't published.
    published=$(compose port tegola-server 8080 2>/dev/null)
    check "stack: server port not published" "" "${published#:0}"
  else
    echo "- ❌ stack: compose up failed, see build/docker-compose.log" >> "$SUMMARY"; STATUS=1
  fi
  compose logs > build/docker-stack.log 2>&1
  compose down -v > /dev/null 2>&1
  rm -f "$env_file"
fi

cat "$SUMMARY"
exit $STATUS
