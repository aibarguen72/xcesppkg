#!/bin/sh
# late.sh — preseed late_command of the XCESP installer (runs in the
# installer, the new system is mounted at /target).
#
# Installs XCESP from /cdrom/xcesp/xcespkg-debian-*.tar.gz with the package's
# own install.sh inside the new system (systemctl only enables units in the
# chroot), installs the first-login setup, and forces the administrator to
# change the initial password.  The log stays in /var/log/xcesp-install.log.
set -u
LOG=/target/var/log/xcesp-install.log
echo "XCESP installer late_command $(date)" > "$LOG"

TGZ=$(ls /cdrom/xcesp/xcespkg-debian-*.tar.gz 2>/dev/null | head -1)
if [ -z "$TGZ" ]; then
    echo "no XCESP package on the installer medium" >> "$LOG"
    exit 0
fi
mkdir -p /target/root/xcesp-install
cp "$TGZ" /target/root/xcesp-install/
cp /cdrom/xcesp/xcesp-setup /target/usr/sbin/xcesp-setup
chmod 0755 /target/usr/sbin/xcesp-setup
cp /cdrom/xcesp/xcesp-firstlogin.sh /target/etc/profile.d/xcesp-firstlogin.sh
chmod 0644 /target/etc/profile.d/xcesp-firstlogin.sh

in-target sh -c 'cd /root/xcesp-install && tar xzf xcespkg-debian-*.tar.gz && \
    cd xcespkg-debian-* && XCESP_NO_PKG_INSTALL=1 ./install.sh' >> "$LOG" 2>&1
echo "install.sh exit $?" >> "$LOG"

in-target systemctl enable xcesp.service >> "$LOG" 2>&1
in-target chage -d 0 xcespadmin >> "$LOG" 2>&1
mkdir -p /target/var/lib/xcesp
touch /target/var/lib/xcesp/firstboot-pending
exit 0
