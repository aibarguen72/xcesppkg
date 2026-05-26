#!/bin/sh
# chrony-install.sh — extract chronyd + chronyc from a Debian .deb without
# running maintainer scripts, registering with dpkg, or installing the
# systemd unit / user account that collide with our appliance packaging.
#
# Usage: place this script in the same directory as the chrony .deb
# (typically `chrony_<version>_<arch>.deb`) and run as root:
#
#     sudo ./chrony-install.sh
#
# What it does:
#   1. Finds the chrony .deb next to the script (must be exactly one).
#   2. `dpkg-deb -x` into a scratch dir — file extraction only, no
#      maintainer scripts, no dpkg database entry, no user creation,
#      no systemd unit registration.
#   3. Installs only /usr/sbin/chronyd and /usr/bin/chronyc into the
#      live filesystem.  Everything else from the .deb (the default
#      /etc/chrony/chrony.conf, /lib/systemd/system/chrony.service,
#      AppArmor profile, etc.) is discarded — xcesp manages chronyd
#      per-namespace and reads its own conf under /run/xcesp/ntp/.
#   4. Applies the file caps xcesp-activate would otherwise apply on
#      first boot (cap_net_bind_service + cap_net_raw=ep) so chronyd
#      can bind UDP 123 and 323 inside its netns.  This step is also
#      idempotent under xcesp-activate — if you re-run that later, it
#      will just see the caps are already correct and leave the
#      binary alone.
#
# Library dependencies: chrony links libnettle/libgnutls/libtomcrypt/
# zlib depending on how the .deb was built.  If `ldd /usr/sbin/chronyd`
# reports missing shared libraries after install, extract them from
# the appropriate distro packages the same way (or `apt-get install
# --no-install-recommends libnettle8 libgnutls30` etc.).  We do NOT
# pull libs from the chrony .deb because they belong to other packages
# and would collide.
#
# Idempotency: re-running this script over an existing install
# replaces the binaries with the .deb's copies, re-applies caps,
# and leaves nothing else behind.

set -eu

# ---------------------------------------------------------------------------
# Locate the chrony .deb next to this script.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

DEB_COUNT=$(find "$SCRIPT_DIR" -maxdepth 1 -name 'chrony_*.deb' | wc -l)
if [ "$DEB_COUNT" -eq 0 ]; then
    echo "ERROR: no chrony_*.deb found alongside $0" >&2
    echo "       expected something like chrony_4.6.1-1_arm64.deb" >&2
    exit 1
fi
if [ "$DEB_COUNT" -gt 1 ]; then
    echo "ERROR: multiple chrony_*.deb files in $SCRIPT_DIR — keep only one" >&2
    find "$SCRIPT_DIR" -maxdepth 1 -name 'chrony_*.deb' >&2
    exit 1
fi
DEB=$(find "$SCRIPT_DIR" -maxdepth 1 -name 'chrony_*.deb')

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (writes /usr/sbin/chronyd, /usr/bin/chronyc)" >&2
    exit 1
fi

command -v dpkg-deb > /dev/null 2>&1 || {
    echo "ERROR: dpkg-deb not found in PATH" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Extract to a scratch dir and copy ONLY the two binaries we want.
# ---------------------------------------------------------------------------
STAGE=$(mktemp -d -t chrony-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM

echo "Extracting $(basename "$DEB") ..."
dpkg-deb -x "$DEB" "$STAGE"

# The .deb may put chronyd under /usr/sbin (Debian Bookworm and earlier) or
# /usr/sbin via merged-usr.  Probe both.  Same for chronyc.
SRC_CHRONYD=""
for c in "$STAGE/usr/sbin/chronyd" "$STAGE/sbin/chronyd"; do
    [ -x "$c" ] && SRC_CHRONYD="$c" && break
done
SRC_CHRONYC=""
for c in "$STAGE/usr/bin/chronyc" "$STAGE/bin/chronyc"; do
    [ -x "$c" ] && SRC_CHRONYC="$c" && break
done

if [ -z "$SRC_CHRONYD" ] || [ -z "$SRC_CHRONYC" ]; then
    echo "ERROR: chronyd or chronyc not found inside $(basename "$DEB")" >&2
    find "$STAGE" -name 'chronyd' -o -name 'chronyc' >&2
    exit 1
fi

# Use `install` (BSD/GNU semantics shared) — it overwrites atomically
# (creates the target via rename) so a concurrent chronyd doesn't see
# a half-written binary.
install -m 0755 -o root -g root "$SRC_CHRONYD" /usr/sbin/chronyd
install -m 0755 -o root -g root "$SRC_CHRONYC" /usr/bin/chronyc
echo "Installed /usr/sbin/chronyd"
echo "Installed /usr/bin/chronyc"

# ---------------------------------------------------------------------------
# File caps for chronyd.  Skip silently if libcap isn't installed — the
# operator can apply them later via xcesp-activate.
# ---------------------------------------------------------------------------
if command -v setcap > /dev/null 2>&1; then
    setcap cap_net_bind_service,cap_net_raw=ep /usr/sbin/chronyd
    echo "setcap cap_net_bind_service,cap_net_raw=ep → /usr/sbin/chronyd"
else
    echo "NOTE: setcap not found; xcesp-activate will apply caps on next run"
fi

# ---------------------------------------------------------------------------
# Quick sanity output.  ldd may flag missing libraries (libgnutls,
# libnettle, libtomcrypt, zlib depending on chrony build flags).
# Don't fail on that — the operator may install them separately.
# ---------------------------------------------------------------------------
echo
echo "chronyd version:"
/usr/sbin/chronyd -v 2>&1 || true
echo
echo "Shared library status (any 'not found' lines need attention):"
ldd /usr/sbin/chronyd 2>&1 | grep -E 'not found|=> /' | head
echo
echo "Done."
