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

**Out, by tegola's decisions.** Accounts, sync, subscriptions, a cover-art CDN (tegola D-25, Q3/Q9); anything about the rest
of a shelf (tegola PLAN §2.7). A photo arrives only through `identifyObject`, when the collector turns Identify on
for that shot, and is never kept (tegola D-71, D-24 here). The server never decides for the collector: it proposes candidates with
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
- **Stores** sit behind protocols (`AttestKeyStore`, `ChallengeStore`): `PostgresStore` in production (D-17), the
  in-memory ones in tests and development.

## 3. The contract

`api/tegola-lookup.openapi.yaml` is tegola's file (D-1). This repo keeps a byte-identical copy that the generator
reads through `Sources/TegolaServer/openapi.yaml`. Changing the contract is how either side asks for a change: edit it
in tegola (with `scripts/lint-api.sh` there), then `scripts/sync-contract.sh` here, build, and implement what the
compiler asks for. `scripts/ci.sh` fails while the two differ.

What the generator enforces: types, required fields, enums, unknown keys under `additionalProperties: false`. What it
doesn't, and `Validation` does: `pattern`, `maxLength`, `minimum`/`maximum`, `maxItems`, and IdentifyHints's
"at least one of" (D-11, D-24); for an identify photo, its size and its JPEG signature (D-24).

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

**Chosen** (owner, 2026-11-01; D-22): MusicBrainz for `music`; IGDB and ScreenScraper for `video-game`; BoardGameGeek
for `board-games`; nothing for `thing`. Only MusicBrainz has a barcode index: video-game and board-game barcodes
answer "no match", and the app falls back to words, as tegola's `board-games.yml` already says.

**Added** (owner, 2026-11-01; D-26): Wikidata, for `thing`, and as the **fallback** for the other three. A type's
suppliers are asked in tiers: the fallback only when the primary sources found nothing (or failed). Wikidata also
has a barcode index (GTIN, P3962), so a `thing` barcode can match.

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
| Counter rewind by re-registering a key | Re-registration keeps the stored counter; revoked keys stay revoked | `AttestKeyStore.register` (`ON CONFLICT DO NOTHING` in Postgres) |
| Concurrent replays across instances | One conditional `UPDATE … WHERE counter < $new`: exactly one passes | `PostgresStore.advanceCounter` |
| A database outage read as "no key" or "replay" | A store that can't answer is 503 with `Retry-After`, never 401 or a pass; `/health` says `degraded` | `AppAttestMiddleware`, `LookupAPI`, D-17 |
| Database exposure | Internal-only network, no published port, `scram-sha-256`; outside the stack, `verify-full` TLS by default; parameterised statements; the password never printed | `docker-compose.yml`, `DatabaseSettings`, `PostgresStore` |
| Oversized or hostile bodies | `Content-Length` rejected at the edge, body read with a cap (413; identify's 3 MiB read only once the key is known, D-24), strict CBOR with bounded lengths and depth, unknown JSON keys refused, every limit validated | `EdgeMiddleware`, `AppAttestMiddleware`, `CBORReader`, `Validation` |
| Volumetric abuse, quota draining | Token buckets per IP, per key, and a stricter one for registration; bounded tables; idle timeout | `RateLimiter`, `EdgeMiddleware` |
| Spoofed client address | `X-Forwarded-For` ignored unless `TEGOLA_TRUSTED_PROXY_HOPS`; then only the trusted hop counts | `EdgeMiddleware.clientAddress` |
| Information leaks in errors | Problem documents with fixed titles; decoder errors become a bare 400; unexpected errors a bare 500 | `ProblemKind`, `EdgeMiddleware.problem` |
| Privacy leaks in logs | Route template, status, duration, reason codes only | `EdgeMiddleware`, handlers |
| Browser-based misuse | `default-src 'none'` CSP, `nosniff`, `DENY` framing, `same-origin` CORP, no CORS headers | `EdgeMiddleware.addSecurityHeaders` |
| Downgrade to HTTP | HSTS on every response; TLS at the proxy; loopback bind | `EdgeMiddleware`, §6 |
| Secrets in the repo | Environment only; `.env` ignored; secret scan in CI | `scripts/secret-scan.sh` |
| A moved image or action tag | Images pinned by digest, actions by commit SHA; Dependabot bumps them through CI | `scripts/pin-check.sh`, D-20 |
| A tampered trust anchor | Apple's root pinned in source, its SHA-256 fingerprint checked by a test | `AppleRootCA`, `appleRootIsPinned` |

**Accepted for now** (D-9, D-5): rate-limit buckets live in memory, so limits apply per instance. App Attest's
fraud-metric receipts aren't checked yet.

## 6. Operations

- **One instance** behind a TLS-terminating reverse proxy, as a Docker Compose stack (`docker-compose.yml`): Caddy
  (automatic certificates, HTTP→HTTPS, TLS 1.2/1.3, `/v1/*` only) in front of the server, which publishes no port.
  `Dockerfile` builds a static binary into a slim image running as uid 10001, read-only and without capabilities.
  `docs/DEPLOY.md` is the runbook and the go-live checklist; `scripts/docker-smoke.sh` checks the image and the stack
  (D-16).
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
| **M2 · persistence** (done) | `PostgresStore` for keys and challenges, migrations, required in production; Postgres in the Compose stack (D-17) | Restart keeps keys; concurrent replays: exactly one passes |
| **M3 · first sources** | One source per launch type (§4), caching, timeouts, circuit breaker, attribution | Recorded-response tests per source; `/health` lists the types |
| **M4 · production** | Host, domain (the contract's placeholder `api.tegola.app`), proxy, secrets, monitoring; a run against the real app on a device | The app's M6 lookup flow works end to end on a device |

Tegola's client needs the server from its M6 (tegola HANDOFF), so M2–M4 can follow the app's pace.

## 9. Open questions for the owner

Deferred by the owner until release (2026-10-31): "I don't have response for this at the moment so prepare what you
need with docker; I will provide those informations when we are close to release." Each answer's place is in
`docs/DEPLOY.md`, "Go-live checklist"; nothing else waits on them.

1. ~~**Sources**~~ **Answered:** MusicBrainz, IGDB + ScreenScraper, BoardGameGeek (owner, 2026-11-01; D-22), and
   Wikidata for `thing` and as every type's fallback (D-26). Still open: registering the keys, which binds whoever holds them to each provider's terms.
2. **Hosting:** where it runs (a VPS with Caddy, Fly.io, a container platform), and the real domain.
3. ~~**Persistence**~~ **Answered:** Postgres (owner, 2026-10-31; D-17). Still open: the stack's Postgres or a managed
   one, decided with the hosting.
4. **Team id:** the Apple Team ID for `TEGOLA_APP_ID`.
5. **Shared caches:** the contract makes barcode answers `public`; a CDN in front would serve cached answers without
   App Attest. Fine for public catalogue data, or should the cache stay private to the server (D-14)?
