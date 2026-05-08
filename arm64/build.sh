#!/bin/bash
# build.sh — runs INSIDE the ARM64 Docker container.
# Builds the 4 XCESP binaries natively for aarch64.
# Sources are mounted at /src (mirrored from the local xsrc/ tree).
set -e

SRCROOT=/src

echo "=== ARM64 build started on $(uname -m) ==="

for proj in xcespserver xcespcli xcespproc xcespwdog; do
    echo ""
    echo "=== Building $proj ==="
    # Clean first so that PROJECT version bumps and other changes that don't
    # invalidate .o file mtimes (e.g. -DPRJVERSION compile flag) still force
    # a full rebuild — otherwise stale .o files from prior runs leak through.
    make -C "$SRCROOT/$proj" clean || true
    make -C "$SRCROOT/$proj" all
done

echo ""
echo "=== All ARM64 builds complete ==="
echo "Binaries:"
for proj in xcespserver xcespcli xcespproc xcespwdog; do
    bin="$SRCROOT/$proj/bin/$proj"
    if [ -f "$bin" ]; then
        echo "  $bin ($(du -sh "$bin" | cut -f1))"
    else
        echo "  ERROR: $bin not found"
        exit 1
    fi
done
