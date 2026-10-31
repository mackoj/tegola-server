# Handoff

The state of the work for whoever picks it up next: a new session, another agent, or the owner. Read this first, keep
it short and current.

**Updated:** 2026-11-01. M1 and M2 are merged (PRs #1–#4). The review of M1–M2 ran, and its fixes are on
`claude/tegola-hummingbird-bff-9ad714` (D-19), open as tegola-server PR #5. That PR waits for tegola PR #10 (below).

## Resume here (in this order)

1. **tegola PR #10** (`mackoj/tegola`, branch `claude/tegola-hummingbird-bff-9ad714`): the contract says a revoked key
   stays revoked (tegola D-55). The merge conflict with tegola's M3 is resolved and the branch is pushed. Merge it once
   its `linux-core` check is green.
2. **tegola-server PR #5** (this branch): the review fixes (D-19). Its CI drift check compares the contract with
   tegola's `main`, so it goes green only after step 1 (the same thing happened with PR #1). After #10 merges, re-run
   CI (push an empty-tree change, such as a HANDOFF date, or re-run the jobs), then merge once `linux` and `docker`
   are green.
3. **Owner answers**, deferred until release: sources per type, hosting and domain, Team ID, shared caches (PLAN §9;
   persistence is answered: Postgres, D-17). `docs/DEPLOY.md` says where each answer goes.
4. **M3, sources** (once the owner picks them): one per launch type behind `LookupService`, with recorded-response
   tests. `matchBatch` already charges one token per row (D-19).
5. **M4, production**, paced by tegola's M6 (the app's lookup client).

The owner's working style: carry on without asking. Use a worktree per task, branch, commit, push, open the PR, wait
for green CI, merge. Stop only for decisions that are the owner's (PLAN §9). To keep the PR description free of the
footer this session's GitHub tool appends, create the PR with a placeholder body, then set the real body with an
update.

## Where things stand

- **Spec:** `docs/PLAN.md`; decisions D-1 to D-19 in `docs/DECISIONS.md`.
- **M1 (foundation):** the contract's seven operations served by Hummingbird 2 from generated code. App Attest
  registration and assertions are verified end to end, with every control of PLAN §5 and no lookup source yet (D-12).
  Report: `docs/milestones/M1.md`.
- **M2 (persistence):** keys and challenges in Postgres (`PostgresStore`), required in production. The Compose stack
  runs Postgres on an internal-only network. Report: `docs/milestones/M2.md`.
- **Review (D-19):**
  - Two independent agents found nothing critical or high. All findings are fixed except digest pinning and shared
    rate limits.
  - The fixes: registration bucket by operation, IPv6 /64 keys, per-row match cost, atomic challenge cap, Postgres
    <16 lock literal, password decoded once, 406, clean startup exits, `Vary`, image trusts no X-Forwarded-For, drift
    check can't pass empty, Dependabot.
- **Verified on this branch** (Linux, Swift 6.4.2, Postgres 17.11 in Docker):
  - `swift test`: 77 tests in 8 suites (18 + 59).
  - `scripts/docker-smoke.sh`: 25 checks. The image part (13) was re-run after the last change; the stack part (12)
    passed on the run before, and nothing it covers changed since.
- **Not verified:** a real device's attestation (tegola M6); a real domain and certificate; a managed Postgres with
  `verify-full`.
- **tegola** knows about this repo: its `CLAUDE.md` ("Companion repo"), D-41, D-42, D-55 and its HANDOFF.

## Run it locally

```sh
git clone https://github.com/mackoj/tegola-server.git && cd tegola-server
scripts/test.sh            # → build/test-summary.md
scripts/ci.sh              # the full gate → build/ci-summary.md (contract drift needs ../tegola, or TEGOLA_DIR)
TEGOLA_ENVIRONMENT=development TEGOLA_APP_ID=ABCDE12345.fr.macko.tegola \
  TEGOLA_DEBUG_TOKEN="$(openssl rand -hex 24)" swift run tegola-server
```

**If anything fails:** paste `build/ci-summary.md`, and the log it names, into a session.


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
- **Gotchas found in the review:** Hummingbird's router ignores empty path segments, so never choose behaviour by
  path prefix: use the operation id. A `.build` copied from another checkout fails on stale module caches: delete
  `.build/out` and `.build/plugins`, keep `.build/checkouts`. A wrong database password isn't fatal to PostgresNIO,
  which retries; the server exits 1 at the 60 s startup limit, and the refusal (SQLSTATE 28P01) is logged before that.
- **Gotchas found in M2:** the generated server drops an `undocumented` response's headers and body: throw
  `ServiceUnavailable` instead (D-18). In Swift Testing, a closure whose only `try` is inside `#expect` needs an
  explicit `async throws in`.
- **Gotchas found in M1:** the generated server percent-encodes string response headers (set them in a middleware,
  D-14); the runtime reports a body that doesn't decode as 500 (mapped to 400, D-7); swift-asn1 rejects PEM lines
  longer than 64 characters.
