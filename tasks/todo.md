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
- [ ] Merge tegola-server PR #5 once its CI is green

## M3 · first sources

Waits on the owner's choice of sources (PLAN §9, question 1).

## Open follow-ups

- Owner: check the pinned root's fingerprint against apple.com once (D-4).
- Owner: answer PLAN §9 (sources, hosting, Team ID, shared caches; persistence answered: Postgres), deferred until release
  (`docs/DEPLOY.md`, go-live checklist).
- [x] Docker: image built and checked, Caddy + server stack, `docs/DEPLOY.md`, `scripts/docker-smoke.sh`, CI job
  (D-16).
