#!/usr/bin/env bash
# Builds and tests the server: every target, or one suite.
#   scripts/test.sh                      # everything
#   scripts/test.sh SecurityTests        # one suite or test (swift test --filter)
# Writes build/test-summary.md. On the Mac it uses Xcode's toolchain (xcrun), never swiftly's; elsewhere `swift` on
# PATH (Linux CI, a cloud session through scripts/cloud-toolchain.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
if command -v xcrun >/dev/null 2>&1; then SWIFT=(xcrun swift); else SWIFT=(swift); fi
SUMMARY=build/test-summary.md
LOG=build/test.log
echo "# Test summary ($(date '+%Y-%m-%d %H:%M'), $("${SWIFT[@]}" --version 2>&1 | head -1))" > "$SUMMARY"
ARGS=()
[[ $# -ge 1 ]] && ARGS=(--filter "$1")
if "${SWIFT[@]}" test "${ARGS[@]}" >"$LOG" 2>&1; then
  # Swift Testing prints one "Test run with N tests in M suites passed" line per test bundle.
  totals=$(grep -Eo 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG" |
    awk '{ tests += $4; suites += $7 } END { printf "%d tests in %d suites passed", tests, suites }')
  echo "- ✅ $totals" >> "$SUMMARY"
  STATUS=0
else
  echo "- ❌ failed, see $LOG" >> "$SUMMARY"
  grep -E "error:|✘" "$LOG" | sort -u | head -30 | sed 's/^/    /' >> "$SUMMARY"
  STATUS=1
fi
cat "$SUMMARY"
exit $STATUS
