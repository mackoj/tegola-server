# Handoff

The state of the work for whoever picks it up next: a new session, another agent, or the owner. Read this first, keep
it short and current.

**Updated:** 2026-11-01. M1 to M3 are merged, and so are contract 0.2.0 (D-24), music cover art (D-25) and
Wikidata with tiers (D-26). **M5 · providers** has started from the owner's "Data Providers" proposal
(`docs/proposals/data-providers.dc.html`), adopted with changes (D-27): T5.1 and T5.2 are done on this branch.
Providers now return `ProviderRecord`s, and `LookupRouter` ranks them one way and merges records of one release from
several providers. "Supplier" is "provider" in the code. tegola's M5 and M6 are merged, so the app's lookup client
exists: M4's end-to-end run waits only on a host and a device.

## Resume here (in this order)

1. **M5, next task: T5.3 manifests** (`tasks/plan.md`, M5; D-27 says what changed from the proposal and why). Then
   T5.4 caches by licence, T5.5 ledger, budget and kill switch. The owner's answers: keep the cost data and group it
   later; assume some sources will be paid; one repo.
2. **tegola D-76 (PR #19): the proposal's product half**, recorded for the owner to decide: free-tier caps, type
   packs, a subscription (sections 05–06), and the ledger's per-install pseudonym. It conflicts with tegola D-25 and
   ADR-0001. Merge the PR once its CI is green; the decisions stay the owner's.
3. **Owner, keys:** register the providers' keys (`deploy/env.example`, "Lookup sources"): a MusicBrainz contact, a
   Twitch application for IGDB, a ScreenScraper developer account, a BoardGameGeek XML API token. Then, with the
   keys, re-record `Tests/TegolaServerTests/ProviderFixtures.swift` from the live APIs: they're hand-written from the
   documented formats, since this sandbox can't reach the providers. Check in particular:
   - each answer's Content-Type (the generated clients refuse undeclared ones, D-23);
   - IGDB's `release_region`;
   - that MusicBrainz's release search returns `cover-art-archive` (D-25);
   - Wikidata's answers (no key, only `TEGOLA_WIKIDATA_CONTACT`), and whether its classes and weights suit (D-26);
   - ScreenScraper's system ids;
   - BGG's bearer token.
   - whether IGDB's and ScreenScraper's titles, regions and years agree often enough to merge (D-27).
4. **Adding a provider:** write (or fetch) its description in `api/sources/`, add a `<Name>API` target in
   `Package.swift` (copy an existing one), and conform a type to `DataProvider` in `Sources/TegolaServer/Providers/`.
   It returns `ProviderRecord`s: fill the type file's field keys, the external ids (its own included), `identifying`
   for those that name the release itself (not its game or work), and `matched` for what it matched exactly; never a
   confidence (D-27). Then wire it in `ProviderFactory.swift` and
   `SourceSettings`, and add tests with fixtures that carry the real Content-Type. A general source that should only
   answer when the type's own find nothing sets `tier: .fallback` (D-26), and `weights` when its matches are looser.
5. **Dependabot PRs**, weekly: merge one only once both `linux` and `docker` are green (the `docker` job takes about
   ten minutes; #8 was merged before it failed). An image bump that touches the Dockerfile's `swift` or Compose's
   `postgres` fails `pins` until CI's copy in `.github/workflows/ci.yml` carries the same digest: move it in the same
   PR. A Postgres major bump needs the upgrade step in D-21 once a deployment exists.
6. **Owner answers**, deferred until release: hosting and domain, Team ID, shared caches (PLAN §9; persistence and
   sources are answered, D-17, D-22). `docs/DEPLOY.md` says where each answer goes.
7. **M4, production**: tegola's M6 (the app's lookup client) is merged; what remains needs the owner's host, domain
   and a device (`tasks/plan.md`, M4).
8. **Open options:**
   - an image source for Identify, per type (D-24 says where it plugs in, and what PD-118 asks of it; T5.6);
   - a provider cache and rate limits shared by several instances (D-9; the cache part is T5.4);
   - an import batch that answers the rows it reached instead of 503 (a contract change, tegola first);
   - a range for `MatchItem.year` in the contract (the server drops out-of-range years today).

The owner's working style: carry on without asking. Use a worktree per task, branch, commit, push, open the PR, wait
for green CI, merge. Stop only for decisions that are the owner's (PLAN §9). To keep the PR description free of the
footer this session's GitHub tool appends, create the PR with a placeholder body, then set the real body with an
update.

## Where things stand

- **Spec:** `docs/PLAN.md`; decisions D-1 to D-27 in `docs/DECISIONS.md`.
- **M5 (providers, in progress):** D-27. Providers return `ProviderRecord`s; `Ranking` scores them (D-22's formula
  times `ProviderWeights`); `RecordMerge` makes one candidate of records that share a release-level external id
  (`identifying`) or agree on type, title, subtype, region and year, one to one. Tests: `RecordMergeTests.swift`.
- **M1 (foundation):** the contract's seven operations served by Hummingbird 2 from generated code. App Attest
  registration and assertions are verified end to end, with every control of PLAN §5 and no lookup source yet (D-12).
  Report: `docs/milestones/M1.md`.
- **M3 (sources):** MusicBrainz (music: barcode and words), IGDB + ScreenScraper (video games: words),
  BoardGameGeek (board games: words); the owner's choice (D-22). Wikidata (barcode and words) for `thing`, and as the
  other types' fallback tier (D-26). Each is described in
  `api/sources/*.openapi.yaml` with a generated client (`Sources/<Name>API/`), conforms to `DataProvider`
  (`Sources/TegolaServer/Providers/`), and turns on with its environment variables. All clients send through
  `ProviderTransport`, which applies pace, breaker, timeout, size cap and no redirects (D-23). Tests:
  `ProviderTests.swift`, with fixtures in `ProviderFixtures.swift`.
- **M2 (persistence):** keys and challenges in Postgres (`PostgresStore`), required in production. The Compose stack
  runs Postgres on an internal-only network. Report: `docs/milestones/M2.md`.
- **Review (D-19):**
  - Two independent agents found nothing critical or high. All findings are fixed except shared rate limits (D-9),
    which wait on the hosting answer. Pinning was done after (D-20).
  - The fixes: registration bucket by operation, IPv6 /64 keys, per-row match cost, atomic challenge cap, Postgres
    <16 lock literal, password decoded once, 406, clean startup exits, `Vary`, image trusts no X-Forwarded-For, drift
    check can't pass empty, Dependabot.
- **Pinning (D-20):** every image by digest, every action by commit SHA; `scripts/pin-check.sh` in the gate refuses
  a tag alone, or one image with two digests across files.
- **Verified on this branch** (Linux, Swift 6.4.2):
  - `scripts/ci.sh`: tests, format, contract drift, secrets and pins green (contract lint skipped: no Node here; CI
    runs it).
  - `scripts/docker-smoke.sh`: image and stack, built from the pinned digests, now with a persistence check
    (D-21).
  - The store tests on Postgres 18.6.
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
  postgres:18-alpine` (pulled from `mirror.gcr.io/library/postgres:18-alpine` and tagged), then
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
- **Gotchas found in M5:** the router drops a record whose `provider` or `typeID` isn't the provider's own, so a
  test provider's records must carry its name (the tests' `record("<name>:<n>")` does). A candidate's confidence now
  comes from the router: test a provider's ranking through `candidates(_:)` (`ProviderTests.swift`), which scores its
  records as the router does.
- **Gotchas found in M3:**
  - swift-openapi-generator takes one document per target, so each supplier has its own target.
  - Every module generates its own `Components`, `Operations` and `Client`: qualify them by module
    (`MusicBrainzAPI.Operations`), or the server's own win.
  - OpenAPI ignores an `Authorization` header parameter, so keys go through `HeadersMiddleware`.
  - A generated client refuses an answer whose Content-Type its description doesn't declare: declare what the
    provider really sends (BGG: `text/xml`).
  - FoundationXML needs `libxml2` in the runtime image.
  - `pkill -f <script>` also matches the shell that runs it.
- **Gotchas found while pinning (D-20, D-21):** Postgres 18 keeps its data in `/var/lib/postgresql/18/docker` and
  refuses a volume on the old `/data` path. `docker compose port` changed its answer for an unpublished port (":0",
  then "invalid IP:0"): the smoke test asks `docker port` instead. Compose carries anonymous volumes over on
  `--force-recreate`, so only `down` and `up` proves data is in the named volume. Run the disk dry and Docker builds
  fail half-way: `docker builder prune -af` and deleting a stale `.build` free most of it.
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
