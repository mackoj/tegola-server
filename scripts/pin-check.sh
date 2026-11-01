#!/usr/bin/env bash
# Fails unless everything the build pulls is pinned (DECISIONS D-20): each base image (Dockerfile), Compose image
# and CI image by digest, each GitHub Action by commit SHA. An image that appears in several files must carry the same
# digest everywhere, so a Dependabot bump that misses one file fails here instead of testing one image and shipping
# another. Images built locally (`tegola-server:local`) are not pulled and are skipped.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
refs=$( {
  grep -hE '^FROM ' Dockerfile | awk '{print "Dockerfile " $2}'
  grep -hE '^\s+image: ' docker-compose.yml | awk '{print "docker-compose.yml " $2}'
  grep -hE '^\s+(container|image): ' .github/workflows/*.yml | awk '{print ".github/workflows " $2}'
} | grep -v ' tegola-server:local$')
while read -r file ref; do
  if [[ ! "$ref" =~ ^[^@]+@sha256:[0-9a-f]{64}$ ]]; then echo "$file: image not pinned by digest: $ref"; FAIL=1; fi
done <<<"$refs"
while read -r image; do
  echo "$refs" | awk -v i="$image" '{split($2, p, "@"); if (p[1] == i) print $1 ": " $2}'
  FAIL=1
done < <(echo "$refs" | awk '{print $2}' | sort -u | awk -F@ '{print $1}' | uniq -d)
while IFS= read -r line; do
  echo "action not pinned by commit SHA: ${line#*uses: }"; FAIL=1
done < <(grep -hE '^\s+- uses: |^\s+uses: ' .github/workflows/*.yml | grep -vE 'uses: [^@ ]+@[0-9a-f]{40}( # v[0-9.]+)?$')
if [[ $FAIL -eq 0 ]]; then echo "every image and action is pinned"; fi
exit $FAIL
