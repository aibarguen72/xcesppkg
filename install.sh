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
          "$RUN_DIR"; do
    mkdir -p "$d"
done

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------
info "Installing binaries to $BINDIR ..."
for bin in xcespserver xcespcli xcespproc xcespwdog; do
    src="$INSTALL_DIR/bin/$bin"
    [ -f "$src" ] || error "Binary not found in package: $src"
    install -o root -g root -m 0755 "$src" "$BINDIR/$bin"
    info "  $BINDIR/$bin"
done

# ---------------------------------------------------------------------------
# Capabilities (xcespproc needs namespace + network admin)
# ---------------------------------------------------------------------------
info "Setting file capabilities on xcespproc..."
if command -v setcap > /dev/null 2>&1; then
    setcap cap_net_admin,cap_sys_admin=ep "$BINDIR/xcespproc"
    info "  cap_net_admin,cap_sys_admin=ep set on $BINDIR/xcespproc"
else
    warn "setcap not found — install libcap2-bin (Debian/Ubuntu) or libcap (RHEL/Fedora)"
    warn "Then run:  setcap cap_net_admin,cap_sys_admin=ep $BINDIR/xcespproc"
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
# Schema
# ---------------------------------------------------------------------------
info "Installing schema to $SCHEMA_DIR ..."
cp -rT "$INSTALL_DIR/schema" "$SCHEMA_DIR"
chown -R "$XCESP_USER:$XCESP_GROUP" "$SCHEMA_DIR"
find "$SCHEMA_DIR" -type d -exec chmod 0755 {} \;
find "$SCHEMA_DIR" -type f -exec chmod 0644 {} \;

# ---------------------------------------------------------------------------
# Python rules
# ---------------------------------------------------------------------------
info "Installing Python rules to $RULES_DIR ..."
cp -rT "$INSTALL_DIR/rules" "$RULES_DIR"
chown -R "$XCESP_USER:$XCESP_GROUP" "$RULES_DIR"
find "$RULES_DIR" -type d  -exec chmod 0755 {} \;
find "$RULES_DIR" -type f -name "*.py" -exec chmod 0755 {} \;

# ---------------------------------------------------------------------------
# Python virtual environment
# ---------------------------------------------------------------------------
info "Setting up Python virtual environment at $VENV_DIR ..."

if ! python3 -c "import venv" > /dev/null 2>&1; then
    error "python3-venv is not available.\n  Debian/Ubuntu: apt install python3-venv\n  RHEL/Fedora:   dnf install python3"
fi

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip

# Install xcesppy if bundled
PYTHON_PKG="$INSTALL_DIR/python"
if [ -f "$PYTHON_PKG/pyproject.toml" ]; then
    info "  Installing xcesppy into virtual environment..."
    "$VENV_DIR/bin/pip" install --quiet "$PYTHON_PKG"
fi

# Install any additional requirements (future packages go here)
if [ -f "$PYTHON_PKG/requirements.txt" ]; then
    info "  Installing additional Python requirements..."
    "$VENV_DIR/bin/pip" install --quiet -r "$PYTHON_PKG/requirements.txt"
fi

chown -R "$XCESP_USER:$XCESP_GROUP" "$VENV_DIR"
chmod -R o-rwx "$VENV_DIR"

# ---------------------------------------------------------------------------
# Fix up ownership
# ---------------------------------------------------------------------------
chown -R "$XCESP_USER:$XCESP_GROUP" "$CFG_DIR" "$LOG_DIR"
chmod 0750 "$CFG_DIR" "$LOG_DIR"
chown "$XCESP_USER:$XCESP_GROUP" "$RUN_DIR"
chmod 0750 "$RUN_DIR"

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
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "====================================================================="
echo " XCESP installation complete"
echo "====================================================================="
echo "  Binaries      : $BINDIR/xcespserver, xcespcli, xcespproc, xcespwdog"
echo "  Configuration : $CFG_DIR/"
echo "  Logs          : $LOG_DIR/"
echo "  Schema        : $SCHEMA_DIR/"
echo "  Rules         : $RULES_DIR/"
echo "  Python venv   : $VENV_DIR/"
echo "  Runtime dir   : $RUN_DIR/   (ctrl.sock lives here)"
echo ""
echo "Review $CFG_DIR/xcespwdog.ini before starting the service."
echo ""
echo "  Start   : systemctl start xcesp"
echo "  Status  : systemctl status xcesp"
echo "  Logs    : journalctl -u xcesp -f"
echo "  CLI     : xcespcli [--socket $RUN_DIR/ctrl.sock]"
echo "====================================================================="
