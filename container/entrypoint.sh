#!/bin/bash
# xcesp-entrypoint — PID 1 of the generic XCESP container.
#
# Does what xcesp.service does on a host, without systemd:
#   1. first start of an instance: seed the (bind-mounted, empty) state
#      directories from the package defaults
#   2. loop: xcesp-activate (root), then xcespwdog as user xcesp in the
#      foreground.  `reboot light` / `system activate` / a restart request
#      (see /usr/bin/systemctl in the image) ends xcespwdog with the restart
#      flag set -> the loop runs activate + xcespwdog again.
#   3. `podman stop` (SIGTERM): stop xcespwdog and exit.
#   sshd (1.1.1) runs beside the loop: host keys are made once per instance
#   in /var/lib/xcesp/ssh and kept; a stack restart leaves sshd and its
#   sessions alone, as restarting xcesp.service does on a host.  Accounts,
#   keys and the ForceCommand drop-in come from xcesp-activate (aaa).
#
# Per-instance state (bind mounts, see xcesp-ctr.sh):
#   /var/xcesp/cfg   configuration (xcespserver.conf, ini files)
#   /var/lib/xcesp   runtime state (ifIndex map, users, licences, leases)
#   /var/xcesp/dsk   files (recordings, software, exports)
#   /var/xcesp/log   logs
set -u

RUN=/run/xcesp-ctr
DEFAULTS=/usr/share/xcesp-ctr
XUSER=xcesp
XGROUP=xcesp
log() { echo "xcesp-entrypoint: $*" >&2; }

mkdir -p "$RUN" /run/xcesp
chown "$XUSER:$XGROUP" /run/xcesp
chmod 0750 /run/xcesp

# --- 1. seed a new instance -------------------------------------------------
seed() {   # $1 = live dir, $2 = default copy in the image
    local dst="$1" src="$2"
    mkdir -p "$dst"
    if [ -d "$src" ] && [ -z "$(ls -A "$dst" 2>/dev/null)" ]; then
        cp -a "$src/." "$dst/"
        log "new instance: seeded $dst"
    fi
}
seed /var/xcesp/cfg "$DEFAULTS/cfg"
seed /var/lib/xcesp "$DEFAULTS/lib"
# Per-instance machine-id, kept in the state dir: XCESP derives the licence
# system-mac and the secret-encryption key from /etc/machine-id, which the
# image would otherwise share between all instances.
IDF=/var/lib/xcesp/instance-machine-id
if [ ! -s "$IDF" ]; then
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$IDF"
    echo >> "$IDF"
    log "new instance: machine-id $(cat "$IDF")"
fi
cp "$IDF" /etc/machine-id
chmod 0444 /etc/machine-id

# SSH host keys: one set per instance, created on the first start and kept
# in the state dir (they change only when the state is deleted).
SSHKEYS=/var/lib/xcesp/ssh
install -d -m 0700 -o root -g root "$SSHKEYS"
for t in ed25519 ecdsa rsa; do
    if [ ! -s "$SSHKEYS/ssh_host_${t}_key" ]; then
        ssh-keygen -q -t "$t" -N '' -C "root@$(hostname)" -f "$SSHKEYS/ssh_host_${t}_key"
        log "new instance: SSH host key $t"
    fi
done
mkdir -p /etc/ssh/sshd_config.d
{
    echo "# xcesp container: per-instance host keys (xcesp-entrypoint)"
    for t in ed25519 ecdsa rsa; do echo "HostKey $SSHKEYS/ssh_host_${t}_key"; done
} > /etc/ssh/sshd_config.d/10-xcesp-ctr.conf

mkdir -p /var/xcesp/dsk /var/xcesp/log
chown -R "$XUSER:$XGROUP" /var/xcesp/dsk /var/xcesp/log
chown root:"$XGROUP" /var/xcesp/cfg /var/lib/xcesp
chmod 2775 /var/xcesp/cfg /var/lib/xcesp
find /var/xcesp/cfg -maxdepth 1 -type f -exec chown "$XUSER:$XGROUP" {} + 2>/dev/null

# What systemd's control-group kill does when xcesp.service stops: every
# process the stack started (xcespserver / xcespproc that outlived
# xcespwdog, FRR, charon, dnsmasq, the web and doc servers, snmpd) ends
# before the next start, or their ports and pid files block it.
# sshd and everything below it (SSH sessions, their xcespcli) survive a
# stack restart: list those pids so stop_all skips them.
sshd_tree() {
    local sp
    sp=$(cat /run/sshd.pid 2>/dev/null) || return 0
    ps -eo pid=,ppid= | awk -v root="$sp" '
        { parent[$1] = $2; pids[NR] = $1 }
        END { for (i = 1; i <= NR; i++) { p = pids[i]; q = p
                while (q != "" && q > 1) { if (q == root) { print p; break } q = parent[q] } } }'
}
sshd_ensure() {
    [ -f /run/sshd.pid ] && kill -0 "$(cat /run/sshd.pid)" 2>/dev/null && return 0
    mkdir -p /run/sshd && chmod 0755 /run/sshd
    /usr/sbin/sshd && log "sshd started" || log "sshd failed to start"
}

stop_all() {
    local pids p i keep
    keep=" $(sshd_tree | tr '\n' ' ') "
    pids=$(ps -eo pid= | awk -v self="$$" -v keep="$keep" '$1 != 1 && $1 != self && index(keep, " " $1 " ") == 0')
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    for i in $(seq 1 20); do
        pids=$(ps -eo pid=,stat= | awk -v self="$$" -v keep="$keep" '$1 != 1 && $1 != self && $2 !~ /^Z/ && index(keep, " " $1 " ") == 0 { print $1 }')
        [ -z "$pids" ] && break
        sleep 0.5
    done
    for p in $pids; do kill -KILL "$p" 2>/dev/null; done
    rm -f "$RUN/snmpd.pid"
}

# --- 3. stop handling -------------------------------------------------------
stopping=0
on_term() {
    stopping=1
    rm -f "$RUN/restart"
    [ -f "$RUN/wdog.pid" ] && kill -TERM "$(cat "$RUN/wdog.pid")" 2>/dev/null
}
trap on_term TERM INT

# --- 2. activate + xcespwdog loop -------------------------------------------
# A new instance has no managed-users.state yet: xcespserver writes it (and
# managed-keys.state, aaa-config.state) from the seeded config only after
# xcesp-activate ran.  Apply them once when they appear, as `system activate`
# does, so seeded users and SSH keys work from the first start.
first_activate=0
[ -f /var/lib/xcesp/managed-users.state ] || first_activate=1
rc=0
while [ "$stopping" = 0 ]; do
    rm -f "$RUN/restart"
    log "xcesp-activate"
    /usr/bin/xcesp-activate || log "xcesp-activate exited $? (continuing)"

    # snmpd: started when xcesp-activate wrote the XCESP block (management
    # snmp enabled); xcesp-activate's own `systemctl restart snmpd` goes to
    # the stand-in and does the same.
    if grep -q '^# BEGIN xcesp-snmp' /etc/snmp/snmpd.conf 2>/dev/null && \
       ! { [ -f "$RUN/snmpd.pid" ] && kill -0 "$(cat "$RUN/snmpd.pid")" 2>/dev/null; }; then
        /usr/bin/systemctl start snmpd
    fi

    sshd_ensure

    if [ "$first_activate" = 1 ]; then
        first_activate=0
        (
            for _ in $(seq 1 240); do
                if [ -f /var/lib/xcesp/managed-users.state ]; then
                    sleep 1
                    /usr/bin/xcesp-activate --config >/dev/null 2>&1 \
                        && log "first start: users, SSH keys and AAA applied (xcesp-activate --config)"
                    exit 0
                fi
                sleep 0.5
            done
        ) &
    fi

    log "starting xcespwdog"
    runuser -u "$XUSER" -- /usr/bin/xcespwdog --config /var/xcesp/cfg/xcespwdog.ini &
    echo $! > "$RUN/wdog.pid"
    wait "$!"
    rc=$?
    # `wait` returns early when a trapped signal arrives: let xcespwdog finish.
    while kill -0 "$(cat "$RUN/wdog.pid")" 2>/dev/null; do sleep 0.5; done
    rm -f "$RUN/wdog.pid"
    stop_all

    if [ -f "$RUN/restart" ] && [ "$stopping" = 0 ]; then
        log "restart requested — restarting the XCESP stack"
        sleep 2
        continue
    fi
    break
done
[ -f /run/sshd.pid ] && kill -TERM "$(cat /run/sshd.pid)" 2>/dev/null
log "stopped (xcespwdog rc=$rc)"
[ "$stopping" = 1 ] && exit 0
exit "$rc"
