# Deploying tegola-server

Everything needed to run the server in production is in the repo and tested (`scripts/docker-smoke.sh`, CI's `docker`
job). What's missing are the owner's answers in `docs/PLAN.md` §9, which are deferred until release. Each one is a
value in `.env` or a small, named change, listed under "Go-live checklist" below.

## What runs

```
Internet ──443/80──► caddy (TLS, HTTP→HTTPS, /v1/* only) ──private network──► tegola-server :8080 (not published)
                                                                                    │ db network (internal, no route out)
                                                                                    ▼
                                                                         postgres :5432 (not published)
```

| Piece | Where | Notes |
|---|---|---|
| `tegola-server` image | `Dockerfile` | Static release binary on `ubuntu:noble`, uid 10001. In compose: read-only root, no capabilities, `no-new-privileges`, 512 MB, 256 processes |
| Caddy | `deploy/Caddyfile` | Let's Encrypt certificate for `TEGOLA_DOMAIN`, TLS 1.2/1.3, 256 KB body cap, health checks on `/v1/health`, no admin API, no access log |
| Postgres 17 | `docker-compose.yml` | Keys and challenges (D-17). Internal-only network, no published port, read-only root, minimal capabilities, `scram-sha-256`, data in the `postgres_data` volume |
| Stack | `docker-compose.yml` | One server, one Caddy, one Postgres. Caddy gets only `TEGOLA_DOMAIN`; the server's secrets stay with the server |
| Settings | `deploy/env.example` → `.env` | `.env` is git-ignored. The server refuses to start on a missing or unsafe value (exit 78) |

## Rehearse locally

```sh
cp deploy/env.example .env          # TEGOLA_DOMAIN=localhost: Caddy uses its own CA
docker compose up -d --build
curl -k https://localhost/v1/health # {"status":"ok","types":[]}
docker compose logs -f tegola-server
docker compose down
```

Or run every check at once: `scripts/docker-smoke.sh` (writes `build/docker-smoke.md`).

## Go-live checklist

| # | Decision (PLAN §9) | Where it goes | Until then |
|---|---|---|---|
| 1 | **Team ID** | `TEGOLA_APP_ID=<TeamID>.fr.macko.tegola` in `.env` | The example value; App Attest registrations fail with any other team |
| 2 | **Hosting and domain** | A Linux host with Docker, ports 80 and 443 open, a DNS A/AAAA record for the domain pointing at it; `TEGOLA_DOMAIN=<domain>` in `.env`. Also update the contract's `servers` placeholder (`https://api.tegola.app`) in tegola first, then `scripts/sync-contract.sh` | `localhost` |
| 3 | **Persistence**: answered, Postgres (D-17) | `TEGOLA_DB_PASSWORD` in `.env` (`openssl rand -hex 32`) for the stack's Postgres. For a managed Postgres instead, remove the `postgres` service and set `TEGOLA_DATABASE_URL=postgres://…?sslmode=verify-full` for the server | Nothing: the stack runs Postgres |
| 4 | **Sources** | M3. Each source's keys go in `.env` (see the commented lines in `deploy/env.example`) | Lookups answer "no match"; `/health` lists no types |
| 5 | **Shared cache** | Nothing to do if the answer is "no": the stack has none. If "yes", a CDN goes in front of Caddy, and D-14 is updated | No shared cache |

Before the first production start:

- [ ] `TEGOLA_ENVIRONMENT=production` and `TEGOLA_DEBUG_TOKEN` empty (the server refuses otherwise).
- [ ] App Attest's production entitlement in the app (tegola, M6), so its keys carry the production AAGUID.
- [ ] Compare Apple's root fingerprint with apple.com once (D-4).
- [ ] `scripts/docker-smoke.sh` green on the host, or the latest `docker` CI job green on the commit you deploy.
- [ ] Back up the `postgres_data` volume (the registered keys; losing it makes every install register again) and
      `caddy_data` (the certificate and ACME account). A logical backup:
      `docker compose exec -T postgres pg_dump -U tegola tegola > tegola-$(date +%F).sql`.

## Run it

```sh
git clone https://github.com/mackoj/tegola-server.git && cd tegola-server
cp deploy/env.example .env && $EDITOR .env      # the checklist's values
docker compose up -d --build
docker compose ps                                # both services "running"
curl https://<domain>/v1/health
```

- **Update:** `git pull && docker compose up -d --build`. The server stops gracefully (15 s), migrates the schema
  before serving again, and keeps every key (D-17).
- **Logs:** `docker compose logs tegola-server`. One `request` line per call (method, route template, status, ms), plus `auth failed` / `attestation rejected` with a reason code. Never content, IPs or key ids (D-15). Watch the rate of `auth failed` and of `status=429`.
- **Rollback:** check out the previous commit and `docker compose up -d --build`.
- **Behind a proxy that intercepts TLS** (some CI or sandboxes): `DOCKER_PROXY_CA=/path/ca.pem scripts/docker-smoke.sh`, or `docker build --secret id=proxy_ca,src=/path/ca.pem …`. The CA is used only to fetch packages and never reaches the image.

## Not covered yet

- More than one server instance needs shared rate limits first (D-9). Keys and challenges are already shared.
- No metrics endpoint. Monitoring reads the logs (PLAN §6).
- Image pinning by digest and automatic base-image updates: decide with the host (Dependabot or Renovate can pin and bump `FROM` lines).
