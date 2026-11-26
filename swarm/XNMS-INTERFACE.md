# XCESP ↔ xNMS interface agreement (version 2.3, 2026-11-26; 2.2 accepted by xNMS)

Answers to the xNMS requests of 2026-11-25, and the contract both projects
build against. XCESP owns this file (`xcesppkg/swarm/` on branch `next`).
Changes to it are agreed between the two projects first.

**Changes in version 2** (answers to the xNMS review of draft 1):
public keys move up to step 3 (§1, §8). The SSH change sequence is defined:
merge without committing, `--timer-commit`, `--check`, `confirm`/`save`
through `-c`, all-or-nothing, and error lines with a line number or config
path (§2). Delegating to user `xnms` (§3.1). Timings measured (§3). How
field configs with E1/T1, serial or SFP are handled (§4.1). Per-device
`image` in the inventory (§5). Version fidelity of twins and seeding from a
backup (§6). New delivery order (§8). Decisions taken and still open (§9).

**Changes in version 2.1** (xNMS cleanup): xNMS does not manage 1.0.x
nodes (§0), so 1.0.x twins and `twin-cli` are dropped (§3.1, §6.1). The
`ERROR:` line format falls under a stability rule (§2.1). Answers and
version 3 items for the five open points (§9).

**Changes in version 2.2** (xNMS accepted 2.1): exit status 4 in the §2
table; `show status server <key>` with value-only output and a stability
rule for the status keys xNMS reads (§2.2); the xNMS public key in the twin
seed (§3.1).

**Changes in version 2.3** (xNMS request of 2026-11-26, owner-approved):
stable key `server/sw/main/release`, the bare platform version, so xNMS
can refuse nodes below 1.1.1 without parsing human output (§2.2).

## 0. Baseline

* **Release line.** xNMS targets XCESP **1.1.1 or later** (branch `next`).
  Until 1.1.1 GA, swarms run `next` pre-releases (image tag
  `xcesp:1.1.1-devN`). Nothing below is backported to 1.0.x.
* **xNMS does not manage 1.0.x nodes.** Field nodes come under xNMS only
  once they run 1.1.1 or later, so every managed node and every twin has
  sshd, public keys and `-c`.
* **Schedule.** The first xNMS demo is planned for the end of December 2026.
  XCESP delivers in the order of section 8.
* **Status of this document.** It is a design. Sections marked *exists* work
  today. Everything else is planned and not built yet.

## 1. SSH access (request 1)

How SSH works on an ISO node today (*exists*): an operator configures users
under `management aaa` and turns on `aaa sshd-integration true`.
`xcesp-activate` then creates the Linux accounts (groups
`xcespg1..xcespg4` = roles 1..4) and installs the sshd drop-in that forces
`xcesp-login` → `xcespcli`. Local users log in with a **password only**.

Container plan (*planned*):

* **sshd in the image.** The image gets `openssh-server`, and the entrypoint
  starts sshd on all addresses, so it is reachable on the mgmt IP (`eth0`).
  The `systemctl` stand-in handles `reload/restart sshd` for `xcesp-activate`.
* **Host keys.** They are created on the first start into
  `<state>/lib/ssh/` and reused on every later start, re-creation and
  `reset`. They change only with `destroy --purge`.
* **Management account.** It comes from the seed config, not from swarm
  magic, so a device is set up exactly like a customer node. The seed
  `xcespserver.conf` contains the `management aaa` user (role 1 for xNMS)
  and `sshd-integration true`. xcesp-swarm adds nothing of its own.
* **Public keys** (*planned, product feature, ISO too; delivery step 3,
  right after sshd*). A `management aaa user` gets an optional public-key
  attribute (one or more OpenSSH public keys). `xcesp-activate` writes
  `authorized_keys` for that account and enables pubkey authentication for
  it in the sshd drop-in, which still forces `xcesp-login`. A user can have
  a key, a password or both. xNMS logs in with keys only, so it does **not**
  need a password-login stopgap: steps 2 and 3 ship together, before the
  demo.
  *Delivered in 1.1.1-dev1:* `public-key <label>` / `key <line>` under
  `management aaa user`. Committed keys are installed at the next XCESP
  start or with `system activate` (show mode), like every AAA change. Key
  rotation: commit the new label and `no public-key <old>`, then
  `system activate`.
* **Health.** `status`/`health` get an `SSH` column (TCP 22 on the mgmt IP)
  next to `CLI` (TCP 9900). A device counts as `up` when **both** answer.

## 2. One command over SSH, no banner (request 4)

*Planned, product feature (ISO and container).*

* **`xcespcli -c "<command>"`** runs one command in show mode and exits. It
  prints no logo, server or user banner and no prompt, and writes only the
  command output to stdout and errors to stderr. It respects the role
  (role 4 cannot run actions).
* **`xcesp-login`.** When `$SSH_ORIGINAL_COMMAND` is set,
  `ssh xnms@node show running` runs exactly that one command through
  `xcespcli -c` and returns its output and exit status. Without a command,
  the interactive session with banners is unchanged.
* **Exit status:**

  | Code | Meaning |
  |---|---|
  | 0 | OK |
  | 1 | The command was rejected or failed (the reason is on stderr) |
  | 2 | Usage error, or not allowed for the role |
  | 3 | No connection to xcespserver |
  | 4 | `confirm` with no timer-commit pending (*planned*, version 3, §9 point 2) |

* **Config over SSH.** `ssh node --merge-config -` (the file on stdin) and
  later `--replace-config -` follow the same pattern.

### 2.1 Changing config over SSH (the xNMS change sequence)

**What `--merge-config` does today** (*exists*, checked in the 1.0.1
code): xcespcli reads the running config, applies the `no …` lines, merges
the file into it, and sends the result as **one commit**. xcespserver
checks the whole new config before it changes anything (parse, schema,
Python validation hooks, licence gates). If any check fails, the commit is
rejected and the running config is **unchanged**: nothing is ever partly
applied. It commits but does **not** `save`. It cannot be wrapped in a
timer-commit yet, and on stdout it prints only `OK`, or `ERROR:<reason>` on
stderr.

**Planned (product, ISO too, delivery step 5):**

| Need | Command (over SSH: `ssh xnms@node <args>`) |
|---|---|
| Dry run: merge and check, do not commit | `--merge-config - --check` |
| Merge and commit with automatic rollback | `--merge-config - --timer-commit <10-3600>` |
| Confirm the pending timer-commit | `-c confirm` |
| Save running to the startup config | `-c save` |
| Read back | `-c "show running"`, `-c "show candidate"` |

* `-c` runs any **show-mode** command the role allows: `show …`, `save`,
  `confirm` and actions. `commit` and `timer-commit` need a candidate,
  which a one-shot session does not have. That is why the timer is an
  option of `--merge-config`.
* `--timer-commit` arms the server-side timer **before** the commit, as
  the interactive `timer-commit` does. If the SSH session dies right after
  the commit, the node still rolls back. A rejected commit cancels the
  timer. Without `confirm` within the time, XCESP restarts with the saved
  configuration (light restart, not a reboot).
* The xNMS sequence becomes:
  `--merge-config - --check` → `--merge-config - --timer-commit 300` →
  checks (any `-c "show …"`) → `-c confirm` → `-c save`.

**Errors.** On exit status 1, stderr has one line per error, all errors
(not only the first one), and **nothing was applied**:

```
ERROR: <source>:<line>: <message>          parse error in the merged file
ERROR: <config-path>: <message>            schema or validation-hook error
ERROR: <message>                           licence gate or apply failure
```

`<source>` is `-` for stdin. Line numbers refer to the file as sent.
Today a top-level `no …` line is removed before parsing, which shifts later
line numbers. This is fixed in the same step. `<config-path>` is the
node path, for example `router r1/interface ge1/address`. A parse error
stops before the server is asked. A validation error comes from the
server's checks of the whole merged config, so it can point at a node that
the file did not touch but that the change made invalid.

**Stability rule** (same as the inventory, §5). The three `ERROR:` line
shapes above, the exit codes of §2 and the `OK` line are a stable
interface. Adding a new line shape or exit code keeps them compatible, and
xNMS treats an unknown shape as `ERROR: <message>`. Changing or removing a
shape, or the meaning of an exit code, needs a new version of this contract
agreed by both projects. The `<message>` text itself is **not** stable:
xNMS shows it and does not parse it.

### 2.2 Reading server status keys (*planned*, version 3, delivery step 5)

`-c "show status server <key>"` prints **only the value** of one key,
followed by a newline. An empty value prints an empty line. An unknown key
exits with status 1 and `ERROR: <key>: unknown status key`. The keys xNMS
reads are stable:

| Key | Value |
|---|---|
| `server/config/saved` | `true` \| `false`: running equals the startup file |
| `server/commit-timer/remaining-s` | seconds left, empty when no timer is pending (*exists*) |
| `server/detected/arch` | `x86_64` \| `arm64` |
| `server/sw/main/release` | the running platform version, bare: `1.1.1-dev1`, `1.1.1` (the version token of `/var/xcesp/mainsw/VERSION`). Empty when XCESP does not run from an installed package (development tree). *Key exists from xcespserver 1.1.1-dev2*; read it with the one-key form once step 5 ships. |

`server/sw/main/version` (the full line, e.g. `XCESPKG 1.1.1-dev1
(debian 13 x86_64)`) is not stable: use `server/sw/main/release`. The
`xcespcli vX.Y.Z` banner is the CLI's own build version, not the
platform's.

**Stability rule** (as in §2.1): these key names and their value formats
change only with a new version of this contract. More keys can be added.
The full, multi-line `show status server` output is meant for people and
is **not** stable: xNMS uses the one-key form only.

## 3. Resetting a device (request 2)

*Planned (xcesp-swarm).*

```
xcesp-swarm reset <swarm> <dev> [--seed <dir>] [--timeout <sec>] [--json]
```

1. Stop the device.
2. Wipe `cfg/` and the config-derived runtime state in `lib/`.
3. Apply the seed (the default seed, or `--seed`).
4. Start the device and wait for health `up` (CLI + SSH).
5. Print the elapsed time. `--json` prints
   `{"device":…,"result":"up"|"timeout","seconds":N}`. The exit status is
   0 only when the device is up.

The reset **keeps** the identity (hostname, mgmt IP, MACs), the SSH host
keys, `instance-machine-id` and the licence state.

**Timing.** First measurements, 2026-11-25. Rootless podman on a 2-vCPU,
8 GB dev VM, image `xcesp:1.0.1`, empty config:

| Operation | Time |
|---|---|
| 3 devices created + started → CLI answers | ~5 s |
| 10 devices (8 in parallel) → all CLI answer | 24 s |
| `down` of 10 devices | 26 s |
| `up` of 10 stopped devices → all CLI answer | 31 s |
| Idle device | ~17 MB (podman stats), ~45 MB summed process RSS, 2–4 % of one core |

Estimates from those numbers: **`reset`** (container path) **5–10 s** per
device. **`reset --soft`** (`--replace-config`, no restart) **1–3 s**, the
time of one commit. So a twin can be reset on every job. Root podman on
XNMS1 and a realistic config (FRR, charon, xcespproc objects deployed)
will be measured and replace these numbers.

**Faster, in-device path** (*planned, product feature*):
`xcespcli --replace-config <file>`. The file becomes the whole running
config: top-level nodes that are not in the file are deleted, then the file
is merged, in one commit. Today (*exists*) there is only `--merge-config`,
where top-level `no <type> <inst>` lines delete nodes. That gives a reset in
seconds without restarting the container. `reset` will use it with
`--soft`, and fall back to the container path otherwise.

### 3.1 Delegating to user `xnms` (request: reset without root)

*Planned (xcesp-swarm, delivery step 6).* Devices are privileged
containers, so a free `xcesp-swarm exec`/`shell` is root on the host. It
is **not** delegated. Instead, `xcesp-swarm install` ships:

* `/usr/local/sbin/xcesp-swarm-delegate`: a root wrapper that accepts only
  the commands below, checks every argument (swarm and device names, no
  options other than those listed), and runs them only on the swarms listed
  in `/etc/xcesp-swarm/delegate.conf` (`DELEGATE_SWARMS="twins"`). The
  preprod swarm is managed like field nodes and is not delegated.
* `/etc/sudoers.d/xcesp-swarm`:
  `%xnms ALL=(root) NOPASSWD: /usr/local/sbin/xcesp-swarm-delegate`

| Delegated | Not delegated |
|---|---|
| `status`, `health`, `inventory`, `list`, `show` (read only) | `exec`, `shell`, `install` |
| `reset <swarm> <dev> [--soft] [--seed <name>] [--json]`, where a seed is a name under `/etc/xcesp-swarm/seeds/`, not a path | `init`, `up`, `down`, `scale`, `destroy` |
| `restart <swarm> <dev>` | `log` (may show secrets) |

xNMS reaches every twin over SSH like a managed node, so nothing that runs
inside a device is delegated.

**Twin seeds hold the xNMS key.** Each seed under `/etc/xcesp-swarm/seeds/`
(root-owned, written once when XNMS1 is installed) contains the `management
aaa` user for xNMS with the **xNMS public key** and `sshd-integration
true`. A `reset` therefore leaves the twin reachable with the key. The
xNMS side documents this in its `docs/deploy-xnms1.md`. When the xNMS key
changes, the seeds are updated and the twins reset.

## 4. Ports and topology (request 3)

**Ethernet only.** A container has no E1/T1 engine, no serial ports and no
SFPs.

| Field port | In a swarm |
|---|---|
| Ethernet | traffic interface (below) |
| E1/T1 (TDM) | dedicated XCESP containers running **TDMTEST** services (software TDM, no E1 engine). A twin checks the config and the software TDM paths, not the physical layer. |
| Serial (modem DTE) | the **TCP equivalent** of the modem DTE endpoint |
| SFP | not available, no equivalent |

**Port names.** There are two levels, and both are already in XCESP
(*exists*).

* The XCESP `interface <name>` is the logical port name that xNMS sees in
  the config. `device <linux-dev>` maps it to the Linux interface.
* Linux interface names have at most 15 characters and cannot contain `/`.
  The swarm makes the Linux names match the field node, so the field config
  is replayed unchanged.

  *Planned (xcesp-swarm):* an optional per-device file
  `<seed>/<device>/ports` with one line per traffic interface,
  `<network-or-link> <linux-name>`, for example `net1 enp3s0`. Podman
  creates the interface with that name; nothing is renamed after XCESP has
  started. Without the file the names stay `eth1..ethN`.

**Topology** (*planned*):

* **Shared L2 networks.** `TRAFFIC_NETS` may list any number of them. This
  exists in the draft script.
* **Point-to-point links.** `LINKS="001:eth3-002:eth3 …"` in the swarm
  definition gives each link its own 2-port internal bridge. A
  `<seed>/<device>/ports` entry can rename the link end.
* **Limits.** At most 999 devices per swarm, and at most 1024 ports per
  Linux bridge.

### 4.1 Field configs with E1/T1, serial or SFP ports (replay unchanged)

Checked in the code (*exists*): whether XCESP accepts a config never
depends on the hardware that is present. Parsing, the schema, the Python
validation hooks and the licence gates read only the config, and no hook
looks for devices, TDM ports, ttys or SFPs. So a twin **accepts** a field
config with E1/T1, serial or SFP references, and **rejects it exactly when
the field node would** (same image version, see §6.1).

What the twin cannot show is the result *after* the commit: objects bound
to missing hardware deploy and then report down (no device, LOS, link
down) in `show status`. For xNMS:

* **No transform is needed for accept/reject.** Replay the config unchanged.
* **Not validated by a twin:** physical-layer state and alarms of E1/T1
  ports, serial line control (DTR/RTS/CTS, real baud rates), SFP/optics,
  clock recovery from a real line, and anything measured on the wire.
  Treat `show status` of those objects on a twin as meaningless.
* **One platform check:** TDM-PW FEC (`fec-data`, `fec-protect`) is allowed
  only on x86_64. Twins are x86_64, so a twin accepts FEC that an arm64
  field node rejects. xNMS must check FEC against the node's architecture
  (in its inventory) itself.
* Transforms are still needed for the **mgmt** part, not for hardware
  ports. See §6.2.

## 5. Inventory (request 5)

`<state>/inventory.json` is written on every `up`, `scale` and `reset`.
`xcesp-swarm inventory <swarm> --format json` prints the same data.

**Stability rule.** Adding fields keeps `schema_version`. Renaming or
removing a field, or changing its meaning, increases it. xNMS must ignore
fields it does not know.

```json
{
  "schema_version": 1,
  "generated": "2026-12-01T10:00:00Z",
  "swarm": "replica", "id": 2,
  "image": "xcesp:1.1.1-dev3", "xcesp_version": "1.1.1-dev3",
  "mgmt": { "subnet": "10.202.0.0/16", "gateway": "10.202.0.1" },
  "networks": [
    { "name": "net1", "kind": "shared", "bridge": "xs2n1" },
    { "name": "l001", "kind": "link",   "bridge": "xs2l1" }
  ],
  "devices": [
    {
      "device": "replica-001", "index": 1, "container": "xsw-replica-001",
      "image": "xcesp:1.1.1-dev3", "xcesp_version": "1.1.1-dev3",
      "mgmt_ip": "10.202.0.11", "mgmt_mac": "02:58:02:00:00:01",
      "ssh_port": 22, "cli_port": 9900,
      "ssh_host_keys": { "ed25519": "SHA256:…", "rsa": "SHA256:…" },
      "interfaces": [
        { "name": "eth0",   "network": "mgmt", "mac": "02:58:02:00:00:01" },
        { "name": "enp3s0", "network": "net1", "mac": "02:58:02:01:00:01" }
      ]
    }
  ]
}
```

* **`xcesp_version`** is read once per image, without logging in.
* **`ssh_host_keys`** are read from the state directory, without logging
  in. They are present once the device has started at least once.
* **`image` / `xcesp_version` per device.** Each device carries the image
  it actually runs. They can differ from the swarm's pinned image during an
  upgrade rehearsal. The swarm-level fields give the default for new
  devices.
* **Runtime state** (health) is not in the inventory. `xcesp-swarm status`
  and `xcesp-swarm health` report it.

## 6. Answers (request 6)

**Container and ISO behaviour.** Both install the **same Debian 13 XCESP
package** with the same `install.sh`, so the CLI, schemas and config output
are the same binaries and the same files. The container is not a perfect
copy of an ISO node, though:

* There is no systemd. A stand-in `systemctl` is used instead, and
  `reboot` restarts the XCESP stack, not a host.
* There is no hardware (section 4).
* `copy sw` / `software-install` do not survive re-creating the container.
  Upgrading means a new image.
* NETCONF is absent in both, since Debian 13 does not package sysrepo.

A twin is valid for config and control-plane behaviour, not for hardware
behaviour.

### 6.1 Version fidelity

**A twin runs the field node's 1.1.x line**: image `xcesp:<major.minor>.*`,
the newest patch of that line, or the node's exact version when xNMS asks
for it. xNMS reads the version per device from the inventory (§5). A twin
from another line can accept config that the node rejects (new nodes and
attributes), and its `show running` can differ in new defaults.

### 6.2 Seeding a twin from a backup

`--merge-config` is a **union**: nodes and attributes of the seed that are
not in the backup stay. Attributes in the backup override the seed's. So
after a plain `reset`, *seed + merged backup* is **not** equal to the
backup. It keeps the seed's mgmt and aaa entries. Worse, the backup's own
mgmt interface would move the twin off its swarm mgmt IP, so xNMS would
lose the twin.

Agreed flow:

1. `reset <swarm> <dev>` (or `--soft`).
2. xNMS applies the **replica transform** to the backup. It replaces the
   field mgmt interface address and route and the field `management aaa`
   with the twin's (taken from the seed). Everything else stays unchanged
   (§4.1).
3. `--replace-config -` with the transformed backup: the twin's running
   config is then **exactly** the transformed backup.
4. Apply the job with the change sequence (§2.1).

`--replace-config` is needed for step 3, so it moves forward in §8. Until
it exists, use a **minimal seed**: only the mgmt interface and the aaa
user, nothing the backup redefines. After step 1, merging the transformed
backup then gives the same result.

### 6.3 Licensing on twins

Agreed: xNMS labels a twin's "accepted" result as "licence not checked".

**Licensing.** For the xNMS test system, swarms run with
`LICENSE_ENFORCE=false` for now. xcesp-swarm writes it into each device's
`xcespserver.ini` at seed time (*planned*, swarm option `LICENSE_ENFORCE`,
default `false`).

* With enforcement off, a device advertises unlimited capabilities, so a
  twin can accept a config that a licensed field node would reject. xNMS
  must not treat "the twin accepted it" as "licensing allows it".
* Fixed MACs and a persistent `instance-machine-id` are kept anyway, so
  real per-device licences remain possible later. The final licensing model
  for swarms is still open (owner).

### 6.4 Limits per host

Root podman. Memory and CPU per device: first numbers in §3, final ones
from the XNMS1 run. Further limits:

* `xcesp-swarm preflight` checks these sysctls and warns when they are
  below the recommended value:
  * `fs.inotify.max_user_instances` 8192
  * `fs.inotify.max_user_watches` 524288
  * `net.ipv4.neigh.default.gc_thresh3` and `net.ipv6.neigh.default.gc_thresh3` 8192
  * `kernel.pid_max` 4194304
  * `fs.file-max` 1000000
  * `net.bridge.bridge-nf-call-iptables` must be 0
* `nf_conntrack_max` will be added to these checks (mgmt NAT).
* At most 1024 ports per bridge.
* Each device is a privileged container with its own FRR, charon and
  xcespproc. Measuring memory per device on XNMS1 is the first test after
  SSH lands.

## 7. Health states (stable, used by `status`, `monitor`, `health`)

| State | Meaning |
|---|---|
| `up` | running, and CLI 9900 + SSH 22 answer on the mgmt IP (CLI only for `next` images built before sshd, delivery step 2) |
| `starting` | running, and not all of them answer yet |
| `stopped` | the container exists but is not running |
| `missing` | the container has not been created |
| `extra` | a device above `NODES` |

## 8. Delivery order (XCESP side, branch `next`)

Demo-critical for xNMS (end of December): steps 1–4. Step 5 is nice to
have for the demo (phase 1 backups work with the banner workaround). Steps
6–8 serve the twin and replica phases afterwards.

1. **xcesp-swarm validated.** *Done rootless on 2026-11-25* (init, up,
   scale, status, health, down, destroy; L2 on traffic nets, NAT, fixed
   MACs). Still to do: the run on XNMS1 with root podman and a realistic
   config.
2. **Image:** sshd, persistent host keys, the `SSH` health column, and
   `LICENSE_ENFORCE` at seed time.
3. **Public keys for `management aaa` users** (product, ISO too). Ships
   with step 2, so xNMS needs no password stopgap.
4. **Inventory `schema_version` 1** (§5, with per-device `image`).
5. **`xcespcli -c`, `xcesp-login` `SSH_ORIGINAL_COMMAND`, the change
   sequence** (§2.1: `--merge-config -`, `--check`, `--timer-commit`, error
   lines) (product, ISO too).
6. **`xcesp-swarm reset`**, timed, plus the `xnms` delegate (§3.1).
7. **`--replace-config`** and `reset --soft` (needed to seed twins from
   backups, §6.2).
8. **Ports file and point-to-point `LINKS`.**

## 9. Decisions

* **Decided (XCESP owner, 2026-11-25):** no 1.0.x twins, no `twin-cli`, no
  sshd or key login on 1.0.x images; nothing is backported to the
  commercial line. Settled by xNMS not managing 1.0.x (§0).

Still open:

* **XCESP owner:** the final licensing model for swarms.
* **xNMS:** the replica transform of §6.2 (which mgmt and aaa nodes it
  replaces), using the list of point 4 below.

**Points for version 3** (xNMS, 2026-11-25; none blocks the demo):

1. **Running equal to saved?** Not available today. *Planned:* status
   key `server/config/saved` (`true` when the running config equals the
   startup file, updated on every commit and `save`), read with
   `-c "show status server"`.
2. **Timer pending, time left?** *Exists:* the status key
   `server/commit-timer/remaining-s` gives the seconds left, empty when no
   timer is pending (`-c "show status server"`). *Exists:* `confirm` with no
   timer pending fails with `no timer-commit pending`. *Planned:* under
   `-c` that case gets its own exit status **4**, so xNMS does not need to
   match the text.
3. **Architecture of a node?** Not readable from `-c` today (only the
   interactive banner shows it). *Planned:* status key
   `server/detected/arch` = `x86_64` | `arm64`, read with
   `-c "show status server"`. Inventory devices are always `x86_64`. xNMS
   applies the FEC rule of §4.1 to arm64 1.1.x nodes.
4. **Config nodes that can cut management reachability.** XCESP will
   publish the list in version 3, by schema path, with the reason (address
   or route of the mgmt interface, VRF binding, firewall/ACL, `management
   aaa`, sshd integration, ...). It is built from the schema and rules,
   not written by hand.
5. **Stability of the `ERROR:` lines.** Adopted in version 2.1 (§2.1).

Points 1–3 ship with delivery step 5 (`-c`). Point 4 comes before step 7
(`--replace-config`), when the replica transform needs it.
