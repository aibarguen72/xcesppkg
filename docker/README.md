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
  (LICENSE_ENFORCE=false, DOC_HTTPD disabled, wdog launches server +
  proc directly with no xcesp-activate stage).
- `build.sh` — build the image on THIS host (needs podman + qemu-user).
- `save.sh` — export the built image to a docker-loadable `.tar`.
- `load.sh` — run on the TARGET device to `docker load` the tar.
- `run.sh` — run on the TARGET device to start the container with
  operator-supplied flags.

## Build + package (this host)

```
cd docker
./build.sh                     # -> localhost/xcesp-modem:<VER>-arm64
./save.sh                      # -> xcesp-modem-<VER>-arm64.tar
```

Copy `xcesp-modem-<VER>-arm64.tar`, `load.sh`, and `run.sh` to the
target device.

## Load + run (target device)

```
chmod +x load.sh run.sh          # exec bit may not survive scp
./load.sh xcesp-modem-<VER>-arm64.tar
./run.sh --msisdn +34600000099 \
         --rvp 10.0.0.1 \
         --transport-ip 192.168.1.20 \
         --serial /dev/ttyMV1 \
         --passphrase fleet-shared-secret
```

Container starts detached with `--restart unless-stopped`.  Follow
the log with `docker logs -f xcesp-modem`.

## Network mode

`run.sh --network host` (the default) is simplest — the container
binds directly on the host's real interfaces.  Requires the docker
daemon to permit host networking.

`run.sh --network bridge` is the fallback for hosts where host
networking is blocked by policy.  The script:

- Passes `--network=bridge` to docker.
- Adds `-p <TCP>:<TCP>` and `-p <UDP>:<UDP>/udp` for the transport
  ports so the container is reachable at the host's real IP.
- Clamps `transport-ip` to `0.0.0.0` (the host IP doesn't exist
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

`run.sh` creates both on first launch if missing.  On upgrade
(new image tag), `docker rm -f` + fresh `run.sh` reuses the same
mount so state carries over cleanly.

## What the container does NOT do

- **No routing / VRF / MPLS.**  This is a modem-only container.
  Full router workloads use the systemd `install.sh` from the
  xcesppkg tarball on a bare-metal host.
- **No local license.**  Set `LICENSE_ENFORCE=false` — the fleet is
  licensed centrally at the RVP (`license-code` on the pstn-rvp
  node covers modem slots for every registered MSISDN).
- **No modem-peers file.**  The RVP is the single source of truth
  for peer discovery (LOOKUP by MSISDN).
- **No DOC HTTPD.**  Documentation ships on the operator's admin
  host, not inside every device.

## Version stamping

The image tag encodes the bundled xcesppkg version
(`xcesp-modem:0.4.67-arm64`).  `build.sh` reads `../PROJECT`'s
`PRJVERSION` and picks a matching tarball name — no manual version
juggling.  For a container-only release (same binaries, new
entrypoint / wdog INI), pass the previous version's tarball
explicitly: `./build.sh ../xcespkg-arm64-<older>.tgz`.
