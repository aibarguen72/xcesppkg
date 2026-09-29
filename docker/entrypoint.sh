#!/bin/bash
# entrypoint.sh — xcesp-modem container init.
#
# Reads deployment parameters from environment variables and generates
# /var/xcesp/cfg/xcespserver.conf on every start.  Then exec's
# xcespwdog as PID 1.
#
# The container is intentionally stateless w.r.t. config: whatever's
# in the docker run env wins on restart, and any operator changes
# made through xcespcli are lost.  Persistent state (SMS counters,
# managed-users, dsk store) lives under /var/lib/xcesp which is
# expected to be bind-mounted from the host.
set -euo pipefail

# ---------------------------------------------------------------------------
# Required parameters — fail fast on missing rather than silently
# generating a broken config that xcespserver rejects with a subtle
# schema-validation warning buried in the log.
# ---------------------------------------------------------------------------
require() {
    local name=$1
    if [ -z "${!name:-}" ]; then
        echo "[xcesp-modem] required env var $name is not set" >&2
        exit 2
    fi
}

require MSISDN
require RVP_IP
require TRANSPORT_IP
require DTE_SERIAL_DEVICE

# ---------------------------------------------------------------------------
# Defaults for optional parameters.
# ---------------------------------------------------------------------------
: "${SYSTEM_NAME:=xcesp-modem}"
: "${MODEM_NAME:=modem1}"
: "${DOMAIN_NAME:=lab}"
: "${PROFILE:=wismo-q2403a}"
: "${DTE_SERIAL_BAUD:=9600}"
: "${TRANSPORT_TCP_PORT:=5001}"
: "${TRANSPORT_UDP_PORT:=5011}"
: "${RVP_PORT:=8888}"
: "${RVP_RENEWAL_SEC:=300}"

# CRYPTO_PASSPHRASE is intentionally optional (per operator decision on
# 2026-09-24): unset → no `crypto-passphrase` line → modem runs
# plaintext against the RVP + peers.  Set → line is emitted and the
# same passphrase must be configured on the RVP (either as a
# `crypto-peer <MSISDN>` explicit entry or the `crypto-peer *`
# wildcard fallback).

# ---------------------------------------------------------------------------
# Sanity check: serial device must actually be present at container
# start.  Better to fail here with a clear message than let xcespproc
# log a cryptic "openDteSerial failed: ENOENT" 5 seconds after boot.
# ---------------------------------------------------------------------------
if [ ! -c "$DTE_SERIAL_DEVICE" ]; then
    echo "[xcesp-modem] $DTE_SERIAL_DEVICE is not a character device" >&2
    echo "              did you pass --device=<host>:$DTE_SERIAL_DEVICE to docker run?" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# Persistent-config mode (opt-in via CONFIG_PERSIST=1).
#
# Default behaviour of this container is stateless w.r.t. config: the
# generator below rewrites /var/xcesp/cfg/xcespserver.conf from env
# vars on every start, so any `configure/commit/save` the operator
# runs via xcespcli is discarded on restart.  That's the right posture
# for a fleet of identical field modems.
#
# When CONFIG_PERSIST=1 (set by `xcesp-modem.sh start --persist-config`),
# the operator also bind-mounts /var/xcesp/cfg/xcespserver.conf from
# the host.  Two cases:
#
#   file is non-empty  → treat it as authoritative; DO NOT regenerate.
#                        Env vars (MSISDN, RVP_IP, etc.) are effectively
#                        ignored — the operator is now managing config
#                        via CLI, and xcespserver's `save` writes back
#                        through the same bind mount → survives restart.
#
#   file is empty      → first launch on this device.  Fall through to
#                        the env-var-driven generator below; that write
#                        lands in the host file via the bind mount and
#                        persists from here on.
#
# Intended use: the single fleet device that ALSO hosts pstn-rvp (needs
# a growing crypto-peer list) or carries `license-code` lines under
# server 1 (fleet licensing).  Every other device leaves CONFIG_PERSIST
# unset and gets today's stateless behaviour.
# ---------------------------------------------------------------------------
CFG=/var/xcesp/cfg/xcespserver.conf
if [ "${CONFIG_PERSIST:-0}" = "1" ] && [ -s "$CFG" ]; then
    echo "[xcesp-modem] persist mode: using existing $CFG ($(wc -l < "$CFG") lines) from host bind mount"
    echo "[xcesp-modem]   env-var config inputs (MSISDN, RVP_IP, TRANSPORT_IP,"
    echo "[xcesp-modem]   DTE_*, CRYPTO_PASSPHRASE, DTE_*_SOURCE) are IGNORED —"
    echo "[xcesp-modem]   edit via 'xcesp-modem.sh cli' and commit+save instead."
    # Skip the generator and jump straight to the launch section.
    CFG_SKIP_GEN=1
fi

# ---------------------------------------------------------------------------
# Generate xcespserver.conf.  Assembly-by-hand (rather than envsubst)
# because we want the crypto-passphrase line to conditionally appear;
# envsubst has no natural way to say "emit this line only if X is set"
# without leaving a stray blank line.
# ---------------------------------------------------------------------------
if [ "${CFG_SKIP_GEN:-0}" = "1" ]; then :; else
{
    echo "management"
    echo "  system"
    echo "    system-name $SYSTEM_NAME"
    echo "  !"
    echo "!"
    echo ""
    echo "domain $DOMAIN_NAME"
    echo "  modem $MODEM_NAME"
    echo "    profile $PROFILE"
    echo "    msisdn $MSISDN"
    echo "    dte-endpoint serial"
    echo "    dte-serial-device $DTE_SERIAL_DEVICE"
    echo "    dte-serial-baud $DTE_SERIAL_BAUD"
    echo "    transport-ip $TRANSPORT_IP"
    echo "    transport-tcp-port $TRANSPORT_TCP_PORT"
    echo "    transport-udp-port $TRANSPORT_UDP_PORT"
    echo "    rvp-ip $RVP_IP"
    echo "    rvp-port $RVP_PORT"
    echo "    rvp-renewal-seconds $RVP_RENEWAL_SEC"
    if [ -n "${CRYPTO_PASSPHRASE:-}" ]; then
        echo "    crypto-passphrase $CRYPTO_PASSPHRASE"
    fi
    # Optional `dte-lines` child.  Emitted only when at least one
    # DTE_*_SOURCE env var is set — matches the schema convention that
    # every source attr defaults to `none` (no physical mapping).
    # Typical use on the lab Wistron ONT (mvebu-uart on /dev/ttyMV1
    # exposes RTS/CTS to the DB9 but not DCD/DSR/DTR/RI):
    #   -e DTE_DCD_SOURCE=primary:rts
    # remaps the modem's DCD egress onto the RTS pin so AT&C1 behaves
    # as expected on a board that physically lacks a DCD wire.
    if [ -n "${DTE_DCD_SOURCE:-}${DTE_DSR_SOURCE:-}${DTE_CTS_SOURCE:-}${DTE_RI_SOURCE:-}${DTE_DTR_SOURCE:-}${DTE_RTS_SOURCE:-}" ]; then
        echo "    dte-lines"
        [ -n "${DTE_DCD_SOURCE:-}" ] && echo "      dcd-source $DTE_DCD_SOURCE"
        [ -n "${DTE_DSR_SOURCE:-}" ] && echo "      dsr-source $DTE_DSR_SOURCE"
        [ -n "${DTE_CTS_SOURCE:-}" ] && echo "      cts-source $DTE_CTS_SOURCE"
        [ -n "${DTE_RI_SOURCE:-}"  ] && echo "      ri-source $DTE_RI_SOURCE"
        [ -n "${DTE_DTR_SOURCE:-}" ] && echo "      dtr-source $DTE_DTR_SOURCE"
        [ -n "${DTE_RTS_SOURCE:-}" ] && echo "      rts-source $DTE_RTS_SOURCE"
        echo "    !"
    fi
    echo "  !"
    echo "!"
    echo ""
    echo "server 1"
    echo "  hostname $SYSTEM_NAME"
    echo "  processes routing"
    echo "    count 1"
    echo "  !"
    echo "!"
} > "$CFG"

echo "[xcesp-modem] generated $CFG"
echo "[xcesp-modem]   MSISDN=$MSISDN  RVP=$RVP_IP:$RVP_PORT" \
     "transport=$TRANSPORT_IP:$TRANSPORT_TCP_PORT/$TRANSPORT_UDP_PORT" \
     "dte=$DTE_SERIAL_DEVICE@$DTE_SERIAL_BAUD" \
     "crypto=$([ -n "${CRYPTO_PASSPHRASE:-}" ] && echo on || echo off)"
fi   # end of CFG_SKIP_GEN guard

# ---------------------------------------------------------------------------
# Ensure runtime dirs exist and are writable.  /run/xcesp is tmpfs
# inside the container (never bind-mounted).  /var/xcesp/log and
# /var/lib/xcesp are typically bind-mounts from the host — create
# them defensively in case the operator forgot the -v flags.
# ---------------------------------------------------------------------------
mkdir -p /run/xcesp /var/xcesp/log /var/lib/xcesp /var/xcesp/dsk

# ---------------------------------------------------------------------------
# Wait for TRANSPORT_IP to become bindable before launching xcespwdog.
#
# On a cold boot, docker's --restart=unless-stopped can bring the
# container up before the host has finished configuring the interface
# that carries our transport IP (typical: link-local /16 on a lanN
# port that only appears after ifplugd or the boot's network stage
# completes).  If we launch xcespwdog before that, SmsTransport's
# bind(TRANSPORT_IP:UDP) fails with EADDRNOTAVAIL, ModemXc bring-up
# errors out, and wdog never retries the modem (soft LLD isn't a
# process-crash so wdog's respawn logic doesn't fire).  Container ends
# up "docker ps Up" but with no working modem — silent failure mode.
#
# Under --network=bridge the operator's TRANSPORT_IP is clamped to
# 0.0.0.0 by run.sh (docker's -p forward exposes the port), which is
# always bindable, so we skip the wait entirely.
#
# The bind-test uses python3 (already in the image for other tooling)
# rather than depending on iproute2 — one less apt package to carry
# and the actual bind() is exactly what xcespproc will do next.
# ---------------------------------------------------------------------------
: "${TRANSPORT_IP_WAIT_SECONDS:=60}"
if [ "$TRANSPORT_IP" != "0.0.0.0" ] && [ "$TRANSPORT_IP_WAIT_SECONDS" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$TRANSPORT_IP_WAIT_SECONDS" ]; do
        if python3 - "$TRANSPORT_IP" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.bind((sys.argv[1], 0))
finally:
    s.close()
PY
        then
            [ "$i" -gt 0 ] && \
                echo "[xcesp-modem] $TRANSPORT_IP became bindable after ${i}s"
            break
        fi
        i=$((i + 1))
        if [ "$i" = 1 ]; then
            echo "[xcesp-modem] $TRANSPORT_IP not yet on any interface —" \
                 "waiting up to ${TRANSPORT_IP_WAIT_SECONDS}s"
        fi
        sleep 1
    done
    if [ "$i" -ge "$TRANSPORT_IP_WAIT_SECONDS" ]; then
        echo "[xcesp-modem] $TRANSPORT_IP still not bindable after" \
             "${TRANSPORT_IP_WAIT_SECONDS}s — launching anyway (modem" \
             "bring-up will fail loudly)" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Hand off to xcespwdog as PID 1.  `exec` so signals (SIGTERM from
# `docker stop`) reach xcespwdog directly, which forwards to
# xcespserver + xcespproc for a clean shutdown.
# ---------------------------------------------------------------------------
exec /usr/bin/xcespwdog --config /var/xcesp/cfg/xcespwdog.ini
