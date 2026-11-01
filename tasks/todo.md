# Todo

## M1 · foundation (branch `claude/tegola-hummingbird-bff-9ad714`)

Plan: `tasks/plan.md`, M1. Report: `docs/milestones/M1.md`.

- [x] T1.1 Skeleton
- [x] T1.2 App Attest verification, with a fake CA and device for tests
- [x] T1.3 Generated server, handlers, validation, no sources yet
- [x] T1.4 Security controls (configuration, edge, App Attest middleware, cache policy, rate limits, stores, problems)
- [x] T1.5 Contract wording for the signed bytes and the challenge (tegola PR, then synced)
- [x] T1.6 Tooling: scripts, CI, Dockerfile
- [x] T1.7 Docs
- [x] T1.8 tegola's CLAUDE.md, DECISIONS and HANDOFF point here
- [x] Separate review agent over the M1 branch (ran over M1 and M2 together, D-19)

## M2 · persistence (Postgres, D-17)

Plan: `tasks/plan.md`, M2. Report: `docs/milestones/M2.md`.

- [x] T2.1 Store protocols, failures as 503, `degraded` health
- [x] T2.2 `PostgresStore` and migrations
- [x] T2.3 `TEGOLA_DATABASE_URL`, required in production
- [x] T2.4 Client as a service, migrations before serving
- [x] T2.5 Postgres in Compose and CI, smoke checks
- [x] T2.6 Undeclared 503s keep their headers and body (D-18)
- [x] T2.7 Docs and report
- [x] Separate review agents over M1 and M2 (security; correctness and contract). Fixes: D-19, PR #5
- [x] Merge tegola PR #10 (revoked key, tegola D-55)
- [x] Merge tegola-server PR #5 once its CI is green
- [x] Pin images by digest and actions by SHA, `scripts/pin-check.sh` (D-20)
- [x] Postgres 18 everywhere, its new data path, a persistence smoke check (D-21)

## M3 · first sources

Plan: `tasks/plan.md`, M3. Report: `docs/milestones/M3.md`. Sources chosen by the owner on 2026-11-01 (D-22).

- [x] T3.1 Infrastructure: transport, pace, breaker, timeouts, cache, composite
- [x] T3.2 MusicBrainz (music: barcode and words)
- [x] T3.3 IGDB (video games: words)
- [x] T3.4 ScreenScraper (video games: words)
- [x] T3.5 BoardGameGeek (board games: words)
- [x] T3.6 Configuration
- [x] T3.7 Docs and report
- [ ] T3.8 Each source described by an OpenAPI file (the supplier's, or ours) with a generated client; one protocol for
  any data supplier (owner, 2026-11-01; HANDOFF item 1)
- [ ] Docker smoke test with the new dependency, recorded in the report
- [ ] Separate review agent over M3
- [ ] Owner: register the keys (D-22); then re-record the fixtures from the live APIs

## Open follow-ups

- Owner: check the pinned root's fingerprint against apple.com once (D-4).
- Owner: answer PLAN §9 (sources, hosting, Team ID, shared caches; persistence answered: Postgres), deferred until release
  (`docs/DEPLOY.md`, go-live checklist).
- [x] Docker: image built and checked, Caddy + server stack, `docs/DEPLOY.md`, `scripts/docker-smoke.sh`, CI job
  (D-16).
