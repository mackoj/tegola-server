# Implementation plan

Source of truth: `docs/PLAN.md` (spec) and `docs/DECISIONS.md`. This file breaks each milestone into tasks. A task is
one commit (or one PR) on the milestone's branch. A milestone ends with a report in `docs/milestones/M<n>.md` and a
merge into `main`.

Each task lists what must be true when it's done (**Acceptance**) and how that is checked (**Verify**). Everything
verifies on Linux: `scripts/ci.sh`, locally, in CI, or in a cloud session through `scripts/cloud-toolchain.sh`.

## Dependency graph

```
M1 foundation ──► M2 persistence ──► M3 first sources ──► M4 production (with tegola's M6)
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

Broken down at the start of M2. Roughly: choose SQLite or Postgres (PLAN §9, question 3); a database `AttestKeyStore`
with the atomic counter update and a concurrency test; challenges in the same store; migrations; optionally the App
Attest receipt check.

## M3 · first sources

Broken down once the owner picks the sources (PLAN §9, question 1). One source per launch type, recorded-response
tests, caching, timeouts, a circuit breaker, attribution in `Candidate.sources`.

## M4 · production

Host, domain, proxy and secrets (PLAN §9, question 2), monitoring of the `auth failed` and 429 rates, and an end-to-end
run with the app on a device (tegola M6).
