#!/bin/bash
# build.sh — build (and optionally save) the generic XCESP container image.
#
# Usage: container/build.sh [<xcespkg-debian tarball>] [--save]
#   default tarball: ../xcespkg-debian-<PRJVERSION>.tar.gz (debian/build-debian.sh)
#   image:  xcesp:<version>     --save: also xcesp-<version>-x86_64.tar
#           (docker-archive, for `xcesp-ctr.sh load` on another host)
set -euo pipefail

CTR_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$CTR_DIR/.." && pwd)"
VERSION="$(grep '^PRJVERSION' "$PKG_DIR/PROJECT" | awk -F':=' '{gsub(/ /,"",$2); print $2}')"
TARBALL=""; SAVE=0
for a in "$@"; do
    case "$a" in --save) SAVE=1 ;; *) TARBALL="$a" ;; esac
done
TARBALL="${TARBALL:-$PKG_DIR/xcespkg-debian-$VERSION.tar.gz}"
[ -f "$TARBALL" ] || { echo "tarball not found: $TARBALL (run debian/build-debian.sh)" >&2; exit 1; }
VERSION_TAG="${XCESP_CTR_TAG:-$VERSION}"
TAG="xcesp:$VERSION_TAG"

# Build context = this directory + the tarball (bare file name for COPY).
NAME="$(basename "$TARBALL")"
cp "$TARBALL" "$CTR_DIR/$NAME"
trap 'rm -f "$CTR_DIR/$NAME"' EXIT
echo "==> building $TAG from $NAME"
podman build --build-arg "XCESPPKG_TARBALL=$NAME" -t "$TAG" "$CTR_DIR"
podman images --filter "reference=$TAG"

if [ "$SAVE" = 1 ]; then
    OUT="$PKG_DIR/xcesp-$VERSION_TAG-x86_64.tar"
    echo "==> saving $TAG -> $OUT"
    podman save --format=docker-archive -o "$OUT" "$TAG"
    echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
    sha256sum "$OUT"
fi
