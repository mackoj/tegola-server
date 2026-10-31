#!/usr/bin/env bash
# The full gate, as CI runs it: tests, format lint, contract lint, contract drift, secret scan.
# Writes build/ci-summary.md. Contract lint needs Node (npx); it's skipped with a note when Node is missing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
if command -v xcrun >/dev/null 2>&1; then SWIFT=(xcrun swift); else SWIFT=(swift); fi
SUMMARY=build/ci-summary.md
echo "# CI summary ($(date '+%Y-%m-%d %H:%M'))" > "$SUMMARY"
STATUS=0
step() { # $1 name, rest: command
  local name="$1"; shift
  if "$@" >"build/ci-$name.log" 2>&1; then echo "- ✅ $name" >> "$SUMMARY"
  else echo "- ❌ $name, see build/ci-$name.log" >> "$SUMMARY"; STATUS=1; fi
}
step tests scripts/test.sh
step format "${SWIFT[@]}" format lint --strict --recursive Sources Tests Package.swift
if command -v npx >/dev/null 2>&1; then step contract-lint scripts/lint-api.sh
else echo "- ⏭ contract-lint (no Node)" >> "$SUMMARY"; fi
step contract-drift scripts/sync-contract.sh --check
step secrets scripts/secret-scan.sh
cat "$SUMMARY"
exit $STATUS
