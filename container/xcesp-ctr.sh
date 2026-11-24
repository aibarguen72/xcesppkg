#!/bin/bash
# xcesp-ctr.sh — run XCESP instances from the generic XCESP container image.
#
# One image (xcesp:<version>), any number of instances: each instance is a
# container `xcesp-<name>` with its own state directory on the host (config,
# runtime state, files, logs) and a fixed MAC address (licences are bound to
# it).  All instances join the podman network `xcesp-lab`, so they reach each
# other (pseudowires, trunks, routing) as separate systems would.
#
# Usage: xcesp-ctr.sh <command> [args]
#   load <image.tar>                 load the image (podman/docker load)
#   start <name> [options]           create or start an instance
#       --state-dir <dir>            state directory (default: $XCESP_CTR_HOME/<name>,
#                                    XCESP_CTR_HOME defaults to /var/lib/xcesp-ctr
#                                    as root, ~/xcesp-ctr otherwise)
#       --image <image>              default: the newest loaded xcesp:<version>
#       --network <net>|host         default: xcesp-lab (created if missing)
#       --ip <address>               fixed address on the network
#       --web-port <port>            publish the web interface (8081) on this host port
#       --cli-port <port>            publish the xcespcli control port (9900)
#   stop <name> | restart <name>     stop / restart the instance
#   remove <name>                    delete the container (the state directory stays)
#   cli <name> [xcespcli args]       xcespcli inside the instance
#   shell <name>                     shell inside the instance
#   log <name> [-f]                  instance log (xcespwdog + entrypoint)
#   status [<name>] | list           running instances
#   version [<name>]                 XCESP version of the image / instance
#
# Needs podman (or docker) and, for routing / TDM over the kernel (network
# namespaces, MPLS, L2TP, raw sockets, real-time scheduling), privileged
# containers: run it as root.  Kernel modules are loaded from the host
# (/lib/modules is mounted read-only).
set -euo pipefail

ENGINE="${XCESP_CTR_ENGINE:-$(command -v podman || command -v docker || true)}"
[ -n "$ENGINE" ] || { echo "xcesp-ctr: podman or docker is required" >&2; exit 1; }
if [ "$(id -u)" = 0 ]; then HOME_DEF=/var/lib/xcesp-ctr; else HOME_DEF="$HOME/xcesp-ctr"; fi
CTR_HOME="${XCESP_CTR_HOME:-$HOME_DEF}"
NET_DEF=xcesp-lab

die()  { echo "xcesp-ctr: $*" >&2; exit 1; }
cname() { echo "xcesp-$1"; }
exists() { "$ENGINE" container inspect "$(cname "$1")" >/dev/null 2>&1; }
need_name() { [ -n "${1:-}" ] || die "instance name required"; case "$1" in *[!A-Za-z0-9_.-]*) die "bad instance name '$1'";; esac; }

latest_image() {
    "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E '(^|/)xcesp:[0-9]' | sed 's|^localhost/||' | sort -t: -k2 -V | tail -1
}

# Locally administered, stable per instance name: 02:58:43 ("XC") + 3 bytes.
mac_for() {
    local h
    h=$(printf '%s' "$1" | md5sum | cut -c1-6)
    printf '02:58:43:%s:%s:%s' "${h:0:2}" "${h:2:2}" "${h:4:2}"
}

cmd_load() {
    [ -f "${1:-}" ] || die "usage: load <image.tar>"
    "$ENGINE" load -i "$1"
}

cmd_start() {
    local name="${1:-}"; need_name "$name"; shift
    local state="" image="" net="$NET_DEF" ip="" webp="" clip=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --state-dir) state="$2"; shift 2 ;;
            --image)     image="$2"; shift 2 ;;
            --network)   net="$2"; shift 2 ;;
            --ip)        ip="$2"; shift 2 ;;
            --web-port)  webp="$2"; shift 2 ;;
            --cli-port)  clip="$2"; shift 2 ;;
            *) die "unknown option $1" ;;
        esac
    done
    if exists "$name"; then
        [ -z "$state$image$ip$webp$clip" ] || echo "xcesp-ctr: $(cname "$name") exists; options ignored (remove it to change them)" >&2
        "$ENGINE" start "$(cname "$name")"
        return
    fi
    image="${image:-$(latest_image)}"
    [ -n "$image" ] || die "no xcesp image loaded (xcesp-ctr.sh load <image.tar>)"
    state="${state:-$CTR_HOME/$name}"
    mkdir -p "$state/cfg" "$state/lib" "$state/dsk" "$state/log"
    local netopt=(--network "$net")
    if [ "$net" != host ]; then
        "$ENGINE" network exists "$net" 2>/dev/null || "$ENGINE" network create "$net" >/dev/null
        netopt+=(--mac-address "$(mac_for "$name")")
        [ -n "$ip" ] && netopt+=(--ip "$ip")
    fi
    local pub=()
    [ -n "$webp" ] && pub+=(-p "$webp:8081")
    [ -n "$clip" ] && pub+=(-p "$clip:9900")
    "$ENGINE" run -d --name "$(cname "$name")" --hostname "$name" \
        --privileged --restart unless-stopped --stop-timeout 45 \
        "${netopt[@]}" "${pub[@]}" \
        -v "$state/cfg:/var/xcesp/cfg:Z" -v "$state/lib:/var/lib/xcesp:Z" \
        -v "$state/dsk:/var/xcesp/dsk:Z" -v "$state/log:/var/xcesp/log:Z" \
        -v /lib/modules:/lib/modules:ro \
        "$image" >/dev/null
    echo "instance $name: container $(cname "$name"), image $image, state $state"
    [ "$net" != host ] && echo "  network $net, MAC $(mac_for "$name") (licences are bound to it)"
    [ -n "$webp" ] && echo "  web interface: http://<this host>:$webp/ (enable it with management web)"
    echo "  configure: xcesp-ctr.sh cli $name"
}

cmd_version() {
    if [ -n "${1:-}" ]; then
        "$ENGINE" exec "$(cname "$1")" head -1 /var/xcesp/mainsw/VERSION
    else
        local img; img=$(latest_image); [ -n "$img" ] || die "no xcesp image loaded"
        "$ENGINE" run --rm --entrypoint head "$img" -1 /var/xcesp/mainsw/VERSION
    fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
    load)    cmd_load "$@" ;;
    start)   cmd_start "$@" ;;
    stop)    need_name "${1:-}"; "$ENGINE" stop -t 40 "$(cname "$1")" ;;
    restart) need_name "${1:-}"; "$ENGINE" restart -t 40 "$(cname "$1")" ;;
    remove)  need_name "${1:-}"; "$ENGINE" rm -f "$(cname "$1")" >/dev/null
             echo "container removed; state kept in $CTR_HOME/$1 (or the --state-dir used)" ;;
    cli)     need_name "${1:-}"; n="$1"; shift; exec "$ENGINE" exec -it "$(cname "$n")" xcespcli "$@" ;;
    shell)   need_name "${1:-}"; exec "$ENGINE" exec -it "$(cname "$1")" /bin/bash ;;
    log)     need_name "${1:-}"; n="$1"; shift; exec "$ENGINE" logs "$@" "$(cname "$n")" ;;
    status|list)
             if [ -n "${1:-}" ]; then "$ENGINE" ps -a --filter "name=^$(cname "$1")\$"
             else "$ENGINE" ps -a --filter 'name=^xcesp-'; fi ;;
    version) cmd_version "$@" ;;
    help|-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' (xcesp-ctr.sh help)" ;;
esac
