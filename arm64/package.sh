#!/bin/bash
# package.sh — assemble xcespkg-arm64-X.X.X.tgz from ARM64 binaries.
# Usage: bash arm64/package.sh <bindir>
#   <bindir>  directory containing the 4 arm64 binaries downloaded from the
#             remote build machine (xcespserver xcespcli xcespproc xcespwdog)
#
# Run from xcesppkg/ (the script locates its siblings by $PKGDIR).
set -e

BINDIR="${1:-}"
if [ -z "$BINDIR" ]; then
    echo "Usage: $0 <bindir>" >&2
    exit 1
fi

# Resolve to absolute path
BINDIR="$(cd "$BINDIR" && pwd)"

# We must be run from xcesppkg/
PKGDIR="$(cd "$(dirname "$0")/.." && pwd)"
XSRC="$(cd "$PKGDIR/.." && pwd)"

# Read version from PROJECT
VERSION="$(grep PRJVERSION "$PKGDIR/PROJECT" | awk -F':=' '{gsub(/ /,"",$2); print $2}')"
if [ -z "$VERSION" ]; then
    echo "ERROR: could not read PRJVERSION from $PKGDIR/PROJECT" >&2
    exit 1
fi

PKG_NAME="xcespkg-arm64-$VERSION"
TARBALL="$PKGDIR/${PKG_NAME}.tgz"

echo "Building $TARBALL ..."

# Helper: read version from a subproject PROJECT file
ver() { grep PRJVERSION "$XSRC/$1/PROJECT" 2>/dev/null | awk -F':=' '{gsub(/ /,"",$2); print $2}'; }

# --- Verify input binaries ---
for b in xcespserver xcespcli xcespproc xcespwdog xcesp-ip; do
    if [ ! -f "$BINDIR/$b" ]; then
        echo "ERROR: $BINDIR/$b not found" >&2
        exit 1
    fi
done

# --- Create staging directory ---
STAGING="$PKGDIR/$PKG_NAME"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# --- Binaries (arm64) ---
mkdir -p "$STAGING/bin"
cp "$BINDIR/xcespserver" "$STAGING/bin/xcespserver"
cp "$BINDIR/xcespcli"    "$STAGING/bin/xcespcli"
cp "$BINDIR/xcespproc"   "$STAGING/bin/xcespproc"
cp "$BINDIR/xcespwdog"   "$STAGING/bin/xcespwdog"
cp "$BINDIR/xcesp-ip"    "$STAGING/bin/xcesp-ip"

# --- Config templates ---
mkdir -p "$STAGING/cfg"
cp "$PKGDIR/cfg/xcespserver.ini"  "$STAGING/cfg/"
cp "$PKGDIR/cfg/xcespproc.ini"    "$STAGING/cfg/"
cp "$PKGDIR/cfg/xcespwdog.ini"    "$STAGING/cfg/"
cp "$PKGDIR/cfg/xcespserver.conf" "$STAGING/cfg/"

# --- Schema ---
mkdir -p "$STAGING/schema"
# Direct xcesptest schema files
for f in domain.schema _types.schema udpbert.schema udpbert.status udptester.schema udptester.status; do
    cp "$XSRC/xcesptest/schema/$f" "$STAGING/schema/"
done
# ON library schema directories (copied directly — bypasses broken symlinks)
mkdir -p "$STAGING/schema/on-rtr" "$STAGING/schema/on-pw" "$STAGING/schema/on-xc" "$STAGING/schema/on-server"
cp -r "$XSRC/xcesp-on-rtr/schema/."    "$STAGING/schema/on-rtr/"
cp -r "$XSRC/xcesp-on-pw/schema/."     "$STAGING/schema/on-pw/"
cp -r "$XSRC/xcesp-on-xc/schema/."     "$STAGING/schema/on-xc/"
cp -r "$XSRC/xcespserver/schema/."     "$STAGING/schema/on-server/"
# Flatten validate hooks from plugin schemas to top-level schema dir
find "$XSRC/xcesp-on-rtr/schema" "$XSRC/xcesp-on-pw/schema" \
     "$XSRC/xcesp-on-xc/schema"  "$XSRC/xcespserver/schema" \
     -maxdepth 1 -name "*.validate.py" -exec cp {} "$STAGING/schema/" \; 2>/dev/null || true

# --- Python rules ---
mkdir -p "$STAGING/rules/config-to-objects" "$STAGING/rules/status-to-global"
cp "$XSRC/xcesptest/rules/worker.py" "$STAGING/rules/"
find "$XSRC/xcesptest/rules/config-to-objects" -maxdepth 1 -type f -name "*.py" \
    -exec cp {} "$STAGING/rules/config-to-objects/" \;
find "$XSRC/xcesptest/rules/status-to-global" -maxdepth 1 -type f -name "*.py" \
    -exec cp {} "$STAGING/rules/status-to-global/" \;
cp "$XSRC/xcesp-on-rtr/rules/config-to-objects/"*.py "$STAGING/rules/config-to-objects/"
cp "$XSRC/xcesp-on-rtr/rules/status-to-global/"*.py  "$STAGING/rules/status-to-global/"
cp "$XSRC/xcesp-on-pw/rules/config-to-objects/"*.py  "$STAGING/rules/config-to-objects/"
cp "$XSRC/xcesp-on-pw/rules/status-to-global/"*.py   "$STAGING/rules/status-to-global/"
cp "$XSRC/xcesp-on-xc/rules/config-to-objects/"*.py  "$STAGING/rules/config-to-objects/"
cp "$XSRC/xcesp-on-xc/rules/status-to-global/"*.py   "$STAGING/rules/status-to-global/"
find "$STAGING/rules" -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# --- xcesppy Python library ---
mkdir -p "$STAGING/python/xcesppy"
cp "$PKGDIR/python/pyproject.toml" "$STAGING/python/"
cp -r "$XSRC/xcesppy/xcesppy/." "$STAGING/python/xcesppy/"
find "$STAGING/python" -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# --- Documentation (mkdocs-built static site) ---
# Which documentation PROFILE to bundle.  The doc tree builds one site
# per profile (see doc/build-docs.sh), because XCESP is sold in parts and
# a customer must not receive chapters for parts they have not bought:
#
#   DOC_PROFILE=full   -> doc/site/        complete documentation set
#   DOC_PROFILE=modem  -> doc/site-modem/  XCESP-MODEM customer set
#
# Defaults to 'full' so an unqualified package build is unchanged.
# Bundled only if the profile's site directory exists — gracefully
# skipped if the doc tree has not been rebuilt locally.
DOC_PROFILE="${DOC_PROFILE:-full}"
if [ "$DOC_PROFILE" = "full" ]; then
    DOC_SRC="$XSRC/doc/site"
else
    DOC_SRC="$XSRC/doc/site-$DOC_PROFILE"
fi
if [ -d "$DOC_SRC" ]; then
    mkdir -p "$STAGING/doc"
    cp -r "$DOC_SRC/." "$STAGING/doc/"
    echo "  Bundled docs ($DOC_PROFILE profile): $DOC_SRC → $STAGING/doc"
else
    echo "  Skipping docs ($DOC_SRC not found — run 'doc/build-docs.sh $DOC_PROFILE')"
fi

# --- Management scripts ---
# install.sh calls scripts/xcesp-login unconditionally, so this one must be
# present.  xcesp-ipsec-vip-installer is optional (install.sh WARNs when
# missing) but shipping it costs nothing and makes IPsec VIP-on-loopback
# work out of the box.
mkdir -p "$STAGING/scripts"
cp "$PKGDIR/scripts/xcesp-activate"              "$STAGING/scripts/"
cp "$PKGDIR/scripts/xcesp-swap.sh"               "$STAGING/scripts/"
cp "$PKGDIR/scripts/xcesp-dhclient-script"       "$STAGING/scripts/"
cp "$PKGDIR/scripts/chrony-install.sh"           "$STAGING/scripts/"
cp "$PKGDIR/scripts/xcesp-login"                 "$STAGING/scripts/"
cp "$PKGDIR/scripts/xcesp-ipsec-vip-installer"   "$STAGING/scripts/"
chmod +x "$STAGING/scripts/xcesp-activate" \
         "$STAGING/scripts/xcesp-swap.sh"  \
         "$STAGING/scripts/xcesp-dhclient-script" \
         "$STAGING/scripts/chrony-install.sh" \
         "$STAGING/scripts/xcesp-login" \
         "$STAGING/scripts/xcesp-ipsec-vip-installer"

# --- Systemd service ---
mkdir -p "$STAGING/services"
cp "$PKGDIR/services/xcesp.service" "$STAGING/services/"

# --- VERSION file ---
{
    echo "XCESPKG $VERSION (arm64)"
    echo "Built:  $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "Arch:   aarch64"
    echo ""
    printf "%-22s %s\n" "Component" "Version"
    printf "%-22s %s\n" "---------" "-------"
    printf "%-22s %s\n" "xcespserver"  "$(ver xcespserver)"
    printf "%-22s %s\n" "xcespcli"     "$(ver xcespcli)"
    printf "%-22s %s\n" "xcespproc"    "$(ver xcespproc)"
    printf "%-22s %s\n" "xcespwdog"    "$(ver xcespwdog)"
    printf "%-22s %s\n" "xcesp-on-rtr" "$(ver xcesp-on-rtr)"
    printf "%-22s %s\n" "xcesp-on-pw"  "$(ver xcesp-on-pw)"
    printf "%-22s %s\n" "xcesp-on-xc"  "$(ver xcesp-on-xc)"
    printf "%-22s %s\n" "xcespmap"     "$(ver xcespmap)"
    printf "%-22s %s\n" "xcespschema"  "$(ver xcespschema)"
    printf "%-22s %s\n" "xcespconfig"  "$(ver xcespconfig)"
    printf "%-22s %s\n" "xcesppy"      "$(ver xcesppy)"
} > "$STAGING/VERSION"

# --- Installer script ---
cp "$PKGDIR/install.sh" "$STAGING/install.sh"
chmod +x "$STAGING/install.sh"

# --- Create tarball ---
cd "$PKGDIR"
tar czf "$TARBALL" "$PKG_NAME"
rm -rf "$STAGING"

echo "Package ready: $TARBALL"
echo "Size: $(du -sh "$TARBALL" | cut -f1)"
