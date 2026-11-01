# M3 reviews

## First review: fixed

From a separate review agent over `a810cc2`, read-only (no builds, no network), 2026-11-01. Line numbers are at
`a810cc2`. **Status: all fixed in `0f1665d`, with the OpenAPI restructure (D-23).** Each fix has a test in
`SupplierReviewTests` (`Tests/TegolaServerTests/SupplierTests.swift`) that sends the attack or the failure. The
batch deadline (finding 7) is the exception: 20 seconds is too long for a unit test, and it's a plain clock check in
`LookupAPI.matchBatch`. Kept below as found.

## Critical

1. **One import row can crash the server.**
   - Where: `TextMatch.confidence` (`SourceSupport.swift:376`) computes `abs(candidateYear - year)`. `MatchItem.year`
     is unbounded: not in the contract, not in `Validation.match`.
   - Failure: a `matchBatch` row with `year: Int.min` overflows the subtraction and traps the process.
   - Fix: refuse a year outside 1800…2100 in `Validation.match`. Make `confidence` safe on its own (compare only
     when both years are in range). Propose `minimum`/`maximum` on `MatchItem.year` in tegola's contract.

## High

2. **One source failing while another answers empty reads as "no match"**
   (`SourcesLookupService.swift:150-161`).
   - Failure: IGDB is busy and ScreenScraper answers `[]`. The lookup is 200 with nothing, and the import files the
     row as `unknown` without retrying.
   - Fix: when any source failed and the merged answer is empty, throw `SourceUnavailable` with the failure's retry.

## Medium

3. **Error pages can read as "no match".**
   - BGG: libxml2 runs in recover mode, so an HTML or `<errors>` body with 200 can parse to zero items, and the
     empty answer is cached.
   - ScreenScraper: a JSON error without `jeux` does the same.
   - Fix: require the `<items>` root for BGG and `jeux` present for ScreenScraper; otherwise `.failed("undecodable")`.
4. **XML entities: the hardening is unproven on Linux.** swift-corelibs' `XMLParser` may substitute entities
   whatever `shouldResolveExternalEntities` says.
   - Fix: refuse any body containing `<!DOCTYPE` or `<!ENTITY` before parsing.
   - Tests: the entity in element text; a billion-laughs fixture.
5. **Credentials may follow redirects.** `HTTPClient.shared` follows them, so the BGG bearer token, IGDB's headers
   or ScreenScraper's URL credentials could reach the redirect target.
   - Fix: our own `HTTPClient` with redirects off, and a 3xx treated as a failure.
6. **The cache is bounded by entries, not bytes.** An IGDB entry can hold about 240 candidates.
   - Fix: rank and keep at most 10 per source before caching, and/or cap the total size.
7. **A 50-row import can run for minutes and starve other users** of the shared MusicBrainz pace.
   - Fix: a deadline for the whole batch; stop at the first `busy`.
   - Consider a fair share per key on the shared pacers.
8. **Concurrent first IGDB calls each fetch a Twitch token** (the actor is re-entered across the `await`).
   - Fix: share the in-flight fetch as a `Task`.

## Low

- **Cache keys can collide.** They're joined with `|`, while `catalogueNumber` and `region` are raw. Encode the key
  unambiguously, for example as JSON.
- **The Lucene escape splits on spaces only.** A tab or U+3000 next to `OR`/`NOT` keeps the operator. Split on all
  Unicode whitespace.
- **MusicBrainz medium and format mapping:**
  - `contains("CD")` also catches VCD, SVCD and CD+G.
  - A release with no media is `medium: Other` but has no subtype.
  - A single 12" Vinyl maps to "LP".
- **IGDB's `platform` field uses IGDB's own name** ("Neo Geo AES"). Use the subtype's preset name
  (`VideoGamePlatforms.name`), as ScreenScraper does.
- **Decode and parse failures don't count towards the circuit breaker.**
- **`AnswerCache` eviction drifts.** An expired key removed in `value()` stays in `order`, so eviction can drop a
  fresh entry.
- **`URLComponents` doesn't encode `+`.** A `+` in a query, or in the Twitch form body, arrives as a space.
- **`SourceSettings.ClientCredentials` and `ScreenScraperSettings` have no redacting `description`.**

## Tests that prove too little

- **`anExternalEntityIsNotResolved` proves nothing.** The entity sits in an attribute, where XML forbids it anyway,
  and `try?` hides the failure. Put the entity in `<image>` text, expect a thrown failure, and add billion laughs.
- **Missing tests:**
  - an extreme `MatchItem.year` (finding 1);
  - one source failing while another answers empty (2);
  - BGG answering HTML with 200 (3);
  - a redirect (5);
  - a tab or U+3000 in Lucene input;
  - concurrent first IGDB calls (8).

## Found sound

- **Ids:** UUIDs for MusicBrainz, integers for the others.
- **Query escaping:** IGDB's quoted string.
- **The Twitch secret:** in the POST body, never a URL.
- **Images:** the host allowlist.
- **Logs:** reason codes only.
- **Contract shape:** confidence clamped, at least one reason and one source on every candidate.
- **Provider formats:** IGDB regions, ScreenScraper system ids, BGG endpoints and its bearer token.

## Second review: fixed

From a second separate review agent over the whole milestone (`origin/main...HEAD` at `dfe8e69`), read-only,
2026-11-01. It confirmed that every first-review fix holds, and found nothing critical. All fixed in `42e5640`, each
with a test in `SupplierSecondReviewTests`, unless noted.

- **High:**
  1. **BGG answers `text/xml`, and its description declared only `application/xml`.** The generated client would
     have refused every answer. Fixed: both types declared, and the fixtures carry each provider's real
     Content-Type.
- **Medium:**
  2. **Reading the body had no timeout.** Fixed: the whole exchange is raced against the timeout, and AHC gets
     connect and read timeouts.
  3. **"Busy" wasn't remembered.** Fixed: the supplier is skipped until its `Retry-After`.
  4. **An answer too large for one query opened the breaker for everyone.** Fixed: `too-large` doesn't count.
  5. **The year fix refused a whole batch over one row.** Fixed: the year is dropped instead.
- **Low:**
  6. **The batch deadline was checked between rows only.** Each row is now bounded by the pace wait plus the
     timeout. No test.
  7. **A DOCTYPE in UTF-16 got past the check.** Fixed: answers must be UTF-8 without NULs first.
  8. **A finished Twitch fetch could clear a newer one.** Fixed: a fetch clears only itself.
  9. **IGDB re-fetched its token on every 401.** Fixed: not when the token is less than a minute old.
  10. **The half-open breaker let everyone through.** Fixed: one probe.
  11. **MusicBrainz's `date` and `format` were hard filters.** Fixed: they now rank and filter locally.
- **Tests:**
  - The fixtures now carry their Content-Type.
  - The token test now overlaps its callers for real.
  - The redirect test still only proves that `exchange` maps a 3xx to a failure. The AHC `.disallow` setting has no
    test without a live HTTPS server: it's one line in `AsyncHTTPTransport`.
