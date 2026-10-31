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
- [ ] Separate review agent over the M1 branch before merge

## M2 · persistence

Broken down at the start of M2 (`tasks/plan.md`).

## Open follow-ups

- Owner: check the pinned root's fingerprint against apple.com once (D-4).
- Owner: answer PLAN §9 (sources, hosting, persistence, Team ID, shared caches), deferred until release
  (`docs/DEPLOY.md`, go-live checklist).
- [x] Docker: image built and checked, Caddy + server stack, `docs/DEPLOY.md`, `scripts/docker-smoke.sh`, CI job
  (D-16).
