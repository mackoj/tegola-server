# Handoff

The state of the work for whoever picks it up next: a new session, another agent, or the owner. Read this first, keep
it short and current.

**Updated:** 2026-10-31, M1 done on `claude/tegola-hummingbird-bff-9ad714`, PR open into `main`. M2 is next.

## Where things stand

- **Spec:** `docs/PLAN.md`; decisions D-1 to D-15 in `docs/DECISIONS.md`. Open owner questions: PLAN §9.
- **M1 (foundation):** the contract's seven operations served by Hummingbird 2 from generated code; App Attest
  registration and assertions verified end to end; every control of PLAN §5; no lookup source yet (D-12).
  Report: `docs/milestones/M1.md`.
- **Verified:** on Linux (Swift 6.4.2), `scripts/ci.sh`: 48 tests in 5 suites, format lint, contract lint (Redocly),
  contract drift, secret scan. The binary was run: it refuses a bad config (exit 78), serves `/v1/health` with the
  security headers, answers 401 to an unsigned lookup and 403 to a debug token in production.
- **Not verified:** the Docker image (no Docker in the session); a real device's attestation (needs the app's M6).
- **tegola** knows about this repo: its `CLAUDE.md` ("Companion repo"), D-34 and its HANDOFF.

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

1. **Owner answers** to PLAN §9: sources per type, hosting and domain, SQLite or Postgres, the Team ID, shared caches.
2. **M2, persistence:** a database `AttestKeyStore` with the atomic counter update, challenges in the same store, a
   concurrent-replay test. Break it down in `tasks/plan.md` first.
3. **M3, sources:** one per launch type behind `LookupService`, with recorded-response tests.
4. **M4, production**, paced by tegola's M6 (the app's lookup client).

## How the work is run

- **Branch:** one milestone branch from `main`, one commit per task, one PR per milestone into `main`.
- **Toolchain in a cloud session:** there's no Swift by default, download.swift.org is blocked and Docker Hub
  rate-limits the shared address. `scripts/cloud-toolchain.sh install` unpacks `swift:6.4.2-noble` from Google's
  Docker Hub mirror (`mirror.gcr.io`) into `/opt/swiftroot`; `scripts/cloud-toolchain.sh run scripts/ci.sh` runs a
  command there with the repo (and `../tegola`, if present) bind-mounted and the proxy passed through.
- **The contract:** change it in tegola (`scripts/lint-api.sh` there), then `scripts/sync-contract.sh` here and build;
  the compiler lists what to implement. Never edit `api/` here alone.
- **Generated code** is in `.build/plugins/outputs/…/OpenAPIGenerator/GeneratedSources/` after a build: read
  `Types+Operations.swift` for the shapes a handler returns.
- **Gotchas found in M1:** the generated server percent-encodes string response headers (set them in a middleware,
  D-14); the runtime reports a body that doesn't decode as 500 (mapped to 400, D-7); swift-asn1 rejects PEM lines
  longer than 64 characters.
