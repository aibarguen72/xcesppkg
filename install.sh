#!/bin/bash
# install.sh — XCESP system installer
# Must be run as root:  sudo ./install.sh
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BINDIR=/usr/bin
XCESP_BASE=/var/xcesp
CFG_DIR=$XCESP_BASE/cfg
LOG_DIR=$XCESP_BASE/log
SCHEMA_DIR=$XCESP_BASE/schema
RULES_DIR=$XCESP_BASE/rules
DOC_DIR=$XCESP_BASE/doc
VENV_DIR=$XCESP_BASE/venv
PYLIB_DIR=$XCESP_BASE/lib/python
MAINSW_DIR=$XCESP_BASE/mainsw
BACKUPSW_DIR=$XCESP_BASE/backupsw
DSK_DIR=$XCESP_BASE/dsk
RUN_DIR=/run/xcesp
# Persisted DHCP lease storage (survives reboot — /run is tmpfs)
VAR_LIB_DIR=/var/lib/xcesp
DHCP_LEASE_DIRS="$VAR_LIB_DIR/dhcp-client $VAR_LIB_DIR/dhcp4 $VAR_LIB_DIR/dhcp6"
SYSTEMD_DIR=/etc/systemd/system
XCESP_USER=xcesp
XCESP_GROUP=xcesp

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || error "install.sh must be run as root  (sudo ./install.sh)"

# ---------------------------------------------------------------------------
# System user and group
# ---------------------------------------------------------------------------
info "Checking xcesp system account..."
if ! getent group "$XCESP_GROUP" > /dev/null 2>&1; then
    groupadd --system "$XCESP_GROUP"
    info "  Created group: $XCESP_GROUP"
fi
XCESP_HOME="/home/$XCESP_USER"
if ! getent passwd "$XCESP_USER" > /dev/null 2>&1; then
    useradd --system \
            --gid "$XCESP_GROUP" \
            --home-dir "$XCESP_HOME" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "XCESP service account" \
            "$XCESP_USER"
    info "  Created user: $XCESP_USER"
fi
# Home directory: needed for scp/sftp known_hosts storage.
# Idempotent — safe to run on reinstall or if user already existed.
install -d -o "$XCESP_USER" -g "$XCESP_GROUP" -m 0750 "$XCESP_HOME"
install -d -o "$XCESP_USER" -g "$XCESP_GROUP" -m 0700 "$XCESP_HOME/.ssh"

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
info "Creating directory layout..."
for d in "$CFG_DIR" "$LOG_DIR" "$SCHEMA_DIR" \
          "$RULES_DIR/config-to-objects" "$RULES_DIR/status-to-global" \
          "$MAINSW_DIR/bin" "$MAINSW_DIR/schema" \
          "$MAINSW_DIR/rules/config-to-objects" "$MAINSW_DIR/rules/status-to-global" \
          "$MAINSW_DIR/python" \
          "$RUN_DIR" \
          $DHCP_LEASE_DIRS; do
    mkdir -p "$d"
done

# backupsw: create only if it does not exist (preserve any existing backup)
if [ ! -d "$BACKUPSW_DIR" ]; then
    mkdir -p "$BACKUPSW_DIR"
    info "  Created empty $BACKUPSW_DIR"
else
    info "  $BACKUPSW_DIR already exists — leaving untouched"
fi

# dsk: file storage directories (writable by xcesp group)
for d in "$DSK_DIR/img" "$DSK_DIR/bcfg" "$DSK_DIR/log" "$DSK_DIR/cap"; do
    mkdir -p "$d"
    chown root:"$XCESP_GROUP" "$d"
    chmod 775 "$d"
done
info "  Created $DSK_DIR/{img,bcfg,log,cap}"

# dsk/cert: X.509 certificate and private-key storage.  Subdirectory
# layout — read by FileActionHandler (cert-* actions) and by charon when
# strongSwan picks up the per-namespace creds:
#   ca/   CA certificates (public material) — group-readable
#   dev/  Device (own) certificates          — group-readable
#   key/  Private keys                       — group-readable, NOT world
# Files inside use mode 0640 (group-only); the dirs are 0750 so non-xcesp
# users can't list private key names either.
for d in "$DSK_DIR/cert/ca" "$DSK_DIR/cert/dev" "$DSK_DIR/cert/key"; do
    mkdir -p "$d"
    chown root:"$XCESP_GROUP" "$d"
    chmod 0750 "$d"
done
chown root:"$XCESP_GROUP" "$DSK_DIR/cert"
chmod 0750 "$DSK_DIR/cert"
info "  Created $DSK_DIR/cert/{ca,dev,key} (mode 0750)"

# ---------------------------------------------------------------------------
# Binaries → /var/xcesp/mainsw/bin/  AND  /usr/bin/
# ---------------------------------------------------------------------------
info "Installing binaries..."
for bin in xcespserver xcespcli xcespproc xcespwdog; do
    src="$INSTALL_DIR/bin/$bin"
    [ -f "$src" ] || error "Binary not found in package: $src"
    install -o root -g root -m 0755 "$src" "$MAINSW_DIR/bin/$bin"
    install -o root -g root -m 0755 "$src" "$BINDIR/$bin"
    info "  $BINDIR/$bin"
done

# xcesp-ip → /usr/lib/xcesp/ (NOT on PATH).  This is a privileged wrapper
# only invoked by xcesp-dhclient-script.  Keeping it off PATH means normal
# users can't discover it; its file caps (applied by xcesp-activate) only
# help our script's code path.
info "Installing xcesp-ip wrapper..."
src="$INSTALL_DIR/bin/xcesp-ip"
if [ -f "$src" ]; then
    install -d -o root -g root -m 0755 "$MAINSW_DIR/lib/xcesp"
    install -d -o root -g root -m 0755 /usr/lib/xcesp
    install -o root -g root -m 0755 "$src" "$MAINSW_DIR/lib/xcesp/xcesp-ip"
    install -o root -g root -m 0755 "$src" /usr/lib/xcesp/xcesp-ip
    info "  /usr/lib/xcesp/xcesp-ip (and $MAINSW_DIR/lib/xcesp/)"
else
    warn "xcesp-ip wrapper not in package — DHCP client may fail on Debian/Fedora"
fi

# ---------------------------------------------------------------------------
# Capabilities (xcespproc needs namespace + network admin)
# ---------------------------------------------------------------------------
info "Setting file capabilities on xcespproc..."
XCESPPROC_CAPS="cap_net_admin,cap_sys_admin,cap_sys_module,cap_net_raw,cap_net_bind_service,cap_sys_time=ep"
if command -v setcap > /dev/null 2>&1; then
    setcap "$XCESPPROC_CAPS" "$BINDIR/xcespproc"
    setcap "$XCESPPROC_CAPS" "$MAINSW_DIR/bin/xcespproc"
    info "  $XCESPPROC_CAPS set"
else
    warn "setcap not found — install libcap2-bin (Debian/Ubuntu) or libcap (RHEL/Fedora)"
    warn "Then run:  setcap $XCESPPROC_CAPS $BINDIR/xcespproc"
fi

# strongSwan / charon: setuid root, NO file capabilities.
#
# Ubuntu's strongSwan charon ships without libcap (verified:
# `ldd /usr/libexec/ipsec/charon | grep cap` is empty).  Its
# CAP_NET_BIND_SERVICE check inside capabilities_t::keep() falls through
# to a `geteuid()==0 ? TRUE : FALSE` fallback.  When xcespproc (running
# as xcesp) execs charon with file caps, the caps are granted but euid
# stays non-zero, so the check returns FALSE — socket-default refuses
# to register and logs "socket-default plugin requires CAP_NET_BIND_SERVICE
# capability".  IKE_SAs stay CONNECTING forever, no packets are sent.
#
# Fix: drop file caps and use setuid root.  charon then exec's as euid=0
# inside the per-ns mount/net namespace and socket-default binds 500/4500
# normally.  This matches the upstream Ubuntu strongswan systemd unit
# (which also runs charon as root).
#
# Earlier (<=0.1.71) we relied on file caps — replaced because of the
# libcap-less build above.  We explicitly strip any leftover file caps
# here so upgrades from 0.1.71 land in a clean state.
#
# Probe every candidate path — distros put charon under different prefixes.
for charon_bin in /usr/libexec/strongswan/charon \
                  /usr/lib/strongswan/charon \
                  /usr/libexec/ipsec/charon \
                  /usr/lib/ipsec/charon \
                  /usr/local/libexec/strongswan/charon; do
    [ -f "$charon_bin" ] || continue
    command -v setcap > /dev/null 2>&1 && setcap -r "$charon_bin" 2>/dev/null || true
    chmod u+s "$charon_bin"
    info "  setuid root applied to $charon_bin (file caps removed)"
done

# Ubuntu's strongswan-charon ships /etc/strongswan.d/charon/*.conf as
# mode 0600 root:root.  Our per-namespace charon runs as xcesp; an
# include that finds unreadable files is fatal on Ubuntu's strongSwan
# (charon dies before syslog opens).  These files contain only plugin
# enable/disable defaults — no secrets — so making them world-readable
# is safe.  Both Fedora and Debian/Ubuntu candidate paths handled.
for plugin_dir in /etc/strongswan/strongswan.d/charon \
                  /etc/strongswan.d/charon; do
    [ -d "$plugin_dir" ] || continue
    chmod a+rx "$plugin_dir" 2>/dev/null || true
    chmod a+r  "$plugin_dir"/*.conf 2>/dev/null || true
    info "  relaxed perms on $plugin_dir/*.conf for xcesp readability"
done

# ---------------------------------------------------------------------------
# FRR group integration — allow xcespproc to write to /etc/frr/<ns>/
# ---------------------------------------------------------------------------
# xcespproc creates per-namespace subdirectories under /etc/frr/ to store the
# daemons file and frr.conf for each router namespace.  /etc/frr is owned by
# frr:frr; adding xcesp to the frr group and making /etc/frr group-writable
# gives the minimum required access without granting broader privileges.
info "Checking FRR group integration..."
if getent group frr > /dev/null 2>&1; then
    if ! id -Gn "$XCESP_USER" 2>/dev/null | grep -qw frr; then
        usermod -aG frr "$XCESP_USER"
        info "  Added $XCESP_USER to frr group"
    else
        info "  $XCESP_USER is already in the frr group"
    fi
    # Ensure the frr group has write access to /etc/frr so xcespproc can
    # create per-namespace subdirectories at runtime.
    if [ -d /etc/frr ]; then
        chmod g+rwx /etc/frr
        info "  /etc/frr: group write enabled"
    fi

    # sudoers rule for frrinit.sh and vtysh.
    # frrinit.sh unconditionally checks EUID=0 and exits if not root.
    # xcespproc calls it via "sudo -n frrinit.sh start <ns>".
    # vtysh must also run as root to connect to FRR daemon VTY sockets.
    FRRINIT=""
    for candidate in /usr/libexec/frr/frrinit.sh /usr/lib/frr/frrinit.sh \
                     /usr/local/lib/frr/frrinit.sh; do
        [ -f "$candidate" ] && FRRINIT="$candidate" && break
    done
    VTYSH_BIN="$(command -v vtysh 2>/dev/null || true)"

    if [ -n "$FRRINIT" ] || [ -n "$VTYSH_BIN" ]; then
        FRR_SUDOERS=/etc/sudoers.d/xcesp-frr
        # Disable use_pty for xcesp: some systems set "Defaults use_pty" globally
        # which prevents sudo from working in service processes that have no TTY.
        echo "Defaults:$XCESP_USER !use_pty" > "$FRR_SUDOERS"
        [ -n "$FRRINIT" ] && \
            echo "$XCESP_USER ALL=(root) NOPASSWD: $FRRINIT *" >> "$FRR_SUDOERS" && \
            info "  sudoers: $XCESP_USER → $FRRINIT"
        [ -n "$VTYSH_BIN" ] && \
            echo "$XCESP_USER ALL=(root) NOPASSWD: $VTYSH_BIN *" >> "$FRR_SUDOERS" && \
            info "  sudoers: $XCESP_USER → $VTYSH_BIN"
        chmod 0440 "$FRR_SUDOERS"
        info "  $FRR_SUDOERS installed"

        # Ensure /etc/sudoers includes /etc/sudoers.d — some embedded systems
        # ship a sudoers without the @includedir line, making drop-in files invisible.
        if ! grep -qE '^[#@]includedir\s+/etc/sudoers\.d' /etc/sudoers; then
            echo "@includedir /etc/sudoers.d" >> /etc/sudoers
            info "  Added @includedir /etc/sudoers.d to /etc/sudoers"
        fi
    else
        info "  frrinit.sh not found — skipping FRR sudoers rule (install FRR first)"
    fi
else
    info "  frr group not found — FRR not installed, skipping"
fi

# ---------------------------------------------------------------------------
# sudoers rule — allow xcesp to create IPsec config directories via xcespproc
# ---------------------------------------------------------------------------
# xcespproc creates per-namespace subdirectories under /etc/swanctl/ (newer
# Fedora) or /etc/strongswan/swanctl/ (RHEL/older Fedora) to hold swanctl.conf
# and strongswan.conf for each router namespace.  These paths are under /etc/
# and not writable by the xcesp user; sudo -n mkdir -p is used at runtime.
info "Installing sudoers rule for IPsec config directory creation..."
SWAN_SUDOERS=/etc/sudoers.d/xcesp-swan
cat > "$SWAN_SUDOERS" <<'SUDOERS'
# Allow xcespproc to create and own per-namespace IPsec config directories.
# xcespproc calls "sudo -n mkdir -p <dir> && sudo -n chown $(id -u) <dir>"
# when setting up each router's namespace swanctl/strongswan conf dirs.
xcesp ALL=(root) NOPASSWD: /usr/bin/mkdir -p /etc/swanctl/*, \
                            /usr/bin/mkdir -p /etc/strongswan/swanctl/*, \
                            /usr/bin/mkdir -p /run/strongswan/*, \
                            /usr/bin/chown * /etc/swanctl/*, \
                            /usr/bin/chown * /etc/strongswan/swanctl/*, \
                            /usr/bin/chown * /run/strongswan/*
SUDOERS
chmod 0440 "$SWAN_SUDOERS"
info "  $SWAN_SUDOERS installed"

# ---------------------------------------------------------------------------
# sudoers rule — allow xcesp to load kernel modules via xcespserver
# ---------------------------------------------------------------------------
info "Installing sudoers rule for kernel module loading..."
SUDOERS_FILE=/etc/sudoers.d/xcesp-modprobe
cat > "$SUDOERS_FILE" <<'SUDOERS'
# Allow the xcesp service account to load specific kernel modules.
# Required by xcespserver when 'mpls true', 'l2tp true', or 'vxlan true'
# is configured in xcespserver.conf under the server block.
xcesp ALL=(root) NOPASSWD: /usr/sbin/modprobe mpls_router, \
                            /usr/sbin/modprobe mpls_iptunnel, \
                            /usr/sbin/modprobe l2tp_core, \
                            /usr/sbin/modprobe l2tp_netlink, \
                            /usr/sbin/modprobe l2tp_ip, \
                            /usr/sbin/modprobe l2tp_eth, \
                            /usr/sbin/modprobe vxlan
SUDOERS
chmod 0440 "$SUDOERS_FILE"
info "  $SUDOERS_FILE installed"

# ---------------------------------------------------------------------------
# Pre-load kernel modules
# ---------------------------------------------------------------------------
# We are root in install.sh, so do the modprobe here directly.  This sidesteps
# any sudoers / capability propagation issues — once loaded, the modules stay
# resident until reboot or rmmod.
#
# Missing modules are non-fatal: xcespserver only requires them if the
# corresponding feature is enabled in xcespserver.conf (mpls true / l2tp true
# / vxlan true).  We never call out to package managers because (a) the user
# may be on an isolated machine with no repository access, and (b) they may
# not need the feature at all — installing kernel-modules-extra unprompted
# is intrusive.
info "Pre-loading kernel modules (missing modules are reported but not fatal)..."
MODULES_NEEDED="mpls_router mpls_iptunnel l2tp_core l2tp_netlink l2tp_ip l2tp_eth vxlan"
MODULES_MISSING=""
for mod in $MODULES_NEEDED; do
    if modinfo "$mod" > /dev/null 2>&1; then
        if modprobe "$mod" 2>/dev/null; then
            info "  modprobe $mod: OK"
        else
            warn "  modprobe $mod: load failed"
        fi
    else
        MODULES_MISSING="$MODULES_MISSING $mod"
    fi
done
if [ -n "$MODULES_MISSING" ]; then
    warn ""
    warn "The following modules are not present on this kernel:"
    warn "    $MODULES_MISSING"
    warn ""
    warn "If you do not use the corresponding feature (MPLS / L2TP / VXLAN),"
    warn "this is harmless and you can ignore this warning."
    warn ""
    warn "If you DO need them and you are on Fedora / RHEL, install:"
    warn "    sudo dnf install kernel-modules-extra-\$(uname -r)"
    warn "and re-run this installer."
    warn ""
fi

# ---------------------------------------------------------------------------
# Configuration templates (non-destructive: existing files are never overwritten)
# ---------------------------------------------------------------------------
info "Installing configuration templates to $CFG_DIR ..."
for f in xcespserver.ini xcespproc.ini xcespwdog.ini xcespserver.conf; do
    src="$INSTALL_DIR/cfg/$f"
    dst="$CFG_DIR/$f"
    if [ ! -f "$dst" ]; then
        install -o "$XCESP_USER" -g "$XCESP_GROUP" -m 0640 "$src" "$dst"
        info "  Installed : $dst"
    else
        info "  Skipped (exists): $dst"
    fi
done

# ---------------------------------------------------------------------------
# Schema → mainsw/schema/  (then activated to /var/xcesp/schema/ below)
# ---------------------------------------------------------------------------
info "Installing schema to $MAINSW_DIR/schema ..."
cp -rT "$INSTALL_DIR/schema" "$MAINSW_DIR/schema"

# ---------------------------------------------------------------------------
# Python rules → mainsw/rules/  (then activated to /var/xcesp/rules/ below)
# ---------------------------------------------------------------------------
info "Installing Python rules to $MAINSW_DIR/rules ..."
cp -rT "$INSTALL_DIR/rules" "$MAINSW_DIR/rules"

# ---------------------------------------------------------------------------
# xcesppy source → mainsw/python/
# ---------------------------------------------------------------------------
info "Installing xcesppy source to $MAINSW_DIR/python ..."
cp -rT "$INSTALL_DIR/python" "$MAINSW_DIR/python"

# ---------------------------------------------------------------------------
# Documentation → mainsw/doc/  (activated to /var/xcesp/doc/ below).
# Only present when the package was built with ../doc/site/ available; the
# doc-httpd server slot in xcespserver.ini gracefully no-ops if DOC_DIR is
# missing.
# ---------------------------------------------------------------------------
if [ -d "$INSTALL_DIR/doc" ]; then
    info "Installing documentation to $MAINSW_DIR/doc ..."
    mkdir -p "$MAINSW_DIR/doc"
    cp -rT "$INSTALL_DIR/doc" "$MAINSW_DIR/doc"
else
    info "  No documentation in this package (../doc/site was missing at build time)"
fi

# ---------------------------------------------------------------------------
# VERSION → mainsw/VERSION
# ---------------------------------------------------------------------------
if [ -f "$INSTALL_DIR/VERSION" ]; then
    cp "$INSTALL_DIR/VERSION" "$MAINSW_DIR/VERSION"
    info "  VERSION: $(head -1 "$MAINSW_DIR/VERSION")"
fi

# ---------------------------------------------------------------------------
# Activate mainsw → working locations (schema, rules, doc)
# ---------------------------------------------------------------------------
info "Activating mainsw to working locations..."
cp -rT "$MAINSW_DIR/schema" "$SCHEMA_DIR"
cp -rT "$MAINSW_DIR/rules"  "$RULES_DIR"
if [ -d "$MAINSW_DIR/doc" ]; then
    mkdir -p "$DOC_DIR"
    cp -rT "$MAINSW_DIR/doc" "$DOC_DIR"
fi

# ---------------------------------------------------------------------------
# Fix ownership and permissions
# ---------------------------------------------------------------------------
chown -R "$XCESP_USER:$XCESP_GROUP" \
    "$MAINSW_DIR" "$CFG_DIR" "$LOG_DIR" "$SCHEMA_DIR" "$RULES_DIR" \
    $( [ -d "$DOC_DIR" ] && printf '%s ' "$DOC_DIR" )
chmod 0750 "$CFG_DIR" "$LOG_DIR"
find "$SCHEMA_DIR" -type d -exec chmod 0755 {} \;
find "$SCHEMA_DIR" -type f -exec chmod 0644 {} \;
find "$RULES_DIR"  -type d  -exec chmod 0755 {} \;
find "$RULES_DIR"  -type f -name "*.py" -exec chmod 0755 {} \;
if [ -d "$DOC_DIR" ]; then
    find "$DOC_DIR" -type d -exec chmod 0755 {} \;
    find "$DOC_DIR" -type f -exec chmod 0644 {} \;
fi
find "$MAINSW_DIR" -type d -exec chmod 0755 {} \;
# Group-owned by xcesp with group-write so xcespserver can extract a new
# tarball into mainsw/ on swap and so `software-install` (which renames
# mainsw <-> backupsw) can rename without root.  Files inside stay
# root-owned 0644 / 0755 — the directory perms are what matter.
chown root:"$XCESP_GROUP" "$MAINSW_DIR"
chmod 2775 "$MAINSW_DIR"
chown root:"$XCESP_GROUP" "$BACKUPSW_DIR"
chmod 2775 "$BACKUPSW_DIR"
# /var/xcesp itself: xcesp group needs write here too, otherwise
# `software-install` cannot `rename mainsw -> mainsw_swap_tmp` etc.
# Setgid (mode 2775) ensures any new subdir created by xcespserver
# (e.g. extraction temps) inherits the xcesp group.
chown root:"$XCESP_GROUP" "$XCESP_BASE"
chmod 2775 "$XCESP_BASE"
chown "$XCESP_USER:$XCESP_GROUP" "$RUN_DIR"
chmod 0750 "$RUN_DIR"

# Persisted DHCP lease dirs.  The PObjs create per-namespace/device subdirs
# lazily; here we only need the top-level dirs to exist with the right
# ownership.  /var/lib survives reboot so client and server leases remain
# valid across xcesp restarts.
for d in $DHCP_LEASE_DIRS; do
    chown "$XCESP_USER:$XCESP_GROUP" "$d"
    chmod 0750 "$d"
done
chown root:"$XCESP_GROUP" "$VAR_LIB_DIR"
chmod 2775 "$VAR_LIB_DIR"

# ---------------------------------------------------------------------------
# Python environment — venv if available, direct install otherwise.
# xcesppy uses only stdlib (json, socket) so no third-party packages are
# needed; venv is just the cleaner isolation option when present.
# ---------------------------------------------------------------------------
info "Setting up Python environment..."
PYTHON_MODE="direct"

if python3 -c "import ensurepip" > /dev/null 2>&1; then
    PYTHON_MODE="venv"
else
    warn "python3-venv / ensurepip not available — xcesppy will be installed to $PYLIB_DIR instead"
fi

if [ "$PYTHON_MODE" = "venv" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip

    if [ -f "$MAINSW_DIR/python/pyproject.toml" ]; then
        info "  Installing xcesppy into virtual environment..."
        "$VENV_DIR/bin/pip" install --quiet "$MAINSW_DIR/python"
    fi

    if [ -f "$MAINSW_DIR/python/requirements.txt" ]; then
        info "  Installing additional Python requirements..."
        "$VENV_DIR/bin/pip" install --quiet -r "$MAINSW_DIR/python/requirements.txt"
    fi

    chown -R "$XCESP_USER:$XCESP_GROUP" "$VENV_DIR"
    chmod -R o-rwx "$VENV_DIR"
    info "  Virtual environment ready: $VENV_DIR"
else
    # Copy xcesppy source to a fixed location outside the swap tree, then
    # register it via a .pth file in Python's site-packages so every user
    # and script on the system can 'import xcesppy' without setting PYTHONPATH.
    mkdir -p "$PYLIB_DIR"
    cp -rT "$MAINSW_DIR/python/xcesppy" "$PYLIB_DIR/xcesppy"
    chown -R root:root "$PYLIB_DIR"
    chmod -R a+rX "$PYLIB_DIR"

    SITE_PKG=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || true)
    if [ -n "$SITE_PKG" ] && [ -d "$SITE_PKG" ]; then
        echo "$PYLIB_DIR" > "$SITE_PKG/xcesppy.pth"
        info "  xcesppy installed to $PYLIB_DIR"
        info "  Registered via $SITE_PKG/xcesppy.pth"
    else
        warn "Could not determine site-packages directory"
        warn "Add PYTHONPATH=$PYLIB_DIR to your environment to use xcesppy"
    fi
fi

# ---------------------------------------------------------------------------
# Management scripts → /usr/bin/  AND  $MAINSW_DIR/scripts/
# ---------------------------------------------------------------------------
# Two destinations: /usr/bin/ is what systemd invokes; mainsw/scripts/ ships
# with the package so a CLI upgrade (copy sw → backup-sw → software-install)
# can self-update /usr/bin/xcesp-activate from the new mainsw.  Without the
# mainsw copy, /usr/bin/xcesp-activate would stay frozen at install-time.
info "Installing management scripts..."
mkdir -p "$MAINSW_DIR/scripts"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-activate" "$BINDIR/xcesp-activate"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-activate" "$MAINSW_DIR/scripts/xcesp-activate"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-swap.sh"  "$BINDIR/xcesp-swap.sh"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-swap.sh"  "$MAINSW_DIR/scripts/xcesp-swap.sh"
# dhclient callback script — referenced by RtrDhcpClient via `-sf`.  Shipping
# our own avoids depending on distro-customized /sbin/dhclient-script (e.g.
# the "dnfv" ARM64 Ubuntu variant uses vtysh + arping and silently fails when
# those aren't installed, leaving dhclient bound but no address on the iface).
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-dhclient-script" "$BINDIR/xcesp-dhclient-script"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-dhclient-script" "$MAINSW_DIR/scripts/xcesp-dhclient-script"
info "  $BINDIR/xcesp-activate         (and $MAINSW_DIR/scripts/)"
info "  $BINDIR/xcesp-swap.sh          (and $MAINSW_DIR/scripts/)"
info "  $BINDIR/xcesp-dhclient-script  (and $MAINSW_DIR/scripts/)"

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
info "Installing systemd service ..."
install -o root -g root -m 0644 \
    "$INSTALL_DIR/services/xcesp.service" \
    "$SYSTEMD_DIR/xcesp.service"
systemctl daemon-reload
systemctl enable xcesp.service
info "  xcesp.service installed and enabled"

# Restart the service if it is currently running so the upgraded binaries
# take effect immediately.  `try-restart` is a no-op when the service is
# stopped, so a fresh install does not get an unnecessary start.
if systemctl is-active --quiet xcesp.service; then
    systemctl restart xcesp.service
    info "  xcesp.service restarted (running new binaries)"
fi

# ---------------------------------------------------------------------------
# Schema installation verification
# ---------------------------------------------------------------------------
info "Verifying schema installation..."
SCHEMA_COUNT=$(find "$SCHEMA_DIR" -name "*.schema" 2>/dev/null | wc -l)
if [ "$SCHEMA_COUNT" -lt 10 ]; then
    warn "Schema directory looks incomplete: only $SCHEMA_COUNT .schema files found in $SCHEMA_DIR"
    warn "Expected at least 60. Re-run install.sh or check for cp errors above."
else
    info "  Schema files installed: $SCHEMA_COUNT (in $SCHEMA_DIR)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " XCESP installation complete"
echo "====================================================================="
echo "  Active version  : $(head -1 "$MAINSW_DIR/VERSION" 2>/dev/null)"
echo ""
echo "  Binaries        : $BINDIR/{xcespserver,xcespcli,xcespproc,xcespwdog}"
echo "  mainsw          : $MAINSW_DIR/"
echo "  backupsw        : $BACKUPSW_DIR/  (empty — ready for a second version)"
echo "  Configuration   : $CFG_DIR/"
echo "  Logs            : $LOG_DIR/"
echo "  Schema          : $SCHEMA_DIR/    ($SCHEMA_COUNT .schema files)"
echo "  Rules           : $RULES_DIR/     (synced from mainsw on each start)"
if [ "$PYTHON_MODE" = "venv" ]; then
    echo "  Python          : venv at $VENV_DIR/"
else
    echo "  Python          : direct install at $PYLIB_DIR/ (no venv)"
fi
echo "  Runtime dir     : $RUN_DIR/       (ctrl.sock lives here)"
echo ""
echo "Review $CFG_DIR/xcespwdog.ini before starting the service."
echo ""
echo "  Start   : systemctl start xcesp"
echo "  Status  : systemctl status xcesp"
echo "  Logs    : journalctl -u xcesp -f   or   tail -f $LOG_DIR/xcesp.log"
echo "  CLI     : xcespcli [--socket $RUN_DIR/ctrl.sock]"
echo ""
echo "---------------------------------------------------------------------"
echo " Operator access"
echo "---------------------------------------------------------------------"
echo "  xcespcli connects via Unix socket: $RUN_DIR/ctrl.sock"
echo "  The socket is accessible only to members of the '$XCESP_GROUP' group."
echo ""
echo "  To grant CLI access to an operator account:"
echo "    sudo usermod -aG $XCESP_GROUP <username>"
echo "  The user must log out and back in for the new group to take effect."
echo ""
echo "---------------------------------------------------------------------"
echo " Schema TAB/? completion"
echo "---------------------------------------------------------------------"
echo "  xcespcli loads its schema automatically from xcespserver (CLI_ACK)."
echo "  If TAB completion does not work, verify:"
echo "    ls $SCHEMA_DIR/on-rtr/*.schema | wc -l   # should be ~55"
echo "    xcespcli --schema-dir $SCHEMA_DIR         # check for 'schema load failed'"
echo ""
echo "---------------------------------------------------------------------"
echo " Optional: physical-layer (ethtool) support"
echo "---------------------------------------------------------------------"
echo "  If you plan to use 'phy-managed true' on device-type interfaces"
echo "  (to inspect/force speed-duplex-autoneg and read SFP+DDMI), install"
echo "  the ethtool utility on this host:"
echo "    apt install ethtool   (Debian/Ubuntu)"
echo "    dnf install ethtool   (Fedora/RHEL)"
echo "  Without it, 'show physical interface <name>' will report"
echo "  'ethtool not installed' and per-namespace phy-managed objects"
echo "  will surface an 'ethtool-missing' applyWarning."
echo ""
echo "---------------------------------------------------------------------"
echo " Optional: DHCP feature daemons"
echo "---------------------------------------------------------------------"
echo "  XCESP's DHCP support drives a small set of standard daemons inside"
echo "  the router's netns.  Install them only for the modes you intend to"
echo "  enable; each PObj logs a warning and is otherwise inert when its"
echo "  binary is missing."
echo "    Client / Relay (v4 + v6) :"
echo "      apt install isc-dhcp-client isc-dhcp-relay    (Debian/Ubuntu)"
echo "      dnf install dhcp-client dhcp-relay            (Fedora/RHEL)"
echo "    Server, IPv4 (re-uses dnsmasq from the DNS feature; no extra pkg)"
echo "    Server, IPv6 :"
echo "      apt install kea-dhcp6-server                  (Debian/Ubuntu)"
echo "      dnf install kea                               (Fedora/RHEL)"
echo "  Persisted lease files live under $VAR_LIB_DIR/dhcp{-client,4,6}/."
echo ""
echo "To install a second version and swap:"
echo "  1. Unpack a new package into $BACKUPSW_DIR/"
echo "  2. sudo xcesp-swap.sh"
echo "  3. systemctl restart xcesp"
echo "====================================================================="
