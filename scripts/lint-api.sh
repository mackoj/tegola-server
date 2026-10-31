#!/usr/bin/env bash
# Lints the lookup contract with Redocly's recommended rules. Needs Node (npx); the version is pinned so a Redocly
# release can't change what "valid" means without a commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
npx --yes @redocly/cli@1.25.11 lint --format=stylish api/tegola-lookup.openapi.yaml
