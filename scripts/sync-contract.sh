#!/usr/bin/env bash
# The contract's home is mackoj/tegola, api/tegola-lookup.openapi.yaml (DECISIONS D-1). This repo keeps a copy.
#   scripts/sync-contract.sh                  # copy tegola's file over ours (from $TEGOLA_DIR, default ../tegola)
#   scripts/sync-contract.sh --check          # fail if they differ. With no tegola checkout it passes with a note
#                                             # locally, and fails in CI (CI=true) or when TEGOLA_DIR was given, so a
#                                             # missing checkout can't look like "in sync" (D-19)
# After a copy, build: the generated server changes with the contract, and the compiler lists what to implement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SOURCE="${TEGOLA_DIR:-../tegola}/api/tegola-lookup.openapi.yaml"
OURS=api/tegola-lookup.openapi.yaml
if [[ ! -f "$SOURCE" ]]; then
  echo "tegola's contract not found at $SOURCE (set TEGOLA_DIR); nothing to compare"
  if [[ "${1:-}" == "--check" && "${CI:-}" != "true" && -z "${TEGOLA_DIR:-}" ]]; then exit 0; fi
  exit 1
fi
if [[ "${1:-}" == "--check" ]]; then
  if cmp -s "$SOURCE" "$OURS"; then echo "contract in sync with $SOURCE"; exit 0; fi
  diff -u "$OURS" "$SOURCE" | head -60
  echo "contract differs from $SOURCE: run scripts/sync-contract.sh"
  exit 1
fi
cp "$SOURCE" "$OURS"
git --no-pager diff --stat -- "$OURS"
