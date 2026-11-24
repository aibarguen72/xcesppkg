#!/bin/bash
# build-debian.sh — XCESPKG for Debian 13 (trixie) x86_64.
#
# Usage: debian/build-debian.sh [<x86 tarball>]
#   default tarball: xcespkg-<PRJVERSION>.tar.gz next to PROJECT (run `make`
#   first).  Output: xcespkg-debian-<PRJVERSION>.tar.gz.
#
# The binaries are rebuilt in a debian:trixie podman container (image
# localhost/xcesp-debian-builder, from debian/Dockerfile) from a copy of the
# xsrc tree, with the same build script as ARM64 (arm64/build.sh: hermetic
# wipe, 4 binaries + xcesp-ip).  Everything else — schema, rules, docs, web,
# wheels, scripts — comes unchanged from the x86 tarball, so the two packages
# differ only in bin/ and VERSION.
#
# Debian differences: no NETCONF (sysrepo is not packaged on Debian 13); the
# bundled offline Python wheels are built for the Fedora build host's python,
# so on Debian the web interface's aiohttp installs from the package index.
set -euo pipefail

PKGDIR="$(cd "$(dirname "$0")/.." && pwd)"
XSRC="$(cd "$PKGDIR/.." && pwd)"
VERSION="$(grep '^PRJVERSION' "$PKGDIR/PROJECT" | awk -F':=' '{gsub(/ /,"",$2); print $2}')"
X86_TGZ="${1:-$PKGDIR/xcespkg-$VERSION.tar.gz}"
IMAGE=localhost/xcesp-debian-builder:latest
WORK="${XCESP_DEBIAN_WORK:-$PKGDIR/build/debian}"
OUT="${XCESP_DEBIAN_OUT:-$PKGDIR/xcespkg-debian-$VERSION.tar.gz}"

[ -f "$X86_TGZ" ] || { echo "x86 tarball not found: $X86_TGZ (run make)" >&2; exit 1; }
command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }

echo "==> builder image"
if ! podman image exists "$IMAGE"; then
    podman build -t "$IMAGE" -f "$PKGDIR/debian/Dockerfile" "$PKGDIR/debian"
fi

echo "==> source copy in $WORK/src"
mkdir -p "$WORK/src"
rsync -a --delete --links \
    --exclude='**/build/' --exclude='**/bin/' --exclude='**/lib/' --exclude='**/testbin/' \
    --exclude='.git/' --exclude='xcespqa/' --exclude='reports/' \
    --exclude='node_modules/' --exclude='*.tar.gz' --exclude='*.tgz' --exclude='*.tar' \
    "$XSRC/" "$WORK/src/"

echo "==> build in debian:trixie"
podman run --rm -v "$WORK/src:/src:Z" "$IMAGE" bash /src/xcesppkg/arm64/build.sh

echo "==> package"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
find "$STAGE" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar xzf "$X86_TGZ" -C "$STAGE"
SRCDIR="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -1)"
PKG_NAME="xcespkg-debian-$VERSION"
mv "$SRCDIR" "$STAGE/$PKG_NAME"
D="$STAGE/$PKG_NAME"
for b in xcespserver xcespcli xcespproc xcespwdog; do
    install -m 0755 "$WORK/src/$b/bin/$b" "$D/bin/$b"
done
install -m 0755 "$WORK/src/xcesppkg/bin/xcesp-ip" "$D/bin/xcesp-ip"
glibc=$(objdump -T "$D"/bin/* 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1)
{
    head -1 "$D/VERSION" | sed 's/$/ (debian 13 x86_64)/'
    tail -n +2 "$D/VERSION"
    echo ""
    echo "Binaries built in debian:trixie (needs ${glibc:-GLIBC ?}); no NETCONF (no sysrepo on Debian 13)."
} > "$D/VERSION.new"
mv "$D/VERSION.new" "$D/VERSION"
tar czf "$OUT" -C "$STAGE" "$PKG_NAME"
echo "==> $OUT ($(du -h "$OUT" | cut -f1)), binaries need ${glibc:-?}"
sha256sum "$OUT"
