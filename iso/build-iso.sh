#!/bin/bash
# build-iso.sh — XCESP installer ISO (USB / DVD, BIOS + UEFI) from the
# official Debian 13 netinst image and the Debian XCESP package.
#
# Usage: iso/build-iso.sh <debian-13.x.y-amd64-netinst.iso> [<xcespkg-debian tarball>] [--serial-test]
#   default tarball: ../xcespkg-debian-<PRJVERSION>.tar.gz (debian/build-debian.sh)
#   output: xcesp-installer-<ver>-amd64.iso next to PROJECT
#           (XCESP_ISO_OUT overrides; --serial-test adds -serial to the name)
#
# Adds a first boot-menu entry "Install XCESP (ERASES THE FIRST DISK)" to the
# BIOS (isolinux) and UEFI (GRUB) menus: unattended install with
# iso/preseed.cfg, XCESP from the tarball (iso/late.sh), first-login setup
# (iso/xcesp-setup).  The entry is selected but never started by itself: the
# menus keep no timeout (Debian's 30 s speech-synthesis autostart is removed).  --serial-test: serial console + 5 s menu timeout,
# for an unattended QEMU test only — never ship that image.
# The ISO is rewritten with xorriso (debian:trixie container) replaying the
# original boot setup, so it stays a hybrid image (dd to a USB stick).
set -euo pipefail

ISO_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$ISO_DIR/.." && pwd)"
VERSION="$(grep '^PRJVERSION' "$PKG_DIR/PROJECT" | awk -F':=' '{gsub(/ /,"",$2); print $2}')"
IN_ISO=""; TGZ=""; SERIAL=0
for a in "$@"; do
    case "$a" in
        --serial-test) SERIAL=1 ;;
        *.iso) IN_ISO="$a" ;;
        *) TGZ="$a" ;;
    esac
done
[ -f "$IN_ISO" ] || { echo "usage: $0 <debian netinst iso> [<xcespkg-debian tarball>] [--serial-test]" >&2; exit 1; }
TGZ="${TGZ:-$PKG_DIR/xcespkg-debian-$VERSION.tar.gz}"
[ -f "$TGZ" ] || { echo "tarball not found: $TGZ (run debian/build-debian.sh)" >&2; exit 1; }
SUFFIX=""; [ "$SERIAL" = 1 ] && SUFFIX="-serial"
OUT="${XCESP_ISO_OUT:-$PKG_DIR/xcesp-installer-$VERSION-amd64$SUFFIX.iso}"
IMAGE=localhost/xcesp-iso-builder:latest
WORK="${XCESP_ISO_WORK:-$PKG_DIR/build/iso}"

if ! podman image exists "$IMAGE"; then
    printf 'FROM docker.io/library/debian:trixie\nRUN apt-get update && apt-get install -y --no-install-recommends xorriso && rm -rf /var/lib/apt/lists/*\n' \
        | podman build -t "$IMAGE" -f - "$ISO_DIR"
fi

mkdir -p "$WORK/w/xcesp" "$WORK/w/isolinux" "$WORK/w/grub"
find "$WORK/w" -type f -delete
cp "$IN_ISO" "$WORK/w/in.iso"
cp "$ISO_DIR/preseed.cfg" "$ISO_DIR/late.sh" "$ISO_DIR/xcesp-setup" \
   "$ISO_DIR/xcesp-firstlogin.sh" "$WORK/w/xcesp/"
cp "$TGZ" "$WORK/w/xcesp/"
head -1 "$TGZ" >/dev/null

# Original boot menus out of the image.
podman run --rm -v "$WORK/w:/w:Z" "$IMAGE" xorriso -osirrox on -indev /w/in.iso \
    -extract /isolinux/isolinux.cfg /w/isolinux/isolinux.cfg \
    -extract /isolinux/menu.cfg /w/isolinux/menu.cfg \
    -extract /isolinux/gtk.cfg /w/isolinux/gtk.cfg \
    -extract /isolinux/spkgtk.cfg /w/isolinux/spkgtk.cfg \
    -extract /boot/grub/grub.cfg /w/grub/grub.cfg >/dev/null 2>&1
chmod u+w "$WORK"/w/isolinux/* "$WORK"/w/grub/*

ARGS="auto=true priority=critical preseed/file=/cdrom/xcesp/preseed.cfg"
if [ "$SERIAL" = 1 ]; then
    # After `---`: the installer copies these into the installed system's
    # boot options, so its kernel and login also use the serial console.
    KOPT="$ARGS --- console=ttyS0,115200n8"
else
    KOPT="vga=788 $ARGS --- quiet"
fi

# BIOS: our entry first and default; the graphical one loses its default.
cat > "$WORK/w/isolinux/xcesp.cfg" <<EOF
label xcesp
	menu label ^Install XCESP (ERASES THE FIRST DISK)
	menu default
	kernel /install.amd/vmlinuz
	append initrd=/install.amd/initrd.gz $KOPT
EOF
sed -i '/menu default/d' "$WORK/w/isolinux/gtk.cfg"
# Debian's BIOS menu boots the speech-synthesis installer after 30 s without a
# key (spkgtk.cfg: timeout / ontimeout / menu autoboot, included last so it
# overrides any other timeout).  An XCESP installer waits for a key instead;
# the speech entry itself stays in the menu.
sed -i -e '/^# timeout to speech/d' -e '/^timeout /d' -e '/^ontimeout /d' -e '/^menu autoboot /d' \
    "$WORK/w/isolinux/spkgtk.cfg"
sed -i 's/^include gtk.cfg$/include xcesp.cfg\ninclude gtk.cfg/' "$WORK/w/isolinux/menu.cfg"
if [ "$SERIAL" = 1 ]; then
    sed -i 's/^timeout 0$/timeout 50/' "$WORK/w/isolinux/isolinux.cfg"
    sed -i '1i serial 0 115200' "$WORK/w/isolinux/isolinux.cfg"
fi

# UEFI: same entry first, default.
{
    echo "set default=0"
    [ "$SERIAL" = 1 ] && echo "set timeout=5"
    cat <<EOF
menuentry 'Install XCESP (ERASES THE FIRST DISK)' {
    set background_color=black
    linux    /install.amd/vmlinuz $KOPT
    initrd   /install.amd/initrd.gz
}
EOF
} > "$WORK/w/grub/xcesp-entry.cfg"
awk -v entry="$WORK/w/grub/xcesp-entry.cfg" '
    !done && /^menuentry / { while ((getline l < entry) > 0) print l; done = 1 }
    { print }
' "$WORK/w/grub/grub.cfg" > "$WORK/w/grub/grub.cfg.new"
mv "$WORK/w/grub/grub.cfg.new" "$WORK/w/grub/grub.cfg"

podman run --rm -v "$WORK/w:/w:Z" "$IMAGE" xorriso -indev /w/in.iso -outdev /w/out.iso \
    -map /w/xcesp /xcesp \
    -map /w/isolinux/xcesp.cfg /isolinux/xcesp.cfg \
    -map /w/isolinux/menu.cfg /isolinux/menu.cfg \
    -map /w/isolinux/gtk.cfg /isolinux/gtk.cfg \
    -map /w/isolinux/spkgtk.cfg /isolinux/spkgtk.cfg \
    -map /w/isolinux/isolinux.cfg /isolinux/isolinux.cfg \
    -map /w/grub/grub.cfg /boot/grub/grub.cfg \
    -boot_image any replay 2>&1 | tail -3
mv "$WORK/w/out.iso" "$OUT"
rm -f "$WORK/w/in.iso"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
sha256sum "$OUT"
