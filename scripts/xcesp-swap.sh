#!/bin/bash
# xcesp-swap — atomically swap /var/xcesp/mainsw and /var/xcesp/backupsw
#
# Preconditions (all must hold):
#   1. Both /var/xcesp/mainsw and /var/xcesp/backupsw exist
#   2. Both directories are non-empty
#   3. /var/xcesp/backupsw/VERSION exists (confirms it is a valid XCESP package)
#
# After swapping, restart the service to activate the new version:
#   systemctl restart xcesp
#
# Usage:  sudo xcesp-swap.sh

set -euo pipefail

XCESP_BASE=/var/xcesp
MAINSW=$XCESP_BASE/mainsw
BACKUPSW=$XCESP_BASE/backupsw
TEMPSW=$XCESP_BASE/.swaptmp

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "ERROR: must be run as root  (sudo xcesp-swap.sh)" >&2; exit 1; }

# Clean up any leftover temp dir from a previous failed swap
[ -d "$TEMPSW" ] && rm -rf "$TEMPSW"

# ---------------------------------------------------------------------------
# Precondition checks
# ---------------------------------------------------------------------------
[ -d "$MAINSW" ]   || { echo "ERROR: $MAINSW does not exist"  >&2; exit 1; }
[ -d "$BACKUPSW" ] || { echo "ERROR: $BACKUPSW does not exist — nothing to swap with" >&2; exit 1; }

[ "$(ls -A "$MAINSW"   2>/dev/null)" ] || { echo "ERROR: $MAINSW is empty"   >&2; exit 1; }
[ "$(ls -A "$BACKUPSW" 2>/dev/null)" ] || { echo "ERROR: $BACKUPSW is empty" >&2; exit 1; }

[ -f "$BACKUPSW/VERSION" ] || {
    echo "ERROR: $BACKUPSW/VERSION not found — not a valid XCESP package" >&2
    echo "       Use 'make install' or copy a package to $BACKUPSW before swapping." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Show what will change
# ---------------------------------------------------------------------------
MAIN_VER="$(head -1 "$MAINSW/VERSION"   2>/dev/null || echo "unknown")"
BACK_VER="$(head -1 "$BACKUPSW/VERSION" 2>/dev/null || echo "unknown")"

echo "Swapping software directories:"
echo "  Current mainsw  : $MAIN_VER  →  will become backupsw"
echo "  Current backupsw: $BACK_VER  →  will become mainsw"
echo ""

# ---------------------------------------------------------------------------
# Atomic swap via temporary rename
# All three mv operations are on the same filesystem (/var/xcesp) so each
# mv is an atomic directory rename at the kernel level.
# ---------------------------------------------------------------------------
mv "$MAINSW"   "$TEMPSW"
mv "$BACKUPSW" "$MAINSW"
mv "$TEMPSW"   "$BACKUPSW"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo "Swap complete."
echo "  New mainsw  : $(head -1 "$MAINSW/VERSION")"
echo "  New backupsw: $(head -1 "$BACKUPSW/VERSION")"
echo ""
echo "Run the following to activate the new version:"
echo "  systemctl restart xcesp"
