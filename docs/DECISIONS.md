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

### D-8 · Milestone 1 keeps keys in memory

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
- **Checked** by `scripts/docker-smoke.sh` (15 checks: the image's user, the exit-78 refusals, health, 401, 403 for
  a debug token, then the stack over HTTPS: health, HSTS, no `Server`, 401, 404 outside `/v1`, HTTP→HTTPS, no
  published server port) locally and in CI's `docker` job.
- **Not decided here:** the host, the domain, persistence, sources and a shared cache. They are the owner's (PLAN §9).
