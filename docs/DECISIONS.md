# tegola-server: decisions

**What this is.** How the server reads its specification (`docs/PLAN.md`, the contract, tegola's decisions) where it
is unclear, contradicts itself, or meets reality. A question that comes up during a task gets a new number here, and
the task carries on with that reading. Numbers are never reused; a replaced decision stays, marked
**superseded by D-n**.

**Format.** Each entry names the question and gives the decision, with its source.

---

### D-1 · Where the contract lives

> Owner: "start a swift server using hummingbird that implement this …/tegola/api/tegola-lookup.openapi.yaml".

**Decision.** tegola's `api/tegola-lookup.openapi.yaml` is the contract's only source. This repo keeps a byte-identical
copy at the same path (`Sources/TegolaServer/openapi.yaml` links to it, as tegola's `TegolaLookupAPI` links to its
own). A change is made in tegola first, then copied with `scripts/sync-contract.sh`; `scripts/ci.sh` fails on drift
when tegola is checked out next to this repo (CI checks it out). A git submodule was rejected: it would make every
clone and cloud session depend on access to tegola.

### D-2 · Stack

**Decision.** Hummingbird 2 with swift-openapi-generator (`generate: [types, server]`, `accessModifier: package`,
`namingStrategy: idiomatic`, as tegola's client) and swift-openapi-hummingbird. Swift 6.4, tools 6.2, the three
upcoming features tegola uses. One package, Linux first: everything builds and tests in a cloud session.

### D-3 · Configuration fails closed

**Decision.** `ServerConfiguration.load` reads `TEGOLA_*` and refuses to start (exit 78) on anything missing or unsafe:
no `TEGOLA_APP_ID` or one that isn't `<TeamID>.<bundle id>`; an unknown environment; a port or hop count out of range;
a debug token in production, or shorter than 32 characters in development. The environment defaults to
`production` and the host to `127.0.0.1`, so forgetting a setting is the safe mistake.

### D-4 · Apple's root certificate is pinned in source

**Decision.** `AppleRootCA.swift` carries Apple's App Attestation Root CA as PEM; the test `appleRootIsPinned` checks
its SHA-256 fingerprint (`1CB9823B…6242C932`), so a changed byte fails the gate. Fetching it at runtime was rejected:
a network dependency at start, and a trust anchor that could change under the server.

**Provenance.** apple.com was unreachable from the session that wrote it. The PEM came from two independent npm
packages (`node-app-attest` 1.0.1 and `appattest-checker-node` 1.0.3); their copies are identical, subject
"Apple App Attestation Root CA", valid 2020-03-18 to 2045-03-15. **Owner check:** compare the fingerprint with
`https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem` once.

### D-5 · App Attest verification

**Decision.** `AppAttestVerifier` follows Apple's steps for an attestation: format `apple-appattest`; the `x5c` chain
validates to the pinned root (RFC 5280 policy at the current time); the credential certificate's
`1.2.840.113635.100.8.2` extension equals `SHA-256(authData ‖ SHA-256(challenge))`; the key id is `SHA-256` of the
certificate's public key; the relying party hash is `SHA-256(appID)`; the counter is 0; the AAGUID is
`appattest` + 7 zero bytes in production (or `appattestdevelop` where development is allowed); the credential id is
the key id. It stores the key id, public key, counter and environment, nothing else. For an assertion: the signature
over `SHA-256(authData ‖ clientDataHash)` with the stored key, the relying party hash, and a counter strictly greater
than the stored one; the store then advances the counter only if it is still greater (atomic), so of two concurrent
replays one passes.

- **The challenge's bytes:** `SHA-256(challenge)` hashes the UTF-8 bytes of the challenge string as the server issued
  it (base64 text, not the decoded bytes). Added to the contract's `AttestKeyRegistration.attestation` description.
- **The challenge is consumed before verification**, whatever the outcome, so a failed attempt can't be retried with it.
- **CBOR** is read by a strict, bounded reader written for the two objects App Attest sends (no tags, floats,
  indefinite lengths, duplicate keys or trailing bytes; lengths checked against what's left; depth ≤ 8) rather than a
  general library, so a hostile input has as little surface as possible.
- **Not yet:** the receipt (fraud metric) isn't checked or stored; that needs a call to Apple and is M2's option.

### D-6 · The bytes an assertion signs

**Gap.** The contract said "SHA-256(body)" inside a string concatenation without saying how the digest is written,
and "path-with-query" without saying whether the base path is included.

**Decision.** `method` upper case; `path-with-query` exactly as sent on the wire, base path included
(`/v1/types/…?symbology=ean13`), no re-encoding; the timestamp as the header's text; the body digest as 64 lower-case
hex digits (an absent body hashes as empty). `RequestSignature` builds them, a test pins them, and the same wording is
now in the contract (tegola's copy first, D-1), so the app's `AppAttestMiddleware` (tegola M6) builds the same bytes.

### D-7 · Errors say what to do, never how the server works

**Decision.** Every error is an RFC 9457 problem document (`application/problem+json`) with a fixed title per kind
(`ProblemKind`) and `type` `/problems/<kind>`. No stack, no underlying error text, no echo of the input; a validation
failure names the field, not its value. Authentication failures are one indistinguishable 401, except the two the
contract defines: `/problems/unknown-key` (register again) and 403 for a revoked key. The reason (bad signature,
replay, stale timestamp…) goes to the log as a code. Body decoding failures, which the runtime reports as 500, become
400 (`EdgeMiddleware.problem`).

### D-8 · Milestone 1 keeps keys in memory (superseded in production by D-17)

**Decision.** `InMemoryAttestKeyStore` behind the `AttestKeyStore` protocol. A restart loses every key, and each
install re-registers on its next call through the contract's `unknown-key` path, so nothing breaks, it just costs one
registration per install. M2 brings a database store with the same atomic counter rule (`UPDATE … SET counter = $new
WHERE id = $id AND counter < $new`). Re-registering a known key keeps its stored counter, so it can't reopen old
assertions; a revoked key can't come back.

### D-9 · Rate limits

**Decision.** In-memory token buckets (`RateLimiter`), bounded at 200,000 entries (idle buckets pruned first, then
refusal). Defaults: per IP 120 burst, 2/s; per key 60 burst, 1/s; registration (`/v1/app-attest/*`) per IP 10 burst,
10/hour. 429 with `Retry-After` (whole seconds, ≥ 1). The client address is the peer's, or with
`TEGOLA_TRUSTED_PROXY_HOPS = n` the n-th from the right of `X-Forwarded-For`; what a client writes further left never
counts. Limits are per instance: running several instances needs a shared store first.

### D-10 · The edge

**Decision.** TLS is terminated by a reverse proxy; the server speaks HTTP/1.1 on loopback by default (`0.0.0.0` only
inside the container image). There is no route outside the contract: no admin, metrics or static files. Every
response gets HSTS (2 years, subdomains), `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src
'none'; frame-ancestors 'none'`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`,
`Cross-Origin-Resource-Policy: same-origin`, and `Cache-Control: no-store` unless D-14 applies; no `Server` header and
no CORS. Bodies are capped at 256 KiB: a larger `Content-Length` is refused before reading, and an undeclared length
is read up to the cap (the contract's largest request, 50 match rows, is well under it). Idle connections close after
30 s. The image runs as an unprivileged user.

### D-11 · What the handlers validate

**Decision.** `Validation` checks every limit the generator doesn't: the `code`, `typeID` and `subtype` patterns,
every `maxLength` (counted in Unicode scalars, as JSON Schema counts), `year` and `limit` ranges, and SearchRequest's
"at least one of `title`, `text`, `catalogueNumber`" (whitespace-only doesn't count). Match: more than 50 items is
413 as the contract says; zero items or a bad item is 400. `getWork` declares no 400, so an impossible id is 404.

### D-12 · No sources in milestone 1

**Decision.** `NoSourcesLookupService`: lookups answer 200 with no candidates (the contract's "no match"), match
answers `unknown` for every row, `getWork` 404, and `/health` lists no types, so the app knows there's nothing to ask
yet. Sources come in M3 behind `LookupService` (PLAN §4).

### D-13 · Match buckets

**Gap.** The contract says `matched` has one strong candidate and `ambiguous` two or three, without a threshold.

**Decision.** No candidate: `unknown`. One candidate, or a best one at confidence ≥ 0.8 and at least 0.25 ahead of the
next: `matched` with that one. Otherwise `ambiguous` with the best two or three. Confidence is clamped to 0…1 before
ranking. The app never confirms on its own either way (tegola PD-042).

### D-14 · Cache-Control is written by a middleware

**Gap.** The generated server percent-encodes string response headers, so the contract's
`Cache-Control: public, max-age=604800` went out as `public%2C%20max-age%3D604800`, which no cache understands
(found by `registerThenSignedLookupsWithAStrictlyIncreasingCounter`).

**Decision.** Handlers leave the generated `cacheControl` header unset; `CachePolicyMiddleware` writes it by operation
id: `public, max-age=604800` on a successful `lookupBarcode`, `no-store` on everything else.

**Owner question.** A shared cache or CDN in front would serve a cached barcode answer to anyone, without App Attest.
The answer is public catalogue data and identical for everyone, so this is consistent with the contract, but it is a
way around the proof of "what calls". Until the owner decides, deploy without a shared cache (PLAN §9, question 5).

### D-15 · Logs

**Decision.** One `request` line per call: method, route template (`/v1/types/{typeID}/barcodes/{code}`, never the
path), status, milliseconds, Hummingbird's request id. Plus `auth failed` with the operation and a reason code, and
`attestation rejected` / `key registered` with a reason or environment. Never a body, a query string, OCR text, a key
id, an IP address or a header value (tegola PLAN §2.7: "a log line records shape, never content").

### D-16 · Deployment: a Compose stack ready before the answers

> Owner: "I don't have response for this at the moment so prepare what you need with docker; I will provide those informations maybe when we will be close to release and need to push in prod something."

**Decision.** Production is a Docker Compose stack (`docker-compose.yml`): Caddy in front, the server behind it on a
private network with no published port. Everything that waits on the owner's answers (PLAN §9) is a value in `.env`
(`deploy/env.example`) or a named change in `docs/DEPLOY.md`'s go-live checklist, so going live doesn't need new
design work.

- **Caddy** gets and renews the certificate, redirects HTTP, speaks TLS 1.2/1.3, caps bodies at 256 KB, forwards only
  `/v1/*` (anything else is 404), health-checks `/v1/health`, drops the `Server` header, and has no admin API and no
  access log (its log would hold IPs and full URLs, against D-15). It replaces any client-sent `X-Forwarded-For` with
  the client's address, the one hop the server trusts (D-9). It receives only `TEGOLA_DOMAIN`, never the server's
  env file.
- **The server container** runs as uid 10001 with a read-only root, no capabilities, `no-new-privileges`, and memory
  and process limits. Its env file is `.env`, git-ignored.
- **The image** builds behind a TLS-intercepting proxy through an optional build secret (`proxy_ca`), used only by
  `swift package resolve`. `scripts/docker-smoke.sh` checks that it never reaches the image.
- **Checked** by `scripts/docker-smoke.sh` (15 checks at the time, 25 since M2 and D-19: the image's user, the exit-78 refusals, health, 401, 403 for
  a debug token, then the stack over HTTPS: health, HSTS, no `Server`, 401, 404 outside `/v1`, HTTP→HTTPS, no
  published server port) locally and in CI's `docker` job.
- **Not decided here:** the host, the domain, persistence, sources and a shared cache. They are the owner's (PLAN §9).

### D-17 · Postgres for keys and challenges (M2)

> Owner: "As DB I feel like pgsql should be our choice." (PLAN §9, question 3)

**Decision.** `PostgresStore` implements `AttestKeyStore` and `ChallengeStore` on Postgres through PostgresNIO's
`PostgresClient`, which runs as a service of the application. The in-memory stores stay for tests and for a
development server without a database.

- **Required in production.** `ServerConfiguration.load` refuses to start a production server without
  `TEGOLA_DATABASE_URL` (exit 78): without it every restart would forget every key. Development without one keeps
  the in-memory stores.
- **The URL** is `postgres://user:password@host:port/database?sslmode=…`. `sslmode` defaults to `verify-full`
  (encrypted, certificate and host name checked, TLS 1.2+); `require` encrypts without checking; `disable` is for
  the Compose stack's internal network only. `sslrootcert=` trusts a provider's CA. Any other parameter is refused.
  `DatabaseSettings` never prints the password: not in `description`, `debugDescription` or its mirror (tested).
- **Schema** (migration 1): `attest_keys` (`key_id` 32 bytes, `public_key` 65 bytes, `counter` 0…2³²−1,
  `environment`, `revoked`, `registered_at`), with `CHECK` constraints as a last line of defence, and
  `attest_challenges` (`challenge`, `expires_at`, indexed). Migrations are versioned in `tegola_schema_migrations`,
  each applied in its own transaction under `pg_advisory_xact_lock`, so several instances can start at once. They run
  before the server binds its port; a database that doesn't answer within 60 seconds stops the server.
- **Statements are parameterised** (PostgresNIO binds every interpolated value). Only the constant migration
  statements are sent as text.
- **The counter rule** is one statement: `UPDATE … SET counter = $new WHERE key_id = $id AND counter < $new RETURNING
  1`. Of concurrent replays exactly one updates a row (tested with 20 at once). Registration is
  `INSERT … ON CONFLICT DO NOTHING`, which keeps the stored counter and revocation, as D-8's in-memory store does.
- **Challenges** expire by the server's clock (stored as `expires_at`); expired ones are deleted before each issue,
  and issuing stops at `maximumOutstandingChallenges` (503).
- **A store that can't answer** is a 503 with `Retry-After: 5` and `/problems/unavailable`, for signed calls and
  registration alike. Never a 401, which would make the app throw its key away, and never a pass. `/health` answers
  `degraded` when `SELECT 1` doesn't come back within 2 seconds.
- **In the Compose stack**, Postgres 17 runs on a `db` network that is `internal` (no route out) and that only the
  server joins. It publishes no port, has a read-only root with tmpfs for its socket, the five capabilities its
  entrypoint needs, `no-new-privileges`, and `scram-sha-256` authentication. The password is `TEGOLA_DB_PASSWORD`,
  hex so it needs no escaping in the URL. Its data is the `postgres_data` volume.
- **Tests:** `StoreTests` run every rule against both stores: in-memory always, and Postgres when
  `TEGOLA_TEST_DATABASE_URL` is set (CI's `postgres` service). Each test gets a schema of its own, migrated from
  scratch and dropped afterwards. `StoreFailureTests` cover the 503s and `degraded`; `scripts/docker-smoke.sh` checks
  the migration, the restart, the isolation of the database from Caddy, and that the password never reaches the log.
- **Rate limits** stay in memory, per instance (D-9). More than one instance needs them shared too.

### D-18 · A 503 the contract doesn't declare is thrown, not returned

**Gap.** For an operation without a declared 503, a handler returned the generated `.undocumented(statusCode: 503,
payload)`. The generated server writes only the status of an undocumented response and drops the payload, so those
answers went out as an empty 503 with no `Retry-After` (found by `registrationIs503WhenTheStoresAreDown`). That
affected M1's "challenge store full" and `getWork`'s source outage too.

**Decision.** Handlers throw `ServiceUnavailable(retryAfter:)` instead, and `EdgeMiddleware` answers it with the
problem document and `Retry-After`. No handler returns `.undocumented`. `aSourceOutageOnAWorkIs503WithRetryAfterAndAProblem`
and `StoreFailureTests` pin it.

### D-19 · What the review of M1 and M2 changed

Two independent review agents (security; correctness and contract) read `main` at 80ef72f. Neither found anything
critical or high. Every finding is fixed here, except the two listed under "Left open".

- **Registration's bucket is chosen by operation, not by path** (security, medium). Hummingbird's router ignores
  empty path segments, so `GET /v1//app-attest/challenge` reached `getAttestChallenge` but missed the
  `/v1/app-attest/` prefix check, getting the general bucket (120, then 2/s) instead of 10 an hour. The edge now
  applies only the general per-client bucket and records the client in `RequestScope`; `AppAttestMiddleware` applies
  the registration bucket to `getAttestChallenge` and `registerAttestKey` by operation id.
- **An IPv6 client is its /64** (security, medium). `RateLimitKey.client` keys IPv4 by address, IPv6 by /64, and an
  IPv4-mapped IPv6 address as its IPv4 address. A full limiter table now evicts its least recently used tenth instead
  of refusing every new client with 429, which a spray of addresses could have caused for everyone.
- **A match batch costs one token per row** (security, low, for M3). Each row will be a lookup against a source's
  quota. The middleware takes one token, and `matchBatch` takes the rest from the same per-key bucket
  (`RequestScope.keyID`) or answers 429.
- **The image trusts no `X-Forwarded-For`** (`TEGOLA_TRUSTED_PROXY_HOPS=0`), as the configuration's default says.
  Compose sets 1 for Caddy (security, low).
- **The contract-drift check can't pass by comparing nothing.** It fails in CI, or when `TEGOLA_DIR` is set, if
  tegola's contract is missing, and CI's tegola checkout is required (both reviews, low).
- **The Postgres challenge cap is atomic.** The purge, the count and an `INSERT … SELECT … WHERE count < cap` run in
  one transaction under an advisory lock (both reviews, low). Tested with 20 concurrent issues against a cap of 5, on
  both stores.
- **Postgres 15 and earlier could run the migration** (correctness, medium). The lock key was a SQL literal with
  digit separators, which only Postgres 16 accepts. Both lock keys are now bound parameters.
- **The database password was percent-decoded twice** (correctness, low–medium). `URLComponents` already decodes the
  user and password, so `%25` became `%` and then failed to decode, and the server connected with no password.
- **A 406 is a 406.** An `Accept` that rules out the answer's media type was reported as 415; it is now
  `/problems/not-acceptable` (correctness, low).
- **Startup failures exit cleanly.** An error after the configuration was accepted (a database that can't be reached
  or migrated, an unreadable CA file) used to crash at top level. It is now logged (a database error by code, SQLSTATE
  and server message, never bound values or the password) and exits 1. Configuration errors stay 78 (correctness, low).
- **The cacheable barcode answer says `Vary: Accept-Language`**, since its titles follow that header (correctness,
  low).
- **The contract says a revoked key stays revoked** (correctness, low). It told the app to re-register a revoked key
  on `unknown-key`, while the code answers 403 and refuses to register it again. Fixed in tegola first (its D-55,
  tegola PR #10), then synced.
- **Tests that passed for the wrong reason, or were missing:**
  - The streamed body cap: the test client always declares `Content-Length`, so the edge answered. It is now tested
    on the middleware with a body of unknown length.
  - A production server holding a development key: now refused, and tested.
  - Certificates outside their validity: tested, both expired and not yet valid.
  - The `//` path, IPv6 /64, a full limiter table, per-row cost, 406, `Vary`, and a password containing `%25`.
  - `docker-smoke.sh`: a wrong database password exits 1 with the reason in the log and never the password.
- **Dependabot** now watches the GitHub Actions, the Dockerfile and Compose images, and the Swift packages.

**Left open.** Pinning actions and images by SHA or digest instead of tag (since done: D-20). Shared rate limits for
several instances (D-9).

### D-20 · Everything the build pulls is pinned

**Gap.** D-19 left the images and actions on tags. A tag can be moved: the same Dockerfile could build on a different
base tomorrow, and a re-pointed action tag would run with the job's token. Nothing about it depends on the host, so it
needn't wait for PLAN §9.

**Decision.** Each image is written `tag@sha256:<index digest>` (the multi-arch index, so the Mac and amd64 both
resolve), and each action `owner/action@<commit SHA> # vX.Y.Z`. This covers the Dockerfile's two stages, the Compose
images (Postgres, Caddy) and CI's own (the `swift` container, the Postgres service), and `docker-smoke.sh` takes its
Postgres from `docker-compose.yml`. The tag stays for people and for Dependabot, which bumps tag and digest (or SHA and
comment) together in one PR that CI must pass. The digests were read from Docker Hub and from `mirror.gcr.io`, and
matched.

`scripts/pin-check.sh`, in `scripts/ci.sh`, fails on an unpinned image or action, and on one image carrying two
digests across files. Dependabot doesn't update a workflow's `container:` and `services:` images, so a bump of the
Dockerfile's `swift` or Compose's `postgres` fails that check until CI's copy is moved too, in the same PR. That keeps
CI testing on the image that ships.

### D-21 · Postgres 18, and its new data path

**Gap.** Dependabot's PR #8 moved Compose from `postgres:17-alpine` to `18-alpine`, and it was merged before the
`docker` job finished. From 18 the image keeps its data in `/var/lib/postgresql/18/docker` (`PGDATA`) and refuses to
start while a volume is mounted on the old `/var/lib/postgresql/data`, which is where Compose mounted `postgres_data`.
The stack never became healthy, and `main`'s `docker` job was red from that merge on. CI's own Postgres service and
`scripts/test.sh` stayed on 17, so the gate tested one major version and the stack shipped another.

**Decision.** Postgres 18 everywhere: Compose, CI's service and the smoke test, all on one digest (D-20's check now
refuses the split). `postgres_data` is mounted on `/var/lib/postgresql`, the parent of every major's directory, as the
image expects. `docker-smoke.sh` now writes a table, takes the stack `down` and `up` again (new containers, new
anonymous volumes), and checks the table is still there. Data that lands outside the named volume fails the smoke
test instead of disappearing on the next update. A plain `--force-recreate` wouldn't show it: Compose carries a
container's anonymous volumes over to its replacement. The
store tests pass on 18.6.

**Upgrading a deployment.** None runs yet. A stack that ran 17 has its data in `postgres_data/` at the old layout:
dump it with 17 (`pg_dumpall`), start 18 on a fresh volume, restore. The server migrates its schema at start (D-17).

### D-22 · The first sources, and how every source behaves

**Choice.** The owner picked them on 2026-11-01 (PLAN §9, question 1): MusicBrainz for `music`; IGDB and ScreenScraper
for `video-game`; BoardGameGeek for `board-games`; nothing for `thing`.

**What each answers.**

| Source | Type | Barcode | Words | Key | Pace | Ids |
|---|---|---|---|---|---|---|
| MusicBrainz | `music` | yes, exact hits only (0.95) | release, artist, catalogue number, year, format | none; a contact for the User-Agent | 1 / 1.1 s | `musicbrainz:release:<mbid>`, works `musicbrainz:release-group:<mbid>` |
| IGDB | `video-game` | no index | title, platform, region, year | Twitch client id + secret | 1 / 260 ms | `igdb:game:<id>:<platform>:<region>`, works `igdb:game:<id>` |
| ScreenScraper | `video-game` | no index | title, system, region, year | developer id + password (member optional) | 1 / 1.2 s | `screenscraper:game:<id>:<region>`, works `screenscraper:game:<id>` |
| BoardGameGeek | `board-games` | no index | title, publisher, year | XML API bearer token | 1 / 2 s | `boardgamegeek:<id>` for both |

A barcode for a type with no barcode index answers "no match", and the app falls back to words (tegola's
`board-games.yml` already expects it). Candidates fill the type file's field keys (`medium`, `format`, `label`,
`catalogNumber`, `country`; `platform`, `publisher`, `region`; `designer`, `players`, `playTime`, `minAge`, `weight`)
and the subtype when the platform or medium has one. Every candidate names its source, with the attribution its terms
ask for.

**Ranking.** For words, every source ranks the same way: title similarity 70 %, subtitle 20 %, year 10 %, each
counted only when the query gives it (`TextMatch.confidence`). Titles compare after folding case, accents,
punctuation, `&` and a leading article, by character bigrams, so word order and small typos cost little. D-13's
buckets then apply to imports unchanged. OCR text searches its first three lines, with the reason `ocr`.

**How every source behaves.**
- **One connection each** (`SupplierConnection`, D-23): a pacer keeps the provider's rate across all requests, and refuses a
  request that would wait more than 10 s (12 s for BGG) with `Retry-After` instead of queueing it. A breaker opens
  for 30 s after five failures in a row. Requests time out at 8 s; answers are capped at 2 MB.
- **Failures are 503 with `Retry-After`**, never an empty answer that would read as "no match". A provider's 429 or
  503 (and ScreenScraper's 423, 430, 431) keep its `Retry-After`, an hour for ScreenScraper's daily quota. A refused
  key is logged as `unauthorized`, an operator problem.
- **Several sources for one type** are asked in parallel. When some answer, their answers are enough. When all fail,
  the lookup is 503 with the soonest retry.
- **Answers are cached** in memory for a day (an empty answer for an hour), per source and normalised query, at most
  10,000 of them. Failures are never cached. A 50-row import against a 1-request-a-second source runs out of pace
  part-way and answers 503; the rows it reached are cached, so each retry goes further.

**Security.**
- Keys come from the environment only (`SourceSettings`). A pair set by half, or a value with spaces or control
  characters, stops the server. The start-up log names the sources that are on, never a value.
- Words never change a provider's query. MusicBrainz's Lucene syntax is escaped, with `AND`/`OR`/`NOT` lowered.
  IGDB's quoted string loses `"`, `\` and `;`. Ids are checked before they reach a URL: UUIDs for MusicBrainz,
  integers for the others.
- The Twitch secret goes in a POST body, never a URL. ScreenScraper takes its credentials in the query string by
  design: its URLs are never logged, and its media URLs, which carry them too, are never passed on, so its candidates
  have no images.
- Images are kept only when they're HTTPS on the source's own image host (`images.igdb.com`,
  `cf.geekdo-images.com`), without credentials or a query.
- Provider strings lose control characters and are cut at 300 characters. BGG's XML is parsed without resolving
  external entities.
- A source failure logs the source and a reason code (`network`, `http-5xx`, `busy`, `undecodable`, …), never the
  URL, the words or a key.

**The tests' answers are hand-written** from each provider's documented format: this environment can't reach the
providers. They should be re-recorded from the live APIs once the keys exist.

**Left for later.** Cover art for music (the Cover Art Archive, one more request per release, at MusicBrainz's pace).
A cache shared by several instances, with the shared rate limits (D-9).

### D-23 · Every supplier has an OpenAPI description; one protocol for any supplier

**Direction.** The owner, 2026-11-01: "each data source should have an openapi file that we either create ourself or
that is from our data supplier", and "one protocol that will represent any data supplier abstractly".

**Decision.**
- **One description per supplier**, in `api/sources/`: `musicbrainz`, `twitch` (IGDB's token), `igdb`,
  `screenscraper`, `boardgamegeek`. None of these publishes an OpenAPI description (checked against their docs:
  MusicBrainz WS/2, IGDB v4, Twitch OAuth, ScreenScraper api2, BGG XML API 2), so all five are ours. Each one carries
  its source and the provider's terms, and holds only the operations and fields the server reads. A supplier that
  later publishes its own replaces ours.
- **One generated client per supplier**, each in its own target (`Sources/<Name>API/`, the description linked in,
  `generate: [types, client]`), because the generator takes one document per target. The clients stay internal to the
  package.
- **`DataSupplier`** (was `CatalogueSource`) is the one protocol for any supplier: name, type, id prefix, whether it
  has a barcode index, and `barcode`, `search` and `work`, which return the contract's candidates and works or a
  `SupplierFailure`. Everything specific to a supplier stays behind it: its client, its key, its query language, its
  answer's shape. The composite is `SuppliersLookupService`; the code is in `Sources/TegolaServer/Suppliers/`.
- **Every client sends through `SupplierTransport`**, a `ClientTransport` over `SupplierConnection`, so the generated
  code gets D-22's pace, breaker, timeout and size cap. Tests still replay fixtures through `HTTPTransport`. Keys and
  tokens go through `HeadersMiddleware`, since OpenAPI ignores an `Authorization` header parameter. ScreenScraper's
  credentials are query parameters in its description, because that is its API.
- **What the generator can't do:** BGG answers XML, which the client hands back raw. `BoardGameGeekSupplier` parses
  it, requiring an `<items>` root and refusing any DOCTYPE or entity declaration.

**The first review's findings** (`tasks/M3-review.md`), fixed with this change, each with a test:
- **Years:** the ranking only compares years from 1800 to 2100, and an import row's year outside that range is
  dropped. The contract gives it no range, so the row is still answered. An extreme year could overflow and stop
  the server.
- **Failures:** a supplier failing beside an empty answer is 503, not "no match". Error pages are failures.
- **Redirects** are refused, so no key follows one.
- **Cache:** answers are cut to each supplier's best 10 before caching, keys are JSON, and the eviction is fixed.
- **Imports** stop after 20 s.
- **Twitch:** one token fetch is shared by concurrent first requests.
- **Smaller fixes** to the escaping and the mappings.

**The second review's findings**, over the whole milestone (`tasks/M3-review.md`), fixed with a test each:
- **Content types:** BGG labels its XML `text/xml`, which the description now declares beside `application/xml`.
  Fixtures carry each provider's Content-Type, because the generated clients refuse one their description doesn't
  declare.
- **Time:** the whole exchange, body included, is bounded by the 8 s timeout.
- **Busy providers:** a provider that said "busy" is left alone until its `Retry-After`.
- **Breaker:** an answer too large for one query doesn't count towards it, and once it's half open, only one probe
  goes through.
- **BGG:** answers must be UTF-8 without NULs before the declaration check.
- **Twitch:** a fresh token IGDB refuses isn't fetched again.
- **MusicBrainz:** the year and subtype rank and filter locally instead of in its index.

### D-24 · Identify replaces search (contract 0.2.0)

**Direction.** tegola's D-71 (2026-11-01): `identifyObject` (`POST /types/{typeID}/identify`) replaces
`searchObjects`, and takes words, OCR text, a barcode and a photo in any combination. PD-118: a photo leaves the phone
only through Identify, and the server never keeps it.

**Decision.**
- **Two bodies.** JSON is the hints alone, and needs a title, OCR text, a catalogue number or a barcode (`400`
  otherwise). `multipart/form-data` carries an `image` part (a JPEG) and a `hints` part (the same JSON), each at most
  once; at least one of a photo, a hint or a barcode must be there.
- **The photo is checked, then dropped.** At most 2 MiB (`413`), and it must start with a JPEG's `FF D8 FF`, whatever
  its part says (`415`). No source matches images yet, so the bytes never leave the handler: no `LookupService`,
  supplier, cache or log sees them. A photo with no usable hint answers `200` with no candidates, which the contract
  defines as "no match". An image source, when one is chosen, gets its own parameter on `LookupService.identify` and
  must keep PD-118 (no storage, no source that keeps it).
- **Hints:** the words go to every supplier of the type (as `searchObjects` did), the barcode to the suppliers with a
  barcode index (as `lookupBarcode` does), both at once. A release both find is one candidate with the higher
  confidence and both reasons. One half failing doesn't hide what the other found; with nothing found and a failure,
  it's `503`, as before.
- **Body caps per operation.** `identifyObject` may send 3 MiB (`Limits.maximumIdentifyBodyBytes`); every other
  operation keeps 256 KiB. The edge refuses a declared length above the larger cap before the route is known;
  `AppAttestMiddleware` applies the operation's own. Caddy's `max_size` is 3 MiB.
- **Headers before body.** A secured operation's key id, timestamp and key (known, not revoked, right environment)
  are checked before its body is read, so a caller without a registered key can't make the server read 3 MiB. The
  assertion, which covers the body, is checked after. A secured request that's both unsigned and too large is now
  `401`, not `413`.

