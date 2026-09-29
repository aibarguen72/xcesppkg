#!/bin/sh
# xcesp-log-rotator — cap the size of /var/xcesp/log/xcesp.log without
# needing any host-side cron or write access to /etc.
#
# Runs as a supervised process under xcespwdog (see [process.3] in
# xcespwdog.ini).  Loops on `sleep`, checks the log file size, rotates
# it in place when it exceeds the cap.
#
# Rotation preserves the log file's inode (`: > $LOG` uses O_TRUNC),
# so xcespwdog's open fd — which uses std::ios::app on every write —
# keeps writing to the same file at the (new) end-of-file position 0
# with no SIGHUP or reopen needed on the writer side.  This mirrors
# what `logrotate --copytruncate` does, but shell-only with no
# external dependencies (uses BusyBox-compatible builtins only).
#
# Env vars (all optional, with the defaults below):
#   LOG_MAX_MB               10    cap in MB (0 = disable rotation)
#   LOG_KEEP                 4     number of .1, .2, ..., .K archives
#   LOG_CHECK_INTERVAL_SEC   3600  seconds between size checks
#
# Set LOG_MAX_MB=0 to disable — the rotator then sleeps forever
# rather than exiting, so xcespwdog doesn't respawn-loop it.

: "${LOG_MAX_MB:=10}"
: "${LOG_KEEP:=4}"
: "${LOG_CHECK_INTERVAL_SEC:=3600}"

LOG=/var/xcesp/log/xcesp.log

if [ "$LOG_MAX_MB" = "0" ] || [ "$LOG_MAX_MB" -le 0 ] 2>/dev/null; then
    logger -n 127.0.0.1 -P 1514 --udp -t xcesp-log-rotator \
        "LOG_MAX_MB=$LOG_MAX_MB — rotation disabled, sleeping" 2>/dev/null || true
    exec sleep infinity
fi

MAX_BYTES=$((LOG_MAX_MB * 1024 * 1024))
log() {
    # Route into xcespwdog's SyslogReader on UDP :1514 so the message
    # lands in /var/xcesp/log/xcesp.log next to xcespserver + xcespproc
    # output.  Plain `echo` would go to the container's stdout (visible
    # only via `docker logs`), which is easy to miss on a device where
    # the operator is following the persistent log file.
    logger -n 127.0.0.1 -P 1514 --udp -t xcesp-log-rotator "$@" 2>/dev/null || \
        echo "[xcesp-log-rotator] $*"      # fallback if logger fails
}

log "active: cap=${LOG_MAX_MB} MB keep=${LOG_KEEP} archives check-interval=${LOG_CHECK_INTERVAL_SEC}s"

while true; do
    if [ -f "$LOG" ]; then
        size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_BYTES" ]; then
            # Slide older archives: .K-1 -> .K, ..., .1 -> .2.  Drops the
            # oldest one that would fall off the end.
            i=$LOG_KEEP
            while [ "$i" -gt 1 ]; do
                prev=$((i - 1))
                if [ -f "$LOG.$prev" ]; then
                    mv -f "$LOG.$prev" "$LOG.$i"
                fi
                i=$prev
            done
            # Snapshot the current file into .1 (byte-accurate at cp
            # time), then truncate the live file.  Writes arriving
            # between the cp and the truncate are captured in .1 AND
            # may briefly appear at the end of the truncated file
            # before the truncate takes effect — a small race that
            # loses at worst a few lines, never the archive.
            cp "$LOG" "$LOG.1" && : > "$LOG"
            log "rotated (was ${size} B, ${LOG_KEEP} archives kept)"
        fi
    fi
    sleep "$LOG_CHECK_INTERVAL_SEC"
done
