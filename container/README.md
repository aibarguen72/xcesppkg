# xcesp — generic XCESP container (x86_64, Debian 13)

One image, several XCESP instances per host — for training, testing and
labs.  Each instance is a complete XCESP (routing with FRR and strongSwan,
TDM-PW / XC / VTRUNK, SNMP, web interface) in its own container with its
own state directory on the host.  The modem-only container is in
`../docker/` (xcesp-modem).

## Build (this host)

```
make                                   # x86 tarball xcespkg-<ver>.tar.gz
debian/build-debian.sh                 # xcespkg-debian-<ver>.tar.gz (binaries rebuilt in debian:trixie)
container/build.sh --save              # image xcesp:<ver> + xcesp-<ver>-x86_64.tar
```

The image installs the Debian tarball with the package's own `install.sh`,
so a container and a host install are the same installation.  There is no
systemd: `/usr/bin/systemctl` is a stand-in (`systemctl` here) and
`xcesp-entrypoint` (`entrypoint.sh`) does what `xcesp.service` does —
`xcesp-activate`, then `xcespwdog` as user `xcesp`.

## Run (target host, as root)

```
xcesp-ctr.sh load xcesp-<ver>-x86_64.tar
xcesp-ctr.sh start lab1 --web-port 8081     # first instance
xcesp-ctr.sh start lab2                     # second one, same network
xcesp-ctr.sh cli lab1                       # configure
xcesp-ctr.sh list
```

`xcesp-ctr.sh help` lists every command.  Instances run privileged (network
namespaces, MPLS, L2TP, raw sockets, real-time scheduling) and load kernel
modules from the host; run them as root.  All instances join the podman
network `xcesp-lab` and reach each other as separate systems would.

## Instance state

`--state-dir` (default `/var/lib/xcesp-ctr/<name>`) holds:

| Host | Container | Content |
|---|---|---|
| `cfg/` | `/var/xcesp/cfg` | configuration (`xcespserver.conf`, ini files) |
| `lib/` | `/var/lib/xcesp` | runtime state: ifIndex map, users, licence state, leases, `instance-machine-id` |
| `dsk/` | `/var/xcesp/dsk` | files: recordings, exports |
| `log/` | `/var/xcesp/log` | logs |

A new (empty) state directory is seeded from the package defaults on first
start.  Removing the container (`xcesp-ctr.sh remove`) keeps the state.

**Licences.** XCESP derives the licence system-mac from `/etc/machine-id`.
Each instance gets its own random machine-id on first start, stored in
`lib/instance-machine-id`, so licences are per instance and survive
container re-creation and image upgrades.  `show server` reports the
system-mac to license.

## Behaviour inside a container

* `reboot light` and `system activate` restart the XCESP stack inside the
  container (activate + xcespwdog); `reboot` does the same — the host is
  not rebooted.  `xcesp-ctr.sh restart <name>` restarts the container.
* Software upgrade: load a new image and re-create the instance
  (`remove` + `start` with the same state directory).  `copy sw` /
  `software-install` inside a container do not survive a re-creation.
* snmpd runs inside the instance when `management snmp` is enabled.
* Debian 13 differences from the Fedora package: no NETCONF (sysrepo is
  not packaged on Debian 13); strongSwan 6.0.
