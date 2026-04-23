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
VENV_DIR=$XCESP_BASE/venv
MAINSW_DIR=$XCESP_BASE/mainsw
BACKUPSW_DIR=$XCESP_BASE/backupsw
RUN_DIR=/run/xcesp
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
if ! getent passwd "$XCESP_USER" > /dev/null 2>&1; then
    useradd --system \
            --gid "$XCESP_GROUP" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "XCESP service account" \
            "$XCESP_USER"
    info "  Created user: $XCESP_USER"
fi

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
info "Creating directory layout..."
for d in "$CFG_DIR" "$LOG_DIR" "$SCHEMA_DIR" \
          "$RULES_DIR/config-to-objects" "$RULES_DIR/status-to-global" \
          "$MAINSW_DIR/bin" "$MAINSW_DIR/schema" \
          "$MAINSW_DIR/rules/config-to-objects" "$MAINSW_DIR/rules/status-to-global" \
          "$MAINSW_DIR/python" \
          "$RUN_DIR"; do
    mkdir -p "$d"
done

# backupsw: create only if it does not exist (preserve any existing backup)
if [ ! -d "$BACKUPSW_DIR" ]; then
    mkdir -p "$BACKUPSW_DIR"
    info "  Created empty $BACKUPSW_DIR"
else
    info "  $BACKUPSW_DIR already exists — leaving untouched"
fi

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

# ---------------------------------------------------------------------------
# Capabilities (xcespproc needs namespace + network admin)
# ---------------------------------------------------------------------------
info "Setting file capabilities on xcespproc..."
if command -v setcap > /dev/null 2>&1; then
    setcap cap_net_admin,cap_sys_admin=ep "$BINDIR/xcespproc"
    setcap cap_net_admin,cap_sys_admin=ep "$MAINSW_DIR/bin/xcespproc"
    info "  cap_net_admin,cap_sys_admin=ep set"
else
    warn "setcap not found — install libcap2-bin (Debian/Ubuntu) or libcap (RHEL/Fedora)"
    warn "Then run:  setcap cap_net_admin,cap_sys_admin=ep $BINDIR/xcespproc"
fi

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
        > "$FRR_SUDOERS"
        [ -n "$FRRINIT" ] && \
            echo "$XCESP_USER ALL=(root) NOPASSWD: $FRRINIT *" >> "$FRR_SUDOERS" && \
            info "  sudoers: $XCESP_USER → $FRRINIT"
        [ -n "$VTYSH_BIN" ] && \
            echo "$XCESP_USER ALL=(root) NOPASSWD: $VTYSH_BIN *" >> "$FRR_SUDOERS" && \
            info "  sudoers: $XCESP_USER → $VTYSH_BIN"
        chmod 0440 "$FRR_SUDOERS"
        info "  $FRR_SUDOERS installed"
    else
        info "  frrinit.sh not found — skipping FRR sudoers rule (install FRR first)"
    fi
else
    info "  frr group not found — FRR not installed, skipping"
fi

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
                            /usr/sbin/modprobe vxlan
SUDOERS
chmod 0440 "$SUDOERS_FILE"
info "  $SUDOERS_FILE installed"

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
# VERSION → mainsw/VERSION
# ---------------------------------------------------------------------------
if [ -f "$INSTALL_DIR/VERSION" ]; then
    cp "$INSTALL_DIR/VERSION" "$MAINSW_DIR/VERSION"
    info "  VERSION: $(head -1 "$MAINSW_DIR/VERSION")"
fi

# ---------------------------------------------------------------------------
# Activate mainsw → working locations (schema, rules)
# ---------------------------------------------------------------------------
info "Activating mainsw to working locations..."
cp -rT "$MAINSW_DIR/schema" "$SCHEMA_DIR"
cp -rT "$MAINSW_DIR/rules"  "$RULES_DIR"

# ---------------------------------------------------------------------------
# Fix ownership and permissions
# ---------------------------------------------------------------------------
chown -R "$XCESP_USER:$XCESP_GROUP" \
    "$MAINSW_DIR" "$CFG_DIR" "$LOG_DIR" "$SCHEMA_DIR" "$RULES_DIR"
chmod 0750 "$CFG_DIR" "$LOG_DIR"
find "$SCHEMA_DIR" -type d -exec chmod 0755 {} \;
find "$SCHEMA_DIR" -type f -exec chmod 0644 {} \;
find "$RULES_DIR"  -type d  -exec chmod 0755 {} \;
find "$RULES_DIR"  -type f -name "*.py" -exec chmod 0755 {} \;
find "$MAINSW_DIR" -type d -exec chmod 0755 {} \;
chmod 0750 "$MAINSW_DIR"
# backupsw stays root-owned (empty placeholder)
chown root:root "$BACKUPSW_DIR"
chmod 0755 "$BACKUPSW_DIR"
chown "$XCESP_USER:$XCESP_GROUP" "$RUN_DIR"
chmod 0750 "$RUN_DIR"

# ---------------------------------------------------------------------------
# Python virtual environment (at /var/xcesp/venv — not swapped)
# ---------------------------------------------------------------------------
info "Setting up Python virtual environment at $VENV_DIR ..."

if ! python3 -c "import venv" > /dev/null 2>&1; then
    error "python3-venv is not available.\n  Debian/Ubuntu: apt install python3-venv\n  RHEL/Fedora:   dnf install python3"
fi

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip

# Install xcesppy from mainsw/python
if [ -f "$MAINSW_DIR/python/pyproject.toml" ]; then
    info "  Installing xcesppy into virtual environment..."
    "$VENV_DIR/bin/pip" install --quiet "$MAINSW_DIR/python"
fi

# Install any additional requirements (future packages go here)
if [ -f "$MAINSW_DIR/python/requirements.txt" ]; then
    info "  Installing additional Python requirements..."
    "$VENV_DIR/bin/pip" install --quiet -r "$MAINSW_DIR/python/requirements.txt"
fi

chown -R "$XCESP_USER:$XCESP_GROUP" "$VENV_DIR"
chmod -R o-rwx "$VENV_DIR"

# ---------------------------------------------------------------------------
# Management scripts → /usr/bin/
# ---------------------------------------------------------------------------
info "Installing management scripts..."
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-activate" "$BINDIR/xcesp-activate"
install -o root -g root -m 0755 \
    "$INSTALL_DIR/scripts/xcesp-swap.sh"  "$BINDIR/xcesp-swap.sh"
info "  $BINDIR/xcesp-activate"
info "  $BINDIR/xcesp-swap.sh"

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
echo "  Python venv     : $VENV_DIR/"
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
echo "To install a second version and swap:"
echo "  1. Unpack a new package into $BACKUPSW_DIR/"
echo "  2. sudo xcesp-swap.sh"
echo "  3. systemctl restart xcesp"
echo "====================================================================="
