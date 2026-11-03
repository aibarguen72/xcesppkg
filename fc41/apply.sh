#!/bin/bash
# apply.sh — swap the FC44-built binaries of an installed xcespkg for the
# Fedora 41 builds in this bundle (same sources and versions as the
# installed xcespkg; see BUNDLE_VERSION next to this script).  Schema,
# rules, docs and scripts of the installed package are kept.
#
# The bundle is built in a fedora:41 container (xcesppkg/arm64/build.sh
# run inside a fedora:41 image) for hosts whose glibc is too old for the
# release binaries, e.g. hulk (FC41).
#
# Usage:  sudo ./apply.sh            (check + install + restart xcesp)
#         sudo ./apply.sh --check    (only check that the host can run them)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAINSW=/var/xcesp/mainsw
BINS="xcespserver xcespcli xcespproc xcespwdog"

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
[ -f "$MAINSW/VERSION" ] || { echo "$MAINSW/VERSION missing — is xcespkg installed?" >&2; exit 1; }
echo "installed: $(head -1 "$MAINSW/VERSION")"
[ -f "$HERE/BUNDLE_VERSION" ] && echo "bundle:    $(head -1 "$HERE/BUNDLE_VERSION")"

# 1. Every binary must resolve all its shared libraries on this host.
bad=0
for b in $BINS xcesp-ip; do
    miss=$(ldd "$HERE/bin/$b" 2>&1 | grep -E "not found|version .* not found" || true)
    if [ -n "$miss" ]; then echo "MISSING for $b:"; echo "$miss"; bad=1; fi
done
[ $bad = 0 ] || { echo "host lacks libraries above — install them (dnf) and rerun" >&2; exit 1; }
echo "library check OK"
[ "${1:-}" = "--check" ] && exit 0

# 2. Replace the binaries in mainsw; xcesp-activate (ExecStartPre) copies
#    them to /usr/bin and re-applies the xcespproc file capabilities.
for b in $BINS; do
    install -o root -g root -m 0755 "$HERE/bin/$b" "$MAINSW/bin/$b"
    echo "  $MAINSW/bin/$b"
done
mkdir -p "$MAINSW/lib/xcesp" /usr/lib/xcesp
install -o root -g root -m 0755 "$HERE/bin/xcesp-ip" "$MAINSW/lib/xcesp/xcesp-ip"
install -o root -g root -m 0755 "$HERE/bin/xcesp-ip" /usr/lib/xcesp/xcesp-ip
setcap cap_net_admin,cap_net_raw=ep /usr/lib/xcesp/xcesp-ip || true

# 3. Restart and show the result.
systemctl restart xcesp
sleep 8
systemctl --no-pager status xcesp | sed -n 1,20p

# 4. Verify that the running copies are the bundle's binaries.  The XCESP
#    binaries have no --version flag, so compare by content: /usr/bin/<b>
#    (copied there by xcesp-activate) must be byte-identical to bin/<b>.
echo "verify (running copy == bundle):"
fail=0
for b in $BINS xcesp-ip; do
    case $b in xcesp-ip) inst=/usr/lib/xcesp/xcesp-ip ;; *) inst=/usr/bin/$b ;; esac
    want=$(sha256sum "$HERE/bin/$b" | cut -d' ' -f1)
    have=$(sha256sum "$inst" 2>/dev/null | cut -d' ' -f1 || true)
    if [ "$want" = "$have" ]; then
        printf '  %-12s OK      %s\n' "$b" "${want:0:16}"
    else
        printf '  %-12s DIFFERS %s (bundle %s)\n' "$b" "${have:0:16}" "${want:0:16}"
        fail=1
    fi
done
[ $fail = 0 ] || { echo "some binaries do not match the bundle — check xcesp-activate output" >&2; exit 1; }
echo "all binaries match the bundle"
