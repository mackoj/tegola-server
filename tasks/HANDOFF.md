# Handoff

The state of the work for whoever picks it up next: a new session, another agent, or the owner. Read this first, keep
it short and current.

**Updated:** 2026-10-31, M2 (Postgres) done on `claude/tegola-hummingbird-bff-9ad714`. M3 waits on the owner's choice of
sources.

## Where things stand

- **Spec:** `docs/PLAN.md`; decisions D-1 to D-18 in `docs/DECISIONS.md`. Open owner questions: PLAN §9,
  deferred until release, except persistence: Postgres (D-17).
- **M2 (persistence):** keys and challenges in Postgres (`PostgresStore`), required in production; the Compose stack
  runs Postgres on an internal-only network. Report: `docs/milestones/M2.md`.
- **M1 (foundation):** the contract's seven operations served by Hummingbird 2 from generated code; App Attest
  registration and assertions verified end to end; every control of PLAN §5; no lookup source yet (D-12).
  Report: `docs/milestones/M1.md`.
- **Verified:** on Linux (Swift 6.4.2), `scripts/ci.sh`: 48 tests in 5 suites, format lint, contract lint (Redocly),
  contract drift, secret scan. The binary was run: it refuses a bad config (exit 78), serves `/v1/health` with the
  security headers, answers 401 to an unsigned lookup and 403 to a debug token in production.
- **Docker:** the image, a Caddy + server Compose stack and the go-live runbook (`docs/DEPLOY.md`, D-16).
  `scripts/docker-smoke.sh` is green: 15 checks on the image and on the stack over HTTPS. CI runs it on every push.
- **Not verified:** a real device's attestation (needs the app's M6); a real domain and certificate.
- **tegola** knows about this repo: its `CLAUDE.md` ("Companion repo"), D-41 and its HANDOFF.

## Run it locally

```sh
git clone https://github.com/mackoj/tegola-server.git && cd tegola-server
scripts/test.sh            # → build/test-summary.md
scripts/ci.sh              # the full gate → build/ci-summary.md (contract drift needs ../tegola, or TEGOLA_DIR)
TEGOLA_ENVIRONMENT=development TEGOLA_APP_ID=ABCDE12345.fr.macko.tegola \
  TEGOLA_DEBUG_TOKEN="$(openssl rand -hex 24)" swift run tegola-server
```

**If anything fails:** paste `build/ci-summary.md`, and the log it names, into a session.

## What's next

1. **Owner answers** to PLAN §9, deferred until release: sources per type, hosting and domain, the Team ID, shared
   caches. `docs/DEPLOY.md` says where each one goes; nothing else waits on them.
2. **A separate review** of M1 and M2 (the workflow's rule; not run yet).
3. **M3, sources:** one per launch type behind `LookupService`, with recorded-response tests, once the owner picks them.
4. **M4, production**, paced by tegola's M6 (the app's lookup client).

## How the work is run

- **Branch:** one milestone branch from `main`, one commit per task, one PR per milestone into `main`.
- **Postgres for the tests in a cloud session:** with Docker started, `docker run -d --name tegola-test-pg -p
  127.0.0.1:55432:5432 -e POSTGRES_USER=tegola -e POSTGRES_PASSWORD=tegola-test -e POSTGRES_DB=tegola_test
  postgres:17-alpine` (pulled from `mirror.gcr.io/library/postgres:17-alpine` and tagged), then
  `TEGOLA_TEST_DATABASE_URL='postgres://tegola:tegola-test@127.0.0.1:55432/tegola_test?sslmode=disable'
  scripts/cloud-toolchain.sh run scripts/ci.sh` (the script passes the variable into the chroot).
- **Docker in a cloud session:** `dockerd` is installed but not started (start it in the background). Docker Hub
  rate-limits the shared address: pull from `mirror.gcr.io/library/<image>` and tag (`swift` needs its amd64 digest,
  the multi-arch tag fails on an attestation manifest). Then `DOCKER_PROXY_CA=/root/.ccr/ca-bundle.crt
  scripts/docker-smoke.sh`.
- **Toolchain in a cloud session:** there's no Swift by default, download.swift.org is blocked and Docker Hub
  rate-limits the shared address. `scripts/cloud-toolchain.sh install` unpacks `swift:6.4.2-noble` from Google's
  Docker Hub mirror (`mirror.gcr.io`) into `/opt/swiftroot`; `scripts/cloud-toolchain.sh run scripts/ci.sh` runs a
  command there with the repo (and `../tegola`, if present) bind-mounted and the proxy passed through.
- **The contract:** change it in tegola (`scripts/lint-api.sh` there), then `scripts/sync-contract.sh` here and build;
  the compiler lists what to implement. Never edit `api/` here alone.
- **Generated code** is in `.build/plugins/outputs/…/OpenAPIGenerator/GeneratedSources/` after a build: read
  `Types+Operations.swift` for the shapes a handler returns.
- **Gotchas found in M2:** the generated server drops an `undocumented` response's headers and body: throw
  `ServiceUnavailable` instead (D-18). In Swift Testing, a closure whose only `try` is inside `#expect` needs an
  explicit `async throws in`.
- **Gotchas found in M1:** the generated server percent-encodes string response headers (set them in a middleware,
  D-14); the runtime reports a body that doesn't decode as 500 (mapped to 400, D-7); swift-asn1 rejects PEM lines
  longer than 64 characters.
