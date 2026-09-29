#!/bin/bash
# run.sh — launch the xcesp-modem container on the target ARM device.
#
# Reads deployment parameters from command-line flags, translates them
# into `docker run` env-var flags, and starts the container detached.
# Two directories are bind-mounted from the host so state survives
# container restart:
#
#   /var/lib/xcesp — SMS counters, managed-users, dsk store
#   /var/log/xcesp — xcesp.log (via /var/xcesp/log inside)
#
# Network mode (--network) picks one of:
#
#   host    (default) — container is on the host's network directly.
#           transport-ip binds on the host's real interface.  Zero
#           port-forward config, simplest.  Requires --network=host
#           permission from the docker daemon.
#
#   bridge  — container gets a private IP (172.17.0.x) via docker's
#           default bridge.  Docker's SNAT rewrites the source IP on
#           outbound to the host's WAN/LAN address, so the RVP records
#           the host's IP for the modem (LOOKUP replies point at the
#           host, off-host peers can reach us).  Inbound needs
#           `-p <port>:<port>` DNAT rules, which this script emits
#           automatically for the transport TCP + UDP ports.
#           Under bridge, transport-ip is auto-clamped to 0.0.0.0
#           because the host's IP doesn't exist inside the container
#           netns (bind() would return EADDRNOTAVAIL).
#
# No cap-add flags are needed — the modem workload only opens
# unprivileged sockets + a serial device, none of which require
# CAP_NET_ADMIN or CAP_SYS_ADMIN.  (The routing / VRF / MPLS workload
# does; that lives in the full xcesppkg install, not this container.)
set -euo pipefail

# --- defaults ---
IMAGE="xcesp-modem:0.4.67-arm64"
CONTAINER_NAME="xcesp-modem"
SERIAL_DEV=""
MSISDN=""
RVP_IP=""
RVP_PORT="8888"
RVP_RENEWAL_SEC=""  # empty = entrypoint's default (300s)
TRANSPORT_IP=""
TRANSPORT_TCP_PORT="5001"
TRANSPORT_UDP_PORT="5011"
DTE_BAUD="9600"
CRYPTO_PASSPHRASE=""
SYSTEM_NAME=""
NETWORK_MODE="host"
STATE_DIR=""      # empty = use /var/lib/xcesp + /var/log/xcesp
DETACH="-d"
# DTE line-source overrides (optional).  See xcesp-on-xc's
# schema/dte-lines.schema for the grammar (`primary:<pin>` /
# `secondary:<pin>` / `gpio:<sysfs-path>` / `none`).  Typical mvebu-
# uart ONT need: --dcd-source primary:rts.
DTE_DCD_SOURCE=""
DTE_DSR_SOURCE=""
DTE_CTS_SOURCE=""
DTE_RI_SOURCE=""
DTE_DTR_SOURCE=""
DTE_RTS_SOURCE=""

usage() {
    cat <<'EOF'
usage: run.sh --msisdn <M> --rvp <IP> --transport-ip <IP> --serial <DEV> [options]

Required:
  --msisdn <M>            our own MSISDN (e.g. +34600000001)
  --rvp <IP>              RVP address
  --transport-ip <IP>     interface IP for our own SMS/CSD sockets
                          (ignored + overridden to 0.0.0.0 under
                          --network bridge)
  --serial <DEV>          host serial device (e.g. /dev/ttyUSB0)

Optional:
  --rvp-port <N>          default 8888
  --rvp-renewal <SEC>     REGISTER cadence in seconds (default 300)
  --tcp-port <N>          transport TCP port (default 5001)
  --udp-port <N>          transport UDP port (default 5011)
  --baud <N>              DTE baud rate (default 9600)
  --passphrase <S>        crypto-passphrase (omit = plaintext)
  --system-name <N>       device hostname (default xcesp-modem)
  --network <host|bridge> docker network mode (default host).  Use
                          bridge on hosts where --network=host is not
                          allowed by policy; the script auto-adds
                          the port-forward flags and clamps
                          transport-ip to 0.0.0.0.
  --state-dir <DIR>       root for persistent state (default:
                          /var/lib + /var/log).  When set, uses
                          <DIR>/lib and <DIR>/log — pick a path the
                          launching user can create + write, e.g.
                          /USERFS/disk2/USER/xcesp on Wistron ONT.
  --image <TAG>           docker image tag (default xcesp-modem:0.4.67-arm64)
  --name <N>              container name (default xcesp-modem)
  --foreground            run attached instead of detached
  --dry-run               print the docker command without running it
  --help                  show this

DTE serial line overrides (all optional; unset ones fall through to
the schema's `default=none`, which means "no physical mapping").
Grammar per value: `none`, `primary:<pin>`, `secondary:<pin>`, or
`gpio:<sysfs-path>` where <pin> is a lower-case TIOCM name (dtr,
rts, cts, dcd, dsr, ri).  Boards that lack the DCD pin typically
need `--dcd-source primary:rts` so AT&C1 behaves as expected.
  --dcd-source <SPEC>     re-source DCD egress
  --dsr-source <SPEC>     re-source DSR egress
  --cts-source <SPEC>     re-source CTS egress
  --ri-source  <SPEC>     re-source RI egress
  --dtr-source <SPEC>     re-source DTR ingress
  --rts-source <SPEC>     re-source RTS ingress

The serial device is passed through as-is under the same path inside
the container.  If the host uses a distinctive name (e.g. /dev/ttyMV1),
that's what the config inside the container sees.
EOF
}

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --msisdn)         MSISDN=$2; shift 2 ;;
        --rvp)            RVP_IP=$2; shift 2 ;;
        --rvp-port)       RVP_PORT=$2; shift 2 ;;
        --rvp-renewal)    RVP_RENEWAL_SEC=$2; shift 2 ;;
        --transport-ip)   TRANSPORT_IP=$2; shift 2 ;;
        --tcp-port)       TRANSPORT_TCP_PORT=$2; shift 2 ;;
        --udp-port)       TRANSPORT_UDP_PORT=$2; shift 2 ;;
        --serial)         SERIAL_DEV=$2; shift 2 ;;
        --baud)           DTE_BAUD=$2; shift 2 ;;
        --passphrase)     CRYPTO_PASSPHRASE=$2; shift 2 ;;
        --system-name)    SYSTEM_NAME=$2; shift 2 ;;
        --network)        NETWORK_MODE=$2; shift 2 ;;
        --state-dir)      STATE_DIR=$2; shift 2 ;;
        --dcd-source)     DTE_DCD_SOURCE=$2; shift 2 ;;
        --dsr-source)     DTE_DSR_SOURCE=$2; shift 2 ;;
        --cts-source)     DTE_CTS_SOURCE=$2; shift 2 ;;
        --ri-source)      DTE_RI_SOURCE=$2;  shift 2 ;;
        --dtr-source)     DTE_DTR_SOURCE=$2; shift 2 ;;
        --rts-source)     DTE_RTS_SOURCE=$2; shift 2 ;;
        --image)          IMAGE=$2; shift 2 ;;
        --name)           CONTAINER_NAME=$2; shift 2 ;;
        --foreground)     DETACH=""; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

for req_name in MSISDN RVP_IP TRANSPORT_IP SERIAL_DEV; do
    if [ -z "${!req_name}" ]; then
        echo "missing required option for $req_name" >&2
        usage >&2
        exit 2
    fi
done

case "$NETWORK_MODE" in
    host|bridge) ;;
    *) echo "--network must be 'host' or 'bridge' (got '$NETWORK_MODE')" >&2; exit 2 ;;
esac

if [ "$DRY_RUN" = 0 ]; then
    [ -c "$SERIAL_DEV" ] || {
        echo "$SERIAL_DEV is not a character device on this host" >&2
        exit 1
    }
fi

# Under bridge mode the host's LAN/WAN IP doesn't exist inside the
# container's netns.  Binding transport-ip=<host-ip> would fail with
# EADDRNOTAVAIL; override to 0.0.0.0 so bind() succeeds, and rely on
# docker's -p port-forwarding to make the container reachable at the
# host's real IP.
if [ "$NETWORK_MODE" = "bridge" ] && [ "$TRANSPORT_IP" != "0.0.0.0" ]; then
    echo "[run.sh] --network bridge: clamping TRANSPORT_IP $TRANSPORT_IP -> 0.0.0.0"
    echo "         (the host IP doesn't exist inside the container netns;"
    echo "          docker -p forwards will still expose it externally)"
    TRANSPORT_IP=0.0.0.0
fi

# Resolve state paths.  Default = the FHS locations under /var/{lib,log}
# (needs root or a pre-created writable parent).  --state-dir <DIR>
# points both under a single caller-owned root, useful on devices where
# /var is read-only for the container-launching user.
if [ -n "$STATE_DIR" ]; then
    STATE_LIB="$STATE_DIR/lib"
    STATE_LOG="$STATE_DIR/log"
else
    STATE_LIB="/var/lib/xcesp"
    STATE_LOG="/var/log/xcesp"
fi

# Assemble env args, only including CRYPTO_PASSPHRASE if set (empty
# string counts as unset per the entrypoint's `[ -n "${VAR:-}" ]`).
env_args=(
    -e "MSISDN=$MSISDN"
    -e "RVP_IP=$RVP_IP"
    -e "RVP_PORT=$RVP_PORT"
    -e "TRANSPORT_IP=$TRANSPORT_IP"
    -e "TRANSPORT_TCP_PORT=$TRANSPORT_TCP_PORT"
    -e "TRANSPORT_UDP_PORT=$TRANSPORT_UDP_PORT"
    -e "DTE_SERIAL_DEVICE=$SERIAL_DEV"
    -e "DTE_SERIAL_BAUD=$DTE_BAUD"
)
if [ -n "$SYSTEM_NAME" ]; then
    env_args+=(-e "SYSTEM_NAME=$SYSTEM_NAME")
fi
if [ -n "$CRYPTO_PASSPHRASE" ]; then
    env_args+=(-e "CRYPTO_PASSPHRASE=$CRYPTO_PASSPHRASE")
fi
if [ -n "$RVP_RENEWAL_SEC" ]; then
    env_args+=(-e "RVP_RENEWAL_SEC=$RVP_RENEWAL_SEC")
fi
# DTE line-source overrides — forward only the set ones so unset
# ones fall through to schema `default=none` on the container side.
for src in DCD DSR CTS RI DTR RTS; do
    var="DTE_${src}_SOURCE"
    if [ -n "${!var}" ]; then
        env_args+=(-e "${var}=${!var}")
    fi
done

# Network + port-forward args differ per mode.
net_args=()
if [ "$NETWORK_MODE" = "host" ]; then
    net_args+=(--network=host)
else
    net_args+=(--network=bridge)
    net_args+=(-p "${TRANSPORT_TCP_PORT}:${TRANSPORT_TCP_PORT}")
    net_args+=(-p "${TRANSPORT_UDP_PORT}:${TRANSPORT_UDP_PORT}/udp")
fi

docker_cmd=(
    docker run $DETACH
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    "${net_args[@]}"
    --device="$SERIAL_DEV:$SERIAL_DEV"
    -v "$STATE_LIB:/var/lib/xcesp"
    -v "$STATE_LOG:/var/xcesp/log"
    "${env_args[@]}"
    "$IMAGE"
)

if [ "$DRY_RUN" = 1 ]; then
    printf '%q ' "${docker_cmd[@]}"
    echo
    exit 0
fi

# Persistent host paths.  Created if missing so a fresh device works
# without an install step — fails loudly if the launching user can't
# create them (e.g. default /var paths on a restricted-root device).
mkdir -p "$STATE_LIB" "$STATE_LOG" || {
    echo "" >&2
    echo "cannot create state dirs $STATE_LIB and/or $STATE_LOG" >&2
    echo "either run as root, or pass --state-dir <path-you-can-write>" >&2
    exit 1
}

# Remove any prior container of the same name (docker refuses a name
# collision).  Ignore errors — first run has nothing to remove.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

set -x
exec "${docker_cmd[@]}"
