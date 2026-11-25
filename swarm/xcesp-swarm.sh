#!/bin/bash
# xcesp-swarm — launch, monitor and stop swarms of XCESP containers (xNMS lab).
#
# A swarm is N XCESP instances (the generic xcesp:<version> image, see
# ../container) plus its own networks:
#   mgmt   management: bridge with fixed addresses, NAT to the host's uplink
#          (internet), reachable from the host (where xNMS runs) -> eth0
#   net1.. traffic: internal L2 bridges, no addresses from podman (the XCESP
#          configuration owns them), no host/internet access   -> eth1, eth2..
# Several swarms run side by side on one host, fully independent (own
# networks, subnets, MACs, state).  Each swarm is described by
# $XCESP_SWARM_ETC/<swarm>.conf (written by `init`).
#
# Usage: xcesp-swarm <command> [args]
#   init <swarm> --id <1-60> [options]   create the swarm definition
#       --nodes <N>              number of devices (default 1)
#       --image <image>          default: newest loaded xcesp:<version> (pinned)
#       --mgmt-subnet <cidr>     default: 10.<200+id>.0.0/16
#       --nets "<n1> <n2>.."     traffic networks (default "net1 net2", "" = none)
#       --cpus <n> --memory <m>  per-device limits (podman --cpus / --memory)
#       --seed-dir <dir>         first-start config per device (see README)
#       --force                  overwrite an existing definition
#   up <swarm> [--nodes N]       create networks, create/start devices 1..N
#   down <swarm>                 stop every device (containers + state kept)
#   scale <swarm> <N>            set the device count: start new ones, remove
#                                devices above N (their state is kept)
#   destroy <swarm> [--purge] [--yes]
#                                remove containers and networks; --purge also
#                                deletes the state directories
#   status <swarm> [--problems]  table: device, state, mgmt IP, CLI port, CPU, mem
#   monitor <swarm> [-i <sec>] [--all]
#                                live view; state changes logged to monitor.log
#   health <swarm>               exit 0 when every device is up and its CLI answers
#   inventory <swarm> [--format csv|json|hosts]   device list for xNMS
#   list                         defined swarms and their state
#   show <swarm>                 definition + derived addressing
#   preflight [<swarm>]          host checks (root, image, sysctls, memory)
#   restart <swarm> [<dev>]      restart one device or all
#   cli <swarm> <dev> [args]     xcespcli on a device (<dev> = 7, 007 or lab-007)
#   shell <swarm> <dev>          shell on a device
#   log <swarm> <dev> [-f]       device log (entrypoint + xcespwdog)
#   exec <swarm> <dev>|all -- <cmd...>   run a command on one/all devices
#   install                      install to /usr/local/sbin + systemd unit
#                                xcesp-swarm@<swarm>.service (up/down at boot)
#
# Run as root: devices are privileged containers (namespaces, MPLS, L2TP, raw
# sockets) and the host reaches the mgmt bridge directly only with rootful
# podman.  Environment: XCESP_SWARM_ETC (default /etc/xcesp-swarm),
# XCESP_SWARM_HOME (default /var/lib/xcesp-swarm), XCESP_SWARM_ENGINE (podman).
set -euo pipefail

ENGINE="${XCESP_SWARM_ENGINE:-$(command -v podman || true)}"
if [ "$(id -u)" = 0 ]; then
    ETC_DEF=/etc/xcesp-swarm; HOME_DEF=/var/lib/xcesp-swarm; ROOT=1
else
    ETC_DEF="$HOME/.config/xcesp-swarm"; HOME_DEF="$HOME/xcesp-swarm"; ROOT=0
fi
ETC="${XCESP_SWARM_ETC:-$ETC_DEF}"
SHOME="${XCESP_SWARM_HOME:-$HOME_DEF}"
SELF="$(readlink -f "$0")"
CLI_PORT=9900

die()  { echo "xcesp-swarm: $*" >&2; exit 1; }
warn() { echo "xcesp-swarm: warning: $*" >&2; }
need_engine() { [ -n "$ENGINE" ] || die "podman is required"; }
ts() { date '+%F %T'; }

# ---------------------------------------------------------------- addressing
ip2int() { local IFS=.; set -- $1; echo $(( ($1<<24) | ($2<<16) | ($3<<8) | $4 )); }
int2ip() { local n=$1; echo "$((n>>24&255)).$((n>>16&255)).$((n>>8&255)).$((n&255))"; }

# Definition -> globals.  Defaults first, then the file, then derived values.
load_conf() {
    SWARM="${1:-}"
    [ -n "$SWARM" ] || die "swarm name required"
    check_name "$SWARM"
    local f="$ETC/$SWARM.conf"
    [ -f "$f" ] || die "swarm '$SWARM' not defined ($f; use: xcesp-swarm init $SWARM --id <n>)"
    SWARM_ID=""; NODES=1; IMAGE=""; MGMT_SUBNET=""; MGMT_GATEWAY=""; HOST_OFFSET=10
    TRAFFIC_NETS="net1 net2"; CPUS=""; MEMORY=""; PARALLEL=8; SEED_DIR=""; STATE_DIR=""
    # shellcheck disable=SC1090
    . "$f"
    [[ "$SWARM_ID" =~ ^[0-9]+$ ]] && [ "$SWARM_ID" -ge 1 ] && [ "$SWARM_ID" -le 60 ] \
        || die "$f: SWARM_ID must be 1..60"
    [[ "$NODES" =~ ^[0-9]+$ ]] || die "$f: NODES must be a number"
    [ "$NODES" -le 999 ] || die "$f: NODES must be <= 999"
    MGMT_SUBNET="${MGMT_SUBNET:-10.$((200 + SWARM_ID)).0.0/16}"
    STATE_DIR="${STATE_DIR:-$SHOME/$SWARM}"
    [ -n "$IMAGE" ] || die "$f: IMAGE is empty"
    local base="${MGMT_SUBNET%/*}" len="${MGMT_SUBNET#*/}"
    [[ "$len" =~ ^[0-9]+$ ]] && [ "$len" -ge 8 ] && [ "$len" -le 30 ] || die "$f: bad MGMT_SUBNET $MGMT_SUBNET"
    NET_SIZE=$(( 1 << (32 - len) ))
    NET_INT=$(( $(ip2int "$base") & ~(NET_SIZE - 1) & 0xffffffff ))
    MGMT_GATEWAY="${MGMT_GATEWAY:-$(int2ip $((NET_INT + 1)))}"
    MGMT_PREFIX="$len"
    MAX_NODES=$(( NET_SIZE - 2 - HOST_OFFSET ))
    [ "$NODES" -le "$MAX_NODES" ] || die "$MGMT_SUBNET holds at most $MAX_NODES devices (NODES=$NODES)"
    NET_MGMT="xsw-$SWARM-mgmt"
    read -r -a TNETS <<< "$TRAFFIC_NETS"
}

check_name() {
    [[ "$1" =~ ^[a-z][a-z0-9]{0,11}$ ]] || die "bad swarm name '$1' (a-z, 0-9, starts with a letter, max 12)"
}

nn()      { printf '%03d' "$1"; }
cname()   { echo "xsw-$SWARM-$(nn "$1")"; }
hname()   { echo "$SWARM-$(nn "$1")"; }
node_ip() { int2ip $(( NET_INT + HOST_OFFSET + $1 )); }
# Locally administered, unique per (swarm, network, device): 02:58:<id>:<net>:<dev>
node_mac() { printf '02:58:%02x:%02x:%02x:%02x' "$SWARM_ID" "$2" $(( $1 >> 8 )) $(( $1 & 255 )); }
tnet()    { echo "xsw-$SWARM-$1"; }

# "7", "007", "lab-007", "xsw-lab-007" -> 7
node_arg() {
    local a="${1:-}" n
    [ -n "$a" ] || die "device required"
    n="${a##*-}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "bad device '$a'"
    n=$((10#$n))
    [ "$n" -ge 1 ] || die "bad device '$a'"
    echo "$n"
}

ctr_exists() { "$ENGINE" container exists "$1" 2>/dev/null; }

# Devices that exist as containers (numbers), sorted.
existing_nodes() {
    "$ENGINE" ps -a --filter "label=xcesp.swarm=$SWARM" --format '{{.Names}}' 2>/dev/null \
        | sed -n "s/^xsw-$SWARM-0*\([0-9][0-9]*\)\$/\1/p" | sort -n
}

latest_image() {
    "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E '(^|/)xcesp:[0-9]' | sed 's|^localhost/||' | sort -t: -k2 -V | tail -1
}

# Run "$@ <i>" for each device number on stdin, PARALLEL at a time.
# Prints failures; returns 1 if any failed.
for_nodes_parallel() {
    local tmp i rc=0 f
    tmp=$(mktemp -d)
    while read -r i; do
        ( if "$@" "$i" >"$tmp/$i.out" 2>&1 </dev/null; then :; else touch "$tmp/$i.fail"; fi ) &
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n 2>/dev/null || true; done
    done
    wait
    for f in "$tmp"/*.fail; do
        [ -e "$f" ] || continue
        i=$(basename "$f" .fail); rc=1
        echo "  $(hname "$i"): FAILED: $(tail -3 "$tmp/$i.out" | tr '\n' ' ')" >&2
    done
    rm -rf "$tmp"
    return $rc
}

# ------------------------------------------------------------------ networks
ensure_networks() {
    if "$ENGINE" network exists "$NET_MGMT" 2>/dev/null; then
        local sub
        sub=$("$ENGINE" network inspect -f '{{range .Subnets}}{{.Subnet}} {{end}}' "$NET_MGMT" 2>/dev/null | awk '{print $1}')
        [ "$sub" = "$(int2ip "$NET_INT")/$MGMT_PREFIX" ] \
            || warn "$NET_MGMT has subnet $sub, definition says $MGMT_SUBNET (destroy + up to change it)"
    else
        "$ENGINE" network create --driver bridge \
            --subnet "$MGMT_SUBNET" --gateway "$MGMT_GATEWAY" \
            --interface-name "xs${SWARM_ID}m" \
            --label "xcesp.swarm=$SWARM" --label xcesp.role=mgmt "$NET_MGMT" >/dev/null
        echo "network $NET_MGMT: $MGMT_SUBNET, gateway (host) $MGMT_GATEWAY, bridge xs${SWARM_ID}m"
    fi
    local k=1 t
    for t in "${TNETS[@]}"; do
        if ! "$ENGINE" network exists "$(tnet "$t")" 2>/dev/null; then
            "$ENGINE" network create --driver bridge --internal --ipam-driver none \
                --disable-dns --interface-name "xs${SWARM_ID}n$k" \
                --label "xcesp.swarm=$SWARM" --label xcesp.role=traffic "$(tnet "$t")" >/dev/null
            echo "network $(tnet "$t"): internal L2, bridge xs${SWARM_ID}n$k -> eth$k"
        fi
        k=$((k + 1))
    done
}

remove_networks() {
    local n
    for n in $("$ENGINE" network ls --filter "label=xcesp.swarm=$SWARM" --format '{{.Name}}' 2>/dev/null); do
        "$ENGINE" network rm "$n" >/dev/null && echo "network $n removed"
    done
}

# ------------------------------------------------------------------- devices
# First start with a seed dir: the image defaults + the seed files, with
# @NODE@ @HOST@ @INDEX@ @MGMT_IP@ @MGMT_PREFIX@ @MGMT_GW@ @SWARM@ replaced.
# (The entrypoint seeds the image defaults only into an EMPTY cfg dir.)
seed_cfg() {
    local i="$1" cfg="$2" src f rel
    [ -n "$SEED_DIR" ] || return 0
    [ -z "$(ls -A "$cfg" 2>/dev/null)" ] || return 0
    if [ -d "$SEED_DIR/$(hname "$i")" ]; then src="$SEED_DIR/$(hname "$i")"
    elif [ -d "$SEED_DIR/default" ]; then src="$SEED_DIR/default"
    else return 0; fi
    "$ENGINE" run --rm --network none --entrypoint tar "$IMAGE" -C /usr/share/xcesp-ctr/cfg -cf - . \
        | tar -xf - -C "$cfg"
    (cd "$src" && find . -type f) | while read -r rel; do
        f="$cfg/${rel#./}"
        mkdir -p "$(dirname "$f")"
        sed -e "s|@NODE@|$(nn "$i")|g" -e "s|@INDEX@|$i|g" -e "s|@HOST@|$(hname "$i")|g" \
            -e "s|@MGMT_IP@|$(node_ip "$i")|g" -e "s|@MGMT_PREFIX@|$MGMT_PREFIX|g" \
            -e "s|@MGMT_GW@|$MGMT_GATEWAY|g" -e "s|@SWARM@|$SWARM|g" "$src/$rel" > "$f"
    done
    echo "seeded cfg from $src"
}

start_node() {
    local i="$1" c st
    c=$(cname "$i")
    if ctr_exists "$c"; then
        "$ENGINE" start "$c" >/dev/null
        return
    fi
    st="$STATE_DIR/$(hname "$i")"
    mkdir -p "$st/cfg" "$st/lib" "$st/dsk" "$st/log"
    seed_cfg "$i" "$st/cfg"
    local args=(run -d --name "$c" --hostname "$(hname "$i")"
        --privileged --restart on-failure --stop-timeout 45
        --label "xcesp.swarm=$SWARM" --label "xcesp.node=$i"
        --network "$NET_MGMT:interface_name=eth0,ip=$(node_ip "$i"),mac=$(node_mac "$i" 0)")
    local k=1 t
    for t in "${TNETS[@]}"; do
        args+=(--network "$(tnet "$t"):interface_name=eth$k,mac=$(node_mac "$i" "$k")")
        k=$((k + 1))
    done
    [ -n "$CPUS" ]   && args+=(--cpus "$CPUS")
    [ -n "$MEMORY" ] && args+=(--memory "$MEMORY")
    args+=(-v "$st/cfg:/var/xcesp/cfg:Z" -v "$st/lib:/var/lib/xcesp:Z"
           -v "$st/dsk:/var/xcesp/dsk:Z" -v "$st/log:/var/xcesp/log:Z"
           -v /lib/modules:/lib/modules:ro "$IMAGE")
    "$ENGINE" "${args[@]}" >/dev/null
}

stop_node()   { "$ENGINE" stop -t 40 "$(cname "$1")" >/dev/null; }
remove_node() { "$ENGINE" rm -f -t 40 "$(cname "$1")" >/dev/null; }
restart_node(){ "$ENGINE" restart -t 40 "$(cname "$1")" >/dev/null; }

write_inventory() {
    mkdir -p "$STATE_DIR"
    inventory csv   > "$STATE_DIR/inventory.csv"
    inventory json  > "$STATE_DIR/inventory.json"
    inventory hosts > "$STATE_DIR/hosts"
}

inventory() {
    local fmt="${1:-csv}" i sep=""
    case "$fmt" in
        csv)
            echo "device,container,mgmt_ip,mgmt_mac,cli_port,swarm"
            for ((i = 1; i <= NODES; i++)); do
                echo "$(hname "$i"),$(cname "$i"),$(node_ip "$i"),$(node_mac "$i" 0),$CLI_PORT,$SWARM"
            done ;;
        json)
            printf '{"swarm":"%s","id":%s,"image":"%s","mgmt_subnet":"%s","mgmt_gateway":"%s","traffic_networks":[' \
                "$SWARM" "$SWARM_ID" "$IMAGE" "$MGMT_SUBNET" "$MGMT_GATEWAY"
            local k=1 t
            for t in "${TNETS[@]}"; do
                printf '%s{"name":"%s","interface":"eth%s"}' "$sep" "$t" "$k"; sep=","; k=$((k + 1))
            done
            printf '],"devices":['; sep=""
            for ((i = 1; i <= NODES; i++)); do
                printf '%s\n{"device":"%s","index":%s,"container":"%s","mgmt_ip":"%s","mgmt_mac":"%s","cli_port":%s}' \
                    "$sep" "$(hname "$i")" "$i" "$(cname "$i")" "$(node_ip "$i")" "$(node_mac "$i" 0)" "$CLI_PORT"
                sep=","
            done
            printf '\n]}\n' ;;
        hosts)
            echo "# xcesp-swarm $SWARM ($MGMT_SUBNET)"
            for ((i = 1; i <= NODES; i++)); do echo "$(node_ip "$i") $(hname "$i")"; done ;;
        *) die "inventory format: csv | json | hosts" ;;
    esac
}

# ------------------------------------------------------------------- status
# Fills ST_STATE[i], ST_UP[i] (uptime text), ST_CLI[i] (up/down/-),
# ST_CPU[i], ST_MEM[i] for devices 1..max(NODES, existing).
declare -A ST_STATE ST_UP ST_CLI ST_CPU ST_MEM
ST_MAX=0
probe_cli() {   # $1 = device -> exit 0 when the CLI control port accepts
    if [ "$ROOT" = 1 ]; then
        timeout 2 bash -c "exec 3<>/dev/tcp/$(node_ip "$1")/$CLI_PORT" 2>/dev/null
    else   # rootless: the host cannot reach the bridge; probe from inside
        timeout 4 "$ENGINE" exec "$(cname "$1")" bash -c "exec 3<>/dev/tcp/127.0.0.1/$CLI_PORT" 2>/dev/null
    fi
}
collect_status() {
    local name state status i running=() tmp n cpu mem
    ST_STATE=(); ST_UP=(); ST_CLI=(); ST_CPU=(); ST_MEM=()
    ST_MAX=$NODES
    while IFS='|' read -r name state status; do
        i="${name##*-}"; i=$((10#$i))
        ST_STATE[$i]="$state"; ST_UP[$i]="$status"
        [ "$i" -gt "$ST_MAX" ] && ST_MAX=$i
        [ "$state" = running ] && running+=("$i")
    done < <("$ENGINE" ps -a --filter "label=xcesp.swarm=$SWARM" --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null)
    [ "${#running[@]}" -gt 0 ] || return 0
    tmp=$(mktemp -d)
    for i in "${running[@]}"; do
        ( probe_cli "$i" && touch "$tmp/$i" ) &
        while [ "$(jobs -rp | wc -l)" -ge 32 ]; do wait -n 2>/dev/null || true; done
    done
    wait
    for i in "${running[@]}"; do
        if [ -e "$tmp/$i" ]; then ST_CLI[$i]=up; else ST_CLI[$i]=down; fi
    done
    rm -rf "$tmp"
    local names=()
    for i in "${running[@]}"; do names+=("$(cname "$i")"); done
    while IFS='|' read -r n cpu mem; do
        i="${n##*-}"; i=$((10#$i))
        ST_CPU[$i]="$cpu"; ST_MEM[$i]="${mem%% /*}"
    done < <("$ENGINE" stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' "${names[@]}" 2>/dev/null || true)
}

# up / starting / down / stopped / missing / extra
node_health() {
    local i="$1" s="${ST_STATE[$1]:-missing}"
    if [ "$i" -gt "$NODES" ]; then echo extra; return; fi
    case "$s" in
        running) if [ "${ST_CLI[$i]:-down}" = up ]; then echo up; else echo starting; fi ;;
        missing) echo missing ;;
        exited|stopped|created|configured) echo stopped ;;
        *) echo "$s" ;;
    esac
}

print_status() {   # $1 = 1: only devices that are not up
    local only_bad="${1:-0}" i h n_up=0 n_run=0 rows=0
    printf '%-12s %-9s %-15s %-5s %-8s %-10s %s\n' DEVICE HEALTH MGMT-IP CLI CPU MEM STATUS
    for ((i = 1; i <= ST_MAX; i++)); do
        h=$(node_health "$i")
        [ "$h" = up ] && n_up=$((n_up + 1))
        [ "${ST_STATE[$i]:-}" = running ] && n_run=$((n_run + 1))
        [ "$h" = missing ] && [ "$i" -gt "$NODES" ] && continue
        [ "$only_bad" = 1 ] && [ "$h" = up ] && continue
        printf '%-12s %-9s %-15s %-5s %-8s %-10s %s\n' "$(hname "$i")" "$h" "$(node_ip "$i")" \
            "${ST_CLI[$i]:--}" "${ST_CPU[$i]:--}" "${ST_MEM[$i]:--}" "${ST_UP[$i]:-}"
        rows=$((rows + 1))
    done
    [ "$only_bad" = 1 ] && [ "$rows" = 0 ] && echo "(no problems)"
    echo "swarm $SWARM: $NODES defined, $n_run running, $n_up up (CLI answering)"
    [ "$n_up" = "$NODES" ]
}

# ------------------------------------------------------------------ commands
cmd_init() {
    local name="${1:-}"; check_name "$name"; shift
    local id="" nodes=1 image="" subnet="" nets="net1 net2" cpus="" mem="" seed="" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --nodes) nodes="$2"; shift 2 ;;
            --image) image="$2"; shift 2 ;;
            --mgmt-subnet) subnet="$2"; shift 2 ;;
            --nets) nets="$2"; shift 2 ;;
            --cpus) cpus="$2"; shift 2 ;;
            --memory) mem="$2"; shift 2 ;;
            --seed-dir) seed="$(readlink -f "$2")"; shift 2 ;;
            --force) force=1; shift ;;
            *) die "init: unknown option $1" ;;
        esac
    done
    [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ge 1 ] && [ "$id" -le 60 ] || die "init: --id 1..60 required (unique per host)"
    local f="$ETC/$name.conf" o
    [ -f "$f" ] && [ "$force" = 0 ] && die "$f exists (--force to overwrite)"
    for o in "$ETC"/*.conf; do
        [ -e "$o" ] && [ "$o" != "$f" ] || continue
        grep -qE "^SWARM_ID=$id([^0-9]|\$)" "$o" && die "id $id already used by $(basename "$o" .conf)"
    done
    local t
    for t in $nets; do [[ "$t" =~ ^[a-z][a-z0-9]{0,7}$ ]] || die "bad network name '$t'"; done
    need_engine
    image="${image:-$(latest_image)}"
    [ -n "$image" ] || die "no xcesp image loaded (podman load -i xcesp-<ver>-x86_64.tar)"
    mkdir -p "$ETC"
    cat > "$f" <<EOF
# xcesp-swarm definition: $name (written $(ts); edit, then: xcesp-swarm up $name)
SWARM_ID=$id                 # unique per host: networks, bridges xs${id}*, MACs 02:58:$(printf %02x "$id"):..
NODES=$nodes                     # devices $name-001 .. (xcesp-swarm scale $name <N>)
IMAGE=$image          # pinned image; change + destroy/up to upgrade
MGMT_SUBNET=${subnet:-10.$((200 + id)).0.0/16}     # mgmt network; host = first address
HOST_OFFSET=10              # device i gets subnet address HOST_OFFSET+i
TRAFFIC_NETS="$nets"        # internal L2 networks -> eth1, eth2.. (order matters)
CPUS=$cpus                       # per-device --cpus (empty = no limit)
MEMORY=$mem                     # per-device --memory, e.g. 1g (empty = no limit)
PARALLEL=8                  # devices created/started at the same time
SEED_DIR="$seed"                  # optional: <dir>/<device>/ or <dir>/default/ -> first-start cfg
#STATE_DIR=$SHOME/$name    # per-device state directories
EOF
    echo "defined swarm $name: $f"
    load_conf "$name"
    cmd_show_short
}

cmd_show_short() {
    echo "  $NODES devices $(hname 1) .. $(hname "$NODES"), image $IMAGE"
    echo "  mgmt $MGMT_SUBNET (host $MGMT_GATEWAY): $(node_ip 1) .. $(node_ip "$NODES") -> eth0"
    local k=1 t
    for t in "${TNETS[@]}"; do echo "  $t: internal L2 -> eth$k"; k=$((k + 1)); done
    echo "  state $STATE_DIR"
}

cmd_up() {
    local n=""
    [ "${1:-}" = --nodes ] && { n="$2"; shift 2; }
    [ -n "$n" ] && set_nodes "$n"
    need_engine
    "$ENGINE" image exists "$IMAGE" || die "image $IMAGE not loaded"
    ensure_networks
    echo "starting $NODES devices of $SWARM ($PARALLEL at a time)"
    local rc=0
    seq 1 "$NODES" | for_nodes_parallel start_node || rc=1
    write_inventory
    local extra
    extra=$(existing_nodes | awk -v n="$NODES" '$1 > n' | tr '\n' ' ')
    [ -n "$extra" ] && warn "devices above NODES=$NODES exist ($extra): xcesp-swarm scale $SWARM $NODES removes them"
    echo "inventory: $STATE_DIR/inventory.{csv,json} and $STATE_DIR/hosts"
    echo "XCESP takes ~1 min to come up: xcesp-swarm status $SWARM"
    return $rc
}

set_nodes() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$MAX_NODES" ] && [ "$1" -le 999 ] \
        || die "device count must be 1..$(( MAX_NODES < 999 ? MAX_NODES : 999 ))"
    sed -i "s/^NODES=[0-9]*/NODES=$1/" "$ETC/$SWARM.conf"
    NODES="$1"
}

cmd_down() {
    need_engine
    local nodes; nodes=$(existing_nodes)
    [ -n "$nodes" ] || { echo "swarm $SWARM: no devices"; return 0; }
    echo "stopping $(echo "$nodes" | wc -l) devices of $SWARM"
    echo "$nodes" | for_nodes_parallel stop_node
}

cmd_scale() {
    [ -n "${1:-}" ] || die "usage: scale <swarm> <N>"
    set_nodes "$1"
    cmd_up
    local extra; extra=$(existing_nodes | awk -v n="$NODES" '$1 > n')
    if [ -n "$extra" ]; then
        echo "removing devices above $NODES (state kept in $STATE_DIR)"
        echo "$extra" | for_nodes_parallel remove_node
        write_inventory
    fi
}

cmd_destroy() {
    local purge=0 yes=0
    while [ $# -gt 0 ]; do
        case "$1" in --purge) purge=1 ;; --yes|-y) yes=1 ;; *) die "destroy: unknown option $1" ;; esac
        shift
    done
    need_engine
    if [ "$yes" = 0 ]; then
        local what="containers and networks"; [ "$purge" = 1 ] && what="$what AND state ($STATE_DIR)"
        read -r -p "destroy swarm $SWARM: remove $what? [y/N] " a
        [ "$a" = y ] || [ "$a" = Y ] || die "aborted"
    fi
    local nodes; nodes=$(existing_nodes)
    [ -n "$nodes" ] && { echo "removing $(echo "$nodes" | wc -l) devices"; echo "$nodes" | for_nodes_parallel remove_node || true; }
    remove_networks
    if [ "$purge" = 1 ] && [ -d "$STATE_DIR" ]; then
        # files inside belong to the container's users; podman unshare for rootless
        if [ "$ROOT" = 1 ]; then rm -rf "$STATE_DIR"; else "$ENGINE" unshare rm -rf "$STATE_DIR"; fi
        echo "state $STATE_DIR deleted"
    fi
}

cmd_status() {
    need_engine
    collect_status
    local bad=0; [ "${1:-}" = --problems ] && bad=1
    print_status "$bad" || true
}

cmd_health() {
    need_engine
    collect_status
    local i h bad=()
    for ((i = 1; i <= NODES; i++)); do
        h=$(node_health "$i"); [ "$h" = up ] || bad+=("$(hname "$i")=$h")
    done
    if [ "${#bad[@]}" = 0 ]; then echo "OK: swarm $SWARM, $NODES/$NODES devices up"; return 0; fi
    echo "FAIL: swarm $SWARM, $(( NODES - ${#bad[@]} ))/$NODES up; ${bad[*]:0:20}"
    return 1
}

cmd_monitor() {
    local iv=10 all=0
    while [ $# -gt 0 ]; do
        case "$1" in -i|--interval) iv="$2"; shift 2 ;; --all) all=1; shift ;; *) die "monitor: unknown option $1" ;; esac
    done
    need_engine
    mkdir -p "$STATE_DIR"
    local logf="$STATE_DIR/monitor.log" i h events=""
    declare -A prev=()
    trap 'echo; exit 0' INT TERM
    echo "$(ts) monitor started" >> "$logf"
    while :; do
        collect_status
        for ((i = 1; i <= ST_MAX; i++)); do
            h=$(node_health "$i")
            [ "$h" = missing ] && [ "$i" -gt "$NODES" ] && continue
            if [ -n "${prev[$i]:-}" ] && [ "${prev[$i]}" != "$h" ]; then
                echo "$(ts) $(hname "$i") ${prev[$i]} -> $h" >> "$logf"
            fi
            prev[$i]="$h"
        done
        { printf '\033[H\033[2J'
          echo "xcesp-swarm $SWARM — $(ts) — every ${iv}s (Ctrl-C to quit)   log: $logf"
          echo
          if [ "$all" = 1 ]; then print_status 0 || true; else print_status 1 || true; fi
          echo; echo "recent events:"; tail -8 "$logf" | sed 's/^/  /'; }
        sleep "$iv"
    done
}

cmd_list() {
    need_engine
    local f s n run
    printf '%-12s %-4s %-7s %-8s %-18s %s\n' SWARM ID DEVICES RUNNING MGMT-SUBNET IMAGE
    for f in "$ETC"/*.conf; do
        [ -e "$f" ] || { echo "(no swarms defined in $ETC)"; return 0; }
        s=$(basename "$f" .conf)
        ( load_conf "$s"
          run=$("$ENGINE" ps --filter "label=xcesp.swarm=$SWARM" --format '{{.Names}}' 2>/dev/null | wc -l)
          printf '%-12s %-4s %-7s %-8s %-18s %s\n' "$SWARM" "$SWARM_ID" "$NODES" "$run" "$MGMT_SUBNET" "$IMAGE" ) || true
    done
}

cmd_preflight() {
    local ok=1 v
    [ "$ROOT" = 1 ] || { warn "not root: rootless devices are not reachable from the host on the mgmt network"; ok=0; }
    [ -n "$ENGINE" ] || { warn "podman not installed"; ok=0; }
    chk() {   # sysctl, minimum
        v=$(sysctl -n "$1" 2>/dev/null || echo "")
        if [ -n "$v" ] && [ "$v" -lt "$2" ]; then warn "sysctl $1=$v, recommended >= $2"; ok=0; fi
    }
    chk fs.inotify.max_user_instances 8192
    chk fs.inotify.max_user_watches 524288
    chk net.ipv4.neigh.default.gc_thresh3 8192
    chk net.ipv6.neigh.default.gc_thresh3 8192
    chk kernel.pid_max 4194304
    chk fs.file-max 1000000
    v=$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 0)
    [ "$v" = 1 ] && { warn "net.bridge.bridge-nf-call-iptables=1: traffic on net1/net2 goes through host iptables (set it to 0)"; ok=0; }
    if [ -n "${1:-}" ]; then
        load_conf "$1"
        "$ENGINE" image exists "$IMAGE" || { warn "image $IMAGE not loaded"; ok=0; }
        local avail; avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        echo "swarm $SWARM: $NODES devices; host memory available ${avail} MiB (~$(( avail / NODES )) MiB per device)"
        [ -n "$MEMORY" ] || echo "  tip: measure one device with 'xcesp-swarm status' and set MEMORY to cap each one"
    fi
    if [ "$ok" = 1 ]; then echo "preflight OK"; else
        echo "fix: /etc/sysctl.d/90-xcesp-swarm.conf with the recommended values, then sysctl --system"; fi
}

cmd_install() {
    [ "$ROOT" = 1 ] || die "install: run as root"
    install -m 0755 "$SELF" /usr/local/sbin/xcesp-swarm
    cat > /etc/systemd/system/xcesp-swarm@.service <<'EOF'
[Unit]
Description=XCESP swarm %i (xcesp-swarm)
Wants=network-online.target
After=network-online.target podman.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xcesp-swarm up %i
ExecStop=/usr/local/sbin/xcesp-swarm down %i
TimeoutStartSec=0
TimeoutStopSec=900

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "$ETC" "$SHOME"
    systemctl daemon-reload
    echo "installed /usr/local/sbin/xcesp-swarm and xcesp-swarm@.service"
    echo "  boot start: systemctl enable --now xcesp-swarm@<swarm>"
}

cmd_exec() {
    local target="${1:-}"; shift || true
    [ "${1:-}" = -- ] && shift
    [ $# -gt 0 ] || die "usage: exec <swarm> <dev>|all -- <cmd...>"
    need_engine
    if [ "$target" = all ]; then
        local i
        for i in $(existing_nodes); do
            [ "$("$ENGINE" container inspect -f '{{.State.Running}}' "$(cname "$i")")" = true ] || continue
            echo "=== $(hname "$i")"
            "$ENGINE" exec "$(cname "$i")" "$@" || echo "(exit $?)"
        done
    else
        exec "$ENGINE" exec "$(cname "$(node_arg "$target")")" "$@"
    fi
}

# --------------------------------------------------------------------- main
cmd="${1:-help}"; shift || true
case "$cmd" in
    init)      cmd_init "$@" ;;
    up)        load_conf "${1:-}"; shift; cmd_up "$@" ;;
    down|stop) load_conf "${1:-}"; cmd_down ;;
    scale)     load_conf "${1:-}"; shift; cmd_scale "$@" ;;
    destroy)   load_conf "${1:-}"; shift; cmd_destroy "$@" ;;
    status)    load_conf "${1:-}"; shift; cmd_status "$@" ;;
    monitor)   load_conf "${1:-}"; shift; cmd_monitor "$@" ;;
    health)    load_conf "${1:-}"; cmd_health ;;
    inventory) load_conf "${1:-}"; shift; f=csv; [ "${1:-}" = --format ] && f="$2"; inventory "$f" ;;
    show)      load_conf "${1:-}"; echo "swarm $SWARM (id $SWARM_ID), $ETC/$SWARM.conf"; cmd_show_short ;;
    list)      cmd_list ;;
    preflight) cmd_preflight "$@" ;;
    install)   cmd_install ;;
    restart)   load_conf "${1:-}"; need_engine
               if [ -n "${2:-}" ]; then restart_node "$(node_arg "$2")"
               else existing_nodes | for_nodes_parallel restart_node; fi ;;
    cli)       load_conf "${1:-}"; need_engine; n=$(node_arg "${2:-}"); shift 2
               exec "$ENGINE" exec -it "$(cname "$n")" xcespcli "$@" ;;
    shell)     load_conf "${1:-}"; need_engine; exec "$ENGINE" exec -it "$(cname "$(node_arg "${2:-}")")" /bin/bash ;;
    log)       load_conf "${1:-}"; need_engine; n=$(node_arg "${2:-}"); shift 2
               exec "$ENGINE" logs "$@" "$(cname "$n")" ;;
    exec)      load_conf "${1:-}"; shift; cmd_exec "$@" ;;
    help|-h|--help) sed -n '2,/^set -euo/p' "$SELF" | sed '$d; s/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' (xcesp-swarm help)" ;;
esac
