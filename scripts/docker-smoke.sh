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
docker run --rm -e TEGOLA_APP_ID=$APP_ID "$IMAGE" > /dev/null 2>&1
check "refuses production without TEGOLA_DATABASE_URL (exit 78)" "78" "$?"

# Production needs a database: a throwaway Postgres on a private network, the image Compose pins (D-20).
PG_IMAGE=$(awk '$1 == "image:" && $2 ~ /^postgres:/ {print $2; exit}' docker-compose.yml)
net=tegola-smoke-$$
docker network create "$net" > /dev/null
db=$(docker run -d --network "$net" --network-alias postgres -e POSTGRES_USER=tegola -e POSTGRES_DB=tegola \
  -e POSTGRES_PASSWORD=smoke "$PG_IMAGE")
for _ in $(seq 1 30); do docker exec "$db" pg_isready -U tegola -q 2> /dev/null && break; sleep 1; done
cid=$(docker run -d --network "$net" --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:18080:8080 -e TEGOLA_APP_ID=$APP_ID \
  -e "TEGOLA_DATABASE_URL=postgres://tegola:smoke@postgres:5432/tegola?sslmode=disable" "$IMAGE")
code() { curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "$@"; }
for _ in $(seq 1 30); do [[ "$(code http://127.0.0.1:18080/v1/health)" == 200 ]] && break; sleep 1; done
check "read-only, no capabilities: /v1/health 200" "200" "$(code http://127.0.0.1:18080/v1/health)"
check "unsigned lookup 401" "401" "$(code http://127.0.0.1:18080/v1/types/music/barcodes/0602547817327)"
check "debug token 403 in production" "403" "$(code -H 'X-Tegola-Debug-Token: x' http://127.0.0.1:18080/v1/health)"
check "migrated the database before serving" "1" \
  "$(docker exec "$db" psql -U tegola -d tegola -tAc 'SELECT max(version) FROM tegola_schema_migrations')"
check "the log never holds the database password" "0" "$(docker logs "$cid" 2>&1 | grep -c 'smoke@')"
docker rm -f "$cid" > /dev/null
# A database that refuses the password stops the server with exit 1 after the 60 s startup limit, not a crash. The
# reason is in the log (PostgresNIO logs each refused connection with its SQLSTATE), never the password (D-19).
log=$(docker run --rm --network "$net" -e TEGOLA_APP_ID=$APP_ID \
  -e "TEGOLA_DATABASE_URL=postgres://tegola:wrong-password@postgres:5432/tegola?sslmode=disable" "$IMAGE" 2>&1)
check "a wrong database password stops it (exit 1)" "1" "$?"
check "with the reason in the log, never the password" "yes yes 0" \
  "$(grep -q 'stopped:' <<< "$log" && echo yes) $(grep -q 'password authentication failed' <<< "$log" && echo yes) \
$(grep -c 'wrong-password' <<< "$log")"
docker rm -f "$db" > /dev/null
docker network rm "$net" > /dev/null

# --- The stack: Caddy (TLS) in front --------------------------------------------------------------------------------
if [[ "${1:-}" != "image" ]]; then
  env_file=$(mktemp)
  sed -e "s/^TEGOLA_APP_ID=.*/TEGOLA_APP_ID=$APP_ID/" -e 's/^TEGOLA_DOMAIN=.*/TEGOLA_DOMAIN=localhost/' \
    -e "s/^TEGOLA_DB_PASSWORD=.*/TEGOLA_DB_PASSWORD=$(openssl rand -hex 32)/" deploy/env.example > "$env_file"
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
    published=$(compose port postgres 5432 2>/dev/null)
    check "stack: Postgres port not published" "" "${published#:0}"
    check "stack: schema migrated" "1" \
      "$(compose exec -T postgres sh -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -h 127.0.0.1 -U tegola -d tegola -tAc \
        "SELECT max(version) FROM tegola_schema_migrations"' 2>/dev/null)"
    # Caddy faces the internet; the database is on a network it isn't part of. The control proves `nc` works there.
    check "stack: Caddy reaches the server (control)" "reachable" \
      "$(compose exec -T caddy sh -c 'nc -z -w 3 tegola-server 8080 && echo reachable || echo unreachable' 2>/dev/null)"
    check "stack: Postgres unreachable from Caddy" "unreachable" \
      "$(compose exec -T caddy sh -c 'nc -z -w 3 postgres 5432 && echo reachable || echo unreachable' 2>/dev/null)"
    # A restarted server comes back on the existing schema (its migration is a no-op the second time).
    compose restart tegola-server > /dev/null 2>&1
    for _ in $(seq 1 60); do
      [[ "$(https -o /dev/null -w '%{http_code}' https://localhost/v1/health)" == 200 ]] && break; sleep 1
    done
    check "stack: healthy again after a server restart" "200" \
      "$(https -o /dev/null -w '%{http_code}' https://localhost/v1/health)"
  else
    echo "- ❌ stack: compose up failed, see build/docker-compose.log" >> "$SUMMARY"; STATUS=1
  fi
  compose logs > build/docker-stack.log 2>&1
  compose down -v > /dev/null 2>&1
  rm -f "$env_file"
fi

cat "$SUMMARY"
exit $STATUS
