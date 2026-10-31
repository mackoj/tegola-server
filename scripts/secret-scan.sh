#!/usr/bin/env bash
# Fails if a tracked file looks like it contains a credential.
# A deliberately fake secret in a test is allowed when `TEGOLA-TEST-SENTINEL` is on its line or the line above.
set -uo pipefail
cd "$(dirname "$0")/.."
PATTERNS='(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{32,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
HITS=""
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"
  if sed -n "$((line > 1 ? line - 1 : 1)),${line}p" "$file" | grep -q "TEGOLA-TEST-SENTINEL"; then continue; fi
  HITS+="$hit"$'\n'
done < <(git ls-files -z | xargs -0 grep -nIE "$PATTERNS" -- 2>/dev/null || true)
if [[ -n "$HITS" ]]; then printf '%s' "$HITS"; exit 1; fi
echo "no secrets found"
