#!/bin/bash
# save.sh — export the built xcesp-modem image to a docker-loadable tar.
#
# The target device runs `docker load` (not podman), so we save in
# docker-archive format.  Output: xcesp-modem-<VERSION>-arm64.tar
# next to this script — scp it to the target and hand off to load.sh.
set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$DOCKER_DIR/.." && pwd)"

VERSION=$(grep '^PRJVERSION' "$PKG_DIR/PROJECT" | awk -F':=' '{print $2}' | tr -d ' ')
TAG="xcesp-modem:${VERSION}-arm64"
OUT="$DOCKER_DIR/xcesp-modem-${VERSION}-arm64.tar"

echo "==> saving $TAG -> $OUT"
podman save --format=docker-archive -o "$OUT" "$TAG"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
sha256sum "$OUT"
