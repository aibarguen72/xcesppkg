#!/bin/bash
# xcesp-modem.sh — single operator entry point for the xcesp-modem container.
#
# Replaces the earlier separate load.sh + run.sh with a `<action> [opts]`
# dispatcher.  Ship one script + one tar to the customer device.
#
# Actions:
#   load <TAR>              docker load + auto-retag (podman prefix quirk)
#   start [<start opts>]    docker run — same flags as the old run.sh
#   stop                    docker stop xcesp-modem
#   restart                 docker restart xcesp-modem  (same-config restart;
#                           for a fresh config, use `remove` + `start`)
#   remove | rm             docker rm -f xcesp-modem
#   log [-f]                tail <state-dir>/log/xcesp.log (survives ungraceful
#                           power-off) — add --docker to use docker logs -f
#   cli [<args...>]         docker exec -it xcesp-modem xcespcli <args>
#   status                  docker ps + xcespcli `show modem`
#   shell                   docker exec -it xcesp-modem /bin/bash
#   version                 print image tag currently installed
#   help                    this help
set -euo pipefail

DEFAULT_IMAGE="xcesp-modem:0.4.71-arm64"
DEFAULT_NAME="xcesp-modem"

die() { echo "$@" >&2; exit 1; }

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
action_help() {
    cat <<EOF
usage: $(basename "$0") <action> [options]

Actions:
  load <TAR>              load a container tar into docker + auto-retag
  start [start-opts]      launch the modem container (see 'start --help')
  stop                    docker stop
  restart                 docker restart (same-config)
  remove | rm             docker rm -f
  log [-f] [--docker]     tail the modem log
  cli [xcespcli args]     run xcespcli inside the container (interactive)
  status                  container + modem status snapshot
  shell                   interactive bash inside the container
  version                 print the currently-installed image tag
  help                    this help

Typical first-time deployment:
  ./xcesp-modem.sh load xcesp-modem-0.4.71-arm64.tar
  ./xcesp-modem.sh start --msisdn +34600000001 --rvp 169.254.1.2 \\
       --transport-ip 169.254.1.1 --serial /dev/ttyMV1 \\
       --state-dir /USERFS/rados_user_files/xcesp \\
       --passphrase <fleet-secret> --dcd-source primary:rts
  ./xcesp-modem.sh log -f
EOF
}

# ---------------------------------------------------------------------------
# load
# ---------------------------------------------------------------------------
action_load() {
    local TAR="${1:-}"
    [ -n "$TAR" ] || die "usage: $0 load <xcesp-modem-*.tar>"
    [ -f "$TAR" ] || die "not found: $TAR"

    echo "==> loading $TAR into docker"
    docker load -i "$TAR"

    # Podman-built images arrive with a `localhost/` prefix that our
    # start action's default image tag doesn't include; retag once so
    # the operator doesn't have to remember the workaround.
    local localhost_tag
    localhost_tag=$(docker images --format '{{.Repository}}:{{.Tag}}' \
                    | grep -m1 '^localhost/xcesp-modem:' || true)
    if [ -n "$localhost_tag" ]; then
        local plain="${localhost_tag#localhost/}"
        if ! docker image inspect "$plain" >/dev/null 2>&1; then
            docker tag "$localhost_tag" "$plain"
            echo "==> tagged $localhost_tag -> $plain"
        fi
    fi

    echo "==> installed images:"
    docker images | grep -E '^(REPOSITORY|xcesp-modem)' || true
}

# ---------------------------------------------------------------------------
# start — the whole run.sh flag surface, mostly verbatim
# ---------------------------------------------------------------------------
start_usage() {
    cat <<'EOF'
usage: xcesp-modem.sh start --msisdn <M> --rvp <IP> \
                            --transport-ip <IP> --serial <DEV> [options]

Required:
  --msisdn <M>            our own MSISDN (e.g. +34600000001)
  --rvp <IP>              RVP address
  --transport-ip <IP>     interface IP for our own SMS/CSD sockets
                          (ignored + overridden to 0.0.0.0 under
                          --network bridge)
  --serial <DEV>          host serial device (e.g. /dev/ttyUSB0)

Optional:
  --rvp-port <N>          default 8888
  --rvp-renewal <SEC>     REGISTER cadence (default 300)
  --tcp-port <N>          transport TCP port (default 5001)
  --udp-port <N>          transport UDP port (default 5011)
  --baud <N>              DTE baud rate (default 9600)
  --passphrase <S>        crypto-passphrase (omit = plaintext)
  --system-name <N>       device hostname (default xcesp-modem)
  --network <host|bridge> docker network mode (default host)
  --state-dir <DIR>       root for persistent state (default
                          /var/lib + /var/log — pick a caller-writable
                          path on restricted-root devices)
  --image <TAG>           docker image tag (default xcesp-modem:0.4.71-arm64)
  --name <N>              container name (default xcesp-modem)
  --foreground            run attached instead of detached
  --dry-run               print the docker command without running it

DTE serial line overrides (mvebu-uart-on-ONT typically needs
--dcd-source primary:rts):
  --dcd-source <SPEC>     re-source DCD egress
  --dsr-source <SPEC>     re-source DSR egress
  --cts-source <SPEC>     re-source CTS egress
  --ri-source  <SPEC>     re-source RI egress
  --dtr-source <SPEC>     re-source DTR ingress
  --rts-source <SPEC>     re-source RTS ingress

Log rotation (inside the container, no host cron/logrotate needed):
  --log-max-mb <N>        cap /var/xcesp/log/xcesp.log at N MB
                          (default 10; 0 = disable rotation)
  --log-keep <N>          keep N rotated archives .1, .2, ..., .N
                          (default 4)

Licensing (RVP-hosting device only — ordinary fleet devices are
licensed centrally at the RVP and need nothing here):
  --license-auth <SPEC>   emit a `license-auth` line inside the
                          generated server 1 block.  SPEC values:
                            system-mac        -> license-auth system-mac
                            <iface-name>      -> license-auth mac-device <iface>
                          e.g. `--license-auth wan1` on the
                          Wistron ONT.  Under --network=host the
                          container can read /sys/class/net/<iface>
                          from the host.  Pair with --persist-config
                          so operator-added license-code lines
                          survive restart.

Config persistence (opt-in, for the one fleet device that also
hosts pstn-rvp / carries fleet license-code lines):
  --persist-config [<PATH>]
                          store xcespserver.conf on the host so
                          xcespcli's `configure/commit/save` edits
                          survive container restart.  Default PATH:
                          <state-dir>/xcespserver.conf.  On first
                          launch, env vars seed the file; on
                          subsequent launches, the file is used
                          as-is and MSISDN/RVP/etc. env vars are
                          IGNORED (the operator manages config
                          via CLI at that point).
EOF
}

action_start() {
    # --- defaults ---
    local IMAGE="$DEFAULT_IMAGE" CONTAINER_NAME="$DEFAULT_NAME"
    local SERIAL_DEV="" MSISDN="" RVP_IP="" RVP_PORT="8888"
    local RVP_RENEWAL_SEC="" TRANSPORT_IP=""
    local TRANSPORT_TCP_PORT="5001" TRANSPORT_UDP_PORT="5011"
    local DTE_BAUD="9600" CRYPTO_PASSPHRASE="" SYSTEM_NAME=""
    local NETWORK_MODE="host" STATE_DIR="" DETACH="-d" DRY_RUN=0
    local DTE_DCD_SOURCE="" DTE_DSR_SOURCE="" DTE_CTS_SOURCE=""
    local DTE_RI_SOURCE=""  DTE_DTR_SOURCE="" DTE_RTS_SOURCE=""
    # Persistent config: empty = disabled (default); "auto" = enabled
    # with default host path <state-dir>/xcespserver.conf; explicit
    # absolute path = enabled + use that path.
    local PERSIST_CONFIG=""
    # License-auth: empty = no license-auth line emitted (default —
    # ordinary fleet devices don't need licensing).  Otherwise
    # `system-mac` or an interface name.
    local LICENSE_AUTH=""
    # In-container log rotator caps (empty = use rotator's own
    # defaults of 10 MB × 4 archives).  Set LOG_MAX_MB=0 to disable.
    local LOG_MAX_MB="" LOG_KEEP=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --msisdn)        MSISDN=$2; shift 2 ;;
            --rvp)           RVP_IP=$2; shift 2 ;;
            --rvp-port)      RVP_PORT=$2; shift 2 ;;
            --rvp-renewal)   RVP_RENEWAL_SEC=$2; shift 2 ;;
            --transport-ip)  TRANSPORT_IP=$2; shift 2 ;;
            --tcp-port)      TRANSPORT_TCP_PORT=$2; shift 2 ;;
            --udp-port)      TRANSPORT_UDP_PORT=$2; shift 2 ;;
            --serial)        SERIAL_DEV=$2; shift 2 ;;
            --baud)          DTE_BAUD=$2; shift 2 ;;
            --passphrase)    CRYPTO_PASSPHRASE=$2; shift 2 ;;
            --system-name)   SYSTEM_NAME=$2; shift 2 ;;
            --network)       NETWORK_MODE=$2; shift 2 ;;
            --state-dir)     STATE_DIR=$2; shift 2 ;;
            --dcd-source)    DTE_DCD_SOURCE=$2; shift 2 ;;
            --dsr-source)    DTE_DSR_SOURCE=$2; shift 2 ;;
            --cts-source)    DTE_CTS_SOURCE=$2; shift 2 ;;
            --ri-source)     DTE_RI_SOURCE=$2;  shift 2 ;;
            --dtr-source)    DTE_DTR_SOURCE=$2; shift 2 ;;
            --rts-source)    DTE_RTS_SOURCE=$2; shift 2 ;;
            --image)         IMAGE=$2; shift 2 ;;
            --name)          CONTAINER_NAME=$2; shift 2 ;;
            --foreground)    DETACH=""; shift ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --license-auth)  LICENSE_AUTH=$2; shift 2 ;;
            --log-max-mb)    LOG_MAX_MB=$2; shift 2 ;;
            --log-keep)      LOG_KEEP=$2;   shift 2 ;;
            --persist-config)
                # Accept optional PATH argument.  If the next token starts
                # with '-' or is absent, use the "auto" sentinel; else
                # consume the token as an absolute path override.
                if [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
                    PERSIST_CONFIG=$2; shift 2
                else
                    PERSIST_CONFIG=auto; shift
                fi ;;
            --help|-h)       start_usage; return 0 ;;
            *) echo "unknown start option: $1" >&2; start_usage >&2; return 2 ;;
        esac
    done

    local flag_of
    for req in MSISDN RVP_IP TRANSPORT_IP SERIAL_DEV; do
        if [ -z "${!req}" ]; then
            case "$req" in
                MSISDN)       flag_of=--msisdn ;;
                RVP_IP)       flag_of=--rvp ;;
                TRANSPORT_IP) flag_of=--transport-ip ;;
                SERIAL_DEV)   flag_of=--serial ;;
            esac
            die "missing required start option: $flag_of"
        fi
    done

    case "$NETWORK_MODE" in
        host|bridge) ;;
        *) die "--network must be 'host' or 'bridge' (got '$NETWORK_MODE')" ;;
    esac

    if [ "$DRY_RUN" = 0 ] && [ ! -c "$SERIAL_DEV" ]; then
        die "$SERIAL_DEV is not a character device on this host"
    fi

    # Under bridge, TRANSPORT_IP doesn't exist inside the container netns;
    # clamp to 0.0.0.0 and rely on -p forwards.
    if [ "$NETWORK_MODE" = "bridge" ] && [ "$TRANSPORT_IP" != "0.0.0.0" ]; then
        echo "[start] --network bridge: clamping TRANSPORT_IP $TRANSPORT_IP -> 0.0.0.0"
        TRANSPORT_IP=0.0.0.0
    fi

    local STATE_LIB STATE_LOG
    if [ -n "$STATE_DIR" ]; then
        STATE_LIB="$STATE_DIR/lib"; STATE_LOG="$STATE_DIR/log"
    else
        STATE_LIB="/var/lib/xcesp"; STATE_LOG="/var/log/xcesp"
    fi

    local -a env_args=(
        -e "MSISDN=$MSISDN" -e "RVP_IP=$RVP_IP" -e "RVP_PORT=$RVP_PORT"
        -e "TRANSPORT_IP=$TRANSPORT_IP"
        -e "TRANSPORT_TCP_PORT=$TRANSPORT_TCP_PORT"
        -e "TRANSPORT_UDP_PORT=$TRANSPORT_UDP_PORT"
        -e "DTE_SERIAL_DEVICE=$SERIAL_DEV"
        -e "DTE_SERIAL_BAUD=$DTE_BAUD"
    )
    [ -n "$SYSTEM_NAME" ]        && env_args+=(-e "SYSTEM_NAME=$SYSTEM_NAME")
    [ -n "$CRYPTO_PASSPHRASE" ]  && env_args+=(-e "CRYPTO_PASSPHRASE=$CRYPTO_PASSPHRASE")
    [ -n "$RVP_RENEWAL_SEC" ]    && env_args+=(-e "RVP_RENEWAL_SEC=$RVP_RENEWAL_SEC")
    if [ -n "$LICENSE_AUTH" ]; then
        # Fail fast if the interface doesn't exist on the host.  Under
        # --network=host the container will read the same /sys, so if
        # it's missing on the host it'll be missing inside too and
        # authMac will silently stay empty (the classic
        # "Licensed Features/Objects: [none]" trap).
        if [ "$LICENSE_AUTH" != "system-mac" ] && [ "$DRY_RUN" = 0 ]; then
            if [ ! -r "/sys/class/net/$LICENSE_AUTH/address" ]; then
                die "--license-auth: no host interface '$LICENSE_AUTH' " \
                    "(no /sys/class/net/$LICENSE_AUTH/address).  Available: " \
                    "$(ls /sys/class/net | tr '\n' ' ')"
            fi
        fi
        env_args+=(-e "LICENSE_AUTH=$LICENSE_AUTH")
    fi
    [ -n "$LOG_MAX_MB" ] && env_args+=(-e "LOG_MAX_MB=$LOG_MAX_MB")
    [ -n "$LOG_KEEP" ]   && env_args+=(-e "LOG_KEEP=$LOG_KEEP")
    for src in DCD DSR CTS RI DTR RTS; do
        local var="DTE_${src}_SOURCE"
        [ -n "${!var}" ] && env_args+=(-e "${var}=${!var}")
    done

    # Persistent-config bind mount + entrypoint signal.  Resolve the
    # host path, ensure it exists as a regular file (docker would
    # otherwise create a directory at the mount point), then bind it
    # onto xcespserver's CONFIG_FILE path inside the container.
    local persist_host_path=""
    local -a persist_args=()
    if [ -n "$PERSIST_CONFIG" ]; then
        if [ "$PERSIST_CONFIG" = auto ]; then
            # Default path sits next to lib/ and log/ under the state-dir
            # root — obvious to spot on a running device.  Falls back to
            # /var/lib/xcesp/xcespserver.conf when --state-dir isn't set.
            if [ -n "$STATE_DIR" ]; then
                persist_host_path="$STATE_DIR/xcespserver.conf"
            else
                persist_host_path="/var/lib/xcesp/xcespserver.conf"
            fi
        else
            # Explicit path; must be absolute so bind mount is unambiguous.
            case "$PERSIST_CONFIG" in
                /*) persist_host_path="$PERSIST_CONFIG" ;;
                *)  die "--persist-config <PATH> must be absolute (got '$PERSIST_CONFIG')" ;;
            esac
        fi
        # Touch the host file so docker's `-v <file>:<file>` mounts it
        # as a file rather than creating a directory at the mount point.
        if [ "$DRY_RUN" = 0 ]; then
            mkdir -p "$(dirname "$persist_host_path")" || die \
                "cannot create parent dir for $persist_host_path"
            [ -e "$persist_host_path" ] || : > "$persist_host_path"
        fi
        persist_args+=(-v "$persist_host_path:/var/xcesp/cfg/xcespserver.conf"
                       -e "CONFIG_PERSIST=1")
    fi

    local -a net_args=()
    if [ "$NETWORK_MODE" = "host" ]; then
        net_args+=(--network=host)
    else
        net_args+=(--network=bridge
                   -p "${TRANSPORT_TCP_PORT}:${TRANSPORT_TCP_PORT}"
                   -p "${TRANSPORT_UDP_PORT}:${TRANSPORT_UDP_PORT}/udp")
    fi

    local -a docker_cmd=(
        docker run $DETACH
        --name "$CONTAINER_NAME"
        --restart unless-stopped
        "${net_args[@]}"
        --device="$SERIAL_DEV:$SERIAL_DEV"
        -v "$STATE_LIB:/var/lib/xcesp"
        -v "$STATE_LOG:/var/xcesp/log"
        "${persist_args[@]}"
        "${env_args[@]}"
        "$IMAGE"
    )

    if [ "$DRY_RUN" = 1 ]; then
        printf '%q ' "${docker_cmd[@]}"; echo
        return 0
    fi

    mkdir -p "$STATE_LIB" "$STATE_LOG" || die \
        "cannot create state dirs $STATE_LIB and/or $STATE_LOG — run as root or pass --state-dir <path>"

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    set -x
    exec "${docker_cmd[@]}"
}

# ---------------------------------------------------------------------------
# stop / restart / remove — trivial wrappers
# ---------------------------------------------------------------------------
action_stop()    { docker stop "$DEFAULT_NAME"; }
action_restart() { docker restart "$DEFAULT_NAME"; }
action_remove()  { docker rm -f "$DEFAULT_NAME"; }

# ---------------------------------------------------------------------------
# log — default tails the plain-text file on disk (survives docker JSON-log
# corruption from ungraceful power-off); --docker uses `docker logs`.
# ---------------------------------------------------------------------------
action_log() {
    local follow="" src=file
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--follow) follow=-f; shift ;;
            --docker)    src=docker; shift ;;
            -h|--help)   echo "usage: $0 log [-f] [--docker]"; return 0 ;;
            *) die "unknown log option: $1" ;;
        esac
    done
    if [ "$src" = docker ]; then
        exec docker logs $follow "$DEFAULT_NAME"
    fi
    # Discover the host path bind-mounted at /var/xcesp/log inside the
    # container.  Robust to --state-dir choice — no local state file needed.
    local host_log
    host_log=$(docker inspect --format \
        '{{range .Mounts}}{{if eq .Destination "/var/xcesp/log"}}{{.Source}}{{end}}{{end}}' \
        "$DEFAULT_NAME" 2>/dev/null || true)
    [ -n "$host_log" ] || die \
        "container $DEFAULT_NAME not running or no /var/xcesp/log bind mount found — try 'log --docker'"
    exec tail ${follow:-} -n 200 "$host_log/xcesp.log"
}

# ---------------------------------------------------------------------------
# cli / shell / status / version
# ---------------------------------------------------------------------------
action_cli() {
    exec docker exec -it "$DEFAULT_NAME" xcespcli "$@"
}

action_shell() {
    exec docker exec -it "$DEFAULT_NAME" /bin/bash
}

action_status() {
    docker ps -f "name=$DEFAULT_NAME" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    echo
    if docker ps -q -f "name=$DEFAULT_NAME" | grep -q .; then
        echo -e "show modem\nexit" | docker exec -i "$DEFAULT_NAME" \
            xcespcli --socket /run/xcesp/ctrl.sock \
                     --schema-dir /var/xcesp/schema -v 1 2>/dev/null \
            | tail -40 || true
    else
        echo "(container not running — start it with '$(basename "$0") start ...')"
    fi
}

action_version() {
    local tag
    tag=$(docker inspect --format '{{.Config.Image}}' "$DEFAULT_NAME" 2>/dev/null || true)
    if [ -n "$tag" ]; then
        echo "container in-use image: $tag"
    fi
    echo "images available on this host:"
    docker images --format '  {{.Repository}}:{{.Tag}}' | grep '^  xcesp-modem:' || true
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    load)              shift; action_load "$@" ;;
    start)             shift; action_start "$@" ;;
    stop)              shift; action_stop ;;
    restart)           shift; action_restart ;;
    remove|rm)         shift; action_remove ;;
    log|logs)          shift; action_log "$@" ;;
    cli)               shift; action_cli "$@" ;;
    status|ps)         shift; action_status ;;
    shell|bash)        shift; action_shell ;;
    version)           action_version ;;
    help|--help|-h)    action_help ;;
    *) echo "unknown action: $1" >&2; action_help >&2; exit 2 ;;
esac
