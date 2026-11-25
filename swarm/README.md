# xcesp-swarm — swarms of XCESP containers (xNMS lab)

`xcesp-swarm.sh` launches, monitors and stops swarms of N XCESP devices
built from the generic container image (`../container`, `xcesp:<version>`).
Several swarms run side by side on one host and are fully independent. On
XNMS1 there are two: one for preproduction testing, one that replicates the
field network.

```
                         host (xNMS)  ── uplink ── internet
                              │ 10.201.0.1 (NAT)
   swarm "preprod" ─ mgmt  ───┼──────────────┬──────────────┐   xs1m
                          eth0│          eth0│          eth0│
                        preprod-001    preprod-002  ...  preprod-N
                          eth1│ eth2     eth1│ eth2     eth1│ eth2
                 net1 ────────┴──┼───────────┴──┼───────────┘ │       xs1n1 (internal L2)
                 net2 ───────────┴──────────────┴─────────────┘       xs1n2 (internal L2)

   swarm "replica" (id 2): same layout on 10.202.0.0/16, bridges xs2m, xs2n1, xs2n2
```

| Network | Inside | Addressing | Reach |
|---|---|---|---|
| `mgmt` | `eth0` | fixed: device *i* = subnet + 10 + *i*; host = first address | host, other devices, internet (NAT) |
| `net1`, `net2`, … | `eth1`, `eth2`, … | none from podman. The XCESP configuration sets them | devices of the same swarm only (L2) |

Each device has a fixed hostname (`<swarm>-NNN`), mgmt IP and MAC
(`02:58:<swarm id>:<net>:<device>`), plus its own state directory. Licences
and the xNMS inventory therefore survive container re-creation.

## Setup (once, as root)

```
podman load -i xcesp-1.0.1-x86_64.tar
./xcesp-swarm.sh install                     # /usr/local/sbin/xcesp-swarm + xcesp-swarm@.service
xcesp-swarm preflight                        # sysctls for hundreds of containers
xcesp-swarm init preprod --id 1 --nodes 20
xcesp-swarm init replica --id 2 --nodes 150 --memory 1g
```

`init` writes `/etc/xcesp-swarm/<swarm>.conf`. Edit it there to change the
subnet, the traffic networks, the image or the limits.

## Run

```
xcesp-swarm up preprod                 # networks + devices 1..N (8 in parallel)
xcesp-swarm status preprod             # device, health, mgmt IP, CLI, CPU, mem
xcesp-swarm monitor preprod            # live view, problems only (--all: every device)
xcesp-swarm health preprod             # exit 0 = all up (cron / Nagios / CI)
xcesp-swarm scale preprod 40           # grow or shrink
xcesp-swarm cli preprod 7              # xcespcli on preprod-007
xcesp-swarm exec preprod all -- head -1 /var/xcesp/mainsw/VERSION
xcesp-swarm down preprod               # stop everything, keep containers + state
xcesp-swarm destroy preprod [--purge]  # remove containers + networks [+ state]
systemctl enable --now xcesp-swarm@replica   # up at boot, down at shutdown
```

Health per device:

| Health | Meaning |
|---|---|
| `up` | running, and the CLI port 9900 accepts on the mgmt IP |
| `starting` | running, CLI not answering yet (normal for about 1 minute after start) |
| `stopped` | the container exists but is not running |
| `missing` | the container has not been created |
| `extra` | a device above `NODES` |

`monitor` writes every health change to `<state>/monitor.log`.

## Inventory for xNMS

`up` and `scale` write `/var/lib/xcesp-swarm/<swarm>/inventory.csv`,
`inventory.json` and `hosts` (append the last one to `/etc/hosts` for names).
`xcesp-swarm inventory <swarm> --format json` prints the same data.

## Initial configuration per device (`--seed-dir`)

On a device's first start, if `<seed>/<swarm>-NNN/` exists (or else
`<seed>/default/`), its files are copied into the device's cfg directory on
top of the image defaults, with these placeholders replaced:

| Placeholder | Value |
|---|---|
| `@HOST@` | device hostname |
| `@NODE@` | device number, 3 digits |
| `@INDEX@` | device number |
| `@MGMT_IP@`, `@MGMT_PREFIX@`, `@MGMT_GW@` | mgmt addressing |
| `@SWARM@` | swarm name |

For the replica swarm this is how the field configurations, such as an
`xcespserver.conf` per device, are loaded. A device whose cfg directory is
not empty is not seeded again.

## State

`/var/lib/xcesp-swarm/<swarm>/<swarm>-NNN/{cfg,lib,dsk,log}` has the same
layout as `xcesp-ctr.sh`, see `../container/README.md`.

## Limits and notes

* Run as root. Rootless podman works, but the host cannot reach the mgmt
  bridge, so xNMS could not manage the devices.
* At most 999 devices per swarm and swarm IDs 1–60. A `/16` mgmt subnet
  holds them all.
* Linux bridges do not forward link-local multicast (STP, LACP, LLDP) on
  net1/net2 by default. If a test needs them, set
  `/sys/class/net/xs<id>n<k>/bridge/group_fwd_mask`.
* Software upgrade: set `IMAGE` in the definition, then
  `xcesp-swarm destroy <swarm> --yes && xcesp-swarm up <swarm>`. The state
  is kept.
