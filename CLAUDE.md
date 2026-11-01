# tegola-server: working notes for Claude

## What this is
The backend-for-frontend of the Tegola iPhone app (`mackoj/tegola`): one Swift server, Hummingbird 2, that
implements `api/tegola-lookup.openapi.yaml`. It identifies objects from barcodes and words and matches import rows,
for an app that has no accounts and proves itself with App Attest. Both repos are the owner's; when work here needs a
change in tegola (or the reverse), make it there too, on its own branch and PR, following tegola's `CLAUDE.md`.

## Token & Execution Policy
- Aggressively preserve context: summarize and clear history between distinct phases.
- Offload heavy tasks, multi-file analysis and reviews to cloud agents. Everything here builds and tests on Linux, so a
  cloud session can do the whole job; `tasks/HANDOFF.md` says how to get a Swift toolchain there
  (`scripts/cloud-toolchain.sh`).
  - Each prompt must stand alone. Point it at the repo docs, and restate the attribution rule (no Claude trailers or
    footers).
- Continuously evaluate the test harness to reduce boilerplate and prompt token waste.

## Project rules
- **Spec:** `docs/PLAN.md` is the specification, and `docs/DECISIONS.md` records its interpretations (`D-n`). Product
  decisions are tegola's (its `docs/PLAN.md`, `docs/DECISIONS.md`, and clctn's `PD-###` log, cited by id).
- **The contract** lives in tegola (`api/tegola-lookup.openapi.yaml`); this repo keeps a copy at the same path, and
  `Sources/TegolaServer/openapi.yaml` links to it. A contract change is made in tegola first, then
  `scripts/sync-contract.sh` copies it here (D-1). Never edit the copy alone: `scripts/ci.sh` fails on drift.
- **Process:** `tasks/plan.md` and `tasks/todo.md` track milestones and tasks. Each milestone ends with a report in
  `docs/milestones/M<n>.md`. `tasks/HANDOFF.md` is the state of the work for whoever picks it up next: read it first,
  update it last.
- **Toolchain:** on the Mac, `xcrun swift …` (swiftly's `swift` breaks nothing here, but the scripts use `xcrun` for
  parity with tegola). On Linux and in cloud sessions, `swift`.
- **Run:** `scripts/run.sh [--mock] [--quiet]`, a development server with its log in the terminal (D-28); `--mock`
  answers from `mocks/` and made-up releases, for testing the app.
- **Tests:** `scripts/test.sh [<Suite>]` (set `TEGOLA_TEST_DATABASE_URL` to run the store tests on Postgres too, as
  CI does); `scripts/ci.sh` runs the full gate (tests, `swift format lint --strict`, contract lint, contract drift,
  secret scan, pins). `scripts/docker-smoke.sh` checks the image and the Caddy stack. CI runs both on every push.
- **Workflow:** one task, one commit or PR into the milestone branch; a separate review agent before a milestone is
  marked ready; a milestone branch merges into `main` once its report is written.
- **Attribution:** commits and PRs carry no Claude trailers or footers.

## Secure by design (PLAN §5): rules every change keeps
- **Secured by default.** Every operation needs an App Attest assertion unless its id is in
  `AppAttestMiddleware.publicOperations`. Adding an operation never makes it public by accident.
- **Fail closed.** A missing or unsafe setting stops the server at start (`ServerConfiguration.validate`). Production
  is the default environment; a debug token is refused in production, in the config and on the wire.
- **Validate everything the generator doesn't** (`Validation`): patterns, lengths, ranges, item counts. Bodies are
  capped before decoding.
- **Say nothing on errors.** Every error is a problem document with a fixed title (`ProblemKind`); no internal detail,
  no echo of the input. Auth failures look alike, except the two the contract names (unknown key, revoked key).
- **Log shape, never content.** Route template, status, duration, reason codes. Never a body, a query, OCR text, a
  key id, an IP address or a header value.
- **No secrets in the repo.** Source API keys come from the environment; `scripts/secret-scan.sh` guards the tree. A
  deliberately fake secret in a test carries `TEGOLA-TEST-SENTINEL`.
- **A security check gets a test** that sends the attack and expects the refusal (`SecurityTests`,
  `AppAttestVerifierTests`).
