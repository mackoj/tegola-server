# tegola-server

The backend-for-frontend of [Tegola](https://github.com/mackoj/tegola), a private catalogue for iPhone. It answers one
question for the app: **what is this object?** From a barcode, a few words or OCR text, one at a time or 50 import rows
at once. It holds the API keys of the game, music and board-game databases so the app holds none.

It implements [`api/tegola-lookup.openapi.yaml`](api/tegola-lookup.openapi.yaml), the contract shared with the app.
The app generates its client from that file; this server generates its routes and types from the same file, with
[swift-openapi-generator](https://github.com/apple/swift-openapi-generator) on
[Hummingbird 2](https://github.com/hummingbird-project/hummingbird).

| Endpoint | Auth | What it does |
|---|---|---|
| `GET /v1/types/{type}/barcodes/{code}` | App Attest | Candidates for a barcode, best first; publicly cacheable |
| `POST /v1/types/{type}/identify` | App Attest | Candidates for words, OCR text, a catalogue number, a barcode and a photo, in any combination |
| `POST /v1/types/{type}/match` | App Attest | Up to 50 import rows → matched, ambiguous or unknown |
| `GET /v1/works/{id}` | App Attest | A work and its releases |
| `GET /v1/app-attest/challenge` | none | A single-use challenge for registering a key |
| `POST /v1/app-attest/keys` | none (the attestation is the proof) | Registers an install's App Attest key |
| `GET /v1/health` | none | Up, and which types have a source |

**Status:** milestone 2 (`docs/milestones/M2.md`). The contract, App Attest and every security control are in place
and tested; registered keys live in Postgres (D-17). No lookup source is connected yet: lookups answer "no match" and
`/health` lists no types (D-12).

## Security model, in one screen

There are no accounts, so the server can't know *who* calls; it proves *what* calls: the genuine Tegola app on a
genuine Apple device (PLAN §5).

- **App Attest.** An install registers a key once: challenge → attestation, verified against Apple's App Attest root
  (pinned), the app id, the challenge and the environment. Then every call carries an assertion over method,
  path-with-query, timestamp and body hash. The server checks the signature, that the counter strictly increased (one
  use per assertion) and that the timestamp is within 5 minutes.
- **Production refuses debug tokens**, in its configuration and on the wire (403 to any request carrying one).
- **Limits** before any work: body cap (256 KiB, 3 MiB for identify's photo; 413), per-IP and per-key token buckets (429 with `Retry-After`), a
  stricter bucket for registration, idle-connection timeout, bounded in-memory tables.
- **Validation** of every pattern, length and range in the contract, unknown JSON keys refused.
- **Errors** are RFC 9457 problem documents with fixed titles: nothing internal, nothing echoed.
- **Logs** carry the route template, status and duration. Never bodies, queries, OCR text, key ids or IP addresses.
- **Headers** on every response: HSTS, `nosniff`, `default-src 'none'` CSP, `no-referrer`, `DENY` framing,
  `Cache-Control: no-store` except the barcode lookup.
- **TLS** is terminated by the reverse proxy in front (Caddy or similar); the server binds loopback by default.

## Run it

Needs Swift 6.4 (Xcode 27 on the Mac, or the `swift:6.4-noble` image on Linux).

```sh
git clone https://github.com/mackoj/tegola-server.git && cd tegola-server
scripts/run.sh --mock           # a development server with mock data: no keys, no network (mocks/README.md)
scripts/run.sh                  # the real sources, with the keys you put in .env.local
```

`scripts/run.sh`:
- writes `.env.local` on its first run: a debug token, and the source keys to fill in;
- builds, prints the URL and `curl` lines to try, and the two values to put in the app's Xcode scheme
  (`TEGOLA_LOOKUP_URL`, `TEGOLA_DEBUG_TOKEN`);
- shows the log as it runs: each request, and at debug level which sources each lookup asked, what they answered
  or why they failed, and how long it took (`--quiet` keeps requests and warnings only). The log is also written to
  `build/server.log`.

Ctrl-C stops it. To reach it from an iPhone on the same network, set `TEGOLA_HOST=0.0.0.0` in `.env.local`: the
script then prints the Mac's address for the scheme. If the app refuses plain `http` to that address, its Debug
`Info.plist` needs `NSAllowsLocalNetworking`.

```sh
scripts/test.sh                 # build and test → build/test-summary.md (TEGOLA_TEST_DATABASE_URL adds Postgres)
scripts/ci.sh                   # the full gate → build/ci-summary.md
```

In a cloud session without Swift: `scripts/cloud-toolchain.sh install`, then `scripts/cloud-toolchain.sh run
scripts/ci.sh` (tasks/HANDOFF.md).

## Configuration

Everything comes from the environment. A missing or unsafe value stops the server before it binds a port (exit 78);
a failure after that, such as a database that can't be reached or migrated within 60 s, stops it with exit 1. Both
log the reason first.

| Variable | Default | Meaning |
|---|---|---|
| `TEGOLA_APP_ID` | (required) | `<TeamID>.fr.macko.tegola`, the App Attest relying party |
| `TEGOLA_ENVIRONMENT` | `production` | `production` accepts production App Attest keys only; `development` also accepts development keys and the debug token |
| `TEGOLA_DEBUG_TOKEN` | unset | Development only, ≥ 32 characters; refused in production |
| `TEGOLA_HOST` | `127.0.0.1` | Listen address |
| `TEGOLA_PORT` | `8080` | Listen port |
| `TEGOLA_TRUSTED_PROXY_HOPS` | `0` | Reverse proxies that append to `X-Forwarded-For`; 0 ignores the header |
| `TEGOLA_DATABASE_URL` | (required in production) | `postgres://user:password@host:5432/db?sslmode=verify-full` (`require`, or `disable` on a private network; `sslrootcert=/path` for a provider's CA). Without it, a development server keeps keys in memory |
| `TEGOLA_MUSICBRAINZ_CONTACT` | unset | Turns music on (MusicBrainz): a contact URL or e-mail for its User-Agent |
| `TEGOLA_IGDB_CLIENT_ID`, `TEGOLA_IGDB_CLIENT_SECRET` | unset | Turn IGDB on for video games: a Twitch application's credentials. Both or neither |
| `TEGOLA_SCREENSCRAPER_DEV_ID`, `TEGOLA_SCREENSCRAPER_DEV_PASSWORD` | unset | Turn ScreenScraper on for video games. Both or neither; `TEGOLA_SCREENSCRAPER_USER` and `_PASSWORD` add a member's quota |
| `TEGOLA_BGG_TOKEN` | unset | Turns board games on (BoardGameGeek XML API bearer token) |
| `TEGOLA_WIKIDATA_CONTACT` | unset | Turns Wikidata on: `thing`, and the fallback for music, video games and board games (D-26). A contact URL or e-mail for its User-Agent |
| `TEGOLA_MOCKS` | unset | Development only: mock mode, from this catalogue file (`mocks/catalogue.json`; D-28). Replaces the sources; refused beside their settings and in production |
| `LOG_LEVEL` | `info` | swift-log level. `debug` adds what each lookup asked and got (D-28) |

## Deploy

A Docker Compose stack: Caddy (TLS, Let's Encrypt) in front of the server, which publishes no port and runs
read-only, unprivileged and without capabilities. `docs/DEPLOY.md` is the runbook and the go-live checklist.

```sh
cp deploy/env.example .env      # fill in; TEGOLA_DOMAIN=localhost for a local rehearsal
docker compose up -d --build
scripts/docker-smoke.sh          # builds the image and checks it, then the stack over HTTPS
```

Run one instance: keys are in Postgres (D-17), but rate limits are still in memory, per instance (D-9).

## Layout

```
api/tegola-lookup.openapi.yaml   the contract (a copy of tegola's; scripts/sync-contract.sh)
Sources/AppAttest                CBOR reader, attestation and assertion verification, Apple's pinned root
Sources/TegolaServer             generated routes and types, handlers, middlewares, configuration, stores
Sources/tegola-server            main: configuration, logging, run
Tests/AppAttestTestSupport       a fake App Attest CA and device
Tests/AppAttestTests             verification, CBOR, the pinned root
Tests/TegolaServerTests          security, contract and configuration tests over HTTP
docs/                            PLAN (spec), DECISIONS, milestone reports
tasks/                           plan, todo, HANDOFF
deploy/                          Caddyfile, env.example
docker-compose.yml               Caddy + server
scripts/                         test, ci, docker-smoke, sync-contract, lint-api, secret-scan, cloud-toolchain
```

### Dependencies

| Package | Used for |
|---|---|
| [hummingbird-project/hummingbird](https://github.com/hummingbird-project/hummingbird) 2 | HTTP server, router, middleware, test client |
| [swift-server/swift-openapi-hummingbird](https://github.com/swift-server/swift-openapi-hummingbird) | The generated server on Hummingbird |
| [apple/swift-openapi-generator](https://github.com/apple/swift-openapi-generator), [swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime) | Types and routes from the contract |
| [apple/swift-crypto](https://github.com/apple/swift-crypto) | SHA-256, P-256 ECDSA |
| [apple/swift-certificates](https://github.com/apple/swift-certificates), [swift-asn1](https://github.com/apple/swift-asn1) | The attestation's certificate chain and nonce extension |
| [apple/swift-log](https://github.com/apple/swift-log) | Logging |
| [vapor/postgres-nio](https://github.com/vapor/postgres-nio), [apple/swift-nio-ssl](https://github.com/apple/swift-nio-ssl), [swift-server/swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | Postgres client (keys and challenges), its TLS, its lifecycle |

Versions are pinned in `Package.resolved`. Every target builds in the Swift 6 language mode with `ExistentialAny`,
`InternalImportsByDefault` and `MemberImportVisibility` on, like tegola's packages.

## Project docs

- `docs/PLAN.md`: the specification. `docs/DECISIONS.md`: how it's read where it's unclear.
- `tasks/HANDOFF.md`: where things stand, read first.
- The app side: tegola's `docs/PLAN.md` §7 (lookup and the queue).
