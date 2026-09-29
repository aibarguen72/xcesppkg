# xcesp-modem — single-modem docker container

Repackages a shipped `xcespkg-arm64-<VERSION>.tgz` as an
offline-loadable docker image for customer devices that host one
serial modem each.  The container carries everything the modem
needs (xcespserver, xcespproc, xcespwdog, xcespcli, xcesp-on-xc's
schema + rules) and reads its per-deployment values (MSISDN, RVP,
transport ports, PSK) from environment variables at launch.

## Files

- `Dockerfile` — image recipe (Ubuntu 22.04 aarch64 + libsodium23 +
  python3 + the shipped binaries).
- `entrypoint.sh` — runs at container start; validates env, generates
  `/var/xcesp/cfg/xcespserver.conf`, execs `xcespwdog`.
- `xcespserver.ini` / `xcespwdog.ini` — container-tuned INI files
  (`LICENSE_ENFORCE=true`, `DOC_HTTPD` disabled, wdog launches
  server + proc directly with no xcesp-activate stage).
- `build.sh` — build the image on THIS host (needs podman + qemu-user).
- `save.sh` — export the built image to a docker-loadable `.tar`.
- **`xcesp-modem.sh`** — single operator entry point on the target
  device.  Replaces the earlier `load.sh` + `run.sh` pair with a
  `<action> [opts]` dispatcher (`load / start / stop / restart /
  remove / log / cli / status / shell / version / help`).

## Build + package (this host)

```
cd docker
./build.sh                     # -> localhost/xcesp-modem:<VER>-arm64
./save.sh                      # -> xcesp-modem-<VER>-arm64.tar
```

Copy `xcesp-modem-<VER>-arm64.tar` and `xcesp-modem.sh` to the target
device.

## Load + run (target device)

```
chmod +x xcesp-modem.sh          # exec bit may not survive scp
./xcesp-modem.sh load xcesp-modem-<VER>-arm64.tar
./xcesp-modem.sh start \
    --msisdn +34600000099 \
    --rvp 10.0.0.1 \
    --transport-ip 192.168.1.20 \
    --serial /dev/ttyMV1 \
    --passphrase fleet-shared-secret \
    --dcd-source primary:rts             # boards without a DCD pin
```

The `load` action auto-retags `localhost/xcesp-modem:<VER>-arm64`
(podman default) to plain `xcesp-modem:<VER>-arm64` so the `start`
action's default `--image` matches — no manual `docker tag` step.

Container starts detached with `--restart unless-stopped`.  Follow
the log with `./xcesp-modem.sh log -f` (tails the plain-text file
on the bind-mount, which survives ungraceful power-off — `docker
logs`' JSON stream can go corrupt if the host was killed mid-write).

## Everyday operator commands

```
./xcesp-modem.sh status          # docker ps + `show modem` snapshot
./xcesp-modem.sh log -f          # tail the modem log (--docker for docker logs)
./xcesp-modem.sh cli             # interactive xcespcli inside the container
./xcesp-modem.sh restart         # same-config restart
./xcesp-modem.sh stop            # docker stop
./xcesp-modem.sh remove          # docker rm -f
./xcesp-modem.sh shell           # bash inside the container (diagnostics)
./xcesp-modem.sh version         # print image tag currently in use
```

## Network mode

`--network host` (the default) is simplest — the container
binds directly on the host's real interfaces.  Requires the docker
daemon to permit host networking.

`--network bridge` is the fallback for hosts where host
networking is blocked by policy.  The start action:

- Passes `--network=bridge` to docker.
- Adds `-p <TCP>:<TCP>` and `-p <UDP>:<UDP>/udp` for the transport
  ports so the container is reachable at the host's real IP.
- Clamps `--transport-ip` to `0.0.0.0` (the host IP doesn't exist
  inside the container's netns; docker's `-p` bridges it).

Both modes work identically on both LAN and LTE deployments.  The
RVP records the host's IP as the modem's address either way —
docker's SNAT masquerade takes care of the source-IP rewrite on
bridge mode, and host mode puts the container on the host's iface
directly.

Bridge mode does **not** work if the host is behind carrier-grade
NAT AND the RVP is off-site: inbound SMS UDP / CSD TCP from a peer
would land at the CGN edge, not at the target device.  Host mode
has the same limitation for the same reason — the constraint is
the WAN topology, not docker.

## Persistent state

Two bind mounts survive container restart:

- `/var/lib/xcesp` — managed-users, aaa-config, dsk store, future
  SMS-counter persistence.
- `/var/log/xcesp` — xcesp.log written by xcespwdog.

`start` creates both on first launch if missing.  On upgrade to a
new image tag, `remove` + fresh `start` (with the same
`--state-dir`) reuses the same mount so state carries over cleanly.

## Log rotation

`xcespwdog` inside the container writes to `/var/xcesp/log/xcesp.log`
(bind-mounted to `<state-dir>/log/xcesp.log` on the host).  A shell
rotator runs as a supervised process alongside xcespserver / xcespproc
and caps the file in place — no host-side logrotate or cron needed.

Defaults: 10 MB per file × 4 archives (`xcesp.log.1` … `.4`) = 40 MB
worst-case per device.  On a modem with only 5-minute REGISTER
traffic that never rotates.  Under sustained call activity it rolls
without operator intervention.

Override via `xcesp-modem.sh start` flags:

```
--log-max-mb <N>    cap in MB (default 10; 0 disables rotation)
--log-keep <N>      archives to keep (default 4)
```

Rotation uses in-place truncation (`: > xcesp.log`) so xcespwdog's
open fd stays valid — same effect as `logrotate --copytruncate` but
shell-only with no external dependencies.  When rotation fires, a
line lands in `xcesp.log` itself:

```
[xcesp-log-rotator] rotated at 2026-09-30T02:13:41Z — was 10485760 B, now 0
```

## Persistent config (RVP-hosting device only)

By default `xcespserver.conf` is regenerated from `--msisdn` /
`--rvp` / `--transport-ip` / etc. on every launch — a fleet of
identical field modems is easier to manage that way, and
`xcespcli`'s `configure/commit/save` edits get discarded on
restart.

One device in the fleet typically doubles as the central RVP.
That device needs to persist:
* `pstn-rvp` config (a growing `crypto-peer` list as new
  MSISDNs come online), and
* `license-code` lines under `server 1` (fleet-wide licensing —
  the RVP is the license authority).

Both live in `xcespserver.conf`.  Opt into persistence with
`--persist-config`:

```
./xcesp-modem.sh start \
    --msisdn +34600000000 --rvp 127.0.0.1 \
    --transport-ip 10.0.0.1 --serial /dev/ttyMV1 \
    --state-dir /USERFS/rados_user_files/xcesp \
    --passphrase <fleet-secret> \
    --persist-config              # -> /USERFS/rados_user_files/xcesp/xcespserver.conf
```

The persisted file sits next to `lib/` and `log/` in the state-dir
by default (`<state-dir>/xcespserver.conf`).  Override with an
explicit absolute path: `--persist-config /etc/xcesp-rvp/config.conf`.

Behaviour:
* **First launch** with an empty host file → env vars seed the
  file, xcespserver runs from it, and the write persists via the
  bind mount.
* **Subsequent launches** with a non-empty host file → the
  entrypoint uses the file as-is.  `--msisdn`, `--rvp`,
  `--transport-ip`, `--baud`, `--passphrase`, and the six
  `--*-source` flags are IGNORED (the entrypoint logs a
  WARNING listing them).  From here on the operator manages
  config via `xcesp-modem.sh cli` → `configure` → `commit` →
  `save`, and every `save` writes through the same bind mount.
* **Reset** to first-launch behaviour → delete the host file and
  restart.  Next launch seeds fresh from env vars.

Ordinary fleet devices leave `--persist-config` unset and behave
exactly as before.

## What the container does NOT do

- **No routing / VRF / MPLS.**  This is a modem-only container.
  Full router workloads use the systemd `install.sh` from the
  xcesppkg tarball on a bare-metal host.
- **No modem-peers file.**  The RVP is the single source of truth
  for peer discovery (LOOKUP by MSISDN).
- **No DOC HTTPD.**  Documentation ships on the operator's admin
  host, not inside every device.

`LICENSE_ENFORCE=true` inside the container by default, but a
modem-only deployment ships no `license-code` lines — the fleet is
licensed centrally at the RVP (`license-code` on the pstn-rvp node
covers modem slots for every registered MSISDN) so enforcement is
effectively a no-op.

## Version stamping

The image tag encodes the bundled xcesppkg version
(`xcesp-modem:0.4.71-arm64`).  `build.sh` reads `../PROJECT`'s
`PRJVERSION` and picks a matching tarball name — no manual version
juggling.  For a container-only release (same binaries, new
entrypoint / wdog INI), pass the previous version's tarball
explicitly: `./build.sh ../xcespkg-arm64-<older>.tgz`.
