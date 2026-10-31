#!/usr/bin/env bash
# A Swift toolchain in a cloud session that has none (tasks/HANDOFF.md, "Toolchain in a cloud session").
# download.swift.org is blocked there and Docker Hub rate-limits the shared address; Google's Docker Hub mirror works.
#   scripts/cloud-toolchain.sh install        # once: unpack swift:6.4.2-noble into /opt/swiftroot (needs root)
#   scripts/cloud-toolchain.sh run <command>  # run a command in the repo inside that root, e.g. `run scripts/ci.sh`
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTROOT=/opt/swiftroot
IMAGE_TAG=6.4.2-noble
REGISTRY=https://mirror.gcr.io/v2/library/swift
CA_BUNDLE="${SSL_CERT_FILE:-/root/.ccr/ca-bundle.crt}"

install() {
  mkdir -p "$SWIFTROOT"
  local index digest layers tmp
  index=$(curl -fsS -H 'Accept: application/vnd.oci.image.index.v1+json' "$REGISTRY/manifests/$IMAGE_TAG")
  digest=$(python3 -c 'import json,sys; print(next(m["digest"] for m in json.load(sys.stdin)["manifests"] if m["platform"]["architecture"]=="amd64"))' <<<"$index")
  layers=$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$REGISTRY/manifests/$digest" |
    python3 -c 'import json,sys; [print(l["digest"]) for l in json.load(sys.stdin)["layers"]]')
  tmp=$(mktemp -d)
  for layer in $layers; do
    echo "layer $layer"
    curl -fsSL "$REGISTRY/blobs/$layer" -o "$tmp/layer.tgz"
    tar -xzf "$tmp/layer.tgz" -C "$SWIFTROOT" --no-same-owner 2>/dev/null || true
  done
  rm -rf "$tmp"
  echo "installed: $(chroot "$SWIFTROOT" swift --version 2>&1 | head -1)"
}

run() {
  local work="$SWIFTROOT/work/$(basename "$ROOT")"
  mkdir -p "$work" "$SWIFTROOT/proc" "$SWIFTROOT/dev"
  mountpoint -q "$SWIFTROOT/proc" || mount -t proc proc "$SWIFTROOT/proc"
  mountpoint -q "$SWIFTROOT/dev" || mount --bind /dev "$SWIFTROOT/dev"
  mountpoint -q "$work" || mount --bind "$ROOT" "$work"
  # The tegola checkout next to this one, for scripts/sync-contract.sh --check.
  if [[ -d "$ROOT/../tegola" ]]; then
    mkdir -p "$SWIFTROOT/work/tegola"
    mountpoint -q "$SWIFTROOT/work/tegola" || mount --bind "$ROOT/../tegola" "$SWIFTROOT/work/tegola"
  fi
  cp /etc/resolv.conf "$SWIFTROOT/etc/resolv.conf"
  [[ -f "$CA_BUNDLE" ]] && cp "$CA_BUNDLE" "$SWIFTROOT/etc/ssl/certs/session-ca.crt"
  chroot "$SWIFTROOT" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/root \
    HTTPS_PROXY="${HTTPS_PROXY:-}" HTTP_PROXY="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-}" \
    http_proxy="${HTTP_PROXY:-}" NO_PROXY="${NO_PROXY:-}" TEGOLA_TEST_DATABASE_URL="${TEGOLA_TEST_DATABASE_URL:-}" \
    SSL_CERT_FILE=/etc/ssl/certs/session-ca.crt GIT_SSL_CAINFO=/etc/ssl/certs/session-ca.crt \
    bash -c "cd /work/$(basename "$ROOT") && $*"
}

case "${1:-}" in
  install) install ;;
  run) shift; run "$@" ;;
  *) echo "usage: $0 install | run <command>"; exit 2 ;;
esac
