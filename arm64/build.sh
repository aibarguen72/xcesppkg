#!/bin/bash
# build.sh — runs INSIDE the ARM64 Docker container.
# Builds the 4 XCESP binaries natively for aarch64.
# Sources are mounted at /src (mirrored from the local xsrc/ tree).
set -e

SRCROOT=/src

echo "=== ARM64 build started on $(uname -m) ==="

# ---------------------------------------------------------------------------
# Hermetic cleanup of ALL build artifacts before we start.
#
# The local-side rsync uses `--exclude='**/build/' '**/lib/' '**/bin/' '**/testbin/'`
# which means stale artifacts produced on the remote in a prior run are NOT
# overwritten or deleted by `--delete`.  Combined with rsync preserving the
# source-side mtime of .cpp/.h files, this lets `make` believe a stale .o or
# .a is newer than its (just-edited) source and skip rebuilding.  Symptom is
# a successful build that links against the OLD object code — typically an
# undefined-reference error at the linker step on newly added symbols.
#
# The .o files and .a archives are owned by root (this container builds as
# root); on the host they cannot be removed without sudo.  Cleaning here is
# the only friction-free place to do it.  We wipe build/, lib/, bin/, and
# testbin/ everywhere under /src so every subsequent `make` rebuilds from
# scratch every transitive dependency (xcespconfig, xcespschema, xcespmap,
# xcesp-on-rtr, xcesp-on-pw, xcesp-on-xc, evapplication, logservice, etc.).
# Project makefiles only `make clean` themselves, not their exsrc/ deps —
# the only way to guarantee fresh transitive libs is this top-down wipe.
# ---------------------------------------------------------------------------
echo "=== Wiping stale build artifacts under $SRCROOT ==="
find "$SRCROOT" \( -name build -o -name lib -o -name bin -o -name testbin \) \
    -type d -prune -exec rm -rf {} +

# Recreate the destination dirs that the per-project `subprojects` cp step
# expects to exist (otherwise `cp -u <dep>/lib/*.a lib/` silently fails into
# /dev/null and the binary fails to link with "No rule to make target
# 'lib/libon-rtr.a'").  Just the four final projects need lib/ + bin/.
for proj in xcespserver xcespcli xcespproc xcespwdog; do
    mkdir -p "$SRCROOT/$proj/lib" "$SRCROOT/$proj/bin"
done

for proj in xcespserver xcespcli xcespproc xcespwdog; do
    echo ""
    echo "=== Building $proj ==="
    # `make clean` is redundant given the wipe above, but kept for safety:
    # makefiles may rely on it for non-obvious cleanup (e.g. removing
    # generated headers, copied-in includes, etc.).
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
