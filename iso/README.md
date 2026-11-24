# XCESP installer (USB / DVD, x86_64) — Debian 13 + XCESP

A bootable image that installs Debian 13 and XCESP on a server or a
virtual machine, unattended.  Built from the official Debian netinst image;
BIOS and UEFI; hybrid, so it can be written to a USB stick with `dd`.

## Build

```
make                                                   # xcespkg-<ver>.tar.gz
debian/build-debian.sh                                 # xcespkg-debian-<ver>.tar.gz
iso/build-iso.sh ~/Downloads/debian-13.x.y-amd64-netinst.iso
                                                       # -> xcesp-installer-<ver>-amd64.iso
```

The Debian image comes from
<https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/> (check it
against `SHA256SUMS`).  `build-iso.sh` runs xorriso in a `debian:trixie`
container and keeps the image's own boot setup.  `--serial-test` builds a
variant with a serial console and a 5-second menu timeout for an
unattended QEMU test — never ship it.

## What the image does

The boot menu (BIOS and UEFI) gets a first entry, **Install XCESP (ERASES THE
FIRST DISK)**, selected but not started until Enter is pressed.  It runs the
Debian installer with `preseed.cfg`:

* the whole first disk, one partition plus swap (EFI partition on UEFI);
* network by DHCP during the install — **the packages come from the Debian
  mirror, so the machine needs Internet access while it installs**;
* no root login; administrator `xcespadmin` (sudo) with the initial
  password `xcesp`, which must be changed at the first login;
* Debian standard system, SSH server, and the XCESP runtime packages (FRR,
  strongSwan, net-snmp, chrony, DSP libraries, ...);
* XCESP itself from `/xcesp/xcespkg-debian-*.tar.gz` on the medium, with the
  package's `install.sh` (`late.sh`), log in `/var/log/xcesp-install.log`.

The other entries of the Debian menu are unchanged, except that Debian's
30-second automatic start of the speech-synthesis installer is removed.

## First login

On the console or over SSH, log in as `xcespadmin` / `xcesp`, set a new
password, and answer the setup (`xcesp-setup`, offered once, rerun with
`sudo xcesp-setup`):

1. management interface and address (DHCP or static, gateway, DNS);
2. XCESP status and the **system-mac** to request licences for, and how to
   enter the codes (`server 1 / license-auth system-mac / license-code`).

XCESP starts at every boot (`xcesp.service`); configure it with `xcespcli`.
