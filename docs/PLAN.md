# tegola-server: plan and specification

**Status:** milestone 1 (foundation) done on 2026-10-31 (`docs/milestones/M1.md`). The owner's request:

> Start a Swift server using Hummingbird that implements `api/tegola-lookup.openapi.yaml`. The goal is that this
> server will be the BFF for the app mackoj/tegola. Add in tegola, like in mackoj/telaio, information for the LLM to
> know that it can work on this webservice if needed when working on tegola. Keep in mind to make it secure by
> design. Like tegola and telaio, feel free to create PRs, branches, commits and pushes, keep the same folder
> organisation, the handoff file technique, etc.

**What I read for this plan:** tegola at `3f87b4a` (`CLAUDE.md`, `README.md`, `docs/PLAN.md` §2.7, §6, §7, §10 Q3/Q9,
`docs/DECISIONS.md` D-25, D-33, `tasks/`, `scripts/`, `.github/`, the contract and `TegolaLookupAPI`); telaio at
`1816aee` (`CLAUDE.md`, `docs/DECISIONS.md` D-122 and D-123 for how a companion repo of the owner's is recorded);
Apple's "Validating apps that connect to your server" (App Attest); the Hummingbird 2, swift-openapi-hummingbird and
swift-openapi-runtime sources at the resolved versions.

---

## 1. Scope

**In.** The seven operations of the contract, App Attest registration and verification, the security controls of §5,
the lookup sources behind them (§4), and what it takes to run one instance in production (§6).

**Out, by tegola's decisions.** Accounts, sync, subscriptions, a cover-art CDN (tegola D-25, Q3/Q9); photos or anything
about the rest of a shelf (tegola PLAN §2.7). The server never decides for the collector: it proposes candidates with
`reasons` and `confidence`, and the app writes nothing until the collector agrees.

**Out, for now.** A Discogs account import (OAuth) arrives as a contract change from tegola when that importer is
planned (tegola PLAN §8, "Later").

## 2. Architecture

```
iPhone (TegolaLookupAPI client, App Attest) ──HTTPS──► reverse proxy (TLS, HSTS) ──► tegola-server (loopback)
                                                                                       │
             EdgeMiddleware (Hummingbird): debug-token refusal, Content-Length cap,    │
             per-IP rate limit, errors → problems, security headers, access log        │
                 └─► generated routes (swift-openapi-hummingbird)                       │
                       AppAttestMiddleware: body cap, assertion, counter, per-key limit │
                       CachePolicyMiddleware                                            │
                         └─► LookupAPI (handlers): Validation → LookupService ─────────►│ game / music / board-game
                                                                                          databases (keys held here)
```

- **One package**, Swift 6.4, tools 6.2, the same upcoming features as tegola's packages.
- **`AppAttest`** (pure): a strict CBOR reader, attestation and assertion verification, the request-signature bytes,
  Apple's root pinned in source. No I/O, testable with a fake CA.
- **`TegolaServer`**: the code generated from the contract (`generate: [types, server]`, `accessModifier: package`),
  handlers (`LookupAPI`), middlewares, `ServerConfiguration`, in-memory stores (`InMemoryAttestKeyStore`,
  `ChallengeStore`, `RateLimiter`), the `LookupService` protocol.
- **`tegola-server`**: `main.swift` loads the configuration, refuses to start on a bad one, and runs.
- **Stores** sit behind protocols so milestone 2 swaps memory for a database without touching handlers.

## 3. The contract

`api/tegola-lookup.openapi.yaml` is tegola's file (D-1). This repo keeps a byte-identical copy that the generator
reads through `Sources/TegolaServer/openapi.yaml`. Changing the contract is how either side asks for a change: edit it
in tegola (with `scripts/lint-api.sh` there), then `scripts/sync-contract.sh` here, build, and implement what the
compiler asks for. `scripts/ci.sh` fails while the two differ.

What the generator enforces: types, required fields, enums, unknown keys under `additionalProperties: false`. What it
doesn't, and `Validation` does: `pattern`, `maxLength`, `minimum`/`maximum`, `maxItems`, and SearchRequest's
"at least one of" (D-11).

## 4. Sources (milestones 3+)

Which databases answer for which type is the server's business (tegola PLAN §7); the app only sees candidates and
their `sources`, and shows any attribution a source requires. Page 49 suggests IGDB, ScreenScraper and Wikidata for
games. Candidates to evaluate per v1 type (tegola D-23: music, video games, board games, thing):

| Type | Candidates to evaluate | Notes |
|---|---|---|
| `video-game` | IGDB, ScreenScraper, Wikidata | IGDB needs a Twitch client id/secret and requires attribution |
| `music` | MusicBrainz, Discogs | MusicBrainz asks for a meaningful User-Agent and 1 request/second |
| `board-games` | BoardGameGeek XML API | Rate-limited; attribution expected |
| `thing` | none (or Wikidata) | Barcode-only generic lookups are of little value |

Each source: one type conforming to `LookupService` (or a composite per type), keys from the environment only, a
timeout and a circuit breaker, its own outbound rate limit within the provider's terms, server-side caching of
answers (a barcode's answer is the same for everyone), `SourceUnavailable` → 503 with `Retry-After`. Choosing them is
an owner question (§9).

## 5. Security (secure by design)

**Assets.** The source API keys and quotas (the main thing worth stealing: an open proxy to paid APIs); the
availability of lookups; the collector's privacy (what they own, through what they look up).

**Adversaries.** Scripts and scrapers using the server as a free proxy; someone replaying or forging app traffic;
volumetric abuse; a curious operator reading logs.

| Threat | Control | Where |
|---|---|---|
| Calls from anything but the genuine app | App Attest attestation (chain to Apple's pinned root, nonce, app id, environment, key id) and an assertion on every secured call | `AppAttestVerifier`, `AppAttestMiddleware` |
| Replay of a captured request | Counter strictly increasing, updated atomically; timestamp within 5 min; the assertion covers method, path and query, timestamp and body | `RequestSignature`, `AttestKeyStore.advanceCounter` |
| A new operation shipped unprotected | Secured unless listed in `publicOperations` | `AppAttestMiddleware` |
| Debug access reaching production | Config refuses `TEGOLA_DEBUG_TOKEN` in production; any request carrying the header gets 403 before routing | `ServerConfiguration`, `EdgeMiddleware` |
| Unsafe deployment by omission | Production is the default; loopback is the default; `TEGOLA_APP_ID` is required; start fails on any bad value | `ServerConfiguration.load` |
| Brute force on the debug token | ≥ 32 characters, constant-time comparison, rate limits | `ServerConfiguration`, `AppAttestMiddleware` |
| Challenge reuse or flooding | Single use, consumed before verification, 5-minute life, bounded store | `ChallengeStore` |
| Counter rewind by re-registering a key | Re-registration keeps the stored counter; revoked keys stay revoked | `InMemoryAttestKeyStore.register` |
| Oversized or hostile bodies | `Content-Length` rejected at the edge, body read with a cap (413), strict CBOR with bounded lengths and depth, unknown JSON keys refused, every limit validated | `EdgeMiddleware`, `AppAttestMiddleware`, `CBORReader`, `Validation` |
| Volumetric abuse, quota draining | Token buckets per IP, per key, and a stricter one for registration; bounded tables; idle timeout | `RateLimiter`, `EdgeMiddleware` |
| Spoofed client address | `X-Forwarded-For` ignored unless `TEGOLA_TRUSTED_PROXY_HOPS`; then only the trusted hop counts | `EdgeMiddleware.clientAddress` |
| Information leaks in errors | Problem documents with fixed titles; decoder errors become a bare 400; unexpected errors a bare 500 | `ProblemKind`, `EdgeMiddleware.problem` |
| Privacy leaks in logs | Route template, status, duration, reason codes only | `EdgeMiddleware`, handlers |
| Browser-based misuse | `default-src 'none'` CSP, `nosniff`, `DENY` framing, `same-origin` CORP, no CORS headers | `EdgeMiddleware.addSecurityHeaders` |
| Downgrade to HTTP | HSTS on every response; TLS at the proxy; loopback bind | `EdgeMiddleware`, §6 |
| Secrets in the repo | Environment only; `.env` ignored; secret scan in CI | `scripts/secret-scan.sh` |
| A tampered trust anchor | Apple's root pinned in source, its SHA-256 fingerprint checked by a test | `AppleRootCA`, `appleRootIsPinned` |

**Accepted for milestone 1** (D-8, D-9): keys and buckets live in memory, so a restart makes every install register
again (the contract's `unknown-key` path) and limits apply per instance. App Attest's fraud-metric receipts aren't
checked yet (D-5).

## 6. Operations

- **One instance** behind a TLS-terminating reverse proxy (Caddy: automatic certificates, HTTP→HTTPS, HSTS), on a
  host or container platform. `Dockerfile` builds a static binary into a slim image running as uid 10001.
- **Configuration** in the environment (README table). Source keys arrive the same way in milestone 3, from the
  platform's secret store.
- **Logs** to stdout as `key=value` lines: one per request, plus `auth failed` and `attestation rejected` with a
  reason code, for monitoring abuse without content.
- **Health:** `GET /v1/health` (public, rate-limited) for the platform's probe.

## 7. Testing

- `AppAttestTests`: CBOR (each refused construct), attestation (valid; each of the nine checks broken one at a time;
  a fake chain against Apple's real root), assertion (signature, counter, app id), the pinned root's fingerprint, the
  request-signature bytes.
- `TegolaServerTests` over HTTP with Hummingbird's router test client and the fake CA: registration then signed
  lookups, replay, stale timestamp, tampered query or body, unknown and revoked keys, single-use challenges, debug
  tokens in each environment, 413, 429 per IP and per registration bucket, `X-Forwarded-For` spoofing, 404 problems,
  security headers; every validation rule; buckets; configuration refusals.
- `scripts/ci.sh` is the gate: tests, `swift format lint --strict`, contract lint (Redocly), contract drift, secret
  scan. CI runs it on Linux on every push.

## 8. Milestones

| Milestone | Scope | Exit test |
|---|---|---|
| **M1 · foundation** (done) | Package, generated server, App Attest, every §5 control, configuration, tests, CI, Dockerfile, docs; tegola told it can work here | `scripts/ci.sh` green; a binary that serves `/v1/health` and refuses unsigned lookups |
| **M2 · persistence** | A database-backed `AttestKeyStore` (SQLite or Postgres, atomic counter update), challenges with it; optional receipt check | Restart keeps keys; concurrent replays: exactly one passes |
| **M3 · first sources** | One source per launch type (§4), caching, timeouts, circuit breaker, attribution | Recorded-response tests per source; `/health` lists the types |
| **M4 · production** | Host, domain (the contract's placeholder `api.tegola.app`), proxy, secrets, monitoring; a run against the real app on a device | The app's M6 lookup flow works end to end on a device |

Tegola's client needs the server from its M6 (tegola HANDOFF), so M2–M4 can follow the app's pace.

## 9. Open questions for the owner

1. **Sources:** which databases per type (§4), and who registers the API keys.
2. **Hosting:** where it runs (a VPS with Caddy, Fly.io, a container platform), and the real domain.
3. **Persistence:** SQLite on a volume (one instance) or Postgres (managed, room to scale) for M2.
4. **Team id:** the Apple Team ID for `TEGOLA_APP_ID`.
5. **Shared caches:** the contract makes barcode answers `public`; a CDN in front would serve cached answers without
   App Attest. Fine for public catalogue data, or should the cache stay private to the server (D-14)?
