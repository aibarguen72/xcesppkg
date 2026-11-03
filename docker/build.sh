#!/bin/bash
# build.sh — build the xcesp-modem arm64 image via podman + qemu.
#
# Usage: ./build.sh [<xcesppkg-arm64-tarball>]
#   Default tarball: ../xcespkg-arm64-<PRJVERSION>.tgz where PRJVERSION
#   is read from ../PROJECT.
#
# Requires:
#   * podman with buildx/OCI support (any recent version)
#   * qemu-user-static registered in /proc/sys/fs/binfmt_misc/qemu-aarch64
#     (Fedora ships this via the qemu-user-static package).
#
# Product: local podman image tagged xcesp-modem:<VERSION>-arm64.
set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$DOCKER_DIR/.." && pwd)"

VERSION=$(grep '^PRJVERSION' "$PKG_DIR/PROJECT" | awk -F':=' '{print $2}' | tr -d ' ')

TARBALL="${1:-$PKG_DIR/xcespkg-arm64-${VERSION}.tgz}"
[ -f "$TARBALL" ] || {
    echo "tarball not found: $TARBALL" >&2
    echo "run /build-arm64 first, or pass a path" >&2
    exit 1
}

# Copy tarball next to the Dockerfile so the COPY line is a bare
# filename (no build-context walking of the whole xcesppkg tree).
TARBALL_NAME=$(basename "$TARBALL")
cp -f "$TARBALL" "$DOCKER_DIR/$TARBALL_NAME"
trap 'rm -f "$DOCKER_DIR/$TARBALL_NAME"' EXIT

TAG="xcesp-modem:${VERSION}-arm64"
echo "==> building $TAG from $TARBALL_NAME"
podman build \
    --platform=linux/arm64 \
    --build-arg XCESPPKG_TARBALL="$TARBALL_NAME" \
    -t "$TAG" \
    "$DOCKER_DIR"

echo "==> built $TAG"
podman images "$TAG"
