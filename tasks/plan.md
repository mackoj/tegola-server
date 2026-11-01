# Implementation plan

Source of truth: `docs/PLAN.md` (spec) and `docs/DECISIONS.md`. This file breaks each milestone into tasks. A task is
one commit (or one PR) on the milestone's branch. A milestone ends with a report in `docs/milestones/M<n>.md` and a
merge into `main`.

Each task lists what must be true when it's done (**Acceptance**) and how that is checked (**Verify**). Everything
verifies on Linux: `scripts/ci.sh`, locally, in CI, or in a cloud session through `scripts/cloud-toolchain.sh`.

## Dependency graph

```
M1 foundation ──► M2 persistence ──► M3 first sources ──► M4 production (with tegola's M6)
                                                    └──► M5 providers (D-27)
```

## M1 · foundation (PLAN §8)

| Task | Acceptance | Verify |
|---|---|---|
| T1.1 Skeleton | `Package.swift` (tools 6.2, three upcoming features), `.swift-format` and `.gitignore` from tegola, the contract copied to `api/` and linked into the target | `swift build` |
| T1.2 App Attest | `AppAttest`: strict CBOR reader, authenticator data, attestation and assertion verification, request-signature bytes, Apple's root pinned; a fake CA and device for tests | `AppAttestTests` |
| T1.3 Server | Generated types and server; `LookupAPI` for the seven operations; `Validation`; `NoSourcesLookupService` | `ContractTests` |
| T1.4 Security controls | `ServerConfiguration` (fail closed), `EdgeMiddleware`, `AppAttestMiddleware`, `CachePolicyMiddleware`, `RateLimiter`, `ChallengeStore`, `InMemoryAttestKeyStore`, problem documents | `SecurityTests`, `ConfigurationTests`; the binary refuses a bad config and serves `/v1/health` |
| T1.5 Contract wording | The signed bytes (D-6) and the challenge's bytes (D-5) written into the contract, in tegola first | `scripts/lint-api.sh` in both repos; `scripts/sync-contract.sh --check` |
| T1.6 Tooling | `scripts/` (`test.sh`, `ci.sh`, `sync-contract.sh`, `lint-api.sh`, `secret-scan.sh`, `cloud-toolchain.sh`), `.github/workflows/ci.yml`, `Dockerfile` | `scripts/ci.sh` green |
| T1.7 Docs | `CLAUDE.md`, `README.md`, `docs/PLAN.md`, `docs/DECISIONS.md`, `tasks/`, `docs/milestones/M1.md` | Read-through |
| T1.8 tegola knows | tegola's `CLAUDE.md`, `docs/DECISIONS.md` and `tasks/HANDOFF.md` say tegola-server is the owner's and can be worked on from tegola | tegola PR |

## M2 · persistence

Postgres, the owner's choice (D-17). Done.

| Task | Acceptance | Verify |
|---|---|---|
| T2.1 Store protocols | `AttestKeyStore` and `ChallengeStore` throw; the in-memory stores conform; a failing store is 503, never 401 or a pass; `/health` says `degraded` | `StoreFailureTests` |
| T2.2 `PostgresStore` | Keys and challenges in Postgres, parameterised statements, the conditional counter `UPDATE`, versioned migrations under an advisory lock | `StoreTests` on both stores, with `TEGOLA_TEST_DATABASE_URL` |
| T2.3 Configuration | `TEGOLA_DATABASE_URL` parsed (sslmode `verify-full` by default), required in production, never printed | `ConfigurationTests` |
| T2.4 Wiring | The client runs as a service; migrations before the port opens, 60 s limit | the binary in `scripts/docker-smoke.sh` |
| T2.5 Stack and CI | Postgres in Compose on an internal network; a Postgres service for CI's tests; smoke checks for migration, isolation, restart, no password in logs | `scripts/docker-smoke.sh`, CI |
| T2.6 Fix found on the way | 503s for undeclared statuses keep their `Retry-After` and body (D-18) | `ContractTests`, `StoreFailureTests` |
| T2.7 Docs | D-17, D-18; PLAN, DEPLOY, README, HANDOFF; `docs/milestones/M2.md` | Read-through |

Left as options: the App Attest receipt check (D-5); shared rate limits for several instances (D-9).

## M3 · first sources

The owner's choice (2026-11-01, D-22): MusicBrainz, IGDB + ScreenScraper, BoardGameGeek, nothing for `thing`.

| Task | What | Proof |
|---|---|---|
| T3.1 Infrastructure | `HTTPTransport` (AsyncHTTPClient; replayable), per-source pace, circuit breaker, timeouts, body cap, answer cache, the per-type composite behind `LookupService` | `SourceConnectionTests`, `SourcesLookupServiceTests` |
| T3.2 MusicBrainz | Barcode and words for `music`; Lucene escaping; release-group works | `MusicBrainzTests` |
| T3.3 IGDB | Words for `video-game`, Twitch token, one candidate per platform and region | `IGDBTests` |
| T3.4 ScreenScraper | Words for `video-game`, regional titles, no media URLs | `ScreenScraperTests` |
| T3.5 BoardGameGeek | Words for `board-games`, XML without external entities | `BoardGameGeekTests` |
| T3.6 Configuration | One opt-in per source, pairs or nothing, values never logged | `SourceSettingsTests` |
| T3.8 OpenAPI per supplier | `api/sources/*.openapi.yaml`, a generated client per supplier, `DataSupplier`, `SupplierTransport` (D-23) | `SupplierTests` through the generated clients |
| T3.7 Docs | D-22; PLAN §4, §9; README, DEPLOY, env.example; `docs/milestones/M3.md` | Read-through |

Left for later: re-recording the fixtures against the live APIs once keys exist; cover art for music (done, D-25); a
cache shared by several instances.

## M4 · production

Prepared in M1 (D-16): the image, the Caddy + server Compose stack, `docs/DEPLOY.md` and its go-live checklist, and
`scripts/docker-smoke.sh` in CI. Left for M4: the owner's answers (PLAN §9) filled in per the checklist, a host and
DNS record, monitoring of the `auth failed` and 429 rates, and an end-to-end run with the app on a device (tegola M6).

## M5 · providers

The owner's "Data Providers" proposal, adopted with changes (D-27, `docs/proposals/data-providers.dc.html`): records
and a router, manifests, caches by licence, metering, a budget guard and a kill switch. Some sources will be paid.
Independent of M4: it runs on the M3 sources and their fixtures.

| Task | Acceptance | Verify |
|---|---|---|
| T5.1 Decision and vocabulary | D-27; "supplier" is "provider" in code | Read-through; `scripts/ci.sh` |
| T5.2 Records and the router | Providers return `ProviderRecord`s; `Ranking` scores them one way; `RecordMerge` makes one candidate per release on certain identity, one to one; same numbers for every provider | `RecordMergeTests`, `RankingTests`, the provider suites |
| T5.3 Manifests | Capabilities in code; tier, coverage per type (subtypes, fields), weights, cost model, pace, deadline, cache policy, attribution, regions in `providers/<id>.yml`, checked at start-up (fail closed); Wikidata one provider with coverage per type; the secondary tier's rule; a deadline per provider whose cut is a failure | `ManifestTests`; a bad file stops the server |
| T5.4 Caches by licence | Per-provider query and record caches in Postgres, lifetime the shorter of ours and the manifest's, `.passThrough` never stored, `.storeIDsOnly` keeps ids; a negative cache (24 h); in memory without a database | `StoreTests` on both stores; `CacheTests` |
| T5.5 Metering, budget, kill switch | A `ProviderTransport` middleware writes one ledger row per outbound call and the router one per cache hit (provider, operation, type, subtype, outcome, cost, latency, payer, request id), buffered; payer `HMAC(key id, monthly salt)` with a random salt destroyed each month; raw rows deleted after 35 days, monthly totals kept; a budget per provider and type that refuses calls over it; a kill switch per provider and type | `LedgerTests`; a logs and table check that no key id is written |
| T5.6 Recognizer | A `Recognizer` protocol (photo → `IdentifyHints`), metered, never cached, keeping no photo (PD-118); plugged into Identify (D-24) | when an image source is chosen |
| T5.7 Docs and report | PLAN §4, README, DEPLOY, HANDOFF; `docs/milestones/M5.md`; a separate review agent | Read-through |

