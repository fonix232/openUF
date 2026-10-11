# Protocol validation findings

openUF's assumptions about the UniFi inform protocol were originally inferred from
third-party reference material — [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway)
and [paultyng/go-unifi](https://github.com/paultyng/go-unifi) — never checked against a
real UniFi Network Application. This document is the project's own ground truth,
established by running openUF against a real self-hosted controller, capturing decrypted
inform responses (`debug_dump_file`, see [USAGE.md](USAGE.md#3-configuration)), and
decompiling the controller's own Java bytecode and React bundles.

**Where this document and the third-party references disagree, this document wins.**
In particular, go-unifi models the controller's *admin REST API*, which is a different
surface from the inform wire protocol — several fields that exist there
(`dtim_mode`) have no counterpart on the wire. `bandsteering_mode` does have one, but only for a device that claims `wifi_caps` bit `0x4`. openUF claims it since 2026-09-27 (see [Capability bitmasks](#capability-bitmasks)).

This is a **reference for the confirmed current state**, not a lab journal. Superseded
hypotheses and the investigation trails that produced these facts have been removed;
git history has them if needed. Decompiled evidence is retained inline wherever a claim
would otherwise be hard to re-verify.

**Environments:**

- `lscr.io/linuxserver/unifi-network-application:10.4.57` (Docker, pinned), with openUF as
  the AP in a disposable Alpine container on the same Docker network (`tools/validation/`).
  Mocked `uci`/`ubus`, no radios.
- **Real hardware, 2026-07-28:** a TP-Link Archer C5 v1 (OpenWrt 25.12.5, ath79/mips_24kc,
  ath9k 2.4GHz + ath10k 5GHz) adopted by a **UniFi Cloud Gateway Ultra running Network
  10.4.57** — the same version as the Docker baseline, so the two are directly comparable.
  See [the first real-hardware run](#the-first-real-hardware-run) and
  [the first DSA / 802.11ax board](#the-first-dsa--80211ax-board) for what only appears
  once genuine `netifd`/`hostapd`/radios are in the loop.

**Status:** adoption, provisioning, and every UI-surfaced feature listed in the
[feature matrix](#feature-matrix) are confirmed working end-to-end against a real
controller, except where a row says otherwise. Adoption, the WiFi config push, live
clients and the radios themselves are additionally confirmed on real hardware.

---

## Validation environment

Everything in this section is about `tools/validation/`, not about openUF's product code.
Real OpenWrt target hardware has genuine `uci`/`iw`/`ubus`/`hostapd` and hits none of it.

### Required setup, in order

1. **`lua-openssl` must be present in the AP container.** Without an AES-GCM backend the
   controller will never provision the device — see
   [the GCM provisioning gate](#the-gcm-provisioning-gate). `tools/validation/ap/Dockerfile`
   builds the `zhaozg/lua-openssl` rock (`luarocks-5.1 install openssl`); no prebuilt Alpine
   apk exists. The `openuf` package depends on `lua-openssl` on real OpenWrt hardware.
2. **Set the Inform Host Override before adopting anything.** Devices → Device Updates and
   Settings → Device SSH Settings. It must be the controller container's **literal IP** —
   the controller rejects a bare hostname with `ERROR inform - dev[<mac>] invalid inform_ip
   <hostname>`. This setting lives in the controller's own DB and is wiped by every
   `docker compose down -v`.
3. **Set a Device SSH Authentication password** (≥12 characters, enforced by the controller's
   own validator). Needed for L2/SSH adoption.

Skipping (2) presents as adoption silently stalling: `state.json` never flips
`adopted: true`, and `server.log` logs `inform decryption failed with defaultAuthKey=false`
— the controller *did* issue a per-device key, but the device never received a usable
config push. That is a setup omission, not a new bug.

### Always reset fully; never patch live state

Validation runs start from `docker compose down -v && docker compose up -d --build`.
Hand-editing a running container's `state.json`, or a device doc in Mongo, produces
results that do not reproduce — see [the minidev cache](#the-minidev-cache-never-sees-external-writes).

### The mocks, and their one sharp edge

The Alpine container has no `uci`, `ubus`, `iw`, `bridge`, or `hostapd`. Four
validation-only shims stand in, all outside `openuf/`:

| Shim | Stands in for | Notes |
|---|---|---|
| `ap/uci-mock.lua` | `require("uci")` | Installed at `/usr/local/share/lua/5.1/uci.lua`. Seeded with `radio0`/`radio1` `wifi-device` sections matching `generic-dualband-ap.lua`'s `hwassign`. |
| `ap/ubus-mock.sh` | `ubus call network.wireless status` | Static `radio0`→`wlan0`, `radio1`→`wlan1` map. |
| `ap/iw-mock.sh` | `iw dev … survey/station/scan dump` | Three fake stations with independently growing counters, plus fake neighbour BSSes. |
| `ap/bridge-mock.sh` | `bridge fdb show` | Two fake wired hosts; `entrypoint.sh` seeds `/proc/net/arp` via `ip neigh replace` (kernel state can't be baked into an image layer). |

**`uci-mock.lua` is in-memory only, per process.** Its `db` table is seeded fresh at
process start and only ever one-way dumped to a debug JSON file on `commit()` — never read
back. Consequences:

- Restarting `inform.lua` to pick up code changes **wipes any WiFi network config that was
  only ever pushed to the previous process's memory.** Recreate the WLAN in the controller
  UI afterwards to force a fresh `system_cfg` push.
- A throwaway `lua5.1 script.lua` invocation gets its own pristine mock state and proves
  nothing about the running daemon. **The only reliable way to check live wire data is to
  read what the controller actually received** (Mongo, or the REST API), never a fresh
  local script.

### Other environment facts

- **`cap_add: [NET_ADMIN]`** is required on the `ap` service — `netconfig.lua`'s `ip addr
  add`/`ip route replace` and `firewall.lua`'s `nft` both fail with `Operation not
  permitted` without it. Docker drops the capability by default even for root.
- **A `docker stop`/`start` of an AP container yields a fresh MAC from Docker**, so a
  restarted container is a brand-new device to the controller. Convenient for producing
  fresh adoption targets; means a stopped device's controller entry can never be resumed.
- **`ap2` compose service** (`replacement` profile) provides a second same-model device for
  the replace/clone flows; recipes in `tools/validation/README.md` §6.
- A `reboot` handled inside the container genuinely exits the container (no init to survive
  it). `docker start` the stopped — not removed — container to recover logs.
- Background `127.0.0.1:9080/api/ucore/manifest` and `get-ulp-manifest` connection-refused
  errors appear in `server.log` regardless of device activity. Pre-existing and harmless.

---

## The first real-hardware run

2026-07-28, Archer C5 v1 + UniFi Cloud Gateway Ultra (Network 10.4.57). Everything below
is what the Docker environment structurally *cannot* show: it mocks `uci`/`ubus` and has no
radios, so a config that `apply_config` writes "successfully" is never handed to `netifd`,
`hostapd`, or a regulatory domain. Three of the four findings are of the same shape — UCI
that reads perfectly and not one SSID on the air.

### The discovery path decides the adoption method, not the subnet

A controller that has heard a device's L2 broadcasts adopts it **by SSH**, even when it sits
on the controller's own subnet and its informs are landing perfectly. On the Adopt click the
gateway opened three SSH connections to the AP within 20 seconds:

```
dropbear[3746]: Child connection from 192.0.2.1:33114
dropbear[3746]: Login attempt for nonexistent user from 192.0.2.1:33114
```

and, failing them, parked the device at **Connection Interrupted** while the inform loop kept
running normally. The device record remembers this: removing it, stopping the broadcaster
(`config.l2_announce = false`), and letting the device re-appear from L3 informs alone made
the very next Adopt click complete over the inform channel with no SSH attempted at all.

So a device that cannot accept the controller's SSH login (no password auth, no bootstrap
account) **must** have `l2_announce` off, regardless of topology. "L3 adoption" names how the
controller discovered the device, not where it is.

### `macfilter="disable"` takes both radios off the air

OpenWrt's own schema (`/usr/share/schema/wireless.wifi-iface.json`) declares the option as
`enum: ["allow","deny"]`. 25.12's ucode validator does not ignore an out-of-enum value — it
aborts the radio setup:

```
wifi-scripts: macfilter: disable has to be one of [ "allow", "deny" ]
netifd: radio0 (4179): Died   (validate.uc:47 → die())
```

openUF wrote `macfilter="disable"` whenever the MAC filter was off, i.e. by default, so
**every** config push killed both radios. "Off" is the absence of the option: `ap.uc`'s
`iface_macfilter()` emits `accept_mac_file`/`deny_mac_file` for the two enum values and
returns for anything else. Fixed by deleting the option instead.

### `beacon_rate` is fatal on a driver that cannot program it

hostapd does not treat an unsupported beacon rate as a hint:

```
nl80211: Driver does not support setting Beacon frame rate (legacy)
Failed to set beacon parameters
Interface initialization failed
```

The 2.4GHz ath9k radio never came up, while the ath10k 5GHz radio — which the controller sent
no `beacon_rate` for — was fine. The capability is `NL80211_EXT_FEATURE_BEACON_RATE_LEGACY`,
reported **per phy** in `iw phy`'s "Supported extended features" list; neither phy on this
board has it. openUF now gates the option on that flag and still applies the rate floor
itself (`basic_rate`/`supported_rates`), which needs no driver support.

### The regulatory domain arrives as a numeric code, and nothing was applying it

`get_radio_table` has always *read* UCI `country` to derive the payload's `country_code`, but
nothing ever wrote it — so the radios kept whatever regdomain OpenWrt booted with while
reporting `840`/US back (the fallback when the option is unset). On the wire it is an
**ISO 3166-1 numeric** code, sent both unindexed and per radio:

```
radio.countrycode=203
radio.1.countrycode=203      # radio.1.phyname=radio0
radio.2.countrycode=203      # radio.2.phyname=radio1
```

UCI wants alpha-2, so 203 → `CZ`. Applying it moved the device from `country US: DFS-FCC` to
`country CZ: DFS-ETSI` and the 2.4GHz radio to channel 13 — legal in CZ, not in the US.

Worth knowing for anyone reading channel numbers off a live AP afterwards: with
`channel=auto` (which is what the controller sends unless a channel is pinned) hostapd ACS
picks freely within the new domain, and its choice can be a poor one in practice — it landed
on 5GHz channel 165, which CZ caps at **13 dBm**, and on 2.4GHz channel 13, which plenty of
client devices refuse outright. The controller's site-level Channel Plan exclusions are not
on the wire; pinning the channel per radio in the device's Radios settings is the remedy, and
that push (Auto → 6 / 36) was confirmed reaching UCI and the live radios within one inform
cycle.

### What the real controller sends that the Docker one did not

`radio.<n>.ieee_mode` came through as **`11naht40`** (5GHz) and **`11nght20`** (2.4GHz) — HT,
not HE, even though the device presents as an 802.11ax U6-InWall. openUF's downward clamp of
the PHY generation was therefore never triggered on this site; it remains insurance for a
site configured with wider/newer channel widths, not a confirmed-exercised path.

WPA2/WPA3 transition with PMF Optional arrives as `aaa.<n>.wpa=2` +
`wpa.key.1.mgmt=WPA-PSK` + `pmf.status=enabled` + `pmf.mode=1` — no SAE key-mgmt on the wire
at all, confirming the earlier Docker-era note that this controller signals WPA3-mixed purely
through PMF for a madwifi-driver model.

---

## The ports an AP reported were the CPU's, not the board's — FIXED

2026-08-02, two APs on the real UCG Ultra: a TL-WDR3500 (`Bedroom AP`) and an Archer C5 v1
(`Living room AP`). The Ports view showed **one port per AP**, and the number on it was
wrong. The investigation started from the user's own reading of the UI — only the uplink is
listed, and what is listed looks like it came from the gateway.

What the controller held for each AP (`/proxy/network/api/s/default/stat/device`):

```
port_table: [{port_idx:1, is_uplink:true, speed:1000, full_duplex:true, name:"PoE Out + Data"}]
ethernet_table: []      lldp_table: []
uplink: {..., uplink_remote_port:4, uplink_source:"lldp_downlink"}
```

Three separate things were wrong, all of them on the openUF side:

- **The speed was the CPU port's.** Both modelmaps declared a single port naming the CPU
  netdev, whose link is the internal SoC↔switch one — always `1000/full`. The Bedroom AP's
  actual uplink socket had negotiated 100baseT: `swconfig dev switch0 port 4 get link` said
  `speed:100baseT`, and the gateway's own row for the same cable said **FE** while the AP's
  row said **GbE**. A metric that contradicts the device on the other end of the wire.
- **The other sockets did not exist.** Both boards had live links on sockets the controller
  never heard of (the Archer C5 had three sockets up, of which one was reported).
- **Wired clients were attributed to the gateway.** Two hosts plugged into the APs' own LAN
  sockets showed up as `last_uplink_name: "Cloud Gateway Ultra"`, `sw_port` 2 and 4,
  `sw_depth: 1` — the gateway learned them through its downlink and, since the AP they sit
  behind reported no downstream port at all, the gateway's account was the only one.

The old code's premise was that MAC↔socket mapping "is knowable only from the switch's own
ARL table, which openUF does not read". The fix is that it now does. One
`swconfig dev switch0 show` returns per-port `link`/`pvid`, the ARL table, and (driver
permitting) per-port MIB counters — see the [`port_table[]` entry](#port_table-entry)
reference for what each field is sourced from now.

**Which socket is the uplink is measured, not declared.** The default route's gateway IP →
its MAC in `/proc/net/arp` → that MAC's port in the ARL. On these two boards the same
gateway MAC was learned on physical port 4 and physical port 2 respectively, matching the
cabling — a modelmap constant would have been wrong on one of them, and would go wrong on
either the next time a cable moves. It is also the guard on per-port VLAN: that socket is
refused an assignment, and a board that cannot determine it refuses every port.

**A side effect worth recording:** per-port VLAN assignment was unreachable on both real
boards before this. The only reported port was the uplink, and uplink ports deliberately
carry no `swport` — so the Port Manager had exactly one port and it was the one port that
must never be reassigned.

Two things looked broken and are not openUF's doing: `lldp_table` is empty because `lldpd`
on the APs receives nothing (the UCG Ultra does not transmit LLDP to them, though it happily
parses theirs), and `ethernet_table` is not sent at all — no evidence yet on what the
controller does with it, so it stays unsent rather than guessed at.

### The Ports view's other columns

Empty is the right answer for most of them, and the real gateway is the control group:

| Column | Source | On this site |
|---|---|---|
| **Anomaly** | Controller-side, from its own stats history ("24h AI Anomaly Score") | `0` on every AP port; `20` on the UCG's port facing the 100baseT-linked AP — the same conclusion it records on the device as `detailed_states.negotiated_low_uplink_port_speed: true`, which only appeared once openUF stopped claiming 1000 |
| **STP** | `stp_state`/`stp_pathcost`, a USW port property | `-` for every port, the gateway's own included |
| **Profile** | Port profile (`portconf_id` in `port_overrides`), controller-side config | `-` for every port, the gateway's own included |
| **Operation** | `op_mode` (`switch`/`mirror`/`aggregate`) | The controller writes `op_mode: "switch"` and `forward: "all"` onto openUF's ports **although openUF sends neither** — server-side defaults. `switch` is the truthful value for these sockets anyway |
| **Tx/Rx Sum, Tx/Rx Rate** | `rx_bytes`/`tx_bytes` | Populated from the per-port MIB — see below |
| **Tx/Rx Multicast, Broadcast, Dropped, Packets** | `rx_multicast`, `tx_broadcast`, `rx_dropped`, … | Sent by the gateway, not by openUF: swconfig's per-port MIB exposes `RxGoodByte`/`TxByte` and nothing else, and the CPU netdev's totals belong to every socket at once |

**Per-port counters are a driver setting, not a capability.** The ar8xxx driver only maintains
the MIB while `ar8xxx_mib_poll_interval` is non-zero, and boards differ: the AR9344 shipped at
`500` and reported counters, the AR8327 shipped at `0` and answered "Operation not supported"
for every port, so one AP's Ports view was populated and the other's read 0 B everywhere. One
`swconfig dev switch0 set ar8xxx_mib_poll_interval 500` produced counters on the next read, so
openUF now does that once at startup when the attribute exists and reads 0
(`switchvlan.enable_mib_polling`, opt out with `dev.conf.vlan.mib_poll_ms = false`).

---

## A tagged SSID's trunk deafened every wired client on the AP — FIXED

2026-08-02, same two APs. The user reported a printer at a static `192.0.2.11`, cabled
into the Bedroom AP, that nothing could reach and that never appeared in the controller UI.
It was an openUF bug, and the printer was only the visible half of it — a second host on
another socket had been dead the same way, unnoticed.

The printer was alive and talking: the AP's switch had learned its MAC in the ARL on
physical port 2, and that was the MAC the laptop's ARP cache held for `.11`. Frames got
*from* it and never *to* it.

**UCI and the switch disagreed**, which is the tell:

| | UCI `switch_vlan` for VLAN 1 | live `swconfig dev switch0 show` |
|---|---|---|
| WDR3500 — **AR8229**, `vlans: 16` | `1 2 3 4 0t` (sockets untagged) | `0t 1t 2t 3t 4t` — **all tagged** |
| Archer C5 — **AR8327**, `vlans: 4096` | `0 1 2 3 4 5` | `0 1t 2 3 4 5` — as written |

Both APs carried an identical `openuf_swvlan10` trunk of `0t 1t 2t 3t 4t`, written by
`switchvlan.trunk_ports()` for the tagged IoT SSID. Only the AR8229 let it bleed into
VLAN 1.

**On the `ar8216`/`ar8226`/`ar8229`/`ar8236` driver family, tagging is not a property of
(port, VLAN) — it is one global per-port bitmask.** `ar8xxx_sw_set_ports()` does

```c
if (p->flags & (1 << SWITCH_PORT_FLAG_TAGGED))
        priv->vlan_tagged |= (1 << p->id);
```

and `__ar8216_setup_port()` reads that single bitmask to choose `AR8216_OUT_ADD_VLAN` vs
`AR8216_OUT_STRIP_VLAN`, for every VLAN at once. So marking socket 2 tagged for VLAN 10
made it egress-tagged in VLAN 1 too, and the untagged printer dropped every frame. The
AR8327 escapes this because `ar8327.c` overrides the get/set-ports ops with a real
per-(port, VLAN) tag table — which is exactly why the bug shipped: **it is invisible on
the board the feature was developed against.**

The fix trunks only the CPU port and the uplink socket, which is the entire path a tagged
SSID's frames take. The old code's stated reason for tagging everything — that the uplink
socket is not knowable from config — had gone stale: `sysinfo.uplink_phys_port()` measures
it from the switch's own ARL, and `switchvlan.apply()` already had the answer in hand.
When it cannot be resolved openUF now holds any existing trunk rather than guessing;
letting a transient nil fall through to the reconcile pass would delete a working trunk
and reload, then rewrite it on the next inform, bouncing the IoT WLAN in a loop.

Verified live on both boards. WDR3500: VLAN 1 back to `0t 1 2 3 4t`, printer and the
second host answering ICMP from the AP and from a laptop two hops away. Archer C5: VLAN 1
untouched, VLAN 10 down from `0t 2t 3t 4t 5t` to `0t 2t`. On both, a one-shot
`udhcpc -i br-openuf10` still took a lease from the VLAN 20 gateway, so the feature the
trunk exists for is intact.

**A hardware limit that follows, and cannot be fixed in software.** On a global-bitmask
chip a port cannot be untagged in VLAN 1 *and* tagged in VLAN 10. Running a tagged
wireless VLAN therefore leaves the **uplink** socket egress-tagged for VLAN 1 as well —
visible above as the `4t` in `0t 1 2 3 4t`. The UCG Ultra accepts tagged VLAN 1 on that
port (it is the live, working state), and the effect is confined to the one socket facing
the gateway rather than every socket facing a client.

**Generalising:** this is the third finding in the same shape as the first real-hardware
run — config that reads perfectly and hardware that does something else. A `swconfig`
port string is a *request*; `swconfig dev <sw> show` is the only account of what the ASIC
actually holds, and the two must be compared on each chip family, not one.

---

## Controller behaviors that are not openUF bugs

Each of these cost real investigation time at least once.

### A 404 with an empty body does not mean the inform was rejected

A well-formed, correctly-encrypted first-contact inform gets **HTTP 404 with
`Content-Length: 0`**, with zero corresponding entry in the controller's `inform` logger —
yet the device is created server-side and shows as "1 device is ready to adopt." Verified at
the wire level through a raw byte-logging TCP relay: the `100 Continue` handshake completes
normally and the response genuinely has an empty body.

Malformed packets behave differently and are easy to tell apart: they get **400** with a
specific logged reason (`Bad packet magic`, `Data version 0 is not supported`,
`Content too short`).

Ruled out as causes, so they aren't re-tried: compression (a real zlib-compressed,
correctly-flagged payload gets the same 404) and GCM-vs-CBC (both get the same 404).

`http_post` treats any non-200 as a hard failure and never inspects the body. In every case
observed the body was genuinely empty, so nothing is lost — but the client cannot
distinguish "processed, nothing to say" from "rejected," and backs off identically either way.

**When you see this on a fresh device: click Adopt.** That is the correct next move, not
more debugging.

### Historical stats live in the `unifi_stat` database, on a 5-minute cadence

CPU/memory graphs, per-client Traffic Activity, the Radios tab's "Avg." columns, and the
Ports view's Bps chart are **not** rendered from live inform data. They are read from
`unifi_stat`'s `stat_5minutes` / `stat_hourly` / `stat_archive` collections, written by a
periodic archiver (`com.ubnt.service.system.QDcGUYAmLvJwylXw`, internally labelled
`stat-processor`).

So: a flat/empty graph checked two minutes after adoption is expected. Allow ~15 minutes, or
a few 5-minute buckets, before treating it as a defect. Query
`unifi_stat.stat_5minutes` directly to check whether the data is landing — `db.stat` in the
**`unifi`** database is a different, empty collection and querying it is misleading.

### The minidev cache never sees external writes

`com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ`'s device lookup is cache-then-DB-fallback: an
in-memory "minidev" summary (`_id`, `site_id`, `authkeys`, `x_aes_gcm`, `hash_id`) keyed
`("global", "minidev", mac)`, populated once on the first DB hit and never invalidated by an
external write. Editing a device doc in Mongo while the controller runs therefore has no
observable effect. Restarting the controller to force a reload introduces its own artifact:
the device flips to **Offline** in the UI even while `last_seen` keeps advancing and informs
keep landing, and does not self-heal within a normal observation window.

This is why the "always reset fully" rule exists. It also explains why "Remove"
(factory-reset) leaves informs decrypting successfully afterwards — they are being served
from a stale cache entry while the underlying doc is already gone.

### Config sync can get stuck after informs stabilise

Observed while trying to force pure-WPA3 emission: switching the test WLAN's Security
Protocol to WPA3 made the controller **stop pushing the WLAN's `aaa.<n>`/`wireless.<n>`
blocks entirely** — not just the SAE fields — and reverting the setting did not restore
pushes, even across an `inform.lua` restart. No related error in `server.log`.

**Reusable warning:** a live no-op does *not* always mean "the controller is deliberately
withholding this field because of a capability gate" (which is exactly what it meant for
`advertise_ap_name`). Sometimes it means the environment's config sync is stuck. Decompile
the emitter to tell the two apart before concluding anything.

### A wired client's usage history grows by the gateway's lifetime counter — controller-side, NOT FIXED

Upstream 318cb12, 2026-10-13, real UCG Ultra on Network 10.6. A media player cabled into the Living room AP
showed **968 TB** of 24 h usage. A second wired host on the Office AP was inflated the same
way, only less. The live client totals (`stat/sta` `wired-tx_bytes`/`wired-rx_bytes`) were
sane, about 190 GB. Only the per-client report rows (`5minutes`/`hourly`/`daily` `user`)
were wrong. They started growing on 08-02, the day openUF began reporting real sockets
and their hosts.

**Mechanism (CFR on the 10.6 `internal-dependencies.jar`; class names are per-build):**
- The per-client report accumulator is a counter diff. For each `(user, mac)` record it adds
  `value − last` when that is positive, then stores `last = value`, even when the value went down.
- The gateway feeds that key every cycle. Its station stats carry the gateway's lifetime per-client
  byte and packet counters, rx and tx swapped. For this player that was ≈266.94 GB / 203 M packets.
- An AP feeds the same key for each wired host in its `port_table[].mac_table`. The gate is
  `hasStationStat()`, and it is decided by **device type**: `uap`, `udm`, `uxg`, `ugw` and `uacc` say
  true, `usw` says false. The port-host context has no override for APs, so a wired host on a `uap`
  takes the same path as a wireless station. Its row becomes a report record with no byte fields, so it reads 0.
- A host is processed when its row carries no wireless-event type, or when it is the only host
  on its port (`is_only_station_on_port`).
- Every `0 → lifetime` change therefore adds the gateway's whole lifetime counter.

**Live proof (upstream).** Upstream polled the player's current 5-minute row every 2 s and logged the Living room AP's
informs at the same time (ActiveOpens). Six informs in a row were each followed within
0–4 s by a jump of exactly +266.94 GB. A fresh 5-minute bucket already held 266.94 GB after
15 s. The small steps between jumps are the gateway's real deltas.

**Why the other clients look right:**
- A host on the gateway's own ports has no AP record competing with it.
- A NAS on the Living room AP looks right only because the gateway has counted almost none of its traffic (LAN-local).
- On a **USW**, a host alone on a port takes its traffic from the change in the port's own counters (`port_delta`), and the switch writes no report record. Only the gateway feeds the history, so nothing alternates.

**A real U6-IW should do the same.** The gate depends on the device type, not on anything openUF
sends, so it treats a genuine in-wall AP's port hosts the same way. Firmware can't confirm
what such an AP actually puts in `mac_table`:
- BZ2 4.0.15 (plaintext) has no port or MAC table at all.
- Every in-wall build is encrypted back to 3.9.27 (2018): U2IW, U7IW and UHDIW. Only the kernel `PART` header is in clear.

No public report of the symptom was found.

**Not fixed in openUF, by decision.** No lever on the openUF side is clean:
- Putting counters in `mac_table` rows: any second source that differs from the gateway's
  counter still inflates the history on each alternation.
- A wireless-event type on the row: a host that is alone on its port is processed anyway.
- A `vlan` on the row that doesn't match the network: the host is skipped, which is the same as not reporting it.
- Not reporting wired hosts at all: this fixes the history, but loses the port attribution
  ("player → Living room AP, port 3") that real-socket reporting exists for.

The live totals, the port attribution and the Ports view all stay correct. Only the usage history
of wired clients behind an openUF AP on a site with a UniFi gateway is wrong.

### Controller-side UI quirks

- **Environment tab (AirView) stops updating ~10 s after mount**, with no user interaction:
  the row disappears, "No WiFi broadcasts found" renders, and the sidebar filters grey out.
  Clicking any other Time Range tab instantly restores everything. Verified the data is
  present server-side the whole time (10/10 direct `stat/rogueap` polls over 23 s returned
  all entries). Consistent with the table capturing `rowsPerPage` from the pre-fetch, empty
  selector result at mount (`useState({pageNumber:0,from:0,rowsPerPage:r.length})`) and never
  recomputing it. A genuine defect in the controller's own frontend, outside openUF's control.
- **Radios tab's "Type" filter shows nothing until one option is explicitly checked**, unlike
  Band/MIMO/Status on the same page, where an empty selection means "show all." "Type" here
  means the **AP's own uplink** connection type, so a wired-uplinked AP correctly appears
  under "Wired" — the radios themselves being wireless is irrelevant.
- **"Remove" on a client sends no wire command at all** — pure controller-side bookkeeping.
  A still-present client reappears on the very next inform.
- **The upgrade confirmation dialog truncates versions to 3 components**, so a genuine
  full-string mismatch can render as "Update U6 IW from 6.8.2 to 6.8.2?".

---

## Decompiling the controller

The controller is a Java app, and Java bytecode retains field-name string constants in the
class-file constant pool even under ProGuard-style class/method obfuscation — a far friendlier
analysis target than the AP's encrypted ARM firmware (see [dead ends](#dead-ends--do-not-re-attempt)).

**Procedure:**

1. Extract `/usr/lib/unifi/lib/internal/internal-dependencies.jar` from the container — the
   real ~29 MB application jar. (`ace.jar` is only a license-protected bootstrap `Launcher`.)
   A console does not need to be containerised for this: the exact build it runs is
   published as `unifi_sysvinit_all.deb` in Ubiquiti's download catalog, and the same jar
   comes out of it (how the 10.6.106 decompile in
   [docs/GAP-ANALYSIS-10.6.md](docs/GAP-ANALYSIS-10.6.md) was made; the yesrab fork does the
   same against its UCG Ultra). So a bytecode finding can be made against the version the
   console actually runs instead of an older Docker baseline. Decompile it per steps 2–3
   (the fork used jadx; large method bodies still need CFR).
2. **Unzip it on a case-sensitive filesystem.** `com.ubnt.service.aa` and
   `com.ubnt.service.aA` — and ~55 other package pairs differing only by case — are distinct
   real packages. macOS silently folds them into one directory, corrupting the extraction and
   producing a decompile of the *wrong* class's method body with no warning. Do the
   `unzip` + decompile inside a Linux container (`docker cp` the jar into the controller
   image itself, which already has a JVM).
3. **Use CFR (`cfr.jar` 0.152) for large methods.** `jadx` silently drops method bodies it
   can't reconstruct — no marker, just absent output. The ~5,182-unit method that gates
   provisioning was invisible to jadx and decompiled cleanly under CFR. jadx is still fine
   for browsing and for properly-scoped class listings.
4. For frontend behavior, fetch the live controller's own React chunks
   (`react-app-wrapper.*.js`, `radiosPage.*.js`, `swai.*.js`, `airview.*.js`) and grep them.
   Where a decode function's logic matters, the webpack module registry
   (`window["webpackChunk…"].push([[Symbol()], {}, req => …])`) gives a direct reference to
   the **live** function, which can be called with a sweep of inputs — ground truth, not a guess.

**Logging:** the controller's loggers use flat, hand-picked names (`inform`, `adopt`,
`inform.uap`, `core.lock`, `web.api`), not package paths — see
`com.ubnt.service.system.HCKpgcBFPLu`. Setting `com.ubnt` to DEBUG does nothing for them. A
custom `logback.xml` with explicit `<logger name="inform" level="DEBUG"/>` entries, wired in
via `-Dlogback.configurationFile=`, is needed. Note that most handlers only log on their
*short-circuit* branch, so silence is consistent with everything passing normally.

### Class index

| Class | Role |
|---|---|
| `com.ubnt.service.devmgr.l.MiVjHefaf` | Inform handler / adoption state machine; the provisioning gate; upgrade-offer gate |
| `com.ubnt.service.devmgr.PGOcbDWlbnYQdFW` | `uap`/`uacc` state processor — `radio_table`, `port_table`, `scan_radio_table` ingestion |
| `com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` | Sibling state processor; power/PoE field copy; `radio_caps` passthrough |
| `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD` | vapInformProcessor — filters `vap_table`, copies `sta_table` attrs |
| `com.ubnt.service.devmgr.DyonYyyYJkiyv` | Per-port `mac_table` processing |
| `com.ubnt.service.devmgr.TtZhv` | Client record writer (wired + disconnect-time wireless archive) |
| `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex` | **Live** (still-connected) client generation display |
| `com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ` | Device lookup / minidev cache; replace + clone config services |
| `com.ubnt.service.system.QDcGUYAmLvJwylXw` | Stat archiver (`stat-processor`) — writes `stat_5minutes` `o:"ap"` buckets |
| `com.ubnt.service.system.x.htDMji` | Archiver method that reads `radio_table[].athstats` |
| `com.ubnt.service.aO.hhFgUVZPT` / `aO.bLwwMKkr` | Scan ingestion; the `"PeerScan"` DTO |
| `com.ubnt.service.config.eWivisHeQsnaqDtx` | WLAN/radio config generator (emits `system_cfg`) |
| `com.ubnt.service.config.ubntconf.OXMua` | SAE field emitter |
| `com.ubnt.ace.api.e.VVyiC` | REST per-port VLAN validator |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr` (+ ~90 nested) | The controller's entire internal Device model — one nested class per wire sub-object |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr$QCtdvLKOBb` | vap-stats DTO (**not** the unrelated top-level `com.ubnt.data.QCtdvLKOBb`, a FirewallRule — obfuscated short names collide across packages, always extract by full path) |
| `com.ubnt.data.uuvchZbWVhirD` | Device DTO — `hasFirmwareCapability`, `hasWifiCapability2`, `isSwitch` |
| `com.ubnt.data.dhdeXcHqLRBKMUZk` | Model registry (per-model port count and feature set) |
| `com.ubnt.g.f.e.rYtJfMBbtgWvku` | Radio band enum: `ng`, `na`, `ad`, `6e` |

---

## The inform protocol

### Envelope

Header layout, flags (`0x01` encrypted, `0x02` compressed), zlib-before-encrypt ordering,
AES-128-CBC + PKCS#7, and the default `http://unifi:8080/inform` URL all match openUF's
implementation and fxkr/unifi-protocol-reverse-engineering's published documentation.
`PKT_VERSION` is 1; the GCM AAD is the 40-byte header.

`mgmt_cfg` is a newline-delimited `key=value` **string**, not JSON.

### The GCM provisioning gate

**On 10.4.57 the controller will not provision a device until it has received a genuine
AES-GCM-encrypted inform.** `x_aes_gcm` is set *only* in the decrypt path — `InformServlet`
reads the packet's on-the-wire encryption flag (`header.isGcm()`) and the handler does
`dev.set("x_aes_gcm", true)`. **There is no JSON/payload field that sets it.** The controller
always requests GCM (`use_aes_gcm=true` is written unconditionally into every `mgmt_cfg`), and
once `x_aes_gcm` is set it rejects a GCM→CBC downgrade outright (`"tried to downgrade inform
encryption from AES-GCM to AES-CBC, rejecting"`).

The gate itself, in `MiVjHefaf`:

```java
if (!(dev.isUnsupported() || dev.aesGcmInformEncryptionOnly() || <globalFlag>)) {
    // "dev[..] : mgmt config update before provision"
    resp = new setparam; resp.put("mgmt_cfg", ...);
    dev.set("cfgversion", <fresh random 16-hex>);   // rolls every cycle
    return resp;                                     // returns BEFORE provisioning
}
```

`aesGcmInformEncryptionOnly()` just returns the device doc's `x_aes_gcm` boolean. While it is
false, **every** inform hits this branch, gets a brand-new random `cfgversion`, and returns
early — never reaching `cfgversion`-convergence provisioning, and never reaching the
`wait_for_initial_inform` clear.

**The diagnostic signature** of a device stuck here: adoption reports as completed, informs
decrypt fine, `last_seen` advances — but `cfgversion` is different on *every single* cycle,
`x_aes_gcm` stays false, `provisioned_at` is absent, and the UI shows "Adopting" forever.

Once GCM is sent, all of it resolves in one cycle: `x_aes_gcm` → true, `cfgversion` stabilises,
`provisioned_at` set, `wait_for_initial_inform` cleared, device Connected.

`crypto.lua`'s GCM code works against the `zhaozg/lua-openssl` binding with no changes. The
`openssl(1)` CLI fallback **cannot** do GCM (`enc` refuses AEAD ciphers), so a container
without a real binding silently downgrades to CBC and hangs on this gate.

### Adoption: L2 vs L3

**L3 (inform-only, no SSH).** The controller logs `discovered via L3 inform, skip SSH adoption`
and delivers the new `authkey` directly in the `mgmt_cfg` of the `setparam` sent right after
the Adopt click:

```json
{"_type":"setparam","mgmt_cfg":"capability=notif,notif-assoc-stat\nselfrun_guest_mode=pass\ncfgversion=e07e7991b8c62b47\nled_enabled=true\nstun_url=stun://172.19.0.4:3478/\nmgmt_url=https://172.19.0.4:8443/manage/site/default\nauthkey=ccc32a3bbe40157773294de8ed683627\ninform_url=http://172.19.0.4:8080/inform\nuse_aes_gcm=true\nreport_crash=true\n","server_time_in_utc":"1783841863822"}
```

openUF accepts a hex32 `authkey` from `mgmt_cfg` **only while `st.adopted == false`** — while
unadopted the device is still using the well-known default key, so this exchange carries no
less confidentiality than the rest of L3 provisioning already assumes.

**L2 (broadcast discovery + real SSH).** With `announce.lua` broadcasting, the controller runs
genuine SSH on the Adopt click and executes `syswrapper.sh set-adopt <url> <key>`. The existing
`syswrapper.lua`/`state.lua` shape (`adopted`, `authkey`, `inform_url`, `cfgversion`, `use_gcm`)
is what real SSH adoption expects — confirmed by a real round-trip.

Two things real hardware does that the validation container had to be taught:

- The controller's SSH client (`sshj`) offers only legacy `ssh-rsa` (SHA-1), matching aging
  UBNT firmware; OpenSSH ≥8.8 excludes it by default. `HostKeyAlgorithms +ssh-rsa` /
  `PubkeyAcceptedAlgorithms +ssh-rsa` are needed in `sshd_config`.
- The controller authenticates as the Ubiquiti factory-default account **`ubnt`/`ubnt`**, not
  the admin-configured Device SSH credentials — correct behavior, because `announce.lua`'s
  `IsDefault` byte (`0x17` in the TLV blob, `make_blob_17_1a`) correctly declares the device
  unadopted.

`mgmt_url` is the **web UI deep link** (`https://host:8443/manage/site/default`), *not* an
alias for `inform_url`. Treating them as the same key makes the device overwrite its working
inform endpoint on the first routine post-adopt `setparam` and disappear permanently.

### Response `_type`s

The complete set, per `InformServlet`: `noop`, `setparam`, `cmd`, `upgrade`, `reboot`,
`setdefault`. There is no export/backup/dump command.

| `_type` | Shape | Notes |
|---|---|---|
| `noop` | `{"_type":"noop","interval":…}` | Steady state. `interval` is the heartbeat cadence in seconds the controller wants; openUF waits that long before the next inform, clamped to 5–300 s (pre-adoption noops are unauthenticated), and goes back to its own 10 s when a noop carries none. A failed inform backs off from that cadence, never faster. |
| `setparam` | `{"_type":"setparam","mgmt_cfg":"…","system_cfg":"…","server_time_in_utc":"…"}` | Both configs are flat `key=value` blobs. See [system_cfg](#system_cfg-the-real-config-channel). |
| `cmd` | `{"_type":"cmd","cmd":"…","mac":"…","device_id":"…",…}` | See command table below. |
| `upgrade` | `{"_type":"upgrade","version":"6.8.2.15592","md5sum":"…","url":"http://fw-download.ubnt.com/…"}` | Fire-and-forget, sent exactly once; no retry, no confirmation expected. |
| `reboot` | `{"_type":"reboot","reboot_type":"soft",…}` | The top-level form is the real one; `{"_type":"cmd","cmd":"restart"}` is not the path this action takes. `reboot_type` is unused by openUF. |
| `setdefault` | — | Handler exists but has never been observed dispatched live; see [open questions](#open-questions). |

**After executing a `cmd`, the device must send another inform immediately** (documented by
fxkr and confirmed live: the controller's next `noop` lands in the same second).

Confirmed `cmd` strings:

| `cmd` | Trigger | Payload |
|---|---|---|
| `set-locate` | Locate button | `{"cmd":"set-locate","device_id":…}` |
| `block-sta` | Block client | `{"cmd":"block-sta","mac":"…"}` |
| `unblock-sta` | Unblock client | `{"cmd":"unblock-sta","mac":"…"}` |
| `authorize-guest` / `unauthorize-guest` | Guest portal login / REST `cmd/stamgr` | `{"cmd":"authorize-guest","mac":"…"}`; see [Guest portal](#guest-portal-hotspot-what-the-controller-pushes-and-expects) |
| `rate-update` | A client with its own speed-limit profile, and a guest authorized with a portal limit | `{"cmd":"rate-update","mac":"…","ul_max":…,"ul_min":…,"dl_max":…,"dl_min":…}` (kbps); `ul_max`/`dl_max` applied per client by `shaper.lua`, the minima not |
| `spectrum-scan` | Airtime Scan ("Scan Now", frontend `SPECTRUM_SCAN`) | Handled since `wifi_caps` `0x10` is claimed. Without that bit the controller refuses the REST call (`api.err.InvalidTarget`) and `stat/spectrum-scan` skips the AP, so the handler was unreachable. See [Airtime Scan](#airtime-scan-spectrum-scan). |
| `quick-scan` | RF view "Scan", nightly schedule, Radio AI prescan | `{"cmd":"quick-scan","scan-band":<0\|1\|2>,"scan-bw":…}` — sent only to `wifi_caps2` `0x80` APs; see *Quick scan* below. |

#### A block refuses association (hostapd deny ACL, 2026-10-10)

What the firmware does (`/usr/etc/syswrapper.sh` `block-sta`/`unblock-sta`/`apply-blocked-sta`
and `/usr/etc/platdep_funcs.sh`, firmware-confirmed for 3.9.27 to 4.0.15):
- `block-sta` runs `driver_kick_block_sta`: on every VAP that `is_vap_user_or_guest` (no
  mesh uplink/downlink), `iwpriv $ath addmac_blksta <mac>` and then `kickmac`. The MAC goes into
  `/etc/persistent/cfg/blocked_sta`.
- `unblock-sta` removes it from that file, then `delmac_blksta` on the same VAPs.
- `apply-blocked-sta` (and `-ifup` for one VAP coming up) clears the driver list
  (`maccmd_blksta 3`) and adds every MAC in the file again. The driver list doesn't survive
  a VAP going down, so the firmware rebuilds it.
- No ebtables or iptables rule is involved. The block is the driver refusing the station.

Before this, openUF only dropped the client's frames in nft and deauthed it once. The client
could associate again at once, complete EAPOL, and sit on the SSID with no traffic.

openUF now also puts every blocked MAC into hostapd's **deny ACL** on every AP-mode BSS
(`firewall.deny_sync`, `hostapd_cli -i <bss> deny_acl ADD_MAC|DEL_MAC`). hostapd rejects
authentication and association from a MAC on that list, and it disassociates a station that
is already connected when its MAC is added.
- **Re-applied every tick.** The runtime list lives only in hostapd. Per hostapd's source,
  a restart or a BSS reload resets it to the BSS's config file. So while anything is blocked,
  every inform tick reads each BSS's list (`deny_acl SHOW`) and adds what's missing. Once
  the list is empty, it keeps checking until a pass finds nothing left to remove, and it
  checks once at startup.
- **Stateless.** Any runtime entry the BSS's own `deny_mac_file` doesn't list is taken to be
  openUF's and is removed on unblock. The file is the controller's MAC filter in deny mode
  (`macfilter=deny`, `/var/run/hostapd-<bss>.maclist`). Its entries stay, so unblocking a
  MAC that the filter also denies doesn't open that SSID to it. Nothing else on OpenWrt adds
  deny ACL entries at runtime: usteer and DAWN ban through ubus.
- **nft stays as the backstop.** hostapd checks its accept list before its deny list. A MAC
  filter in allow mode that lists a blocked MAC still lets it associate. The nft drop then
  keeps it off the network, as before.
- `hostapd_cli` exits 0 when hostapd answers `FAIL` and 255 when the BSS has no control
  socket. Both count as "unknown", so no command is sent and the next tick tries again.

Verified:
- **Unit tests** (upstream). 18 mutants across `firewall.lua` and `inform.lua` (add, remove, keep the
  file's entries, `bss=` sections, FAIL, no output, MAC and name validation, the tick hook,
  startup pending, reset and reload) all failed a test.
- **Lab** (upstream; 10.4.57, no hostapd). REST `block-sta`/`unblock-sta` of `00:00:5e:00:53:01` put
  it into the ledger and nft and took it out again. 0 `handle_response failed`.
- **Hardware** (upstream), both of its APs (OpenWrt 25.12.5, wpad). The deployed `firewall.lua` was run
  against live hostapd with the documentation MAC `00:00:5e:00:53:01`:

  | Step | What happened |
  |---|---|
  | add | The MAC appeared on every BSS: `phy0-ap0 phy1-ap0 phy1-ap1` on the Archer C5, `phy0-ap0 phy0-ap1 phy1-ap0` on the AX3000T, each as `… VLAN_ID=0` |
  | again | Nothing to do |
  | `DEL_MAC` by hand on `phy1-ap1` | The next pass put it back |
  | unblock | Removed from every BSS |

  One pass took 0.15 s on the Archer, including loading the modules.
- **Not seen on hardware.** A real blocked client being refused. That needs a named device.
- **This fork.** The same `firewall.deny_sync`, wired into `provision.lua`'s block paths and
  `inform.lua`'s tick (`_block_resync`); unit-tested only, not yet run against hostapd here.

#### Quick scan

From the 10.6.106 decompile (CFR, `internal-dependencies.jar`); not yet seen on the wire,
because all three senders below skip an AP without `supportQuickScan()` (`wifi_caps2`
`0x80`). openUF claims it since 2026-10-03; nothing below has been seen on the wire yet.

- **Senders.** `devmgr.b.g.ctfbDsCjrxgkv` (the devmgr command `quick-scan`, site admin, UAP/UDM;
  refuses with "already scanning" while the device's flag is set), `system.l.rGUtaVWZlySeOK`
  (cron `0 3 * * *`, scheduled only while Radio AI is **off**; band after band, waiting up to
  120 s per band, polling every 1 s, for every AP's flag to clear) and `devmgr.kFACvOhX`
  (Radio AI prescan: inform interval 15 s, watched 180 s; done once `spectrum_scan_timestamp`
  has advanced, or after 5 polls, **and** the flag is clear **and** spectrum rows exist).
  Each first sets the device's `quickscan_scanning = true` and
  `quick_scan_state = {in_progress, last_band, last_width, started_at_ms}`, then queues the
  cmd. `scan-band` is `system.l.RxFvcetMTlkSFFxK`'s value: BAND_NG 0, BAND_NA 1, BAND_6E 2.
- **What the inform does to it** (`devmgr.kDxteQiUX`, called from the inform handler
  `iceUMDuewFNFLMOqti` before the radio tables are built): the new value is the inform's
  top-level `quickscan_scanning` (absent = false) **unless** `started_at_ms` is 10 min old
  (`system.l.EYFcHmSpOqr`), which forces false and logs "Quick scan has timed out". So the
  first inform without the flag ends the scan; the timeout only fires for a device that keeps
  saying true.
- **Results.** While the flag is set, an inform's `radio_table_stats[].spectrum_table` is not
  taken (`kDxteQiUX`, an empty list stands in). On the inform that turns the flag from true to
  false, the handler takes that inform's tables and writes the non-empty ones, plus
  `quick_scan_state` and `spectrum_scan_timestamp`, to the device record. The results must be
  **in the inform that carries false**.
- **Consequence for openUF.** The inform that fetches the cmd is already processed before
  the device has it, so it clears the flag the controller set; a sweep run in the handler is
  over before the next inform. openUF (`provision.lua` → `inform.lua`) therefore holds the
  scan pending: the next inform says true (re-arming the flag; `started_at_ms` is kept), the
  sweep is queued only once that inform has been answered (the next inform goes at once),
  the informs stay true while its chunks run (below), and the inform built after the last
  chunk says false and carries the tables. A failed POST does not count as the controller
  having seen it. Unit-tested (`test_inform_packet.lua`, `test_inform_json.lua`); ⚠️ never
  driven by a controller yet. Claiming `0x80` (done 2026-10-03, on the owner's decision)
  enrols the AP in the 03:00 scheduled sweep and Radio AI prescans, each taking every radio
  of a band off-channel — which is why the sweep is chunked.
- **Chunked sweeps** (ported from the yesrab fork, e7ffb87; their evidence, not ours). The
  fork's first handler swept a whole band in one `iw dev <if> scan ap-force`: on an AP-only
  radio mac80211's software scan does not return to the operating channel until it is
  done, ~2.7 s of the 5 GHz band without a beacon on their mt7986, and every client gave
  the AP up and roamed; a Radio AI Quick Scan asks every eligible AP at once, so there was
  nowhere to roam to ("kicks everyone off and we can't join for a while", an
  `AP-STA-DISCONNECTED` storm). They measured no `SET_SCAN_DWELL` support on mt76. So every
  `quick-scan` and `spectrum-scan` sweep is now a job per radio
  (`provision.spectrum_sweep` / `sweep_tick`): the radio's usable channels from the cached
  `iw phy#N info` (`sysinfo.phy_frequencies`; `(disabled)` left out, `no IR` / `radar
  detection` marked passive), kept to the radio's band, cut into chunks of four (≤ ~0.45 s
  off-channel: four ~110 ms passive dwells), `scan ap-force freq <f>…` per chunk. A chunk
  runs before the inform is built, at most every `SWEEP_CHUNK_GAP` (5 s), and the loop
  informs every 5 s while one is queued however long the controller's own interval: the
  03:00 sweep waits only 120 s per band for every AP's flag to clear, Radio AI's prescan
  180 s. Survey rows are merged by frequency across chunks (this chunk's channels and the
  operating one take the fresh reading). The same command asked again for a radio keeps its
  job's progress; a different one replaces it. Where the channel list cannot be read the
  job is one whole-band chunk, the old behaviour. Unit-tested and mutation-tested;
  ⚠️ not yet run on our hardware, so the client-side effect of a ~0.45 s chunk is the
  fork's claim, not a measurement of ours. Not chunked: the idle-radio sweep
  (`idlescan.lua`), which only runs on a radio with no associated client.
- **Meshed APs are refused.** The yesrab fork (2026-10-03, its own hardware against a UCG
  Ultra) saw the controller refuse Quick and Airtime scans for an AP while it was a wireless
  (meshed) child, with `api.err.InvalidTarget`, as it does for any meshed UniFi AP. openUF
  here has no wireless uplink, so this does not reach it; not observed in this tree.

Block/unblock are **one-shot commands**, not persistent per-inform state. The candidate
persistent field `include_blocks` (present on every response) was ruled out — it stays `[]`
even while a client is genuinely blocked. The device is expected to remember the block itself,
which is why `state.json` carries `blocked_stas` and `firewall.reconcile()` runs at startup.

---

## `system_cfg`: the real config channel

**A real controller never sends `resp.vap_table` / `radio_table` / `network_table` as JSON.**
All device configuration — WiFi, radios, IP settings, per-port VLAN, minimum RSSI — arrives
inside the flat, OpenWrt/hostapd-style `system_cfg` key=value blob on a `setparam`.
`inform.lua`'s `M._parse_wifi_system_cfg()` translates it into the `{radio_table, vap_table}`
shape `ucihelper.apply_config()` expects.

Conventions used throughout: booleans are `"enabled"`/`"disabled"` (sometimes `"true"`/`"1"`);
an **absent block means disabled** — there is generally no explicit `status=false`.

A line splits at its **first** `=`: keys never contain one, values (an SSID, a passphrase,
a base64-like PSK ending `==`) may. Until 2026-10-10 `wlan.lua`'s indexed patterns
(`aaa`/`wireless`/`radio`/`stamgr`/`macacl`/`qos.vap`) split at the last `=`, so a WLAN
whose SSID contained `=` was not provisioned and a passphrase with `=` was cut short
(test: `test_wlan_bss.lua`, "an '=' in an SSID or passphrase"). The other parsers already
split at the first `=`. ⚠️ No live capture yet of a controller pushing an SSID or PSK
with `=`. The parser assumes the value arrives verbatim, not escaped.

### `aaa.<n>.*` — per-SSID security

| Key | Meaning |
|---|---|
| `ssid` | SSID |
| `id` | The wlanconf Mongo ObjectId. **Must be echoed back** — see [`vap_table`](#vap_table-entry). |
| `wpa` | WPA protocol version (`2`/`3`). Stays `2` even for a WPA2/WPA3 transition WLAN. |
| `wpa.psk` | Passphrase |
| `wpa.key.<k>.mgmt` | AKM set (`WPA-PSK`, `SAE`, …). **This**, not `wpa`, is what distinguishes SAE. |
| `pmf.status` / `pmf.mode` | 802.11w. `mode` is `0`\|`1`\|`2` (disabled/optional/required), mapping 1:1 onto hostapd's `ieee80211w`. On this madwifi model, **WPA2/WPA3 transition intent is carried entirely by these fields** — dropping them silently collapses mixed mode to plain WPA2. |
| `pmf.cipher` | `AES-128-CMAC`. Not translated — hostapd's default BIP group-mgmt cipher already is this. |
| `ft.status` | Fast Roaming (802.11r) for the WLAN. No `mobility_domain`/`r0kh`/`r1kh` on the wire — the controller computes and syncs those internally across the site; `ucihelper.derive_mobility_domain()` fills the gap locally. |
| `iapp_key` | 32 hex chars, the wlanconf's `x_iapp_key`: 128 random bits the controller generates per WLAN. Sent whenever `iapp_enabled` (default on), **whatever `ft.status` says**, with the same value on every radio's block for the WLAN. openUF writes it as the `r0kh`/`r1kh` key. |
| `wpa3.ft.status` | FT for the **SAE akm alone**, a separate toggle from `ft.status`, from the wlanconf's `isWpa3SaeFastRoamingEnabled()`. Emitted unconditionally on any SAE push (the first key `OXMua` writes) and absent otherwise. OpenWrt has one `ieee80211r` switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK **and** FT-SAE together, so openUF enables FT if *either* toggle asks and logs the disagreement. Forced to `disabled` unless the radio claims `radio_caps2` bit `0x2` (see [Capability bitmasks](#capability-bitmasks)). |
| `bss_transition` | 802.11v. Present on every band's block, flips independently of Fast Roaming. |
| `br.devname` | `br0` untagged, **`br0.<vlan>`** when the WLAN is assigned to a VLAN network — CONFIRMED live 2026-08-01, the first capture of a tagged WLAN on real hardware. This suffix is the *only* per-WLAN VLAN signal; there is no `network_table`/`networkconf_id` join anywhere in the wire format. |
| `sae.anti_clogging` / `sae.sync` | Plain integers, emitted only when > 0 **and** the WLAN is genuinely WPA3 (see below). |
| `dynamic_vlan`, `wpa.psk_file.status`, `wpa.psk_file.<k>.psk`, `wpa.psk_file.<k>.vlanid` | **Private Pre-Shared Keys**, sent only to a device claiming `wifi_caps` bit `0x100000`. One passphrase per `<k>`; `vlanid` is left out for a key on a VLAN-1 network. The WLAN's own `wpa.psk` is then a random passphrase the controller generates. See [capability bitmasks](#capability-bitmasks). |
| `wpa.psk_radius` | UID IoT's "keys from RADIUS": `0`/`1`/`2` (disabled/optional/required, hostapd's `wpa_psk_radius` values). Decompiled from 10.6.101, **not seen on the wire**. The push names a RADIUS server for it only with RADIUS MAC authentication on; openUF then writes `ppsk=1` for `2`, and skips a `2` WLAN otherwise. |
| `radius.auth.<k>.{ip,port,secret}`, `radius.acct.<k>.{ip,port,secret}`, `interim_update.{status,interval}`, `nas_identifier`, `dynamic_vlan`, `auth_cache`, `radius.macacl.{status,format,emptypassword}` | **WPA-Enterprise and RADIUS**, decompiled from 10.6.106, **not seen on the wire** — see [below](#wpa-enterprise-and-radius-decompiled-106106). |
| `driver` | `madwifi` — confirms the controller is talking to this model as madwifi-era firmware, which explains several value encodings below. |
| `wpa.group_rekey` | GTK rekey interval in seconds, WPA WLANs only (not open/WEP). Decompiled 10.6.106: wlanconf `group_rekey`, default `3600`, forced `0` for WDS and Element WLANs; the field pattern allows `0` or `60`..`86400`. → `wpa_group_rekey`. See [below](#per-bss-knobs-decompiled-106106). |
| `tdls_prohibit` | `enabled`\|`disabled`, every WLAN, default off. → `tdls_prohibit`. |
| `country_beacon` | 802.11d. `enabled`\|`disabled`, every WLAN, default off. Per **radio** on OpenWrt (`country_ie`). |
| `11k.status` | 802.11k, wlanconf `rrm_enabled`. `enabled`\|`disabled`, every WLAN, default off. → `ieee80211k`. |
| `sae.groups.<i>.group`, `sae.has_groups` | wlanconf `sae_groups` (integer list), SAE pushes only; `<i>` counts from 1 in list order, and `has_groups=enabled` comes along only when the list is non-empty. → `sae_groups` in `hostapd_bss_options`. |

A VLAN assignment also produces companion `vlan.*`, `bridge.*` and `netconf.*` blocks.
**The `bridge.*` block is a specification, not decoration** — an earlier revision of this
document said openUF "does not need to reproduce these", which cost a live debugging
session. Captured 2026-08-01 when a WLAN was put on VLAN 20:

```
bridge.1.devname=br0            bridge.2.devname=br0.20
bridge.1.port.1.devname=eth0    bridge.2.port.1.devname=ath2      ← the vap
bridge.1.port.2.devname=ath0    bridge.2.port.2.devname=eth0.20   ← the tagged uplink
bridge.1.port.3.devname=ath1    bridge.2.stp.status=disabled
```

That second bridge is exactly the L2 a tagged SSID needs, and openUF must build the
equivalent (`br-openuf<vlan>` holding `<cpueth>.<vlan>`, with the VAP joined to it).
Skipping it yields a VAP and an uplink sub-device that are both up and completely
unconnected: the client associates and gets no DHCP, no gateway, nothing, while UCI,
netifd and hostapd all look correct.

`netconf.*` blocks are per-device-interface and stay anchored: the AP's own IP settings
remained at `netconf.1` (`devname=br0`) with the VLAN's entries taking later indices, so
inform.lua's `^netconf%.1%.` anchor is safe against a VLAN being added.

**Provisioning is not driven by `cfgversion` alone.** A device reporting a stale or bogus
version sometimes gets an immediate full push and sometimes only `noop`s, indefinitely,
even across restarts and fresh random values. An empty string is ignored outright. The
reliable trigger is a real config change in the controller — and note that a UI form
failing validation (e.g. switching a 2.4-GHz-only WLAN to Manual, where Band Steering
demands two bands) saves nothing and pushes nothing, with no error surfaced beyond the
form itself.

**SAE gating.** `com.ubnt.service.config.ubntconf.OXMua`'s emitter is capability-gate-free:

```
n = wlan.getInt("sae_anti_clogging", -1); if (n > 0) emit "aaa.<idx>.sae.anti_clogging" = n
s = wlan.getInt("sae_sync", -1);          if (s > 0) emit "aaa.<idx>.sae.sync" = s
```

but is only *called* when `wlan.isWpa3() || wlan.isOn6GHzBand()`. `isWpa3()` reads the DB flag
`wpa3_support`, which the **"WPA2/WPA3" dropdown does set** — read live from this site's
wlanconf: `wpa3_support: true`, `wpa3_transition: true`, `pmf_mode: optional`. (An earlier
revision of this document claimed the mixed choice left `wpa3_support` false and that a mixed
WLAN therefore never emits these keys. Wrong: the WLAN-side gate passes; what suppresses the
whole SAE block is the *per-device radio* capability check described in the WPA3 section.)
openUF maps these to hostapd's `sae_anti_clogging_threshold` / `sae_sync`
(the older name, still the broadly-supported one across the OpenWrt/wpad versions targeted).

### Per-BSS knobs (decompiled 10.6.106)

Six per-WLAN keys the generator always sent and openUF never read. All from the WLAN
loop of `com.ubnt.service.config.VAZShipWTNxlo` (the `aaa.<n>` arrays and the 62-entry
`wireless.<n>` array) and the SAE helper `ubntconf.XWWFgnDBrNRLQZ`; booleans render as
`enabled`/`disabled`. Defaults and ranges from the wlanconf getters
(`com.ubnt.data.GlUEhxTYZtqmhf`) and `api/fields/WlanConf.json` in
`internal-dependencies.jar`. **None of them has been seen in a live `system_cfg` diff yet.**

```
aaa.<n>.country_beacon = isCountryBeaconEnabled() = is("country_beacon", false)  every WLAN
aaa.<n>.11k.status     = is("rrm_enabled", false)                                every WLAN
aaa.<n>.tdls_prohibit  = is("tdls_prohibit", false)        both the open and the WPA branch
aaa.<n>.wpa.group_rekey = (isWds() || isElementWlan()) ? 0 : getInt("group_rekey", 3600)
                                                            WPA branch only; ^(0|60..86400)$
wireless.<n>.uapsd     = is("uapsd_enabled", false)                              every WLAN
aaa.<n>.sae.groups.<i>.group = sae_groups[i-1]   (i from 1)     inside the SAE helper only
aaa.<n>.sae.has_groups = enabled                 when at least one group was emitted
```

The OpenWrt side, read from 25.12.0's `wifi-scripts` (schema, `/usr/share/ucode/wifi/`)
and `hostapd.sh`:

- `wpa_group_rekey`, `tdls_prohibit`, `ieee80211k` are wifi-iface options in the schema and
  in `ap.uc`'s `append_vars`; `hostapd.sh` declares all three too. `ap.uc` derives
  `rrm_neighbor_report`/`rrm_beacon_report` from `ieee80211k`.
- `uapsd` is a schema **alias** of `uapsd_advertisement_enabled` (default true); the
  validator rewrites an alias onto its target, and `hostapd.sh` reads `uapsd` itself, so the
  alias is the one name both stacks take.
- `sae_groups` is **not** a wifi-iface option: `ap.uc` only `set_default()`s `'19 20 21'` for
  SAE. openUF sends the controller's list as a `hostapd_bss_options` line, which `ap.uc`
  appends after the default; hostapd's intlist parser frees the previous list, so the last
  line wins (source-read, not observed on a running hostapd).
- `ieee80211d` is a **wifi-device** option (schema default true; `country_ie` is its alias,
  the name `hostapd.sh` reads). `hostapd.uc` emits it only with a country set. It cannot be
  turned off next to 802.11h: with `ieee80211h=1` and no `ieee80211d`, 25.12.0's wpad refuses
  the config —

  ```
  Cannot enable IEEE 802.11h without IEEE 802.11d enabled
  1 errors found in configuration file '/tmp/a.conf'
  ```

  (run in the `openwrt/rootfs:x86-64-25.12.0` container with `wpad-basic-mbedtls`), and
  `hostapd.uc` keeps `ieee80211h` (schema default true) on every `hw_mode=a` radio, 5 and
  6 GHz alike. openUF therefore folds the WLANs' `country_beacon` per radio (on if any
  enabled WLAN wants it), applies off on 2.4 GHz, and on 5/6 GHz only where
  `doth`/`ieee80211h` is `0`.

### WPA-Enterprise and RADIUS (decompiled, 10.6.106)

Tier: decompile only. No Enterprise WLAN has been captured on the wire and none brought up on
hardware. Source: `com.ubnt.service.config.VAZShipWTNxlo` (the AP config generator) and
`com.ubnt.data.GlUEhxTYZtqmhf` (the wlanconf object), 10.6.106, CFR.

**The old claim was wrong for 10.6.** openUF used to skip every Enterprise WLAN because "the
wire carries no RADIUS server, port or secret". That claim (commit `fa2f3a5`) rested on no
capture and no decompile; it only observed that `wpa.psk` is absent, which is true. In 10.6.106
the generator copies the WLAN's RADIUS profile into the wlanconf whenever
`requireRadiusProfile()` (= `isEAP() || radius_mac_auth_enabled`), before generating:
`auth_servers`/`acct_servers` from the profile, `accounting_enabled` forced true, and
`interim_update_enabled`/`interim_update_interval`/`vlan_wlan_mode` copied. An unknown
`radiusprofile_id` logs "invalid radiusprofile_id" and leaves the lists empty. Whether 10.4.x
behaves the same was not checked.

For an Enterprise WLAN (the `isEAP()` branch), per `aaa.<n>`:

```
aaa.<n>.wpa.key.1.mgmt=WPA-EAP          # OSEN for Hotspot 2.0 OSEN; wpa.psk is null, so not written
aaa.<n>.auth_cache=enabled|disabled     # wlanconf auth_cache, default true
aaa.<n>.wpa3.enhanced_192=enabled       # only for WPA3 192-bit
aaa.<n>.radius.auth.<k>.ip / .port / .secret     # k = 1..4 in profile order; port default 1812
aaa.<n>.radius.auth.<k>.tls=enabled + certs      # RadSec, fw2_caps 0x80000 only
aaa.<n>.radius.acct.<k>.ip / .port / .secret     # accounting_enabled; port default 1813
aaa.<n>.interim_update.status=enabled + .interval=<s>   # default 3600
aaa.<n>.radius.das.status/.port=3800+n/.client/.secret, aaa.radius.dad.*   # DAS, fw_caps 0x100000 only
aaa.<n>.radius_acct_send_keyid.status=enabled    # UID IoT with psk_radius only
aaa.<n>.dynamic_vlan=0|1|2              # vlan_wlan_mode: absent/"disabled" 0, "optional" 1, "required" 2
aaa.<n>.hs20.status=disabled            # unless Hotspot 2.0
aaa.<n>.filter_id=<…>                   # fw_caps 0x20000000 plus a site-level RADIUS check
aaa.<n>.nas_identifier=<string>         # whenever requireRadiusProfile(), per nas_identifier_type
aaa.<n>.radius.macacl.status=enabled|disabled (+ .emptypassword, .format)
```

The generation rides on the same keys as for PSK: `wpa3.support` + `wpa3.transition`
(written for any WPA3 WLAN before the EAP/PSK split), plus `wpa3.enhanced_192`. The akm stays
`WPA-EAP` throughout. A server whose `ip` or `x_secret` is empty is skipped with a warning and
its index `<k>` left unused, so the indices can have gaps; at most four of each kind are sent.

**RADIUS Dynamic Authorization (CoA/Disconnect, "DAS").** Emitted only when
`hasFirmwareCapability(0x100000) && (radius_das_enabled || hotspot2conf_enabled)` and only inside
the WLAN's `accounting_enabled` branch (`VAZShipWTNxlo` ~1013-1045):

```
aaa.radius.dad.status=enabled  aaa.radius.dad.port=3799          once per device: the dispatcher
aaa.<n>.radius.das.status=enabled  aaa.<n>.radius.das.port=3800+n  the WLAN's own listener
aaa.<n>.radius.dad.status=enabled
aaa.<n>.radius.das.client=<acct server 1 ip>  .das.secret=<its secret>   the listener's peer
aaa.<n>.radius.dad.client.<k>.cidr=<acct server k ip>/32  .secret        dispatcher clients
```

openUF claims `fw_caps` `0x100000` and does it the same way (`openwrt/das.lua`): hostapd runs the
WLAN's listener (UCI `dae_port` = the controller's `3800+n`, `dae_secret`, and `dae_client` =
**127.0.0.1**, so only the dispatcher reaches it), and the `announce` process binds UDP 3799,
takes a Disconnect-/CoA-Request from a listed client, relays it unchanged from 127.0.0.1 and
returns hostapd's answer. The authenticators are keyed on the shared secret, so hostapd still
checks it end to end. Which WLAN gets a request is **openUF's rule**, not a UniFi AP's (that is
firmware this project does not read): a NAS-Identifier naming a WLAN's `nas_identifier`, else a
Called-Station-Id `<BSSID>:<SSID>` naming its SSID, else every WLAN the source may address, with
the first ACK returned. OpenWrt 25.12 writes `radius_das_*` for EAP BSSes only (`ap.uc`), so the
plan holds Enterprise WLANs only. Limits: hostapd checks against the WLAN's `das.secret` (the
first accounting server's), so a second accounting server with another secret fails there, as
it would against the controller's own pairing; a pre-existing NAS-IP-Address mismatch check in
hostapd still applies. Tested over real UDP sockets in the CI container (a request to 3799
relayed from 127.0.0.1 to a stand-in listener, its ACK returned with the request's id); **not run
against a real hostapd or RADIUS server**.

RADIUS MAC authentication (`radius_mac_auth_enabled`), on a non-Enterprise WLAN, emits the same
server lists through the same method, then `radius.macacl.status=enabled`,
`.emptypassword=enabled|disabled` and `.format=<printf format>`. The format enum
(`GlUEhxTYZtqmhf$RxFvcetMTlkSFFxK`) is `%.2x%.2x%.2x%.2x%.2x%.2x` (the default), `%.2x-…`,
`%.2x:…`, and the three uppercase forms. hostapd (`src/ap/ieee802_11_auth.c`) sends User-Name
and User-Password both as `RADIUS_ADDR_FORMAT` = `%02x%02x%02x%02x%02x%02x` (checked in the
current hostap tree), so only the default format with the empty password off is reproducible.

**OpenWrt side** (25.12 `wifi-scripts`, `files-ucode`, read from the `openwrt-25.12` branch):

- `encryption`: `wpa2` → `auth_type` `eap`, `wpa3` → `eap2` (PMF forced 2), `wpa3-mixed` →
  `eap-eap2`, `wpa3-192` → `eap192` (pairwise forced `GCMP-256`) — `iface.uc`
  `parse_encryption`.
- `wireless.wifi-iface.json` aliases: `auth_server` → `auth_server_addr` (**array**),
  `auth_port` → `auth_server_port` (number), `auth_secret` → `auth_server_shared_secret`
  (string), the same for `acct_*`, `acct_interval` → `radius_acct_interim_interval`, `nasid` →
  `nas_identifier`, `dae_*` → `radius_das_*`, `ownip`/`dynamic_ownip`, `auth_cache` → `okc`;
  `dynamic_vlan` enum 0/1/2; `ppsk` boolean. One port and one secret per list: `ap.uc`
  `iface_authentication_server` repeats the same port/secret after every address.
- `ap.uc` `iface_ppsk`: an open/PSK/SAE/OWE BSS with `auth_server_addr` gets
  `macaddr_acl=2` — then `iface_macfilter` may write its own `macaddr_acl` after it.
  An EAP BSS never gets one. openUF therefore adds `macaddr_acl=2` as a raw
  `hostapd_bss_options` line, which `ap.uc` appends last.
- `validate.uc` converts every alias and **deletes the alias key**, so `ap.uc`
  `iface_roaming`'s `config.auth_secret ?? config.key` sees no `auth_secret`: an EAP BSS with
  802.11r and no explicit `r0kh`/`r1kh` fails `FT_KEY_CANT_BE_DERIVED`. openUF writes `key` =
  the RADIUS secret on such a BSS, which is the derivation upstream intended.
- Dynamic VLAN: `iface_vlan` writes `vlan_file` from the `wifi-vlan` sections and the
  dynamic-VLAN options when `dynamic_vlan` is set; with no `vlan_bridge`, `vlan_no_bridge=1`
  (netifd bridges the `<ifname>-<name>` netdev). openUF writes a `wifi-vlan` for every VLAN
  this AP already carries. A RADIUS-assigned VLAN outside that set is expected to be refused by
  hostapd (no `vlan_file` line, no wildcard) — not verified.

Unit tier: `test_inform_packet.lua` replays a synthetic block in the generator's key names and
order through `_parse_wifi_system_cfg` + `apply_config` with the recording mock cursor;
`test_ucihelper.lua` covers the `vlan_filtering` plan. Mutation-tested (server filter, eap192
mapping, FT key, raw `macaddr_acl`, Management-VLAN mapping, the no-server skip).

### `wireless.<n>.*` — per-SSID radio binding and behavior

| Key | Meaning |
|---|---|
| `ssid`, `parent` | SSID, and the owning radio (`radio0`/`radio1`) |
| `dtim_period` | Plain integer, **always present** regardless of the WLAN's Auto/Custom DTIM toggle. There is no `dtim_mode`/`dtim_ng`/`dtim_na` key on the wire — go-unifi's band-split shape describes the REST API, not this protocol. |
| `no2ghz_oui` | **Band Steering's real wire representation.** Not a per-device `mgmt_cfg` field. Toggling Band Steering changes only this key, and only on the 2.4 GHz entry (the 5 GHz entry stays `disabled` — nothing to toggle there). A madwifi/QCA convention: omitting the AP's OUI from 2.4 GHz beacons nudges dual-band clients toward 5 GHz. Mainline mac80211/hostapd has no equivalent, so openUF derives a single device-wide `steering_active` boolean (true if *any* vap has it) and drives `usteer`, which is itself a device-wide daemon. The AP's own Band Steering setting is a separate, device-level `bandsteering.*` block that also sets it; see [Capability bitmasks](#capability-bitmasks) (`wifi_caps` `0x4`). |
| `mcast.enhance` | Multicast Enhancement / Multicast-to-Unicast. `0`\|`1`. |
| `minrate_data`, `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg` | **Minimum Data Rate Control.** `minrate_data` is the floor in kb/s; `beacon_rate`/`mgmt_rate` simply mirror it. `minrate_cck_rates.status` and `pureg` are derived consequences on 2.4 GHz (a 12 Mbps floor is OFDM, so CCK goes `false` and `pureg` goes `1`). `minrate_below_disable` is the separate "advertising rates" sub-toggle. Emitted per band and **absent entirely** when that band's control is off — not band-gated, which an early reading of a 2.4-GHz-only capture suggested. |
| `bcfilt.status`, `bcfilt.<k>.mac`, `bcfilt.<k>.status` | **Multicast and Broadcast Blocker** (REST `bc_filter_enabled`/`bc_filter_list`). `status` appears whenever the control is on, including with an empty allow-list; the indexed entries only once it is non-empty. `<k>` is 1-based and does **not** follow the REST list's order — adding a second MAC renumbered the first — so the index means nothing beyond grouping. Emitted on both band entries. |
| `l2_isolation` | **Client Isolation.** `enabled`\|`disabled`, always present, emitted on both band entries. → OpenWrt `isolate` (hostapd `ap_isolate`). |
| `devname` | The Ubiquiti-side netdev for this vap (`ath0`…`ath3`). **The join key for the top-level [`macacl.*`](#macacl--mac-address-filter) section**, whose own indices do not line up with `<n>`. Not a name that exists on OpenWrt — enforcement resolves the real netdev via `ubus`. |
| `mac_acl.status`, `mac_acl.policy` | ⚠️ **Decoys — not the MAC Address Filter.** Sit at `enabled`/`deny` with the control off and do not move when it is toggled; the real feature is the top-level [`macacl.*`](#macacl--mac-address-filter) section. |
| `hide_ssid` | **Hide WiFi Name.** `true`\|`false` — note the vocabulary, not the `enabled`/`disabled` most keys here use. Always present, emitted on both band entries, and duplicated verbatim as `aaa.<n>.hide_ssid`. → OpenWrt `hidden` (hostapd `ignore_broadcast_ssid`). |
| `mcastrate` | Multicast rate. Observed only ever as `auto` — no WLAN-level control in 10.4.57's UI moves it, and OpenWrt's `mcast_rate` is adhoc/mesh-only anyway, so openUF does not map it. |
| `uapsd` | U-APSD (WMM power save), wlanconf `uapsd_enabled`. `enabled`\|`disabled`, every WLAN, default off. → `uapsd`. |
| `advertise_ap_name` | "Show Access Point Name in Beacon". **Only emitted when the device declares `wifi_caps2` bit `0x40`** — see [capability bitmasks](#capability-bitmasks). |
| `btm_disassoc.status`, `btm_disassoc.threshold` | **Roaming Assistant.** 5/6 GHz vaps only, and only when the device declares `wifi_caps2` bit `0x20` — see [below](#wirelessnbtm_disassoc--roaming-assistant). |
| `iot`, `qbssload` | **"Force WiFi 4 Mode"** (IoT Optimization; REST field `enhanced_iot`). Absent entirely when off; appear together as `iot=enabled` + `qbssload=disabled` on the WLAN's 2.4 GHz entry when on. The parent radio is *not* touched — `radio.<n>.ieee_mode` keeps the site's configured width — so this is a per-BSS flag only. `qbssload` is its one distinct on-air effect (suppress the QBSS Load IE); the rest of the mode arrives as ordinary keys: the 5 GHz vap is dropped outright, security pinned to WPA2, and `bss_transition`/`proxy_arp`/`no2ghz_oui`/PMF/`advertise_ap_name` all forced off. |

### `radio.<n>.*` — per-radio config

`phyname` (`radio0`), `channel` (integer or the literal `auto`), `txpower` (integer or `auto`),
`txpower_mode` (`auto`/`custom`/`disabled`), `status`, `ieee_mode`. When no radio is
provisionable the blob contains the literal comment `# no wlan provisioned as no radio found`
and the **unindexed** `radio.status=disabled` — see
[`radio_table` must not be empty](#radio_table-entry).

Do not confuse that unindexed key with the **indexed** `radio.<n>.status`, which is the real
per-radio enable/disable control — see
[`radio.<n>.status` — per-radio disable](#radionstatus--per-radio-disable).

`ieee_mode` is **the wire's only channel-width signal**: a compound `11` + band (`ng`/`na`) +
PHY and width token — `11nght20`, `11nght40`, `11naht40`, `11acvht80`, `11axhe80`. Changing
Devices → [AP] → Settings → Radios → "2.4 GHz Channel Width" from 20 to 40 changes exactly this
key (alongside `cwm.mode` 0→1, a redundant channel-width-management flag carrying no extra
information). openUF maps it to UCI `wifi-device.htmode`; on OpenWrt/mac80211 that option is the
PHY ceiling, so `HT20`/`HT40` also *is* "802.11n only". There is no separate 11n/11ac/11ax mode
key — an earlier version of openUF expected one, never populated it, and so silently never
applied channel width at all.

#### `radio.<n>.blklst` / `radio.<n>.acsdfs` — Auto-channel exclusions and DFS

Decompiled from controller **10.6.106** (CFR on `internal-dependencies.jar`): the per-radio
generator `com.ubnt.service.config.ubntconf.PFljhxhmKJyhpeIhf`, called from the system_cfg
builder `VAZShipWTNxlo` right after the `radio.<n>.phyname`/`ack.auto`/… line, with the
site's **Radio AI** setting (the builder field is named `radioAiSetting`;
DTO `WifiAiSettingDto`, setting key `radio_ai`). Both keys sit behind one gate:

```java
if (device.supportsAcsDfs()) {           // = hasWifiCapability2(16): wifi_caps2 0x10
    if (band == BAND_NA)                  // 5 GHz only
        emit("radio.<n>", "acsdfs", dfs ? "enabled" : "disabled");
    if ("auto".equals(channel)) {         // only while the radio's channel is Auto
        Set<String> set = radio_ai.channels_blacklist
            .groupBy(e -> band(e.radio)).map(e -> e.channel)  // per band
            .getOrDefault(band, Set.of());
        if (!set.isEmpty())
            emit("radio.<n>", "blklst", String.join(",", set));
    }
}
// dfs = radio_ai.radios_configuration.find(radio == "na").is("dfs", false)
```

- `blklst`: the site's excluded channels **for this radio's band**, channel numbers joined with
  `,` from a `HashSet` (so in no stable order). Each `channels_blacklist` entry is a record
  `{channel: int, radio: "ng"|"na"|"6e", channel_width: int}`; the width is **not** on the
  wire. Absent when nothing is excluded on the band, and absent whenever the channel is fixed.
- `acsdfs`: `enabled`/`disabled`, 5 GHz radios only, emitted whatever the channel. It reads
  `radios_configuration[radio=na].dfs` with a default of **false**: a site with no `na` entry
  there sends `disabled`.
- On a 6 GHz radio the channel goes out as `radio.<n>.freq`, but `blklst` is still channel
  numbers.

openUF claims `wifi_caps2` `0x10` and maps both, only while the channel is Auto
(`openwrt/ucihelper.lua` `rf_config`):
- `blklst` → the UCI `channels` list (hostapd `chanlist`). On 2.4 GHz the exclusions come off
  UniFi's 1/6/11 plan; elsewhere openUF writes the ranges between them over 1–233
  (`1-51 53-55 …`), since `chanlist` is an allow-list. Stamped `openuf_channels`.
- `acsdfs=disabled` → `acs_exclude_dfs=1`, stamped `openuf_acs_dfs`; `enabled` or absent
  removes a stamped value. A value set by hand (no stamp) is left alone.
- A `dev.conf.radio` board policy wins over both (the operator's override).

OpenWrt 25.12 consumers, read from the wifi-scripts source: `wireless.wifi-device.json`
declares `acs_exclude_dfs` (boolean) and `channels` as an alias of `chanlist` (array, "range
using hyphen … or individual channels … space separated"); `ucode/wifi/hostapd.uc` appends
both, and the legacy `mac80211.sh` does too. hostapd's `hostapd_parse_chanlist` turns spaces
into commas and calls `freq_range_list_parse`, so ranges are accepted.

⚠️ Limit: hostapd's ACS (`src/ap/acs.c`) checks `chanlist` against the **primary** channel
only. A 40/80/160 MHz channel whose primary is allowed can still span an excluded channel as a
secondary. How a real UniFi AP treats an excluded secondary is unknown.

⚠️ Not yet confirmed live: the gate and wire shapes are from the decompile only. Lab check:
add a `channels_blacklist` entry and flip the 5 GHz DFS switch in Radio AI, then diff
`system_cfg` for an Auto radio.

### `stamgr.<n>.*` — per-radio Station Manager (Minimum RSSI, Max Clients)

Indexed the same as `radio.<n>`, **not** tied to any SSID. This is a device/radio-level
setting (Devices → [AP] → Radios), not a WLAN one — distinct from the WLAN Advanced panel's
"Roaming Assistant", a different feature with its own wire keys,
[`wireless.<n>.btm_disassoc.*`](#wirelessnbtm_disassoc--roaming-assistant).

```
stamgr.1.status=true
stamgr.1.radio=ng
stamgr.1.minrssi.status=true
stamgr.1.minrssi.rssi=15
stamgr.1.loadbalance.status=false
```

**The threshold is not plain dBm.** UI `-80 dBm` → wire `15`; UI `-85 dBm` → wire `10`.
The controller's generator (`com.ubnt.service.config`, 10.x) computes it as
`max(min_rssi + 95, 1)` with `min_rssi` defaulting to `-80`, so openUF converts back with a
fixed `- 95` (`openuf/minrssi.lua`). An earlier version added the radio's live noise floor
instead, which moved the threshold by up to 12 dB between drivers (ath9k reads -107, mt76
-90/-92).

**`loadbalance.*` is "Max Clients"** (Devices → [AP] → Radios), the sibling sub-feature
sharing the block. From the UniFi Network 10.6.106 config generator (`VAZShipWTNxlo`,
CFR-decompiled; not yet seen in a live capture with it switched on):

```java
bl9 = radio.is("loadbalance_enabled", false);
bl4 = radio.is("minrssi_enabled", false);
if (advanced_feature_enabled && (bl4 || bl9))
    emit("stamgr." + n, "status","true", "radio",radio.radio, "minrssi.status",bl4,
         "minrssi.rssi",radio.getInt("minrssi"), "loadbalance.status",bl9,
         "loadbalance.maxsta",radio.getString("maxsta"));
```

- `n` is the same counter that numbers `radio.<n>` in that loop, so `stamgr.<n>` and
  `radio.<n>` are the same radio — the join minrssi already relies on.
- The block exists when **either** feature is on, so its presence says nothing about Max
  Clients; `loadbalance.status` (`String.valueOf(boolean)`: `true`/`false`) is the
  discriminator. The emitter skips a `null` value, so `loadbalance.maxsta` is absent when the
  radio has no `maxsta` stored.
- Off arrives three ways: the block gone (neither feature on, or the site's advanced
  features off), `loadbalance.status=false`, or status `true` with no usable count. openUF
  reads all three as "no limit" (`max_sta = false`).

**What the AP does with it (firmware-confirmed for 4.0.15, 2026-10-10).** `ubntbox` passes
`stamgr -n <maxsta>` per radio, 0 unless `loadbalance.status` is true (`get_bool`, then
`get_int32` into `-b %s -r %d -n %d`). `stamgr` (`/bin/stainfo`) ignores a maxsta of 0 or
less. Every interval it zeroes each radio's count and candidate, then walks the stations of
all the radio's VAPs: one it has just kicked for low RSSI is skipped, every other one
increments the count, and the candidate becomes the station with the larger idle time
(driver station field `0x678`, the `idle=` column of `stainfo`'s table; on equal idle the
earlier station stays). After the walk, if `maxsta > 0` and count `> maxsta`, it kicks the
candidate with reason "Too many STAs" (`kick-sta-on`, the same one-shot deauth as
`kick-sta`; logged `kick-sta-on <mac> <ath> (reason:Too many STAs count:<n>)`). One kick per
radio per interval. Nothing refuses an association: no driver `maxsta` is set (`umac.ko`
has an `iwpriv maxsta`, `ubntbox` never writes it), so a full radio admits a newcomer and
the next pass kicks whichever station is then the most idle.

**openUF** (upstream 2026-10-10, ported here 2026-10): the parser turns the block into the radio's
`loadbalance_maxsta` (false when the block is absent, `status` is not true, or `maxsta` is
not a positive number). `rf_config` stores it as the openUF-only `wifi-device` option
`loadbalance_maxsta` and deletes it on off. On every inform, for each radio with a cap,
openUF counts the stations of all its BSSes except any Minimum RSSI kicks in the same pass,
and deauthenticates the `count - maxsta` stations with the largest `inactive time`
(`iw station dump`) through `ucihelper.kick_station`. openUF samples once per inform, not
once a second, so one pass does what the firmware does over that many seconds. The cap is
not echoed in `radio_table`: the controller keeps its own copy.

This fork used to apply it as the **wifi-device** option `maxassoc` (hostapd
`iface_max_num_sta`), which refuses the client over the limit, where the firmware refuses
nothing. A `maxassoc` stamped `openuf_maxassoc` is removed on the next push. Upstream's
hardware note: `iw`'s `inactive time` parses for every station on ath10k and mt76; a real
kick has not been observed.

**Two top-level keys come with it** (lab 10.4.57, 2026-10-10, Minimum RSSI on for one radio):

```
stamgr.status=enabled
stamgr.interval=1
```

`stamgr.status=disabled` (and no `stamgr.<n>` block) when no radio has Minimum RSSI or load
balancing on. `stamgr.interval` is the site's `config.stamgr_interval`, default 1. openUF
does not read either: they stay in the dropped-key report.

**What the AP does with it (firmware-confirmed for 4.0.15, 2026-10-10).** Two halves:

1. **Refuse.** `ubntbox` sets the driver's per-radio `minrssi` to `minrssi.rssi` plus
   `stamgr.<n>.minrssi.rssi.offset` (default 3; the controller never sends it), only while
   `minrssi.status` is true. `umac.ko` then answers no probe request and no authentication
   below it ("probe/auth: disallowed by minrssi").
2. **Kick.** `ubntbox` writes `/bin/stamgr -i <stamgr.interval, default 1> -c
   <stamgr.minrssi_conseq_fails, default 30>` into inittab, plus `-b <band> -r <rssi> -n
   <maxsta>` per radio. `stamgr` (`/bin/stainfo`) samples each station every interval,
   smooths its RSSI (0.2 × previous + 0.8 × current), and counts consecutive samples below
   `-r`; any sample at or above resets the count to 0. At `-c` it runs `kick-sta-on`
   (`syswrapper.sh`), the same one-shot deauth as the `kick-sta` command. Nothing is blocked.

So the firmware kicks a client after **30 s continuously below** the threshold, and lets it
back only **3 dB above** it, which is what stops a weak client from looping kick → rejoin.
The controller emits neither `minrssi_conseq_fails` nor the offset, so the defaults are what
every UniFi AP runs. `stamgr`'s two other kicks are off on a managed AP: `ubntbox` never
passes `-t` (inactivity), and it appends `-K` (no kick for a wireless client seen on
Ethernet) unless `stamgr.kicketh.status` is false. The controller sends neither key.

**openUF (2026-10-10):**
- *Refuse:* hostapd's `rssi_reject_assoc_rssi` and `rssi_ignore_probe_request` at threshold
  + 3 dBm, both `wifi-device` options (present in 25.12's schema, `hostapd.uc`'s
  `append_vars` and `hostapd.sh`; read on both APs, OpenWrt 25.12.5). Stamped `openuf_minrssi`; turning
  the feature off removes exactly the stamped options. A hand-set value on an unstamped radio
  is never touched. hostapd refuses association (not authentication) below the threshold;
  that is the closest it has.
- *Kick:* openUF samples once per inform, not once a second, so it counts time: a station
  whose `signal avg` was below the threshold in every sample for 30 s gets one deauth
  (`ucihelper.kick_station`). One sample at or above restarts the count; a station that
  leaves is forgotten. The previous version kicked on the first sample below, with nothing
  stopping the client from reconnecting at once.
- A station below Minimum RSSI is not also handed to Roaming Assistant.

Lab (10.4.57): the captured push replays through `_parse_wifi_system_cfg` + `apply_config`
into `rssi_reject_assoc_rssi=-77`, `rssi_ignore_probe_request=-77` for `-80 dBm`, and the
real off push removes both. The controller shows `min_rssi: -80` back.

Hardware (2026-10-10, Archer C5 2.4 GHz ath9k, real 10.6 controller): Minimum RSSI set to
-90 dBm (the controller's API accepts -67 to -90 only, `api/fields/Device.json`) arrived as
`stamgr.2.minrssi.rssi=5` with `stamgr.interval=1`. Within ~8 s the live
`/var/run/hostapd-phy1.conf` read `rssi_reject_assoc_rssi=-87` and
`rssi_ignore_probe_request=-87`; only that radio restarted (`AP-ENABLED` 2 s later, the
5 GHz BSS untouched), and the controller showed `min_rssi: -90` back. Switching it off
returned both to `0` (hostapd's off) and removed the stamp. Not observed: an actual refused
association or a 30 s kick, since no client was anywhere near -87 dBm.

**Enforcement semantics.** Minimum RSSI is a **roaming aid, not a block**. The kick is a
single deauth with no persistent drop rule, so it has its own helper,
`ucihelper.kick_station()`, rather than reusing `firewall.deauth()`.

### `stamgr.<n>.loadbalance.*` — Load balance (per-radio client cap)

The device's `radio_table[].loadbalance_enabled` + `maxsta` (REST `rest/device`; the
10.6 schema `api/fields/Device.json` accepts `maxsta` 1 to 200 or empty). The 10.6 web
bundle has no control for it, only a change-log label ("Load Balance", "Maximum Number of
Clients"). The controller's generator (`com.ubnt.service.config`, 10.4) writes the
`stamgr.<n>` block when the site's `advanced_feature_enabled` is on and the radio has
Minimum RSSI or Load balance on. Lab (10.4.57, 2026-10-10), Load balance on for radio0 with
`maxsta` 3 and Minimum RSSI off:

```
stamgr.1.status=true
stamgr.1.radio=ng
stamgr.1.minrssi.status=false
stamgr.1.minrssi.rssi=15
stamgr.1.loadbalance.status=true
stamgr.1.loadbalance.maxsta=3
# stamgr
stamgr.status=enabled
stamgr.interval=1
```

Off: the whole `stamgr.1` block went, and `stamgr.status=disabled`.

**What the AP does with it (firmware-confirmed for 4.0.15, 2026-10-10).** `ubntbox` passes
`stamgr -n <maxsta>` per radio, 0 unless `loadbalance.status` is true (`get_bool`, then
`get_int32` into `-b %s -r %d -n %d`). `stamgr` (`/bin/stainfo`) ignores a maxsta of 0 or
less. Every interval it zeroes each radio's count and candidate, then walks the stations of
all the radio's VAPs: one it has just kicked for low RSSI is skipped, every other one
increments the count, and the candidate becomes the station with the larger idle time
(driver station field `0x678`, the `idle=` column of `stainfo`'s table; on equal idle the
earlier station stays). After the walk, if `maxsta > 0` and count `> maxsta`, it kicks the
candidate with reason "Too many STAs" (`kick-sta-on`, the same one-shot deauth as
`kick-sta`; logged `kick-sta-on <mac> <ath> (reason:Too many STAs count:<n>)`). One kick per
radio per interval. Nothing refuses an association: no driver `maxsta` is set (`umac.ko`
has an `iwpriv maxsta`, `ubntbox` never writes it), so a full radio admits a newcomer and
the next pass kicks whichever station is then the most idle.

**openUF (2026-10-10):** the parser turns the block into the radio's
`loadbalance_maxsta` (false when the block is absent, `status` is not true, or `maxsta` is
not a positive number). `rf_config` stores it as the openUF-only `wifi-device` option
`loadbalance_maxsta` and deletes it on off. On every inform, for each radio with a cap,
openUF counts the stations of all its BSSes except any Minimum RSSI kicks in the same pass,
and deauthenticates the `count - maxsta` stations with the largest `inactive time`
(`iw station dump`) through `ucihelper.kick_station`. openUF samples once per inform, not
once a second, so one pass does what the firmware does over that many seconds. The cap is
not echoed in `radio_table`: the controller keeps its own copy.

Lab (10.4.57): the push above stored `loadbalance_maxsta=3` on radio0, the off push removed
it, 0 `handle_response` failures. Hardware (2026-10-10): deployed to both APs; `iw`'s
`inactive time` parses for every station on ath10k (Archer C5 5 GHz, 3 stations) and mt76
(AX3000T, 14 stations); the ath9k radio had none to read. A dry run of the selection with a
cap of 1 per radio picked 2 of 3 and 12 of 14, and kicked nothing. Not observed: a real
kick, as no radio at home has a cap set.

### `wireless.<n>.btm_disassoc.*` — Roaming Assistant

A per-WLAN, per-band setting (Settings → WiFi → *WLAN* → Advanced; REST
`roaming_assistant_na_enabled`/`_na_rssi` and `_6e_enabled`/`_6e_rssi` on `wlanconf`).
Confirmed live 2026-09-26 against the lab's 10.4.57, by setting
`roaming_assistant_na_enabled=true, roaming_assistant_na_rssi=-72` over REST and diffing
`system_cfg`. Exactly two keys appeared, only on the WLAN's 5 GHz entry:

```
wireless.2.btm_disassoc.status=enabled
wireless.2.btm_disassoc.threshold=-72
```

Switching it off removed both again. There is no `status=disabled`: absence is off.

- **The threshold is plain dBm**, unlike `stamgr.<n>.minrssi.rssi`.
- **The generator** is `com.ubnt.service.config.ubntconf.cZldsW` in 10.6.101, the class
  holding the defaults `-75` (5 GHz) and `-88` (6 GHz). It emits only when all of these hold:
  `Device.supportsAssistedRoaming()` (= `hasWifiCapability2(32)`, **`wifi_caps2` bit `0x20`**),
  the vap's radio is `na` or `6e`, the WLAN is neither WDS nor an Element WLAN, and that band's
  toggle is on. `status` goes through the builder's boolean helper (`enabled`/`disabled`).
- **Why earlier captures never showed it:** openUF claimed only `0x40`. An earlier version of
  this document concluded that the REST fields "never appear on the wire". That was the missing
  capability bit, not the protocol.
- **What a UniFi AP does with it**, from the key name and the controller's
  `MOVED_DUE_TO_ROAMING_ASSISTANT` event: a BSS Transition Management request, then a
  disassociation. openUF implements that in `openwrt/roamassist.lua`, but only when another
  AP on the same SSID and band hears the client at or above the threshold and at least
  `roam_assist_diff_db` (default 8) dB better. A client with no better AP is left alone.
- **usteer's own roam trigger is not used.** It is device-wide, and its only scoping knob,
  `ssid_list`, switches every usteer function off for the other SSIDs, band steering included
  (usteer `local_node.c`, 2025.10.04). openUF reads usteer's cross-AP table
  (`get_client_info`) and makes the per-vap decision itself. Every entry in that table expires
  `local_sta_timeout` (120 s) after the client was last heard, locally or remotely (usteer
  `sta.c`, `remote.c`), so a reading is at most about 2 minutes old.
- **The hostapd calls** are `bss_transition_request` with the target's neighbor-report hex
  (usteer's `rrm_nr[2]`), then, if the client is still there 10 s later, `del_client` with
  reason 12 and a 30 s `ban_time` on the source BSS only. In OpenWrt 25.12's hostapd `ubus.c`,
  `bss_transition_request` has no 802.11v capability check: the frame goes out regardless and a
  non-11v client simply ignores it.
- **Nothing goes off-channel.** The cross-AP readings are the ones usteer already exchanges
  between APs; the AP neither scans nor dwells elsewhere to get them.

### `macacl.*` — MAC Address Filter

A **top-level section keyed by devname**, not by the `wireless.<n>` index. Confirmed live
2026-07-18 by enabling the control on one WLAN with a single allow-listed MAC:

```
macacl.status=enabled                       # global gate
macacl.1.devname=ath0                       # join key -> wireless.<n>.devname
macacl.1.status=enabled
macacl.1.acl.status=enabled
macacl.1.acl.policy=allow                   # allow | deny  (UI "Filter Type")
macacl.1.acl.1.mac=02:11:22:33:44:55
macacl.1.acl.1.status=enabled
macacl.1.acl.1.type=user
macacl.2.devname=ath2                       # the same WLAN's 5 GHz vap
```

Only the vaps belonging to the filtered WLAN get a block, and they are numbered from 1
independently of `wireless.<n>` — in this capture `macacl.1`/`macacl.2` correspond to
`wireless.1`/`wireless.3`. **A join on `devname` is mandatory**; an index-based reading
misfiles the filter onto the wrong WLAN.

Like `bcfilt.<k>`, the `acl.<k>` index carries no meaning beyond grouping, so openUF sorts
the list. Maps onto OpenWrt's `macfilter` (`disable`\|`allow`\|`deny`) + `maclist`, whose
policy vocabulary lines up 1:1 with the controller's.

⚠️ **Two decoys excluded by the same diff.** `wireless.<n>.mac_acl.status` /
`wireless.<n>.mac_acl.policy` sit at `enabled`/`deny` with the control **off** and did not
move when it was toggled — the same shape as `radio.<n>.bcmc_l2_filter.status` was for the
broadcast blocker. `aaa.<n>.radius.macacl.status` is the unrelated RADIUS MAC Authentication
control. Do not re-investigate these.

#### Lock to Access Point (`lock2ap`)

Decompiled from 10.6.106 (`internal-dependencies.jar`, CFR 0.152), 2026-10-10. **Not yet
seen on the wire.** The client doc carries `fixed_ap_enabled` + `fixed_ap_mac` (class
`com.ubnt.data.tQQf`), with no per-band variant anywhere in the jar.

- **Who gets what.** Bean `fixedApConfigService` (`com.ubnt.service.al.ctfbDsCjrxgkv`)
  gives each AP the site's locked clients whose `fixed_ap_mac` is **not** that AP, and
  only while the AP they are locked to is available (`fixed_ap_available`; otherwise it logs
  "Cannot lock Client[{}] to Device[{}], device is unavailable"). The locked AP receives
  nothing for its own clients.
- **Wire shape.** Bean `macAclService` (`com.ubnt.service.al.RPnnqSiu`) turns each MAC into
  a `macacl` entry of type `lock2ap` (enum `USER("user")`, `LOCK_2_AP("lock2ap")`), per VAP:
  - With no user filter, the policy is `deny` and the entries are the locks. A WDS
    downlink VAP gets none.
  - Under a user `allow` filter, the locked MACs are removed from the allow list.
  - Under a user `deny` filter, the lists are merged, and the `user` entry wins on a
    duplicate MAC.
  - A VAP's block is sent when `isMacFilterEnabled() || !locks.isEmpty()`. With neither,
    the VAP has no block, and `macacl.status=disabled` when no VAP has one
    (`com.ubnt.service.config.ubntconf.pASCn`). That absence is how an unlock arrives.

  ```
  macacl.status=enabled
  macacl.1.status=enabled
  macacl.1.devname=ath0
  macacl.1.acl.status=enabled
  macacl.1.acl.policy=deny
  macacl.1.acl.1.status=enabled
  macacl.1.acl.1.mac=00:00:5e:00:53:01
  macacl.1.acl.1.type=lock2ap
  ```
- **When it is re-sent.** A change to a client's `fixed_ap_*` re-provisions the whole site.
  So does a device carrying locked clients changing state ("there are some clients locked
  to it, provisioning all Access Points"). The lock therefore fails open when the locked AP
  goes away, and removing that AP clears `fixed_ap_enabled`.
- **Gate.** `Device.supportLockAp()` = `hasWifiCapability(0x1000000)`. Its only use is the
  site feature check (`com.ubnt.service.J.rGUtaVWZlySeOK`, `case LOCK_AP`): the feature is
  on while every wireless device claims the bit, or while a client is already locked.
  Otherwise the UI is told `NOT_ALL_DEVICES_SUPPORT_FEATURE` (minimum UAP firmware 5.76.0).
  The `macacl` writer itself checks no bit.

openUF claims the bit unconditionally, since the parser already takes every enabled
`acl.<k>` entry whatever its `type`, and hostapd enforces the result. A unit test replays a
lock2ap-only block through `_parse_wifi_system_cfg` + `apply_config` to `macfilter=deny`
with the client in `maclist`, and its absence back to no filter. Hardware tier not yet run.

**The locked AP itself.** Nothing on the wire tells it, so openUF APs exchange their lock
entries over the sibling exchange (authenticated packet v5, `openwrt/siblings.lua`; see
below). A client that a sibling denies and this AP does not is locked here, and openUF
exempts it from steering.
usteer's override `aggressiveness_mac_list` (`"<mac>,<n>"`, read in `sta.c`
`usteer_sta_update_aggressiveness`, usteer 7532e12, 2026-05-19) with `n = 0` makes
`usteer_policy_can_perform_roam()` return false. That function gates both the roam trigger
state machine (`policy.c`) and band steering (`band_steering.c`). `min_snr` kicks, load kicks
and `assoc_steering` don't check it. The override is evaluated only when usteer creates a
station's entry for a node, so `set_config` alone leaves an associated client's old value,
and openUF restarts usteerd on a change. Roaming Assistant skips the same clients. Unit-tested
only.

#### Sibling exchange authentication (`unifi.key`)

Decompiled from 10.6.106, 2026-10-11. `service.config.lwueNrOWUBYJX` writes the system_cfg
`# unifi` block: `unifi.idp` from the site setting `unifi_idp_enabled` (default on), and, only
while that is on, `unifi.mcip=239.254.127.63` and `unifi.key`. The key is
`RPnnqSiu.wpwxm(device)`: the site's `mgmt` setting `x_mgmt_key`, created once as 32 random
hex characters and stored on the site. It is looked up by `device.getSiteId()` alone, so
every adopted device of a site receives the same value. openUF used to drop the block (it
appeared in `/etc/openuf/unhandled.json`).

openUF keys the sibling exchange from it: key = HMAC-SHA256(`unifi.key`, `"openUF sibling
exchange v5"`). Only that derived key is stored (`/etc/openuf/sibling.key`, mode 0600, not
state.json), written when it changes and removed by a full push without `unifi.key` (IDP off).
A v5 packet carries the lock list, the sender's clock and a 16-byte truncated HMAC over the
rest. Lock lists and the BSSIDs backhaul attribution uses come only from v5 packets that
verify and whose clock is within 600 s. The unauthenticated v3 packet is still sent and
accepted, for BSSIDs, models and frequencies, so older APs keep working during an upgrade.
Consequences: with UniFi IDP off, no AP has a key and Lock to Access Point exemptions stop;
an AP whose clock is more than 10 minutes off rejects its siblings' v5 packets. Unit-tested;
not run on hardware.

### `qos.*` — WiFi Speed Limit

Another **top-level section keyed by devname**. Confirmed live 2026-07-18 by creating a
speed-limit profile (33 Mbps down / 17 Mbps up) and assigning it to one WLAN. Note the
per-WLAN toggle does nothing until at least one profile exists in the site settings — with no
profile there is nothing to select and nothing reaches the wire.

```
qos.status=enabled
qos.mode=1
qos.if.1.devname=eth0 / .devspeed=1000 / .type=uplink   # interface inventory
qos.if.2.devname=ath0 / .devspeed=570
qos.vap.1.devname=ath0                                  # join key
qos.vap.1.dwnlink.maxspeed=33000                        # kbps  (UI Mbps x 1000)
qos.vap.1.dwnlink.minspeed=33000
qos.vap.1.uplink.1.devname=eth0
qos.vap.1.uplink.1.maxspeed=17000                       # kbps
qos.ebt.1.cmd=PREROUTING --in-interface ath0 -j mark --mark-or 0x1000 ...
```

| Detail | |
|---|---|
| Units | **kbps**. The UI's Mbps value × 1000. |
| Discriminator | **Presence of `maxspeed`.** Not `qos.status` (global), and *not the block itself*: an unlimited vap still gets a `qos.vap.<m>` block carrying only `minspeed`, set to that radio's raw `devspeed` (570 on 2.4 GHz, 2400 on 5 GHz here). Treating the block as "limited" would cap every WLAN at its own PHY rate. |
| Scope | **Per client.** Corrected 2026-10-11: this row used to say "per-VAP aggregate", inferred from the wire having no per-station structure. The firmware shows otherwise (below): `maxspeed` is each station's cap. |
| `qos.ebt.<n>.cmd` | Literal ebtables fragments that fwmark each VAP's frames both ways (`PREROUTING --in-interface ath0` and `POSTROUTING --out-interface ath0`, `--mark-or 0x1000` for VAP 1, `0x2000` for VAP 2). openUF matches on MAC addresses with `tc` instead (`shaper.lua`). |
| `qos.if.<n>` | The interfaces to build an HTB tree on (`eth0` typed `uplink`, then each VAP) with their link speed in Mbit/s (`devspeed`). |

**What the firmware does with it (firmware-confirmed for 4.0.15).** `ubntbox`'s `do_qos`
writes a script that runs `qosLinkInit.sh 1 <devname> <devspeed>` per `qos.if` (an HTB root
with default class `1:9000`, sfq, ceil = link speed) and
`qosLinkAddVap.sh <devname> <id> <devspeed> <devspeed> <min> <max> <maxclient>` per VAP. The
VAP's class `1:<id>` gets ceil = **link speed**, not `maxspeed`. `maxspeed` is passed down as
the per-station default (`STA_RATE_MAX`, kbps), and the script's own per-station class line
is commented out. The per-station classes come from `libubnt`'s `config_sta_qosrule`
(`add_sta_qosrule` on association, `remove_sta_qosrule` on disassociation): `tc class add
dev <vap> parent 1:<id> classid 1:<(id << 11) + associd> htb rate <min> ceil <dl_maxspeed>
prio <id> quantum 1500` plus an sfq leaf, and the same on the uplink device read from
`/var/run/system.uplink` (`eth0`) with `ul_maxspeed`. It skips a VAP whose `maxspeed` equals
its link speed (no limit). The fw filter maps the VAP mark plus the driver's associd bits to
that classid, so broadcast and multicast (no station) fall to the unshaped default class.
Both directions are queued (HTB egress on the VAP and on `eth0`), nothing is policed.
`update_sta_qosrate` (`rate-update`) runs `tc class change` on one station's classes, adding
them when the VAP had none; a negative `dl_max`/`ul_max` sets that station's ceil to the
link speed, i.e. lifts its cap even on a limited VAP. The controller's UI text agrees: "The
maximum amount of data that can be transferred to a device" (10.4.57 locale,
`SETTINGS_PROFILES_WIFI_SPEED_LIMIT_FORM_DESCRIPTION_LIMIT_BANDWIDTH_DOWNLOAD`).

**`rate-update` is any client's own profile, not only a guest's.** The controller (10.6,
`TtZhv`) builds `{"cmd":"rate-update","mac","ul_max","ul_min":64,"dl_max","dl_min":64}`
from a WiFi Speed Limit profile (`qos_rate_max_up/_down`, `-1` = none). It sends it when a
client's profile is changed while it is online, for every online client of a profile that is
edited, and from the station processor's `qos_policy_applied` latch: once per association
for a guest with `qos_overwrite` or **any client whose profile is not the site default**.
The latch resets when the client roams to another AP or its reported uptime drops
(reconnect). A client moved back to Default gets the Default profile's `-1/-1`.

**openUF (`shaper.lua`, `inform._shaper_resync`)**: per netdev that lists stations, one HTB
class per station matched on its MAC (u32: destination at -14/-12 for download, source at
-8/-4 on an IFB device the netdev's ingress is redirected to for upload), an fq_codel leaf
each, a catch-all class at the WLAN's rate for unicast to (or from) a station not yet seen,
and group-addressed frames unshaped. `rate-update` for any associated MAC goes into
`st.sta_rates` and replaces the WLAN's rate for that client (`-1`: uncapped); it is dropped
when the client leaves or its connected time drops, as the firmware's class is. Changes are
incremental: a station joining or leaving adds or removes only its class and filter.

Evidence, 2026-10-11:
- Docker kernel + iproute2, veth "stations" behind one "VAP", iperf3 both at once:
  per-client classes held 4.72 and 2.80 Mbit/s under 5 and 3 Mbit/s. The police fallback
  held 2.10 and 1.05 under 2 and 1 with openUF's burst, but only 0.78 Mbit/s under 2 with a
  0.1 s bucket. A `-1` override took that client to 9.19 Gbit/s; an unchanged input ran 0
  commands; a client leaving ran 3. u32 keys must be 4-byte aligned (`match u32 ... at -14`
  is `Illegal "match"`).
- Lab, 10.4.57: a 4000/2000 profile on the WLAN pushed `qos.vap.<m>.dwnlink.maxspeed=4000`
  and `uplink.1.maxspeed=2000`; openUF built one 4 Mbit class per mock station. Giving one
  client an 8000/-1 profile brought `rate-update` with `dl_max 8000, ul_max -1` within one
  heartbeat; only that client's class changed, and its upload became `action pass`.
  Dropping its connected time (a simulated reconnect) brought the same `rate-update` again
  on the next heartbeat. Moving it back to Default sent `-1/-1`, which lifted its cap. Removing the
  WLAN's profile tore everything down. `handle_response failed` = 0 throughout.
- Hardware, UCG Ultra 10.6, a temporary SSID with a 5000/2000 profile: the tree built on
  both APs with `tc-tiny` (ath10k and ath9k on the Archer C5, mt76 on the AX3000T), each
  SSID netdev's ingress redirected to its own `oufb<ifindex>`. A phone on 2.4 GHz got class
  `1:10` in both directions; sampled each second at the AP, its upload ran 1.97 Mbit/s over
  the whole 25 s upload window (1.94 over the middle 14 s) and its download 4.54 Mbit/s;
  fast.com showed 4.7/2.1 (a first run showed 2.6 up, which the AP's counters do not bear
  out). The home SSIDs were never shaped; deleting the SSID removed every class and IFB.

### `netconf.*` / `dhcpc.*` / `route.*` / `resolv.*` — IP settings

```
netconf.1.devname=br0
netconf.1.ip=172.19.0.50
netconf.1.netmask=255.255.255.0
netconf.1.autoip.status=disabled
route.1.gateway=172.19.0.1
resolv.nameserver.1.ip=192.168.1.1
resolv.host.1.name=<device name>      # also the source for wps_device_name
dhcpc.status=enabled
dhcpc.1.status / dhcpc.1.devname      # the actual DHCP-vs-static signal
```

**A fresh device's very first post-adopt `setparam` always carries `dhcpc.1.status=enabled`** —
a brand-new device is in DHCP by definition. Acting on that unconditionally (flush + `udhcpc`)
strands the interface if no DHCP server can grant a fresh lease. The revert to DHCP is
therefore only applied when `st.ip_mode == "static"` already, i.e. when genuinely reverting our
own prior static push; first contact and steady-state reaffirmations are a no-op, matching how
real hardware's continuously-running DHCP client needs no manual re-invocation.

**Where it is applied (2026-10-11).** It used to be `ip addr flush/add` on `lan_cpueth`, which
on a DSA board is a bridge port (`lan1`, `wan`) while the address lives on the bridge: the
static address landed on the port and netifd's DHCP client kept the bridge's lease. It is now
UCI on the management interface (`lan_name`, default `lan`): `proto static` + `ipaddr`,
`netmask`, `gateway`, `dns` (or back to `proto dhcp`, the current address kept as the
`ipaddr` hint), committed with a copy of `/etc/config/network` and the same rollback window as
a vlan_filtering plan (`bridge_rollback_timeout`, 180 s): unless an inform succeeds, the copy
goes back. A setting that was rolled back is not applied again until it changes. With the
vlan_filtering backend the plan carries the addressing, as before. **Tier:** unit (mock UCI)
and the 25.12 rootfs with real `libuci-lua` (commit, read back with `uci show`, idempotent
second run, DHCP revert); netifd's reload itself not exercised (no procd there).

### `switch.*` — per-port VLAN

Appears only once the device declares switch capability. Fully mapped live 2026-07-19 by
diffing `system_cfg` across five states. An earlier version of this section claimed the
controller "manages VLAN membership server-side and only needs the device to *accept* the
push" — **that was wrong**, and it is why README claimed the feature worked while no code
existed. The device is sent a complete, actionable VLAN table.

**Baseline (B0) — Port VLAN off**, the state every device sits in until the control is
enabled:

```
switch.status=disabled
switch.vlan.status=disabled
switch.dot1x.status=disabled
switch.jumboframes=disabled
switch.port.1.name=PoE Out + Data   / .opmode=switch
switch.port.2.name=Data             / .opmode=switch     # ... through port 5
```

The `switch.port.N` entries are always present — one per the **model registry's** port count
(5 for U6IW), not per whatever `port_table` openUF reports. They carry only `name`/`opmode`
and never move; they are inventory, not control.

**The discriminator is `switch.status` / `switch.vlan.status` flipping to `enabled`.** Both
sit at `disabled` in B0, so — unlike `wireless.<n>.mac_acl.*` or `radio.<n>.bcmc_l2_filter.status`
— these are genuine gates, not decoys. They are driven by a **device-level** checkbox
(Devices → [AP] → Settings → IP Settings → **Port VLAN**), not by anything per-port, and until
it is ticked the whole per-port VLAN UI is greyed out.

**C1 — Port VLAN enabled, no port override.** The site's VLANs appear as a table:

```
switch.status=enabled
switch.vlan.status=enabled
switch.vlan.1.id=1      / .mode=untagged / .status=enabled
switch.vlan.2.id=20     / .mode=tagged   / .status=enabled
```

`switch.vlan.<m>` is a slot number; `.id` is the real VLAN id. `.mode` here is the VLAN's
device-wide default.

**C2 — port 2's Native VLAN set to the VLAN-20 network.** Three keys are added:

```
switch.port.2.pvid=20              # the port's untagged/native VLAN
switch.vlan.1.port.2.mode=tagged   # VLAN 1 is tagged on port 2
switch.vlan.2.port.2.mode=untagged # VLAN 20 is untagged on port 2
```

So membership is expressed **twice, redundantly**: once per-port (`pvid`) and once as a
per-VLAN-per-port matrix (`switch.vlan.<m>.port.<n>.mode`). The matrix is the authoritative
one — it is what carries tagging, and `pvid` is derivable from it (the VLAN whose mode is
`untagged`).

**`switch.port.<n>` joins directly to `port_table[].port_idx`** — no devname indirection,
unlike `macacl.*`/`qos.vap.*`. Confirmed by the Port Manager UI listing exactly the two ports
openUF reports at the time (not the registry's five) and the override landing on wire index
2, openUF's port_idx 2. This join is why `port_idx` is pinned to a physical socket in the
modelmaps and must not be renumbered: the controller stores a port's settings against it.

**C3 — Tagged VLAN Management → Block All.** One key changes:

```
switch.vlan.1.port.2.mode=exclude   # was "tagged"
```

giving the full mode vocabulary: **`untagged` | `tagged` | `exclude`**, which maps 1:1 onto
swconfig's untagged/tagged/absent port membership.

**C4 — port reverted to default.** The three per-port keys from C2 simply **disappear**, and
the blob returns byte-identical to C1. Teardown is therefore expressible: absence means
default (untagged on the management VLAN, all others tagged), the same "absent block means
disabled" convention used everywhere else in this format.

### `radio.<n>.status` — per-radio disable

Also settled 2026-07-19, in the same session. Setting a radio's **Transmit Power → Disabled**
(Devices → [AP] → Settings → Radios) moves four keys:

```
radio.1.status=disabled            # was enabled
radio.1.txpower_mode=disabled      # was auto
radio.1.virtual.1.status=disabled  # was enabled
wireless.1.status=disabled         # and every other vap on that radio
wireless.2.status=disabled
```

This corrects an earlier reading of this document, which recorded `radio.status=disabled`
only as part of the radio-less `# no wlan provisioned as no radio found` case and concluded
the key carried no per-radio signal. **The indexed `radio.<n>.status` is a real control.**

openUF maps `radio.<n>.status` onto UCI `wifi-device.disabled` and `wireless.<n>.status` onto
each `wifi-iface.disabled`, and reports both back out (`radio_table[].disabled` /
`vap_table[].disabled` already read them off UCI), so the controller sees its own push
reflected. Two details worth keeping:

- The read is **tri-state**. An absent `status` key writes nothing, so a blob that never
  carries it cannot re-enable a radio or SSID the operator disabled by hand in
  `/etc/config/wireless`; only an explicit `enabled`/`disabled` writes. An explicit
  `enabled` must clear the flag, or a radio could never be switched back on.
- Only the **indexed** key is read. The unindexed `radio.status=disabled` in the radio-less
  blob would otherwise take every radio on the device down — the tokenizer's
  `radio.<n>.<key>` shape cannot match a two-component key, so this is structural, but it is
  pinned by a test.

A disabled WLAN is still provisioned, just with `disabled=1`, so its configuration survives
a re-enable.

### `system.timezone` / `ntpclient.*` / `cron.*` — system settings

Carried by every full push, and not read by openUF until 2026-09-25. The yesrab/openUF
fork's capture (2026-09-15) found them; openUF has not yet captured them itself:

```
system.timezone=IST-5:30                    # a POSIX TZ string, not an Olson name
locale.timezone=IST-5:30                    # the same value again
ntpclient.status=enabled
ntpclient.1.status=enabled
ntpclient.1.server=0.ubnt.pool.ntp.org      # x4, slots 1-4
cron.status=enabled
cron.1.status=enabled
cron.1.user=<the site's device SSH user>
cron.1.job.1.status=enabled
cron.1.job.1.schedule=0 4 * * *
cron.1.job.1.cmd=syswrapper.sh 11k-scan
```

The cron job is how the controller schedules the nightly neighbour scan: it runs through
the AP's own crond at 04:00 device-local time. That is why the timezone matters. See USAGE
§ 6 (Controller-managed system settings) for what `sysconf.lua` does with each block.
Upstream openUF answers `11k-scan` with an `iw scan ap-force` of every radio; openUF
deliberately asks a client for an 802.11k beacon report instead, for the 12% packet loss
measured under *Enriching it without scanning* below.
`cron.<n>.user` is deliberately left unrecognized, so it shows in the dropped-key report and
the unhandled ledger.

### `ebtables.*` — L2 hardening

Carried by every full push (the yesrab/openUF fork's capture, 2026-09-15): literal
ebtables fragments, which the stock firmware replays against its `ath<n>` VAPs.

```
ebtables.status=enabled
ebtables.add_vlan.status=disabled
ebtables.<n>.cmd=-t nat -A PREROUTING --in-interface ath0 -d BGA -j DROP     # per VAP
ebtables.<n>.cmd=-t nat -A POSTROUTING --out-interface ath0 -d BGA -j DROP   # per VAP
ebtables.<n>.cmd=-t broute -A BROUTING -i ath1 -p 802_1Q -j DROP             # the tagged SSID's VAP
ebtables.<n>.cmd=-t broute -A BROUTING --vlan-id 10 -p 802_1Q -j DROP        # bridge-wide
```

The `ath<n>` names are the stock firmware's, and they do not map onto OpenWrt netdevs. So
`unifi/hardening.lua` keeps only the two ideas (BPDU drop, tag drop) and
`openwrt/l2guard.lua` applies them to the live AP VAPs. A rule of any other shape is logged
verbatim and not applied. `ebtables.add_vlan.status` is not read, and stays in the
unhandled ledger.

#### The guest chains (`GUESTIN` / `GUESTOUT`) — from the decompile, not yet captured

Source: UniFi Network 10.6.106, `com.ubnt.service.config.ubntconf.YcZSaTCMOYFEMGE`
(the whole `# ebtables` block), `SrOQOGnuakVoL` / `rFCHnXVpfjjP` (`# ipset`),
`DXjFpHAhtGlwvsEEcf` (set names), `ctfbDsCjrxgkv` and `com.ubnt.service.config.hyFnQ`
(subnet sources), `VAZShipWTNxlo` (`wireless.<n>.is_guest`), all decompiled with CFR. No
live capture of a guest push exists yet; `openuf/tests/fixtures/system_cfg_guest_synth.txt`
is synthesised from the generator and says so.

- **The discriminator** is `wireless.<n>.is_guest=true|false`, written for every WLAN
  (`VAZShipWTNxlo`, next to `l2_isolation`, whose default follows it). The guest chains
  are emitted only when at least one WLAN (or a wired guest network) is a guest.
- **Hooks**, per guest VAP: `-t nat -A PREROUTING --in-interface ath<n> -j GUESTIN`,
  `-t nat -A POSTROUTING --out-interface ath<n> -j GUESTOUT`, and, for WPA2 or 6 GHz,
  `-t nat -A GUESTIN --in-interface ath<n> --proto 0x888e -j ACCEPT` (plus `0x886c` and
  `LENGTH` on Broadcom). The guest VAP also always gets the l2guard tag drop
  `-t broute -A BROUTING -i ath<n> -p 802_1Q -j DROP`. A wired guest network
  (`qfbKhmmodhjMTf`) is hooked with `--logical-in br<vlan>` / `--logical-out`.
- **Chain bodies**, in emission order: `-N GUESTIN -P ACCEPT` (`DROP` with a portal),
  `-N GUESTOUT -P ACCEPT`; DHCP request accept (`--pkttype-type broadcast --ip-proto 17
  --ip-sport 68 --ip-dport 67`); ARP accept (`--arp-opcode Request` only without a
  portal); `-N GUEST_DNS -P ACCEPT` (`DROP` with a portal on a dnsmasq-capable AP) with
  UDP/TCP 53 jumping into it; with `fw_caps 0x40000` (`supportIPSet`) a
  `--set guest_pre_allow --set-flags dst -j ACCEPT`; then `-p 0x86dd -j DROP` and
  `--pkttype-type broadcast -j DROP` in both chains, DHCP reply / ARP accept in GUESTOUT;
  `-N CAPTIVE_PORTAL -P RETURN` with TCP 443 jumping into it (accepts
  `config.captive_portal_subnets`).
- **Subnets.** With `supportIPSet`: `GUESTOUT --set guest_pre_allow dst ACCEPT` and
  `GUESTIN --set guest_restricted dst DROP`, the sets sent as `ipset.<n>.name` /
  `.type=hash:net` / `.entry.<m>.value` (`guest_restricted` = `224.0.0.0/4` + every
  `restricted_subnet_<k>`; `guest_pre_allow` = every `allowed_subnet_<k>` + resolved
  allowed hostnames; `guest_authorized_mac` is `hash:mac`, the portal's). Without it —
  openUF's case, `fw_caps 0x110` — inline: `-I GUESTIN -p 0x800 --ip-dst <allowed> -j
  ACCEPT`, `-I GUESTOUT -p 0x800 --ip-src <allowed> -j ACCEPT`, `-A GUESTIN|GUESTOUT
  --ip-dst 224.0.0.0/4 -j DROP`, `-A GUESTIN --ip-dst <restricted> -j DROP`, and the
  (empty, dnsmasq-filled) `ALLOWED_DOMAIN_IN/OUT` / `RESTRICTED_DOMAIN_IN` RETURN chains
  when hostnames are configured. A `/0` restricted subnet becomes `0.0.0.0/1` +
  `128.0.0.0/1`; `/32` is the bare address.
- **Restricted DNS** (`restricted_dns_enabled`): `-N ALLOW_DNS_SERVERS -P DROP`, one
  `--ip-dst <server> -j ACCEPT` per `restricted_dns_servers` entry, and UDP/TCP 53
  **inserted** (`-I`) at the head of GUESTIN into it.
- **Portal** (GUESTIN `-P DROP`): `REDIRECT_HTTP`/`REDIRECT_HTTPS`/`REDIRECT_DNS`
  (`-j mark --mark-or … --mark-target CONTINUE`, `-j redirect`), `AUTHORIZED_GUESTS`
  (`-P RETURN`, `--set guest_authorized_mac src ACCEPT`), `--pkttype-type otherhost -j
  AUTHORIZED_GUESTS`, port 80/443 → redirect, and `-I` accepts / redirects for the
  controller's portal ports.

`-I` matters: the fragments are replayed in order, so the last `-I` ends up first —
restricted DNS above the pre-authorization accepts, those above every drop.

**What openUF does with it.** `unifi/guest.lua` replays every `-t nat` fragment of the
guest machinery (recognised option by option; anything else is reported verbatim and
skipped) into chains in that order, and `unifi/hardening.lua` now counts them instead of
calling them unknown. With a portal on and a usable `redirector.url`, `spec_from()`
keeps the whole ruleset, default-deny included, and leaves the bodies of the four portal
chains to `guestguard` ([Guest portal](#guest-portal-hotspot-what-the-controller-pushes-and-expects),
lab-validated upstream only). Without a URL it drops the portal machinery — the four chains
above, jumps into them, mark/redirect targets, the `hash:mac` set — and turns the portal's
`DROP` policies on GUESTIN and GUEST_DNS into `ACCEPT`, so such a WLAN is restricted like a
portal-less one. `openwrt/guestguard.lua` writes
the chains, policies as final rules, into `bridge openuf_guest` as one `nft -f`
transaction, hooked at prerouting -300 / postrouting 300 (ebtables' nat priorities) on
the guest VAP netdevs, matched by SSID. The EAPOL accept's `--in-interface ath<n>` is
widened to every guest VAP (harmless for an ethertype accept; any other
interface-qualified rule is refused).

**Validated (tier 2, local container, 2026-10-03).** The transaction generated from the
fixture was run with OpenWrt 25.12's `nft` (`openwrt/rootfs:x86-64-openwrt-25.12`) and
Alpine's against dummy ports in a Linux bridge: rc 0, `nft list chain … prerouting`
shows the jump, a second run is rc 0 with the same table (idempotent), `delete table` is
rc 0. Functionally, with a guest netns behind one bridge port and a LAN netns behind
another: before the table every target answered ping; with it, an unrestricted host
answered, a restricted-subnet host did not, the pre-allowed host inside a restricted
subnet did, IPv6 link-local ping did not, and of three UDP/53 probes only the one to the
restricted-DNS server arrived; after teardown the restricted host answered again. Not
validated: a live controller push (the key names, the order and the `is_guest` toggle
are from bytecode), real radios/hostapd, and a board without `kmod-nft-bridge` (the
refusal path is unit-tested only).

#### Guest portal (Hotspot): what the controller pushes and expects

Captured upstream in the 10.4.57 lab on 2026-10-09 (jonasevcik/openUF, C0 discovery). Setup:
`guest_access.portal_enabled` on with `auth: none`, then `PUT rest/wlanconf/<id>
{"is_guest":true}` on the lab WLAN. The `system_cfg` diff across that toggle (310 → 390 lines)
is the whole of what the device is told. `<ctl>` is the controller's IP, and `ath0`/`ath1`
are the guest WLAN's two VAPs.

| Key | Off → on | Meaning |
|---|---|---|
| `wireless.<n>.is_guest`, `aaa.<n>.is_guest` | `false` → `true` | the VAP is a guest VAP |
| `wireless.<n>.usage` | `user` → `guest` | same, the field the stats side keys on |
| `wireless.<n>.l2_isolation` | `disabled` → `enabled` | forced client isolation (already mapped to `isolate`) |
| `redirector.status`, `redirector.https.status` | `disabled` → `enabled` | the AP runs the redirect target |
| `redirector.url`, `redirector.url_https` | (new) `http://<ctl>:8880/guest/s/default/` | where an unauthorized guest is sent |
| `redirector.redirect_pattern` | (new) `http://<ctl>:8882` | |
| `dnsmasq.status`, `dnsmasq.1.devname=br0`, `dnsmasq.1.status` | `disabled` → `enabled` | a local DNS answerer for unauthorized guests |
| `iptables.status` + `iptables.1..3.cmd` | `disabled` → 3 rules | `-t nat -A PREROUTING -p tcp -m mark --mark 0x40000000/0xc0000000 -j REDIRECT --to-ports 80` (0x80000000 → 443; udp 53 → 53) |
| `ebtables.5..51.cmd` | (new) 47 rules | the enforcement itself, below |
| `ebtables.52..53.cmd` | (new) | `-t broute -A BROUTING -i ath<n> -p 802_1Q -j DROP` |
| `qos.status` + `qos.ebt.*`, `qos.if.*`, `qos.vap.*`, `qos.mode=1` | `disabled` → enabled | per-VAP marks (`0x1000`, `0x2000`) and interface speeds: the shaping frame `rate-update` plugs into |

The ebtables ruleset, condensed. These are all `-t nat` rules; `ath<n>` stands for each guest
VAP. This is the first capture of the guest chains, and it matches the decompiled generator
above:
- `-N GUESTIN -P DROP`, `-N GUESTOUT -P ACCEPT`; `PREROUTING --in-interface ath<n> -j GUESTIN`,
  `POSTROUTING --out-interface ath<n> -j GUESTOUT`.
- GUESTIN accepts EAPOL (`--proto 0x888e`), DHCP requests (broadcast, udp 68→67) and ARP.
  It also accepts tcp 8880/8843 to `<ctl>` (the portal) and tcp 8881 to `<ctl>`. Its first
  rule (`-I`) sends tcp 8882 to `<ctl>` to `REDIRECT_HTTP`.
- DNS (udp/tcp 53) goes to `GUEST_DNS` (`-P DROP`). That chain jumps to `AUTHORIZED_GUESTS`,
  then to `REDIRECT_DNS` (mark `0x40000000`, `-j redirect`).
- GUESTIN drops IPv6 (`0x86dd`), other broadcast, multicast `224.0.0.0/4`, and the three
  `restricted_subnet_*` from `guest_access` (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`).
- tcp 443 goes to `CAPTIVE_PORTAL` (`-P RETURN`, empty).
- `-N AUTHORIZED_GUESTS -P RETURN` is **pushed empty**. `GUESTIN -p 0x800 --pkttype-type
  otherhost -j AUTHORIZED_GUESTS` comes before `tcp 80 -j REDIRECT_HTTP` / `tcp 443 -j
  REDIRECT_HTTPS` (marks `0x40000000`/`0x80000000`, `-j redirect`). The device fills the
  chain itself from `authorize-guest`. Whatever leaves GUESTIN unmatched hits its DROP policy.
- GUESTOUT accepts DHCP replies and ARP, and drops IPv6, other broadcast and multicast.

So the controller ships its whole enforcement as ebtables + iptables, and the device's own
parts are the `AUTHORIZED_GUESTS` membership and a local HTTP/DNS answerer for the
redirect marks.

**Station `authorized` is the portal state, and the controller reconciles it every inform.**
`devmgr/dhdeXcHqLRBKMUZk` runs for each `vap_table[].sta_table[]` entry. When the VAP is a
guest VAP and `guest_access.portal_enabled` is on:
- no active guest record, and the station reports `authorized` true → `unauthorize-guest` +
  `guest_kicks++` (`devmgr/l/MiVjHefaf:1448`);
- an active guest record, and the station reports `authorized` not true → `authorize-guest`;
- a guest record over its usage quota → `unauthorize-guest` and the record is ended;
- otherwise nothing.

`is("authorized", true)` defaults a **missing** key to true. Without the field, every
guest-VAP station counts as authorized. Upstream lab: with three mock stations on the guest
WLAN, `unauthorize-guest` was queued for each of them on **every inform**, and `guest_kicks`
reached 77 in about 10 minutes.

**openUF's answer (upstream C1, lab-validated only, 2026-10-09; unconfirmed on hardware).**
Every full `system_cfg` push records the portal WLANs (`unifi/guest.lua` `portal_wlans`):
the `aaa.<n>.id` of each `wireless.<n>.is_guest=true` WLAN, while `redirector.status=enabled`
(it reads `disabled` when the portal is off). This goes to `st.guest_wlans`.
`authorize-guest` / `unauthorize-guest` add the MAC to / remove it from
`st.guest_authorized`. Each `sta_table[]` entry now carries `authorized`: the ledger's answer
on a portal WLAN and `true` elsewhere. Upstream lab, same three mock stations:
- After a force-provision, `guest_kicks` stayed at 1205 over 60 s; before, it rose on every
  inform. `stat/sta` shows the three stations as `authorized: false`.
- A REST `authorize-guest` for `…:01` brought **the first `authorize-guest` cmd ever seen**
  on the next inform. The ledger took the MAC, `stat/sta` showed it `authorized: true`, and
  no `rate-update` came (no `up`/`down` on the record).
- A REST `unauthorize-guest` brought one `unauthorize-guest` (`guest_kicks` 1205 → 1206) and
  nothing after it.
- After an inform restart, an authorized guest stayed `true` and no command was resent.

| Wire (all `{"_type":"cmd", …, "mac":"…"}`) | Sent when |
|---|---|
| `{"cmd":"authorize-guest","mac":…}` | only from the inform reconcile above (openUF: into `st.guest_authorized`). A REST `cmd/stamgr authorize-guest` just writes the guest record (`authorized_by: "api"`, `end`) and sends **nothing** while the station already reports authorized (lab: none queued) |
| `{"cmd":"unauthorize-guest","mac":…}` | REST `cmd/stamgr unauthorize-guest` (ends the record, then the reconcile repeats it while the station still reports authorized: 3 in 30 s in the lab), plus the reconcile and quota paths above. openUF: out of `st.guest_authorized`, then a deauth on every BSS (see below) |
| `{"cmd":"rate-update","mac":…,"ul_max":2048,"ul_min":64,"dl_max":4096,"dl_min":64}` | once per authorization (`qos_policy_applied` latch), when the guest record has `qos_overwrite` (REST `authorize-guest` with `up`/`down` in kbps). The maxima come from the record's `qos_rate_max_up`/`_down`, defaulting to `-1` (no limit). Without an override, the client's user group rate is sent instead (same sender) |

**`unauthorize-guest` disconnects the guest (lab-validated upstream only, 2026-10-10).** UniFi
firmware drops the MAC from `/var/run/guest.authorized` and the authorized ipset, then
runs `kick_sta`: `iwpriv <ath> kickmac <mac>` on every VAP whose `/var/run/vapusage.<ath>`
is `user` or `guest` (`syswrapper.sh` `unauthorize-guest`, `platdep_funcs.sh` `kick_sta`;
firmware-confirmed upstream for 3.9.27 to 4.0.15). It kicks unconditionally, with or without
the portal. Without the kick, the guest stays associated and unauthorized, and its OS never
re-runs captive-portal detection, so it never sees the portal again. openUF does the same
after updating the ledger: a deauth on every BSS through hostapd's ubus `del_client`
(`ucihelper.disconnect_station`, the path `kick-sta` uses). One difference: at most one kick
per MAC per 60 s. The firmware reports `authorized` from the very list it just changed, so
it gets one `unauthorize-guest`. openUF reports it only on the WLANs `st.guest_wlans` names.
If that ever disagreed with the controller, the command would come on every inform, and the
hold keeps it from becoming a deauth storm. Upstream lab, 10.4.57, with a logging wrapper
around its deauth: a REST `unauthorize-guest` brought the cmd on the next heartbeat; the
ledger emptied and one deauth ran per BSS; `guest_kicks` went to 1 and stayed there, and
nothing repeated over the next 60 s.

**The redirect the portal expects** (CFR, 10.4.57, `devmgr/IXbVCbWPDmZdkfbJ`). The initial
redirect handler reads the guest from the query string:
- `id`: the guest's MAC;
- `ap`: the AP's MAC;
- `url`: where the guest was going;
- `ssid`;
- `t`: the AP's epoch seconds. A `t` more than 60 s from the controller's clock is refused.

It stores them in its encrypted `ec` cookie for the login. An `ec` query parameter replaces
all of these with an encrypted cookie made by the AP (keyed by the AP's `guest_token`), but
only on devices with `supportRedirectorInitialEC`, which `redirector.initialec=enabled` would
announce. openUF does not get that key and uses the plain form.

**`guest_token` is required anyway.** Every login path (`"guest authorization"`), and the
`ec` paths, first checks that the AP's device record has a non-empty `guest_token`. If it
doesn't, the controller logs `Missing Guest Token in AP[<mac>] in Site[…] during guest
authorization` and refuses. The portal still answers the browser `{"authorized":true}`, but
no guest record is written and no `authorize-guest` follows. Upstream lab: exactly that,
until openUF reported one. The record's `guest_token` is copied from the device's stats
inform (`devmgr/PGOcbDWlbnYQdFW:1040`, `copyAttrsIfPresent(…, "guest_kicks",
"guest_token")`), so the device names it. Its format is unverified. openUF sends 32 random
hex characters, persisted, while the portal is enforced.

**openUF's enforcement (upstream C2, lab-validated only, 2026-10-10; unconfirmed on
hardware).** Upstream's `guestportal.lua` re-derived the restrictions from the facts in the
rules; the fork keeps its wire-order replay (`unifi/guest.lua`, above) as the one owner of
`bridge openuf_guest` and adds the device's parts of the portal chains in `guestguard.lua`:
`AUTHORIZED_GUESTS` = the `openuf_authorized` MAC set (the `authorize-guest` ledger),
`REDIRECT_HTTP` = mark `0x40000000`, then `ether daddr` set to the bridge MAC plus `pkttype
host` (ebtables `redirect`), `REDIRECT_HTTPS` = drop, `REDIRECT_DNS` = accept. A separate
`ip openuf_guest` table NAT-redirects the marked HTTP to port 8820, and the inform loop
answers there with the `302` above (`openwrt/guestportal.lua`). Upstream lab, 2026-10-10,
with a fake guest in its own network namespace behind a test bridge and a fake gateway
serving `203.0.113.10`, against upstream's tables (the same rules in a different build):
- Unauthorized: `GET http://203.0.113.10/` → `302` to
  `…/guest/s/default/?id=…&ap=…&t=…&url=http%3A%2F%2F203.0.113.10%2F&ssid=probe-wlan`;
  HTTPS timed out.
- The controller accepted that link (`200`), and `POST /guest/s/default/login` answered
  `{"authorized":true,"redirect_url":"http://203.0.113.10/"}`.
- The next inform brought `authorize-guest`. The MAC was in the nft set within the
  heartbeat, and the same `GET` returned the gateway's page (`200`). A `GET` to the AP's own
  address was still redirected, and a host in `10.0.0.0/8` stayed unreachable.
- REST `unauthorize-guest` → the `unauthorize-guest` cmd → the MAC left the set, and the guest
  was redirected again.
- `is_guest:false` on the WLAN → `redirector.status=disabled` → both tables were deleted, the
  listener closed and the guest was free. `is_guest:true` rebuilt everything.

The fork's build of these rules is unit-tested against the same capture
(`tests/fixtures/system_cfg_guest_portal_lab.txt`), not run in that lab. Deliberate gaps:
unauthorized DNS is passed rather than answered locally, marked HTTPS is dropped rather than
answered, and the `redirect` needs an IPv4 address on the guest VAP's bridge.

**`rate-update`, openUF's answer (upstream C3, lab-validated only, 2026-10-10; unconfirmed on
hardware).** A REST `authorize-guest` with `"up":2048,"down":4096` for a mock station brought,
on the next inform, `authorize-guest` and then
`{"cmd":"rate-update","mac":"…","ul_max":2048,"ul_min":64,"dl_max":4096,"dl_min":64}`, in
that order. The values are the REST `up`/`down` unchanged, so they are kbps. openUF keeps
`ul_max`/`dl_max` in `st.guest_rates` for an authorized MAC only (dropped on
`unauthorize-guest`; `-1` = no limit that way). It polices them in `bridge openuf_guest`:
`rate_up` (`ether saddr <mac> limit rate over <kbps×125> bytes/second … drop`) is jumped
before `guestin`, and `rate_down` (`ether daddr`) before `guestout`. They are not queued,
because the VAP's tc root qdisc belongs to the per-WLAN speed limit (`shaper.lua`). Upstream
lab, against its own build of the same rules:
- Full loop with `up:1024, down:3072`: the ledger got the limits and both chains got the rules.
  They were rebuilt from `state.json` after an inform restart, and removed by the next
  `unauthorize-guest`.
- Data path, with the fake guest above limited to 2048 / 4096 kbps, using iperf3 through the
  bridge to the fake gateway:

  | Test | Limit | Result |
  |---|---|---|
  | TCP upload, 20 s | 2048 kbps | 2097 kbps |
  | TCP download, 20 s | 4096 kbps | 4246 kbps |
  | UDP flood, 10 Mbit/s offered | 2048 kbps | 2448 kbps passed (75 % dropped) |
  | Rules flushed (baseline) | none | ~33 Gbit/s |

`ul_min`/`dl_min` (64 kbps guaranteed) are not applied, since policing cannot guarantee a minimum.

`mgmt_cfg` carries `selfrun_guest_mode=pass` in **every** push, guest WLAN or not. Its
source is the site property `config.selfrun_guest_mode`, and any value other than `pass`
goes out as `off` (`config/GWoWvNEX`). It is not in the 10.4.57 UI. The site properties
are the per-site file `data/sites/<site name>/config.properties` (`config/bLwwMKkr` →
the file service by site name), **not** `system.properties`. Upstream lab, 10.4.57: a line
in `system.properties` (restart included) left the wire at `pass`. Writing
`config.selfrun_guest_mode=off` to `data/sites/default/config.properties` made the next
push carry `selfrun_guest_mode=off`, with no restart needed.

**What the AP does with it (UniFi firmware, BZ2 3.9.27 and 4.0.15, read upstream).**
Current firmware is encrypted. These builds are not, and their selfrun code is identical:
- `/bin/mcad` enters SELFRUN (state 3, writes `/var/run/system.selfrun`, calls
  `syswrapper.sh set_selfrun`) once its consecutive-failure count reaches 3 (`fail_count`
  at object offset 0x264, `sltiu …, 3`). The first successful inform calls `unset_selfrun`.
- `/usr/etc/syswrapper.sh` only acts while the portal is on (`redirector.status=enabled`).
  `selfrun_guest()` reads the key from `/etc/persistent/cfg/mgmt`: only `off` is off, so any
  other value, or none, means `pass`.
- `pass`: `ebtables -t nat -F AUTHORIZED_GUESTS; ebtables -t nat -A AUTHORIZED_GUESTS -j
  ACCEPT` ("bypass the guest authorization"). On return, `rm -f /var/run/guest.authorized`
  plus `authorized_guests_updated`: every authorization is forgotten, and the controller
  re-authorizes.
- `off`: `ifconfig $ath down` for every guest VAP (`/var/run/guest_devnames`). The VAP
  scheduler keeps them down while selfrun lasts. On return, `ifconfig $ath up`.

**openUF's answer (upstream C4; lab-validated, and `off` hardware-tested upstream;
unconfirmed on hardware in this port).** It keeps the value as `st.guest_selfrun`, where
only `off` is off. Selfrun starts after 3 failed informs in a row (`GUEST_SELFRUN_FAILS`)
and ends with the first answer. With `pass`, the `selfrun` chain gets an `accept`; it is
jumped from `authorized_guests`, which is the firmware's own position for its ACCEPT. With
`off`, the guest VAPs are taken down with `ip link set` and their names are kept in
`st.guest_vaps_down`, so they come back even across a daemon restart. On return openUF
keeps its authorized list instead of clearing it, because the controller re-authorizes the
same guests either way. Upstream lab, with the controller cut off from the AP by an nft
`reject` on :8080:
- `pass`: three `POST failed`, then "3 informs unanswered, selfrun_guest_mode=pass …
  letting guests through", and the chain held the accept. Once the cut was lifted: "guest
  portal enforced again", and the chain was empty. The guest VAPs stayed up.
- `off` (dummy interfaces, no radios): after the third failure both went DOWN, the chain
  stayed empty, and `guest_vaps_down` was saved. A daemon restart mid-outage kept them DOWN;
  the answer brought them back and cleared the ledger.
- Data path (the fake guest from C2, not authorized): closed → HTTP redirected to the
  portal; open → internet reachable, while a restricted subnet still timed out.

**Hardware, 2026-10-11 (upstream, both its APs, OpenWrt 25.12).** On a real radio,
`ip link set <bss> up` alone leaves the BSS off the air: hostapd does not act on the link
going down, so on the way up it only updates a beacon mac80211 has already stopped.
Reproduced on ath10k: after `ip link set phy0-ap1 down; ip link set phy0-ap1 up`, `iw dev
phy0-ap1 info` showed no SSID and no channel. A guest WLAN now comes back through
`wlansched.set_bss`: link up, then `hostapd_cli -i <bss> raw STOP_AP` and `update_beacon`.
A BSS whose beacon does not restart goes down again and stays in `st.guest_vaps_down`, so
the next answer retries it. Upstream's on-device run of `_guest_selfrun` against a
temporary WPA2 WLAN on ath10k, ath9k, mt76 2.4 GHz and mt76 5 GHz DFS: three missed informs
→ every BSS DOWN with no SSID; one answer → back up with its SSID and channel. The fork's
`wlansched.set_bss` is the same sequence, unit-tested only.

### `atf.*` — Airtime Fairness

The AP's own Airtime Fairness switch, sent only to a device claiming `wifi_caps` bit `0x20`:

```
atf.status=enabled        always, whenever the block is sent (not read)
atf.mode=enabled          the switch: "disabled" when the device's atf_enabled is off
```

`unifi/atf.lua` reads `atf.mode`, and `openwrt/airtime.lua` switches mac80211's scheduler with
it. The evidence, the gate and the OpenWrt counterpart are under
[capability bitmasks](#capability-bitmasks).

---

## The first DSA / 802.11ax board

2026-09-01, Xiaomi Mi Router AX3000T (mediatek/filogic MT7981, OpenWrt 25.12.5) + the same
UCG Ultra. It replaced the TL-WDR3500 in the bedroom. Everything the ath79 boards could not
show, because they are all swconfig and all 802.11n on 2.4 GHz.

### Verified working on the board

Adoption over L3 (identity MAC `00:00:5e:00:53:01`, the board's label MAC, `use_gcm: true`),
LLDP topology (`cid_interface='wan'` → Parent Device *Cloud Gateway Ultra, Port 2*),
per-socket `port_table` including a genuine FE/GbE split and wired clients on the right
sockets, both radios on air, Locate and the LED toggle on the real case LED, and the
tagged-VLAN SSID path.

### A tagged SSID needs no switch trunk on DSA

The swconfig boards need a `switch_vlan` trunk or the ASIC drops every frame of an unknown
VID. DSA needs nothing: with bridge VLAN filtering off — the state a `br-lan` with no
`config bridge-vlan` is in — the switch passes tags straight through, and the 8021q device
on the uplink *bridge port* (`wan.10`) takes its VID before the bridge sees it, because
`vlan_do_receive` runs ahead of the bridge's rx_handler. Confirmed live: `br-openuf10`
holding `wan.10` and the IoT VAP, `wan.10` counting 1.9 MB inbound, the gateway's MAC
learned on it, and untagged wired clients on the other sockets unaffected.

### Per-port VLAN on DSA is a bridge move, not `bridge-vlan`

Same insight, applied to the wired side: assigning a socket to VLAN 10 puts it in
`br-openuf10`, the bridge that already holds `wan.10`. `br-lan` keeps the uplink, the
unassigned sockets and the management address, and nothing runs with `vlan_filtering` — so
a wrong answer here cannot strand the AP, which `config bridge-vlan` on `br-lan` very much
could. It would also have fought the tagged-SSID path for the same `vlan_do_receive`
reason: a `bridge-vlan` for VLAN 10 on `br-lan` would never receive anything, because
`wan.10` takes those frames first.

Confirmed live: port 2 assigned to the IoT network moved `lan2` into `br-openuf10` next to
the IoT VAP, left `br-lan` holding `wan`/`lan4`, and the attached device's frames appeared
on the tagged uplink **byte for byte** — each 342-byte DHCP DISCOVER on `lan2` showed up as
exactly 342 bytes of `wan.10` tx. That counter identity is the cleanest proof the path is
real, and the way to verify a move without relying on the client.

**Turning the feature off does not always announce itself.** The gates were once observed
staying on the wire at `switch.status=disabled`, and openUF treated an absent `switch.*`
block as "say nothing, change nothing" so an older controller or a partial push could not
trigger a teardown. But a device that has HAD Port VLAN on and then has it unticked gets a
full `system_cfg` with **no `switch.*` keys at all** — so the affirmative off signal never
arrived, the teardown never ran, and `br-lan` kept openUF's port list indefinitely. Absence
now counts as off as well, gated on openUF holding a reversibility ledger: that is proof it
applied something, which is proof the controller was sending `switch.*` until now. It is
reachable only inside `type(sys_raw) == "string"`, so a noop response can never trigger it,
and `restore()` spends the ledger so it cannot flap.

An attached client keeps the lease it already held, because the link never drops when a
port changes bridge; a link bounce is what makes it re-DHCP. Scope on DSA is the Native
VLAN — a bridge gives a port one untagged home — and a tagged-only port is refused out
loud rather than half-applied.

### The moved socket must stop learning, or the port is a one-way street

**Correction to this section (2026-09-12).** It previously recorded that an IKEA Trådfri
hub "re-sent DISCOVER once a minute for fifteen minutes without ever accepting an offer"
and filed it under what the client does being its own business. That was openUF's bug, not
the client's.

`br-openuf<vid>` is a software bridge — `wan.10` is an 8021q device the ASIC knows nothing
about — but the moved socket is still a real port on the same ASIC as the uplink, and that
ASIC has one address table. With learning on it files the hub against `lan2`:

```
00:00:5e:00:53:03 dev lan2 self
```

A reply arriving VLAN-tagged on the physical uplink port then *hits that entry*. `lan2` is
no longer in the uplink's bridge port matrix, so the switch resolves the frame in hardware
and drops it instead of punting it to the CPU, where the software bridge would have
delivered it. Exactly the one-FDB hazard that cost the wired clients their gateway in the
`wan.10` case above, reached from the other side.

Captured at three points at once on the AX3000T, hub on port 2:

| | learning on | learning off |
|---|---|---|
| DISCOVER on `lan2` | 4 | 1 |
| same frame on `wan.10` | 4 | 1 |
| same frame on `wan`, tagged | 4 | 1 |
| **any reply, anywhere** | **0** | OFFER + ACK, 2 ms |

**Outbound is perfect in both columns.** That is what makes this class so expensive: the
`/proc/net/dev` counter identity that was offered above as the honest proof of a port move
*passes* while the port is dead, every log line is clean, and the controller shows a
correct config. And a hardware-dropped frame never reaches the CPU, so it is absent from a
capture on the physical port too — the evidence looks like the gateway never answered.

Fixed in `switchvlan.dsa_apply`, which now writes `openuf_brport<vid>_<socket>` with
`learning '0'` for each socket it moves, the same shape `ucihelper` uses for the tagged
uplink. `strings /sbin/netifd` carries `brport/learning`, and the persistence was measured
rather than assumed: forcing `bridge link set dev lan2 learning on` and then reloading the
network put it back to `0`, while the unassigned `lan4` stayed at `1`.

Two costs. One is paid; the other was mispriced and is addressed below.

- an entry the ASIC learned *before* the move cannot be deleted (`bridge fdb del … self` →
  `No such file or directory`, `bridge fdb flush` → `Not supported`) and survives a link
  bounce. It ages out in ~140 s, and the port works from that moment.
- the socket's hosts leave `bridge fdb show dev <socket>`, so `port_table` stops reporting
  who is behind an assigned port. Recorded at the time as costing "an attribution row".

### The attribution row was a client

**Found 2026-09-12 on the AX3000T**, one day after the fix above. The wired IoT device on
the assigned socket was listed in Client Devices under **Cloud Gateway Ultra** at the
gateway's **GbE**, instead of under this AP's **Port 2** at the **FE** that socket had
actually negotiated. `bridge fdb show dev lan2` returned nothing at all, against 2 entries
for `lan4` and 22 for the uplink, both of which still have learning on.

The bridge FDB is not one of several wired-host sources — it is the only one on a DSA board.
Empty it for a socket and that port reports no clients, the controller falls back to whoever
else saw the MAC, and the gateway sees everything.

A second, independent defect surfaced while tracing it: `port_table` resolved the *uplink's*
bridge once and asked it about every socket, so a socket living in any other bridge reported
nothing even with learning on. Masked here by `learning '0'`; real on its own.

#### Why `learning '1'` cannot come back

| Attempt | Outcome |
| --- | --- |
| Learn in software, not in the ASIC | One `BR_LEARNING` flag per bridge port, mirrored into the driver by DSA's `port_bridge_flags`. No split knob exists. |
| Flush the offending ASIC entry | Measured above: ENOENT / EOPNOTSUPP / survives a link bounce, and re-learned on the client's next frame. |
| `locked on` + `mab on` | Locked FDB entries are deliberately *not* pushed to switchdev — the exact split wanted — but `locked` blocks the client until an authenticator authorises it, and authorising means a **static** entry, which *is* offloaded. mt7530 does not offer `BR_PORT_LOCKED` either. |
| Per-bridge FID | `mt7530_port_set_vlan_unaware()` puts VLAN-unaware bridges in transparent/fallback mode on VID 0, so every VLAN-unaware bridge shares one learning domain no matter which Linux bridge owns the port. That *is* the measured failure. |

**The one that would work, and why openUF does not do it.** `vlan_filtering '1'` on `br-lan`
plus `config bridge-vlan` makes MT7531 VLAN-aware; `mt7530_hw_vlan_add()` sets `IVL_MAC`
(independent VLAN learning), so the client's entry would be keyed per-VLAN and the uplink
would be a member of that VLAN — the reply gets forwarded in hardware instead of dropped.
Learning stays on, attribution returns through the ordinary FDB path, and the assigned
socket gains hardware offload it does not have today.

It is blocked on **netifd**, not on the switch:

- netifd's `bridge_enable_member()` deletes the auto-added VLAN 1 from *every* member as
  soon as the bridge has any VLANs, and a member with no explicit `bridge-vlan` entry gets
  no VLAN at all. Every `br-lan` port would need an explicit entry — including the wifi
  VAPs, whose ifnames are generated at runtime and recreated by `wpad` on each wireless
  reload. One missed entry silently blacks out an SSID or the management VLAN.
- OpenWrt [#16314](https://github.com/openwrt/openwrt/issues/16314) is exactly that failing
  at runtime: enabling VLAN filtering does not add WLAN interfaces to the bridge; the
  workarounds are a reboot or a manual `bridge vlan add`. openUF applies controller pushes
  at runtime and never reboots.
- OpenWrt [#9089](https://github.com/openwrt/openwrt/issues/9089): bridge-vlan ports are not
  applied when the bridge was previously empty; a second netifd reload is needed.
- `wan.<vid>` would have to go — 8021q's `vlan_do_receive()` runs before the bridge's
  `rx_handler`, so `wan.10` swallows every VLAN-10 frame before `br-lan` could see it, and
  the uplink cannot be a tagged VLAN member while that sub-device exists. That drags the
  working, verified tagged-SSID path into the same change.

Right architecture, wrong tool for a controller-driven runtime config generator on this
netifd. Recorded here so it is not re-derived.

#### What openUF does instead

A bridge-family nftables tap on the moved socket, filing `ether saddr` into a dynamic set
that `sysinfo.mac_table` reads when the FDB has nothing. It works for the same reason the
original bug existed: the socket's bridge holds a software device, so it cannot be
hardware-offloaded and every frame on that socket reaches the CPU.

```
table bridge openuf_learn {
	set portmacs {
		type ifname . ether_addr
		flags dynamic,timeout
		timeout 5m
		elements = { "lan2" . 00:00:5e:00:53:07 expires 4m34s10ms }
	}
	chain learn {
		type filter hook prerouting priority dstnat; policy accept;
		iifname "lan2" update @portmacs { iifname . ether saddr }
	}
}
```

Verified on the board (nftables v1.1.6): `nft --check` on the generated commands first, then
installed for real, where the tap picked up the wired IoT device's address on the assigned
socket and the controller moved it to **Office AP Port 2 / FE**. Set timeout is 5 minutes to
match the bridge's own FDB ageing, so a host expires exactly as it used to. The FDB always
wins where it has an answer; the tap is only consulted for a socket whose bridge is not the
uplink's, so no other board ever forks `nft`.

#### `mac_table[].vlan` — how a wired client gets its network

Reporting the host was not enough on its own. Credited to the AP's port, the client was
listed under the **management LAN** even though its IP was on the IoT subnet and the Ports
view's own **Native VLAN = IoT** column agreed. Supplying `mac_table[].ip` did not move it,
and neither did a fresh association — so it is not the port's configured native VLAN and not
the IP, both of which the controller already held.

Read out of the 10.6.101 controller (`UniFi/lib/internal/internal-dependencies.jar`,
decompiled with CFR). The wired-client processor iterates the site's layer-2 networks, and
per network keeps only the reported hosts whose `vlan` matches:

```java
// com.ubnt.service.devmgr.isqI
for (VpKpWhVyVFmo host : list) {
    if (network.getVlan() != host.getInt("vlan", 1)) continue;
    ...
}
```

**Defaulting to 1.** Omit `vlan` and every reported host claims the untagged network, which
is exactly what was seen. Two corroborating sites in the same build: the mac_table dedup key
is `mac` .. `vlan` (`wRSpUfdrmMXnppHBKZ`), so one host reachable on two VLANs is two rows
rather than one; and the wired base class copies `vlan` from the report into the client
record, dropping it when it is 1 (`IChoNhjdVpeiMpl`, `QobJuWrHDZesfSeRYc.erGiyFkTC`).

openUF reads the VLAN off the bridge the socket sits in — `br-openuf<vid>` names its own
VLAN — rather than plumbing it down from the `switch.*` push, so it cannot disagree with
where the frames actually go, and leaves it nil for the management VLAN.

With `vlan` and the tap's address both present, the live record reads
`last_connection_network_name: "IoT"`, `vlan: 10`, `last_uplink_name: "Office AP"`,
`last_uplink_remote_port: 2`, at **FE** — every field correct, on a UCG Ultra running
Network 10.6.101.

Note this does **not** contradict the swconfig rule that a socket outside the management
VLAN reports no hosts. There, the Archer C5's WAN socket sits on a VLAN openUF does not
carry, with its CPU port down — the host genuinely is not reachable on the LAN it would be
listed in. Here openUF bridges the VLAN itself and the host is reachable on it.

**Also found and not implemented: `port_table[].mac_table_ipv6`.** The same processor reads
it alongside `mac_table`, mapping each entry's `ip` into the client's `ipv6_addresses`, and
requests it only from devices whose model declares `supportIpv6ClientsReporting()`. openUF
declares no such capability and sends no such list, so this is recorded rather than
guessed at.

### Identity and reported address must come off the same netdev

**Found 2026-09-12 on the AX3000T**, as a gateway alert reading *"IP Address Conflict —
multiple devices are using the same 192.0.2.4 address"* against a network that was
correctly configured.

openUF takes its IDENTITY from `dev.conf.net.lan_cpueth` — that MAC is what the controller
keys the adopted device on and what `lldpd.config.cid_interface` advertises. It takes its
reported IP from the same name, but `announce.get_ip` deliberately hops to the **bridge**
that port is enslaved to, because a bridge member carries no address of its own.

MAC from the port, address from the bridge. That is safe only while the two share a MAC,
which on every swconfig board here they do — `eth1` and `br-lan` read the same address, so
the divergence never existed to be noticed. On DSA it is false: `lan_cpueth` names a
*socket* (`wan`, whose MAC is `board.json`'s `label_macaddr`) while `br-lan` inherits the
DSA conduit's (`eth0`). The AP therefore announced itself as `00:00:5e:00:53:01` while every
frame it sourced — and the ARP entry for the very address it reported — was
`00:00:5e:00:53:02`. Captured on `wan`: `192.0.2.4` sending exclusively from the eth0
MAC. The controller sees one device claiming the IP and another using it.

Not a misconfiguration and not a DHCP problem: this AP is `proto 'static'` with no `udhcpc`
running at all, and `192.0.2.4` sits outside the pool (`.100`–`.254`).

Fixed by `ucihelper.ensure_bridge_identity`, run once at startup from `inform.M.run`: it
pins the bridge's `macaddr` to `lan_cpueth`'s MAC when — and only when — the two differ.
That is what a real UniFi AP looks like, one MAC for identity, LLDP and management traffic.
Adoption is keyed on `lan_cpueth`'s MAC, which is untouched, so the device record survives.

Verified on hardware: `br-lan` went `00:00:5e:00:53:02` → `00:00:5e:00:53:01`, the static
address was unaffected, `192.0.2.4` now sources from the identity MAC, a second restart
logged nothing and reloaded nothing, and the Archer C5 — whose port and bridge already agree
— wrote no `macaddr` and was left entirely alone.

> On a DHCP-addressed board the new L2 identity means a new lease and possibly a new
> address. Adoption is unaffected and openUF reports the change on the next inform, but
> that is why this logs loudly rather than acting silently.

### `radio.<n>.ieee_mode` carries a width, not a PHY generation

The wire says `11nght20` / `11naht40`. Read literally that pins an 802.11ax radio to
802.11n, and the AX3000T's 5 GHz radio came up **HT40 on hardware that does HE160**. The
vocabulary is Atheros-era throughout — the same push names the VAPs `ath0`/`ath1`/`ath2` —
and a real U6-InWall receives the identical string and runs it as HE40. The controller has
no field in which to request a PHY generation at all; that is the device's own business.

Invisible from the controller, which renders the width and got it right. `iw dev` is the
only place it showed. Fixed by taking the width from the wire and the PHY from `iw phy`;
confirmed on both boards, the AX3000T going HE20/HE40 and the Archer C5's 5 GHz going
HT40 → **VHT40** while its HT-only 2.4 GHz radio correctly stayed HT20.

### An HE 2.4 GHz radio is the first that can be over-clamped

`phy_caps` derived a band's max width from the PHY generation, so HE implied 80 MHz on
*both* bands. True while every 2.4 GHz radio here was ath9k; wrong on the first ax board,
where the band still stops at 40 (`board.json` agrees). `clamp_htmode` narrows to 40 only
for kind `HT`, so a pushed HE80 would have reached hostapd, which treats an unprogrammable
width as fatal — the radio simply never starts.

### `/sys/class/leds` lists what drivers registered, not what the case has

The AX3000T's case LED sat a steady orange throughout, and forcing **both** mt76 LEDs to
full brightness changed nothing on it: `mt76-phy0`/`mt76-phy1` are registered by the driver
on every board it supports, wired or not. The real LED is the blue/yellow GPIO pair the
device tree declares, which never registered because the stock filogic image ships no
`gpio-leds` driver — the platform device is there, nothing claims it, and the GPIOs keep
whatever the bootloader set. `kmod-leds-gpio` (9 KB) registers `blue:status` and
`yellow:status`; Locate then blinks the actual box at 4 Hz.

### state.json persisted ten fields it could never read back

`save()` encodes the whole table, `load()` copied back a hardcoded eight. The rest were
written to disk, visible in the file, and nil on the next start — including the per-port
VLAN reversibility ledger, the LED toggle, the locate flag, the static-vs-DHCP guard, and
the identity MAC that `_warn_identity_change` compares against, which made that entire
diagnostic unreachable. Surfaced here because this is the first board whose LED idles at
something other than off, so "the toggle forgets itself on reboot" was finally *visible*.

### 802.11r key holders (`iapp_key`)

openUF used to derive the FT key-holder secret from the passphrase (OpenWrt's
`md5(mobility_domain/psk)`), on the belief that the controller sends no such secret. It does:
`aaa.<n>.iapp_key`. It was never reported as dropped because the dropped-key audit treats the
whole `aaa.<n>.*` namespace as recognized.

**Controller** (10.6 jar, CFR): the wlanconf field `x_iapp_key` is matched against
`[0-9A-Fa-f]{32}` and filled with 32 random hex chars, both by the database migration and for
new WLANs. A WLAN created over REST in the lab came back with the key already set. The
system_cfg emitter writes `aaa.<n>.iapp_key` when `iapp_enabled` is true and the key is
non-empty, and doesn't check `ft.status`. A migration ("Enable all WLAN iapp_enabled by default")
switches `iapp_enabled` on everywhere. Seen on the wire from the 10.4.57 lab and from the 10.x
UCG Ultra: every WLAN except one carried it, with the same value on both radios.

**Firmware** (firmware-confirmed for 3.9.27 to 4.0.15, `ubntbox` and `wpad` disassembled):
- `ubntbox` writes `iapp_key=<hex>` into the hostapd config and, unconditionally,
  `wlan_id=<hex(SHA1("salt" ‖ ssid zero-padded to 32 bytes)[0..1])>`. With `ft.status` on it
  adds `mobility_domain` (`aaa.<n>.mobility_domain` if present, which the controller never
  sends, else that same hash) and `nas_identifier` (the device MAC). It also adds fixed values:
  `r0_key_lifetime=10000`, `r1_key_holder=020055424e54`, `reassociation_deadline=3000`,
  `pmk_r1_push=1`, `ft_over_ds=0`. There are **no `r0kh`/`r1kh` lines and no
  `ft_psk_generate_local`**.
- `iapp_key` and `wlan_id` are options only in Ubiquiti's patched hostapd (2.7-devel).
  - On every association, `wpa_ft_roam` broadcasts an RRB frame (ethertype 0x890d) carrying the
    STA MAC, a timestamp and the `wlan_id`, AES-key-wrapped with `iapp_key`. A peer with the
    same `wlan_id` unwraps it and, if it is under 60 s old, disassociates that STA locally.
  - A second RRB message, also wrapped with `iapp_key`, makes `wpa_ft_rrb_rx` allocate an
    R0KH and an R1KH entry for an unknown sender, with `iapp_key` as their secret.
    `pmk_r1_push` then goes to every peer learned this way.

So UniFi APs **learn** their key holders at runtime, and the shared secret is the
controller's random per-WLAN key.

**openUF** writes the wildcard key holders OpenWrt itself would generate, with that key in
place of the md5:
`r0kh = ff:ff:ff:ff:ff:ff,*,<iapp_key>`, `r1kh = 00:00:00:00:00:00,00:00:00:00:00:00,<iapp_key>`.
OpenWrt reads them only when `ft_psk_generate_local` is 0 (`/usr/share/ucode/wifi/ap.uc`
`iface_roaming`, and `hostapd.sh` on 24.10), so FT-PSK keeps local derivation and FT-SAE/EAP
use the controller's key. Without a key, the md5 fallback still applies.
- openUF also copies the firmware template's `pmk_r1_push=1` and `reassociation_deadline=3000`
  (OpenWrt defaults: 0 and 20000 TU). OpenWrt writes `pmk_r1_push` only on the key-holder path,
  so it matters for FT-SAE/EAP only. Stock hostapd's `wpa_ft_push_pmk_r1` skips an R1KH whose
  address or ID is all zeroes, so the wildcard entry never receives a push. A peer gets pushes
  once it has been learned from its first pull (`wpa_ft_rrb_add_r1kh`, kept for
  `rkh_pos_timeout`, a day by default), which is close to the firmware's learned-peer push.
  `r0_key_lifetime=10000` is already OpenWrt's default. `r1_key_holder` stays unset, so hostapd uses the BSSID,
  because the firmware's fixed `020055424e54` would give every AP the same R1KH-ID.
  Hardware (after a Force Provision): all four FT BSSes on both APs read back `pmk_r1_push=1`
  and `reassociation_deadline=3000` in `/var/run/hostapd-phy*.conf`.
- Lab: the lab controller's push for a new WLAN reached UCI on both radios with
  `x_iapp_key` byte-for-byte.
- Hardware: both APs produced identical `r0kh=`/`r1kh=` lines carrying the gateway's key in
  `/var/run/hostapd-phy*.conf`.
- Forced roams with the new key in place:
  - An FT-SAE client steered with `bss_tm_req` reconnected `auth_alg=ft` with no 4-way
    handshake. It chose the other radio of the same AP, which needs the PMK-R1 fetched from the
    key holder just as a cross-AP roam does.
  - A second FT-SAE client steered across APs was `authenticated` by the target AP with its
    FT AKM already set before association, i.e. the FT authentication including the PMK-R1
    fetch succeeded. The client then never acknowledged the response at -74 dBm and fell back.
  - A third client used PMKSA caching (`auth_alg=open`), which is the client's choice.
  - 2026-10-11, an FT-SAE phone steered from one AP to the other: the first `bss_tm_req`
    was accepted (status 0) and ignored. The second, with `disassoc_imminent`, ended in a full
    SAE + 4-way on the target. At both steers the target AP's hostapd logged
    `l2_packet_send - send: No such device or address`. Its `0x88b7` (RRB OUI, the PMK-R1
    pull/response/push frames) packet socket was bound to ifindex -1, which the kernel sets
    when a bound interface is unregistered. The same hostapd's other packet sockets were on
    `br-lan`'s current ifindex (17), and that ifindex is unchanged since early boot: a later
    recreation would have drawn a far higher one, as the VAPs (48-50) and `br-openuf10` (43)
    did. So `br-lan` was not recreated during the 39 days of uptime. hostapd had started
    10.9 s after boot, and it shares one `0x88b7` socket per `ft_iface` name, freeing it only
    when no BSS uses it any more. Its other sockets are reopened on each BSS reconfiguration.
    The likely cause was a boot-time race: the socket was opened on a `br-lan` that netifd
    replaced during that same boot, and no reload ever released it. A clean reboot of that AP
    (2026-10-11) did not reproduce it: `br-lan` came up as ifindex 7, hostapd's `0x88b7` socket
    was on 7 from the start and stayed there for the four minutes sampled while openUF started.
    The earlier boot had given `br-lan` ifindex 17, so ten interfaces were created before it
    then. What that boot did differently is not known. Until hostapd reopens that socket, the AP can neither pull nor
    answer a pull, so a cross-AP FT involving it cannot succeed. Check with
    `/proc/net/packet`: the `88b7` row of hostapd's sockets must carry `br-lan`'s current ifindex.
    openUF now checks that once a minute and restarts wpad at a cheap moment (`rrbguard.lua`,
    USAGE § 3). The `-1` marker was reproduced on a real kernel (a container: an `AF_PACKET`
    socket for `0x88b7` bound to a dummy interface read `Iface 12`, then `-1` after
    `ip link del`), and `rrbguard.stale()` flagged the second dump and not the first.
  - 2026-10-11, after `/etc/init.d/wpad restart; wifi up` on that AP (its `88b7` socket back on
    `br-lan`'s ifindex): an FT-SAE laptop (`00-0f-ac-9`) that had associated there after the
    restart was steered to the other AP's 5 GHz BSS. A plain `bss_tm_req` was declined
    (status 6, no suitable candidate). With `disassoc_imminent` it accepted (status 0) and the
    target logged `AP-STA-CONNECTED … auth_alg=ft` with no `EAPOL-4WAY-HS-COMPLETED`: ✅ a
    clean cross-AP fast transition, keyed with `iapp_key`, with `pmk_r1_push=1` and the
    3000 TU deadline in place. The log does not say whether the target got the PMK-R1 by push
    or by pull.

The mobility domain deliberately keeps openUF's own hash, not UniFi's. Stock hostapd can't
speak the learned-peer RRB messages, so FT between openUF and a real UAP can't work. A shared
mobility domain would only make clients try it.

The hardware results above are upstream's (2026-10-11, its two APs). In this fork the key
holders, `pmk_r1_push`, `reassociation_deadline` and `rrbguard` are unit-tested only.

### 802.11r was configured, advertised, and not working

Everything visible said fast roaming worked: `ieee80211r=1` and `mobility_domain=82d8`
identical on both APs, the Mobility Domain element in both beacons (`iw` prints it as
`Unknown IE (54): 82 d8 00` — it does not decode element 54, which reads like an absence),
and `PSK FT/PSK PSK/SHA-256 SAE FT/SAE` advertised in the RSN IE. Nothing in the controller
contradicts any of it.

Forcing a roam is what settled it. A station that had negotiated **FT-SAE** reassociated
with `auth_alg=sae` plus a full `EAPOL-4WAY-HS-COMPLETED` — a real fast transition shows
`auth_alg=ft` and no 4-way at all. It failed even between two BSSes on the *same radio*, so
it was never about the APs failing to reach each other.

Cause: openUF pinned `ft_psk_generate_local=1`. Local key generation is **FT-PSK only** —
each AP derives PMK-R0/R1 from the PSK it already holds — while FT-SAE derives PMK-R0 from
the per-session SAE PMK, which no passphrase can reproduce; its PMK-R1 must be pulled from
the origin AP over an `r0kh`/`r1kh` relationship. OpenWrt configures those key holders only
when the option is `0`, and only defaults it to `0` when nothing overrode it. Pinning it to
`1` therefore removed the one mechanism FT-SAE needs, on a `sae-mixed` WLAN where every
WPA3-capable client picks SAE. Measured AKMs at the time: 3× FT-SAE, 3× SAE, 1× PSK,
**0× FT-PSK** — nothing was on the path that would have worked.

Leaving the option unset lets `hostapd.sh` key it on auth type (`psk` → 1, else → 0) and
derive wildcard key holders from `md5(mobility_domain/psk)` — deterministic, so independent
APs sharing an SSID and passphrase compute the same key with no coordination, which is the
same reasoning as the derived mobility domain. Both APs then produced
`r0kh=ff:ff:ff:ff:ff:ff * 8f017bfa84f587a708a51c185973596e`, byte-identical, and the same
forced roam gave `auth_alg=ft` with no 4-way — first between radios on one AP, then across
the two APs, which is the case that needs the PMK-R1 actually pulled over `br-lan`.

The lesson generalises past this option: a wireless feature can be correct in UCI, correct
in the generated hostapd config, correct in the beacon, and still not happen. Only the
station's own state transition proves it.

### Channel choice, for a two-AP site in CZ

`iw reg get` after adoption: 5150–5250 at 23 dBm with no DFS, 5250–5350 and 5470–5725 DFS,
5725–5875 at only 13 dBm. So the non-DFS channels at usable power are exactly **36/40/44/48**
— one 80 MHz block, or two 40 MHz ones. With the other AP on 36+40, this one belongs on
44+48: auto had picked DFS ch 52, which costs 3 dB and a 60 s CAC on every radio start.

On 2.4 GHz auto picked ch 13 because it was genuinely empty. It was also carrying the IoT
SSID, and ch 12–13 are invisible to any client that only scans 1–11 — which most ESP-class
gear does. Moving to ch 11 took that radio from **0 associated clients to 4**.


### The tagged-SSID path, end to end (2026-09-02)

The VLAN-SSID datapath on DSA was the least certain piece of the port. Confirmed hop by
hop on the AX3000T, with the IoT WLAN on VLAN 10:

| Hop | Evidence |
|---|---|
| VAP → VLAN bridge | hostapd's own generated config puts the second BSS on the right bridge: `bss=phy0-ap1` / `bridge=br-openuf10`, while `interface=phy0-ap0` keeps `bridge=br-lan`. The kernel agrees (`phy0-ap1 … master br-openuf10`). |
| Bridge → tagged uplink | `wan.10@wan … master br-openuf10 state forwarding` — the 8021q device on the uplink *socket*, no `config bridge-vlan` and no swconfig trunk. |
| Tagged uplink → the VLAN's DHCP server | `udhcpc -i br-openuf10` from the AP itself took a real lease: **198.51.100.124 from 198.51.100.1**, a different subnet and server from the management LAN the AP is adopted on. |
| Untagged clients unaffected | `phy0-ap0` and the wired sockets stayed on `br-lan` throughout — the regression `7b44a56` fixed on swconfig does not recur here. |

What that leaves unproven is only the 802.11 association itself, which is not openUF's code:
no second radio in the house can act as a station on the IoT WLAN's band, so no client was
put on it. Every hop the AP is responsible for carries traffic.

### Connection timing: what the WiFi Connectivity view counts (2026-09-26)

The Connectivity view (Initial WiFi Connections, the Association/Authentication/DHCP/DNS/Success
percentages and latencies) read **0** with openUF APs while roaming worked. Its data is
`ace_stat.wifi_connectivity_event`, `_class: WIFI_CONNECTION`, and there were none. Traced in
10.6.106 (`devmgr.w.a.VsCpQiCuGEvNvUNmH`, `wifi.connectivity.a.ctfbDsCjrxgkv`,
`wifi.k.fdwW`) and confirmed with hand-sent events:

- For an AP on firmware **6.2.1 or later** (`hyFnQ.supportTrafficStaTrackerEvents`; openUF
  presents 6.8.2) a `success` counts as successful only with **`traffic_delta > 0` and
  `dns_responses > 0`**. `dns_resp_seen: "yes"` is what older firmware is judged by and is not
  read. Anything else goes to a ten-minute in-memory cache and is dropped with its empty
  counters. A hand-sent success with the two fields was stored at once.
- The deltas are **microseconds, cumulative** from the start of the connection, accepted when
  `0 < delta <= 60 000 000` (`Duration.ofMinutes(1).toMillis() * 1000`). The view derives the
  phases as differences: Association = `assoc_delta`; Authentication = the largest of
  `wpa_auth_delta`/`radius_auth_delta`/`auth_delta` beyond `assoc_delta`; DHCP = `ip_delta`
  minus that; DNS = `traffic_delta` minus `ip_delta`; the total is `traffic_delta`. Each phase is
  only counted when it is later than the one before.
- A connection with RSSI below -75 dBm and no success keeps no counters (ignored as weak).
- Failures: `auth_failures`, `wpa_auth_failures`, `radius_auth_status: "failure"`,
  `ip_failures`, `dns_timeouts`, `traffic_failures`, `dns_resp_seen: "no"` each count against
  their phase; zero counts are dropped before storing.

On the AP: hostapd's per-BSS ubus notifications carry `auth` (per Authentication frame, so
several for SAE), `assoc`, `sta-authorized` (with `auth-alg`) and `key-mismatch`. A captured
SAE join on heimdall: three `auth`, `assoc` 260 ms after the first, `sta-authorized` at 310 ms,
DHCP ACK about a second later. A wrong SAE passphrase ends in `key-mismatch` about 3 ms after
`auth`, **with no `assoc`**: SAE checks it in the Authentication exchange. With usteer running
(`notify_response` on), `auth`/`assoc`/`probe` are requests: hostapd waits up to 100 ms and
**rejects the client on any non-zero answer**, and a ucode subscriber whose handler returns
nothing answers `UBUS_STATUS_NO_DATA`. `openwrt/staphase.uc` returns 0 explicitly.

## Wireless uplink (mesh) — ported from yesrab/openUF, 2026-10-03

Everything in this section up to "This port" is **yesrab/openUF's evidence**
(their PROTOCOL-VALIDATION.md and REVERSE-ENGINEERING.md, Investigation 1), gathered on
their two MT7986 APs against a UCG Ultra on Network 10.6.106 and reproduced here with the
addresses and secrets replaced. This repository has no REVERSE-ENGINEERING.md; the parts of
that investigation that bear on the wire are folded in below. None of it has been re-run on
this project's controller or hardware.

### The gate: `wifi_caps` `0x1` (VWIRE), and it gates the backend

The device settings form saves the "mesh-connect" checkbox as `mesh_sta_vap_enabled` with
`PUT /api/s/<site>/rest/device/<_id>`, and a priority parent with
`POST /api/s/<site>/cmd/devmgr {"cmd":"set-priority-uplink","mac":<child>,"prefer1":<parent>}`
(`prefer2` optional; `unset-priority-uplink` clears; the controller's own error,
`api.err.InvalidTarget` "no priority 1 input", names the field). The controller answers the
PUT `rc: ok` either way but **persists the flag only for a device claiming `wifi_caps`
`0x1`** — otherwise `data` is empty and the next read says `false`, the UI's "tick reverts".
Bisected over five masks claimed through `debug_caps`, with a control write that persisted
every time:

| `wifi_caps` claimed | flag persists |
|---|---|
| shipped + MESH `0x80` | no |
| + MESH + MESHV3 `0x800` | no |
| + VWIRE `0x1` + MESH | **yes** |
| + VWIRE only | **yes** |
| + VWIRE + MESH + MESHV3 | **yes** |

The controller then turns the flag **on by itself** (the form's default is
`mesh_sta_vap_enabled ?? true`), so a freshly capable AP gets both VAPs below.

What each bit changes in the push (eight `setparam`s diffed):

- **`0x1` alone** → `connectivity.status=enabled`, `connectivity.uplink_eth=eth0`,
  `connectivity.uplink_bridge=br0`; with the flag on, the **uplink station** and
  `connectivity.uplink_wds=<its devname>`.
- **`0x1` + `0x800`** → also the `mesh.*` block and the **downlink**, with the flag on or off:
  a wired, mesh-capable device is a parent by default.
- **`0x800` without `0x1`** → nothing. **`0x80` (MESH)** → nothing, with or without the others.

The frontend's own names for the bits (Network 10.6.106, `swai.*.js`): `wifi_caps` VWIRE
`0x1`, ZERO_HANDOFF `0x2`, BANDSTEER `0x4`, BANDSTEER_PER_VAP `0x8`, RF_SCAN `0x10`,
AIRTIME_CONFIG `0x20`, BGA_FILTER `0x40`, MESH `0x80`, MIN_RSSI_STRICT_MODE `0x100`,
MULTIPLE_ACL_LIST `0x400`, MESHV3 `0x800`, UNIFI_WIFI_CAP_RADIUS_MAC_AUTH `0x1000`,
HIDE_CH_WIDTH `0x10000`, STA_ONLY `0x2000000`, LOW_PERFORMANCE_MODE `0x4000000`, RF_SCAN_6G
`0x8000000`; `wifi_caps2` MLO `0x1`, MONITOR_RF_SCAN `0x2`, GREEN_AP `0x4`,
DFS_BACKGROUND_SCAN `0x8`, ROAMING_ASSISTANT `0x20`, QUICK_SCAN `0x80`, MESH_MLO_PARENT
`0x4000`, MESH_MLO_CHILD `0x8000`, WIRELESS_UPLINK_ONLY `0x40000`. The UI treats a device as
"wireless uplink only" when its model is a mesh/extender model or it has
WIRELESS_UPLINK_ONLY. Mesh MLO (`wifi_caps2` `0x4000`/`0x8000`) is WiFi 7 MLO meshing and
stays unclaimed.

### What arrives

Child = the device receiving the push, its 5 GHz radio `radio.2`:

```
mesh.status=enabled
mesh.version=3
mesh.essid=vwire-<16 hex>                    ← site setting connectivity.x_mesh_essid
mesh.psk=<32 chars>                          ← site setting connectivity.x_mesh_psk
mesh.serial1=00:00:5E:00:53:01               ← priority-1 parent, only while one is set
connectivity.status=enabled
connectivity.uplink_wds=ath4
connectivity.uplink_eth=eth0
connectivity.uplink_bridge=br0
# the downlink: a hidden WPA2 AP for children
radio.2.virtual.1.devname=vwire3   radio.2.virtual.1.mode=master
wireless.4.devname=vwire3  mode=master  usage=downlink  wds=enabled  vwire=enabled  vport=disabled
wireless.4.ssid=vwire-<16 hex>  hide_ssid=true  parent=radio1
aaa.4.devname=vwire3  wpa=2  wpa.key.1.mgmt=WPA-PSK  wpa.psk=<the same 32 chars>  pmf.status=disabled
# the uplink: a 4-address station toward a parent
radio.2.virtual.2.devname=ath4     radio.2.virtual.2.mode=managed
wireless.5.devname=ath4  mode=managed  usage=uplink  wds=enabled  vport=enabled  vwire=disabled
wireless.5.ssid=vport-<own MAC, no colons>  hide_ssid=true  parent=radio1
aaa.5.devname=ath4  status=disabled            (no key: the station uses mesh.psk)
# plumbing: both join the bridges, tagged for every VLAN the AP carries
bridge.1.port.4.devname=ath4   bridge.1.port.5.devname=vwire3
bridge.2.port.3.devname=ath4.10   bridge.2.port.4.devname=vwire3.10
```

`radio.2.channel` stays `auto`: the controller does not pin a child to its parent's channel,
the station follows the parent. The backhaul ESSID and PSK are site settings (`rest/setting`
key `connectivity`, `x_mesh_essid`/`x_mesh_psk`), not derived. The `vport-<mac>` naming
matches fxkr's 2015 capture of a real UAP's uplink VAP.

**Before this port, openUF provisioned both entries as ordinary access points** whenever a
push carried them (only possible with `debug_caps` claiming the bits): the downlink as a
hidden SSID, the uplink as an **open** AP named `vport-<mac>`. `unifi/wlan.lua` now hands them
to `unifi/mesh.lua` instead (`mode` not `master`, or `usage` not `user`).

### The reporting contract (decompiled)

From the matching Linux package's `internal-dependencies.jar` (UAP inform processor
`com.ubnt.service.devmgr.iceUMDuewFNFLMOqti`, VAP/uplink processor
`com.ubnt.service.devmgr.C.RxFvcetMTlkSFFxK`, names per build; three guessed shapes failed
before it was read):

- The top-level **`uplink` is a string**, the *name* of the uplink interface. Default
  `"eth0"`; `"down"` marks an isolated device. Naming an `if_table` entry takes the wired
  path (identity from the gateway's LLDP); naming a `vap_table` entry of `usage` `uplink`
  takes the wireless path. An object here is read as the default.
- A **wireless uplink is a `vap_table` entry** with `usage: "uplink"`, `name` equal to the
  `uplink` string, `up: true`, a non-zero `channel`, `essid` the site's mesh ESSID (what sets
  `is_mesh_v3`), `bssid` the station's own address, `state` RUN, and a **`sta_table` holding
  exactly one station: the parent's downlink BSS**, with `rx_packets > 0` and the counters the
  controller copies onto the uplink. That station is resolved to a device **by its
  `serialno`**; the fallbacks are a `(vwire|vport)-<12 hex>` ESSID (mesh v2) and an OUI
  derivation that knows only Ubiquiti prefixes — so an OpenWrt board must send `serialno`.
- A **downlink is a `vap_table` entry** with `usage: "downlink"` whose `sta_table` lists the
  children; each resolves by `serialno`, then the controller's BSSID tracker, else "Can't
  resolve wireless mac" and an empty `downlink_table`.
- `uplink_table`, `vwire_table`, `vwire_vap_table`, `downlink_table` and the v2
  `wireless-links` view are **computed by the controller**; device-sent copies are ignored
  (tried bare and with `ap_mac`/`bssid`/`essid`/`type`/`up`). `uplink_bssid` and
  `meshv3_peer_mac` are stored verbatim. The UI's priority-parent dropdown is the device's own
  `uplink_table`.
- A `vap_table` entry whose ESSID starts with `vport-`/`vwire-` but has `usage: user` is
  dropped ("handling is done differently, update AP firmware").

**The parent names its children.** hostapd parks each 4-address peer on its own netdev
(`<bss>.sta<N>`); the bridge learns the child's identity MAC behind it, and the sibling APs
this AP knows say which MACs are site APs. Their intersection is the child's `serialno` when
exactly one sibling is behind the netdev (two would be a grandchild on a multi-hop path).

**The child's half had a cold-boot hole (yesrab/openUF 666f59e, the same evening).** The
child was powered off, cabled off and powered on: the station joined the parent in 40 s,
informs flowed over the hop, the parent named the child — and the controller still drew the
child wired on the gateway's port 2. The uplink VAP's one station had no `serialno`: the
lookup tested scan entries for `is_unifi`/`serialno`, which exist only on the payload's
`scan_radio_table`, while `sysinfo.scan_table()` returns the raw element as `peer_mac`. The
earlier live test had passed because the push names the parent (`mesh.serial1`), and a
device that boots straight onto the air with a matching `cfgversion` never receives that
push. Fixed there by reading `peer_mac` and preferring the BSS actually joined over the
push's parent (which describes the push's topology, not where the station roamed); the
controller flipped the child to `uplink.type: wireless`, the parent as `uplink_mac`, within
one heartbeat. The lesson they drew: the two scan-entry shapes differ, and a test with
hand-built entries proves nothing about which one a caller gets.

**yesrab/openUF's live result (2026-10-03):** cable pulled on the child → station up 20 s
later, joined the parent's hidden downlink at −10 dBm (HE160, `4addr: on`), kept its
address, informed over the hop, a VLAN-10 client behind it kept its network; the controller
showed `uplink.type=wireless`, `uplink_mac` = the parent, `is_mesh_v3`,
`uplink_table=[parent]`, and the parent listed the child as a wireless downlink. Cable back
→ station disabled on the first heartbeat, controller back to the LLDP uplink. Multi-hop not
exercised.

**How it was read, for the next question.** A UniFi OS API key sent as `X-API-KEY` opens the
legacy API (`stat/device`, `rest/device`, `rest/setting`, `cmd/devmgr`),
`/proxy/network/v2/api/...` and the Network app's bundles under
`/proxy/network/manage/react/js/`, so a REST write can be reproduced without the UI. Without
a controller at hand, Ubiquiti's firmware catalogue
(`fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-controller&filter=eq~~channel~~release`)
lists the Network release per platform; the `debian` entry is a `.deb` whose
`usr/lib/unifi/lib/internal/internal-dependencies.jar` is the application (unzip on a
case-sensitive volume, find classes by constant-pool string with `grep -rlaF`).

### This port (2026-10-04)

Split along this repository's rule: `unifi/mesh.lua` parses the `mesh.*` block, recognises
the backhaul VAPs, plans the two sections and shapes the `uplink` fields;
`openwrt/backhaul.lua` runs the wired-first policy and names the peers;
`ucihelper.backhaul_apply` writes `openuf_bh_dl_<radio>` / `openuf_bh_ul_<radio>`
(options checked in 25.12.0's `wireless.wifi-iface.json` and wifi-scripts: `wds` →
`wds_sta=1` in `ap.uc` and `'4addr': !!wds` in `supplicant.uc`, which is also what lets a
station sit in a bridge at all; `hidden`, `ieee80211w`, `isolate`, `vendor_elements`, `bssid`
in the schema; `openuf_*` are openUF's own stamps). Deviations from the fork:

- **Opt-in.** `wifi_caps` `0x801` is claimed only with `wireless_uplink` on. The fork claims it
  by default on DSA boards; here it is unconfirmed on the hardware, and the claim puts a
  hidden BSS on every AP's 5 GHz radio.
- **VLANs do not cross the hop.** The fork's boards rode `br-lan.<vid>`; here the `bridges`
  backend's VLAN bridges ride `<uplink socket>.<vid>` and the `vlan_filtering` backend's
  per-station netdevs get no VLAN membership. Only the management network crosses
  (USAGE.md § Wireless uplink). Not fixed in this port.
- The child's parent is named from the BSS joined first — its raw `peer_mac` (or a decoded
  `is_unifi`/`serialno`) in the station's scan cache, then **the sibling exchange**
  (`openwrt/siblings.lua`, UDP 10011: every openUF AP announces its AP BSSIDs, the hidden
  downlink among them, and the hop is on that LAN), so a station whose scan cache never held
  the downlink's beacon still names its parent — and only then the push's `mesh.serial1`.
  The exchange step is this tree's addition to the fork's fix.
- The uplink VAP's `name` falls back to the section name, never the netdev, so the `uplink`
  string and the `vap_table` entry always agree. The fork's unused `uplink` object fields
  (signal, rates, counters) and the `vport` essid stamp were not ported.
- Backhaul peers are kept out of connection events and the device's and radio's Experience
  score, as well as Minimum RSSI and Roaming Assistant (the fork: the last two only).
- The station's netdev never becomes the remembered wired socket, and before the gateway has
  been seen the board's own uplink socket (`lan_cpueth`) is watched.

**Tiers.** Unit: `tests/test_mesh.lua` (the captured push replayed through
`wlan.parse` → `mesh.plan` → `apply_config` on a recording mock cursor that rejects invalid
section names; the policy; the payload), each guard mutation-tested. Lab: not run — it has no
radios, and a mesh push needs the bits claimed against the lab controller (10.4.57, whose
generator may differ from 10.6.106). Hardware: ⚠️ not run; every AP here is wired.

## Outbound payload field reference

Everything openUF sends. Names were audited against the controller's own Device model
(`com.ubnt.data.cVbZoFIZsWYaVCquTr` and its ~90 nested per-sub-object classes).

### Top level

| Field | Value / notes |
|---|---|
| `_type` | `"state"` |
| `default`, `state` | `not adopted`; `2` connected / `0` unadopted |
| `mac`, `serial`, `model`, `platform`, `hostname`, `ip` | `serial` is the MAC with colons stripped |
| `inform_url`, `cfgversion`, `uptime`, `time` | |
| **`version`** | **Bare firmware version only — never model-prefixed.** See below. |
| `required_version`, `bootrom_version`, `country_code` | `bootrom_version` has no counterpart anywhere in the device schema (closest is `boot_time`, a timestamp); likely ignored, left as-is for want of evidence to rename it to. |
| `mem_total`, **`mem_used`** | Bytes. `mem_used = total − free`; the schema has `mem_used`, not `mem_free`. |
| **`system-stats`** | Hyphenated key, `{cpu, mem, uptime}` — all three **strings**, cpu/mem as percentages. `cpu` is `0` on the very first inform (delta-sampling `/proc/stat` has no prior sample). |
| **`sys_stats`** | Sent beside `system-stats`, as UniFi firmware does: `loadavg_1/5/15` as `/proc/loadavg`'s strings, `mem_total`, `mem_used` (total − free), `mem_buffer` in bytes. The UI's **Load Average**. See [VAP, device and radio fields](#vap-device-and-radio-fields-upstream-8b0ed77-2026-10-10). |
| **`fw_caps`** | `0x110` — see [capability bitmasks](#capability-bitmasks) |
| **`wifi_caps`** | `0x1C` (bits `0x4`, `0x8`, `0x10`), plus `0x20` (Airtime Fairness) and `0x100000` (Private Pre-Shared Keys) where the device can do them, and `0x801` (the wireless uplink) with `wireless_uplink` on — see [capability bitmasks](#capability-bitmasks) |
| `uplink`, `uplink_bssid` | Only while on the wireless uplink and associated: the uplink VAP's name (a **string**) and the BSS joined. Absent otherwise, so the controller's default `"eth0"` and the gateway's LLDP describe a wired uplink — see [Wireless uplink](#wireless-uplink-mesh--ported-from-yesrabopenuf-2026-10-03) |
| **`wifi_caps2`** | `0xF0` — see [capability bitmasks](#capability-bitmasks) |
| `spectrum_scanning` | **Device-level**, not per-radio (the per-radio fields are `spectrum_table`/`spectrum_table_time`). `spectrum_scan_timestamp` is controller-owned: it stamps it itself (ms) from quick-scan results, and nothing reads it from an inform, so openUF does not send it |
| `if_table[]` | `name`, `mac`, `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors` |
| `radio_table[]`, `radio_table_stats[]`, `vap_table[]`, `scan_radio_table[]`, `port_table[]`, `lldp_table[]` | See below |

**Why `version` must be bare.** The upgrade-offer gate in `MiVjHefaf`:

```java
private boolean chgwykfBxZCAuEHPPQ(String string, String string2) {
    return this.TgovGTpPRqBiOa(string) && !StringUtils.equals(string, string2);
}
// object3 = ProductInfo.version         -- e.g. "6.8.2.15592" (bare)
// string  = inform.getString("version")
```

A **strict, unnormalized `StringUtils.equals`** — no prefix stripping, no numeric parsing.
Sending `"U6IW.6.8.2.15592"` never matches `"6.8.2.15592"`, so the "Update Available" banner is
permanent regardless of the actual firmware version. The catalog's version is confirmed bare
by the controller's own startup log: `firmware[U6IW] new version (6.8.2.15592) is available`.

`fw.pre` (`"U6IW."`) remains correct and untouched in `announce.lua`'s L2 discovery
"firmware version verbose" TLV — a different protocol surface. Do not reuse it here.

### Capability bitmasks

| Field | Bit | Controller method | Effect if absent |
|---|---|---|---|
| `fw_caps` | `0x10` (16) | `Device.hasQCASwitch()` = `hasFirmwareCapability(16)` | The Ports view's projection of `port_table` into the device DTO doesn't happen. Wired-client *ingestion* is gated only on `isSwitch()` (a model-registry property), so clients still appear in the list — but the Ports view stays empty. |
| `fw_caps` | `0x100` (256) | `Device.hasOWRTSwitch()` = `hasFirmwareCapability(256)` | Per-port VLAN assignment is rejected outright — see below. |
| `wifi_caps` | `0x4` (4) | `Device.supportBandsteering()` = `hasWifiCapability(4)` | The device-level `bandsteering.status`/`mode` block (the AP's own Band Steering setting) is never emitted. See below. |
| `wifi_caps` | `0x8` (8) | `Device.supportVapBasedBandsteering()` = `hasWifiCapability(8)` | One WLAN without a 2.4/5 GHz pair switches the device-level block to `disabled`. See below. |
| `wifi_caps` | `0x20` (32) | `Device.supportATFConfig()` = `hasWifiCapability(32)` | The controller never emits `atf.*`, the AP's Airtime Fairness switch. Claimed only where mac80211's `airtime_flags` exists in debugfs — see below. |
| `wifi_caps` | `0x100000` | `Device.supportWpaPpsk()` = `hasWifiCapability(0x100000)` | A WLAN with Private Pre-Shared Keys, or UID IoT, is **skipped** ("PPSK is not supported … will be skipped"). Claimed only where OpenWrt's generator writes per-station VLANs and hostapd has VLAN support — see below. |
| `wifi_caps` | `0x1000000` | `Device.supportLockAp()` = `hasWifiCapability(0x1000000)` | The site greys out a client's "Lock to Access Point" (site feature `LOCK_AP`, all wireless devices must claim it). The lock itself travels as `macacl` `lock2ap` entries, which no bit gates. Claimed unconditionally: see [Lock to Access Point](#lock-to-access-point-lock2ap). |
| `wifi_caps2` | `0x40` (64) | `Device.supportAdvertisingDeviceNameInBeacon()` = `hasWifiCapability2(64)` | The controller never emits `wireless.<n>.advertise_ap_name` at all, and doesn't even re-push config on the toggle. |
| `wifi_caps2` | `0x20` (32) | `Device.supportsAssistedRoaming()` = `hasWifiCapability2(32)` | The controller never emits a WLAN's Roaming Assistant (`wireless.<n>.btm_disassoc.*`). Confirmed live in the lab: set, the keys appear on the 5 GHz entry. |
| `wifi_caps` | `0x1` (VWIRE) | backend validator of `rest/device` (`mesh_sta_vap_enabled`); AP config generator | ⚠️ **Claimed only with `wireless_uplink`.** Without it the device's mesh-connect flag is silently dropped; with it the push gains the uplink station VAP and `connectivity.*`. Bisected live by yesrab/openUF on 10.6.106 — see [Wireless uplink](#wireless-uplink-mesh--ported-from-yesrabopenuf-2026-10-03) |
| `wifi_caps` | `0x800` (MESHV3) | AP config generator | ⚠️ **Claimed only with `wireless_uplink`.** With `0x1`: the `mesh.*` block and the hidden WDS downlink VAP. Alone it does nothing |
| `wifi_caps` | `0x80` (MESH) | — | No observable effect on the push (yesrab/openUF, three diffs). Not claimed |
| `wifi_caps2` | `0x10` (16) | `Device.supportsAcsDfs()` = `hasWifiCapability2(16)` | The controller never emits `radio.<n>.blklst` (the site's Auto-channel exclusions) or `radio.<n>.acsdfs` (its 5 GHz DFS switch). Decompiled from 10.6.106 only — see [`radio.<n>.blklst` / `acsdfs`](#radionblklst--radionacsdfs--auto-channel-exclusions-and-dfs). |
| `fw_caps` | `0x1000` | `supportMultiBlockWlanSchedule()` = `hasFirmwareCapability(4096)` | A day's schedule blocks go out under one key (`schedule_<day>`), so the last wins. Claimed since 2026-10-10 — see [WLAN Schedule](#wlan-schedule-wirelessnschedule_). |
| `fw_caps` | `0x400000` | `supportWlanScheduleInvert()` = `hasFirmwareCapability(0x400000)` | The controller sends the complement of the blackout blocks instead of `schedule_invert` + the blocks. Claimed since 2026-10-10 (both readings are implemented). |
| `fw_caps` | `0x20000000` | `supportsRadiusFilter()` | No `aaa.<n>.filter_id`. Claimed since 2026-10-10 — see [RADIUS Filter-Id](#radius-filter-id-aaanfilter_id). |
| `fw_caps` | `0x800000` | `supportHotspot2()` | A Hotspot 2.0 or OSEN WLAN is dropped from the push. Claimed where `hostapd -vhs20` passes — see [Hotspot 2.0](#hotspot-20--passpoint-aaanhs20). |
| `fw_caps` | `0x4000` | `supportsSNMPv3()` | No `snmp.user.1.*` (v1/v2c is sent regardless). Claimed where `snmpd-ssl` is installed — see [SNMP](#snmp-snmp). `0x2000` gates only the UniFi OS (gateway) SNMP path (`config.tmTjAksIyMivqmlnYPu`) and is not claimed. |
| `fw_caps` | `0x80000000` (bit 31) | `supportsMacBasedVlans()` = `hasFirmwareCapability(Integer.MIN_VALUE)` | No `aaa.<n>.accept_mac.*`, and the site feature (Virtual Network Override) is off while any AP or switch with clients lacks it. Claimed where hostapd has VLAN support. **Sent as a negative number** — see [MAC-based VLANs](#mac-based-vlans-aaanaccept_mac). |
| `wifi_caps` | `0x1000` | `supportRadiusMacAuth()` | Nothing: no caller in 10.6.106. Claimed because `aaa.<n>.radius.macacl.*` is applied. |
| `wifi_caps` | `0x10` (16) | `Device.supportSpectrumScan()` = `hasWifiCapability(16)` | REST `cmd/devmgr spectrum-scan` is refused (`api.err.InvalidTarget`) and `stat/spectrum-scan` leaves the AP out, so Airtime Scan does nothing. Claimed (upstream a684980, lab 10.4.57). |
| `wifi_caps2` | `0x400000` | `supportsMulticastSuppressor()` | No `wireless.<n>.multicast.suppressor` and no Aggressive `bypass_types`. Site feature MULTICAST_SUPPRESSOR needs any one AP. Claimed — see [Multicast Suppressor](#multicast-suppressor-wirelessnmulticastsuppressor). |
| `wifi_caps2` | `0x200` | `supportNeighbourInScan()` | Radio AI sends the AP `scan_band`; the per-band neighbour-isolation site features need every AP on the band. Claimed while a sibling scan runs — see [Neighbour isolation](#radio-ai-neighbour-isolation-wifi_caps2-0x200). |
| `wifi_caps2` | `0x2000` | `supportsRoamTopologyStats()` | `sta_roam` is not fed to the roaming detector, and `success` is. Claimed with connection events on — see [Roam topology](#roam-topology-sta_roam-and-assoc_status). |

`wifi_caps2` is a **second, entirely separate** bitmask from `wifi_caps` (which gates
`supportBandsteering()`/`supportZeroHandoff()` and more; openUF claims `0x4`/`0x8`, `0x10`, and
`0x20` (`supportATFConfig()`) and `0x100000` (`supportWpaPpsk()`) where supported, as below).
openUF claims `wifi_caps2` bits `0x40`, `0x20`, `0x10`, `0x80` (quick scan), `0x400000`
(multicast suppressor), `0x2000` (roam topology, with connection events on) and `0x200`
(neighbour in scan, with a sibling scan configured). The mask also gates Mesh MLO and Green
AP, which openUF does not implement and must not claim.

**`wifi_caps` `0x4` + `0x8` (device-level Band Steering): CLAIMED, confirmed in the lab
2026-09-27 (upstream jonasevcik/openUF).** Predicates: `supportBandsteering()` =
`hasWifiCapability(4)` and `supportVapBasedBandsteering()` = `hasWifiCapability(8)`, used by
the AP config generator `com.ubnt.service.config.oHgVgY`'s band steering part (decompiled
from 10.6.101). The setting is the AP's own (Devices → *AP* → Band Steering: Off / Prefer 5G /
Balance, REST `device.bandsteering_mode`), separate from the per-WLAN toggle
(`no2ghz_oui`). The generator emits `bandsteering.status=disabled` when the mode is `off`
(the default when unset), when the site's advanced features switch is off, or when no WLAN
pairs up. A pair is one WLAN's 2.4 and 5 GHz vaps with the same name, security and
passphrase and no wireless uplink. Without `0x8`, a single unpaired WLAN also disables it.
With the device set to Prefer 5G on the lab controller (10.4.57) and two dual-band WLANs:

- Before claiming the bits, setting the mode left `cfgversion` and `provisioned_at` unchanged: nothing to push.
- With `wifi_caps = 0xC` the whole `system_cfg` diff was these added lines:

```
# bandsteering
bandsteering.status=enabled
bandsteering.mode=prefer_5g            (equal for Balance)
bandsteering.1.status=enabled
bandsteering.1.vap.1.devname=ath1      (vap.1 = the 2.4 GHz devname)
bandsteering.1.vap.2.devname=ath3      (vap.2 = the 5 GHz devname)
bandsteering.2.status=enabled
bandsteering.2.vap.1.devname=ath0
bandsteering.2.vap.2.devname=ath2
```

- Off is `bandsteering.status=disabled`, with no mode and no pairs.

openUF reads `status` and `mode` only (`unifi/wlan.lua` `parse_bandsteering`). Prefer 5G
turns usteer's band steering on for the device, in addition to any WLAN's own toggle
(`openwrt/provision.lua` `device_band_steering`). `disabled` never switches the per-WLAN
toggle off, because it also means "advanced features off" or "nothing paired". The pairs are
not read: usteer only steers a client toward a same-SSID 5 GHz interface, which is the
pairing already, so they stay in the dropped-key report. **Balance (`equal`) is not
supported**: it is logged once and changes nothing. usteer balances client counts only
through `assoc_steering`, which rejects association requests and also balances between APs.
`probe_steering` is compiled in but cannot be configured (it is not in usteer's ubus `_cfg`
list or its init script, 2025.10.04 and HEAD). Upstream's lab run of the same logic had 0
`handle_response failed` and logged the `equal` warning once. In this fork it is covered by
unit tests replaying the captured block through `handle_response`.

**Real hardware, 2026-09-27 (upstream jonasevcik/openUF, not re-run on this fork)**: Archer
C5 on upstream HEAD, the real UCG Ultra controller.

- The real controller sends the same block as the lab. The C5 reported `wifi_caps=12`.
- With the device setting unset or Off it sends `bandsteering.status=disabled`.
- On Prefer 5G it sends `status=enabled`, `mode=prefer_5g`, and one pair
  (`vap.1.devname=ath1`, 2.4 GHz; `vap.2.devname=ath0`, 5 GHz) for the dual-band Home WLAN.
  The 2.4-only IoT WLAN gets no pair.
- With the WLAN's own Band Steering off and Roaming Assistant on (upstream keeps usteer
  running for it), the running daemon (`ubus call usteer get_config`) had
  `band_steering_interval: 0`, and openUF had removed the old threshold from UCI. This
  confirms the off switch reaches the daemon. This fork keeps usteer running for Roaming
  Assistant in the same way (`usteer.set_enabled`'s `roam_assist` argument), so here too the
  0 is what stops a daemon that runs with Band Steering off from steering.
- Setting the device to Prefer 5G (WLAN toggle still off) brought the daemon back to its
  default 120000 ms.
- Restoring the WLAN toggle and setting the device to Off left the default interval
  (WLAN toggle on) and `bandsteering.status=disabled`.

The fork's code for all of this is the same logic (`usteer.set_enabled`,
`provision.device_band_steering`), Roaming Assistant argument included.

**Third-party hardware (upstream's code), 2026-09-28** (yesrab fork, `40ed2ce`, their
mt7986/mt76 board, a real UCG Ultra): with the device setting Off, the first push carried
`bandsteering.status=disabled`, and openUF restarted usteer with the old threshold removed.
Same result as on upstream's C5, on a MediaTek board.

**Still unobserved:** an actual 2.4 → 5 GHz steer caused by the device setting alone. No
client that supports BSS Transition was on the C5 at the time. Its two 5 GHz clients have
the BTM bit clear, and usteer only steers clients that have it.

#### Full sweep of the capability gates (controller 10.6.101, 2026-09-27)

Every `has*Capability` predicate on `com.ubnt.data.dChnXOlwHH` (the `Device` class) and
every `radio_caps`/`radio_caps2` bit test on the radio DTO `com.ubnt.i.g.e.DXufmCC` was
traced to its callers, mainly the AP config generator `com.ubnt.service.config.oHgVgY` and
the per-radio WLAN security filter `com.ubnt.service.config.ubntconf.plVcFpIybmrpXclX`.
Calls on `com.ubnt.i.g.OZQcnZuvnRweLFaaG` in oHgVgY check the **model registry**, not
anything the device sends, and are excluded. **This table comes from decompiled code only:
none of the unclaimed rows has been checked on the wire.** openUF sends `wifi_caps = 0x1C`
(`0xC` since 2026-09-27, `0x10` Airtime Scan since upstream a684980), plus `0x20` where it can switch airtime fairness and `0x100000` where
hostapd can put private pre-shared keys on VLANs, and no `fw2_caps`, `fw3_caps` or `hw_caps`
field at all, so each of those reads as 0.

Gates that drop or weaken a feature openUF could implement (each bit openUF claims has its own paragraph under Capability bitmasks):

| Field | Bit | Predicate | Effect while unclaimed |
|---|---|---|---|
| — | — | — | (2026-10-10: the two WLAN Schedule bits that stood here are claimed now, with the rest of the gates listed in the table above.) |

**`radio_caps2` `0x8` (Enhanced Open / OWE): CLAIMED, confirmed in the lab 2026-09-27.**
Predicate: radio DTO `NoFWvUa()`, tested in `plVcFpIybmrpXclX` for an open WLAN with
`wpa3_support` on. Without it an OWE WLAN is dropped from the push entirely (it logs
"WPA3-OWE cannot provision"), and with `wpa3_transition` on it is sent as a plain open
WLAN. The lab confirmed both halves on 10.4.57. With `radio_caps2 = 0x3`, a new WLAN
(`security=open`, `wpa3_support=true`, `wpa3_transition=false`) produced no `aaa`/`wireless`
entry at all. With `0xB` it arrived as:

```
aaa.<n>.wpa.key.1.mgmt=OWE        (no aaa.<n>.wpa, no psk; pmf.status/pmf.mode as for any WLAN)
wireless.<n>.authmode=0
```

With `wpa3_transition=true`, each radio gets **two** VAPs with the same SSID, linked both
ways by `owe_devname`. The oHgVgY generator duplicates the WLAN, sets hide_ssid, and adds
`owe_wpa3_transistion_mode_supplement` to the copy:

```
aaa.1.devname=ath0  aaa.1.owe_devname=ath1  aaa.1.hide_ssid=false  (no mgmt: the open BSS)
aaa.2.devname=ath1  aaa.2.owe_devname=ath0  aaa.2.hide_ssid=true   aaa.2.wpa.key.1.mgmt=OWE
```

OpenWrt 25.12 builds this pair from **one** wifi-iface, `encryption=owe` plus
`owe_transition=1`. hostapd.uc sets up the section twice, once as the hidden OWE BSS and
once as the open BSS. The ucode mac80211.sh gives the open one a second netdev
(`owe_transition_ifname`), which only hostapd knows (`ubus call hostapd bss_info`). So
`unifi/wlan.lua` keeps the open half as a `security="owe", owe_transition=true` VAP and drops
the hidden half. Provisioning both would put two sections with the same radio and SSID into
one section name, and the hidden one would win. Station reporting (and the Minimum RSSI kick
and station events that ride on it), the blocker, the speed limit, l2guard and the
controller's Reconnect read that second netdev from hostapd, so they cover both BSSes.

Both OpenWrt checks are **exact string matches**: hostapd.uc
(`interface.config.encryption == 'owe' && interface.config.owe_transition`) and mac80211.sh
(`v.config.encryption == 'owe' && v.config.owe_transition`), read from the openwrt-25.12
source. This fork writes every other encryption with an explicit cipher suffix
(`psk2+ccmp`, ...), and `owe+ccmp` would fail both checks, leaving a transition WLAN as a
lone hidden OWE BSS. So OWE is written bare: `encryption=owe`. iface.uc then defaults the
cipher to CCMP (`gcmp256` defaults on only for `sae-compat`), so nothing is left to the
board. OpenWrt 24.10 has no ucode generator and its shell hostapd.sh has no
`owe_transition` option at all, so the claim below is never made there.

Two differences from UniFi firmware. OpenWrt names the hidden BSS `<ssid>OWE`, while UniFi
reuses the SSID. Clients follow the transition element either way. The pushed
`pmf.status/pmf.mode` never reaches hostapd: ap.uc forces `ieee80211w=2` on an OWE BSS and
writes 0 on any BSS below WPA2.

Claimed per radio when `sysinfo.owe_supported()` holds. That needs `hostapd -vowe` to exit 0
(it exits 1 on a feature the build lacks; both of upstream's APs' `wpad-mbedtls` pass) and
the ucode generator (`/usr/share/ucode/wifi/hostapd.uc`) to know `owe_transition`. OWE is
probed apart from SAE. In upstream's lab (claim from code via a stub `hostapd` +
`hostapd.uc` in the AP Dockerfile, full `down -v` reset), the transition WLAN landed in the
UCI mock as `encryption=owe`, `owe_transition=1`, `hidden=0`, no key, on both radios, with
`handle_response failed` = 0. This fork carries the same stubs; its lab was not re-run for
the port, and a unit test replays that transition pair through `_parse_wifi_system_cfg` +
`apply_config` to the same UCI. **Hardware tier not yet run**: no OWE BSS has been brought
up on a real AP, and no client has joined one.

**`radio_caps2` `0x2` (FT with WPA3): CLAIMED, confirmed in the lab 2026-09-27.**
Predicate: radio DTO `ytajcagDggPuTaL()`, tested in `plVcFpIybmrpXclX`. Without it
the controller forces `wpa3_fast_roaming` off on every SAE WLAN, and on a WPA3-only one
(no transition) it forces `fast_roaming_enabled` off too. openUF now sends
`radio_caps2 = 0x3` on each SAE-capable radio. The same gate exists on 10.4.57: on the
lab controller two WLANs, both with Fast Roaming and WPA3 fast roaming on (one WPA3-only,
one WPA2/WPA3), went out as follows across the switch from `0x1` to `0x3`:

```
                          radio_caps2=0x1     radio_caps2=0x3
WPA3-only  ft.status      disabled            enabled
WPA3-only  wpa3.ft.status disabled            enabled
WPA2/WPA3  ft.status      enabled             enabled
WPA2/WPA3  wpa3.ft.status disabled            enabled
```

Those keys, on both radios' copies of each WLAN (six lines), were the whole diff across
474 `system_cfg` lines. So before this change a WPA3-only WLAN never got 802.11r from
openUF. A mixed WLAN already had it, because openUF enables FT when either toggle asks.
The captured WPA3-only block replays through `_parse_wifi_system_cfg` + `apply_config` to
`encryption=sae+ccmp` (this fork writes the pushed cipher), `ieee80211w=2`, `ieee80211r=1`
(unit test). The lab AP claims SAE through a stub `/usr/share/ucode/wifi/ap.uc` in its
Dockerfile, since `sysinfo.sae_supported()` reads that file. The capture above was taken
upstream (jonasevcik/openUF) with identical claim code; this fork's lab was not re-run for
the port. Hardware tier (FT-SAE roam on a WPA3-only WLAN): not yet run.

The two schedule bits are claimed since 2026-10-10, with the schedule implemented (see
[WLAN Schedule](#wlan-schedule-wirelessnschedule_)).

Gated, and not to be claimed:
- **No OpenWrt equivalent, or out of scope:**
  - `radio_caps2` `0x4`: WPA3-Enterprise-192.
  - `radio_caps2` `0x400` and `wifi_caps2` `0x1`/`0x4000`/`0x8000`: MLO and Mesh-MLO.
  - `radio_caps` `0x20000`: `radio.<n>.hard_noisefloor.*` / sensitivity level, a QCA RX-sensitivity setting.
  - `wifi_caps` `0x4000`/`0x8000`: multi-vport and Element. (`0x1`/`0x800`, vwire and meshv3, are claimed with `wireless_uplink`; `0x80` does nothing — see the table above.)
  - `wifi_caps` `0x2000` "open hostapd", `0x40` `bga_filter`, `0x4000000` low-performance mode.
  - `wifi_caps2` `0x4` Green AP, `0x20000` (an AP-group check, purpose unclear).
  - `fw2_caps` `0x80000` RadSec (no RadSec client on OpenWrt 25.12, see [Hotspot 2.0](#hotspot-20--passpoint-aaanhs20)), `0x20` `port_table.mac_table_ipv6`, `0x80` device command retry.
- **No callers in the controller**, so a bit does nothing: `supportMinRateCtrl` (`wifi_caps`
  `0x200`), `supportMultiAclList` (`0x400`), `supportHideChWidth` (`0x10000`),
  `supportZeroHandoff` (`0x2`). `supportRadiusMacAuth` (`0x1000`) has no caller either and
  is claimed since 2026-10-10 because the feature is applied. ⚠️ This list came from the
  config generators only, and two entries on it were wrong: `supportLockAp` (`0x1000000`)
  gates the site feature `LOCK_AP` (claimed since 2026-10-10, see
  [Lock to Access Point](#lock-to-access-point-lock2ap)), and `supportsRoamTopologyStats`
  (`wifi_caps2` `0x2000`) is read by the stats ingest (`devmgr.w.a.RPnnqSiu`,
  `VsCpQiCuGEvNvUNmH`, `wifi.connectivity.c.gyWdIcvdh`), not by a config generator
  (claimed since 2026-10-10, see [Roam topology](#roam-topology-sta_roam-and-assoc_status)).
  2026-10-10 also moved `fw_caps` `0x800000` (Hotspot 2.0), `0x20000000` (RADIUS
  `filter_id`), `wifi_caps2` `0x200` (neighbour in scan) and `0x400000` (multicast
  suppressor) out of this list: each is claimed, with its feature.

**The per-port VLAN validator** (`com.ubnt.ace.api.e.VVyiC`, reachable only once
`hasQCASwitch()` is true):

```java
private void chgwykfBxZCAuEHPPQ(UCthhvfQNZ port, boolean hasOWRTSwitch, boolean hasSwitchVlanCap8) {
    nwTNVfYOnNbEWSoCkPq.guoZiIiLhURleoJ(port).ifPresent(forwardMode -> {
        if (!((forwardMode != ALL && forwardMode != CUSTOMIZE) || hasOWRTSwitch)) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
        if (hasSwitchVlanCap8 && forwardMode NOT IN {CUSTOMIZE, NATIVE, DISABLED}) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
    });
}
```

For a port with no explicit `forward` override — the default `ALL` mode, true for every port
openUF sends — the first branch collapses to `!hasOWRTSwitch()`. Without bit `0x100`, **every
default-mode port is unconditionally rejected** with `api.err.VlanTaggingUnsupportedByDevice`,
before `vlan_caps` or anything port-specific is consulted. (Sweeping `switch_caps.vlan_caps`
through 0/3/4/5/6/7/15/31/255 only changed *which* of two near-identical errors fired.)
"OpenWrt switch" as opposed to a QCA hardware switch ASIC is, fittingly, exactly what this is.

**`wifi_caps` `0x20` (Airtime Fairness): CLAIMED.** Ported from upstream jonasevcik/openUF
(fd30306, 7afc7e8). The lab and hardware runs below were made there, on upstream's code;
this fork's port is covered by unit tests only.
Predicate: `supportATFConfig()` = `hasWifiCapability(32)`, the only test in oHgVgY's ATF
generator. The setting is the AP's own (device panel, REST `device.atf_enabled`). Captured
on 10.4.57 with the bit set:

```
# airtime fairness
atf.status=enabled                 (always, whenever the bit is set)
atf.mode=enabled                   (atf_enabled=true; "disabled" for false)
```

`atf.mode` is `enabled` only when the site's `mgmt.advanced_feature_enabled` is also on.
10.4.57 writes that back to `true` even on a full-object REST PUT, so in practice the mode
follows `atf_enabled` alone. Its default is true for every model but U7-NHD, UHD-IW,
UFLHD and UDMB (`getDefaultAirtimeFairnessEnabled`). For the 14 models in
`shouldBlockChangingAirtimeFairnessSettings()`, the device-update hook
(`devmgr.c.offwZmbh` in 10.6.101) copies the old `atf_enabled` back over any change, so their
switch is frozen at the default. The list has `UAIW6`, a MediaTek model, but not `U6IW` (QCA),
the model openUF presents, so the toggle goes through. The same check exists in 10.4.57, where
the REST toggle on the lab's U6IW took effect.

The OpenWrt counterpart is mac80211's airtime scheduler, not hostapd. Every station gets
weight 256, and its deficit is charged from the TX/RX airtime the driver reports. It is on
by default: read-only on 2026-09-27, all four radios of both upstream APs (ath10k + ath9k on
the C5, mt76 on the AX3000T) showed `airtime_flags` = `AIRTIME_TX | AIRTIME_RX` and
per-station `airtime` files with moving TX/RX totals and deficits. So `enabled` is left as the
kernel default (openUF writes `3`), and `disabled` writes `0` to
`/sys/kernel/debug/ieee80211/phy*/airtime_flags`, after which no airtime is charged and
the scheduler is plain round-robin. hostapd's `airtime_mode` (UCI `wifi-device`
`airtime_mode`, in the 25.12 schema and generator) only picks static, dynamic or limited
per-BSS **weights** on top of that scheduler. None of its modes turns it off, so it is not the
counterpart. The value is kept as `st.atf_enabled`, because debugfs resets to `3` at boot
and the controller does not push again, and it is reapplied at startup
(`inform._reapply_airtime`). Forgetting the device writes `3`.

Lab (upstream, full `down -v` reset, claim from code via a tmpfs over `/sys/kernel/debug`
with stub per-phy files seeded by the AP entrypoint): the device reported `wifi_caps` `0x2c`
(`0x20` plus upstream's Band Steering bits). Toggling `atf_enabled` over REST pushed
`atf.mode=disabled`, both stub files became `0`, and `state.json` got
`"atf_enabled":false`. After both files were reset to `3` and inform was restarted, the
startup reapply wrote `0` again. Toggling back pushed `enabled`, and both went to `3`.
`handle_response failed` = 0 throughout.

Hardware (upstream), 2026-09-27 (both APs on fd30306, real UCG Ultra): both devices
reported `wifi_caps` 44 (0x2C), and the controller had **`atf_enabled: false`** stored for
both. That setting was inert while the bit was unclaimed, but it would have switched the
scheduler off at the next push. It was set to true over REST, the push carried
`atf.mode=enabled`, and on all four radios (ath10k, ath9k, mt76 ×2) the write read back as
`AIRTIME_TX | AIRTIME_RX` with no error. `state.json` holds `"atf_enabled":true`. **Not yet
run on hardware:** the off direction (a real write of 0, and per-station airtime totals
stopping).

**Off on third-party hardware (upstream's code), 2026-09-28** (the yesrab/openUF fork,
reported in their PROTOCOL-VALIDATION.md at `40ed2ce`; their mt7986 board with mt76 radios,
a real UCG Ultra). The first push after their deploy carried `atf.status=enabled`,
`atf.mode=disabled`, because the controller had held the setting off from before the bit was
claimed. Both phys' `airtime_flags` then read back empty, i.e. `0`. This is their evidence,
not ours or upstream's.

**`wifi_caps` `0x100000` (Private Pre-Shared Keys): CLAIMED.** Ported from upstream
jonasevcik/openUF (1cd2f0b). The capture and the lab run below were made there, on
upstream's code; this fork's port is covered by unit tests only.
Predicate: `supportWpaPpsk()` = `hasWifiCapability(0x100000)`. Without it the lab controller
logged `PPSK is not supported by <mac> and WiFi[ouf-ppsk] will be skipped` and sent no
`aaa`/`wireless` entry for the WLAN. The emitter is `com.ubnt.service.aF.hEiVLGSwaf`, called from
oHgVgY's PSK branch when `isPrivatePresharedKeysEnabled()`. Its key list comes from
`aF.cZldsW`, which maps each key's `networkconf_id` to that network's VLAN and **drops keys whose
network is not a local-site layer-2 network**. Captured on 10.4.57 with `wifi_caps` `0x10002C`,
REST `private_preshared_keys` = one key each on Default, a VLAN-20 and a VLAN-30 network:

```
aaa.<n>.wpa.key.1.mgmt=WPA-PSK
aaa.<n>.wpa.psk=<random 32 characters>   (passphrase_autogenerated: REST replaced ours)
aaa.<n>.dynamic_vlan=1                   (OPTIONAL)
aaa.<n>.wpa.psk_file.status=enabled
aaa.<n>.wpa.psk_file.1.psk=<key>         (Default network: VLAN 1, so no vlanid)
aaa.<n>.wpa.psk_file.2.psk=<key>
aaa.<n>.wpa.psk_file.2.vlanid=20
aaa.<n>.wpa.psk_file.3.psk=<key>
aaa.<n>.wpa.psk_file.3.vlanid=30
```

on both radios' entries, with `br.devname=br0` and **no** `vlan.*`/`bridge.*`/`netconf.*` block for
VLAN 20 or 30: a UniFi AP creates those interfaces as clients arrive. The generator emits no
vlanid for VLAN 1 (`if (1 != vlan)`), so such a key's client stays on the VAP's own network.

The OpenWrt counterpart exists in 25.12 as is (read on upstream's two APs, 2026-09-27, and
re-read for this port in the 25.12 branch's `ap.uc` and `wireless.wifi-station.json` /
`wireless.wifi-vlan.json` schemas). netifd attaches a `wifi-station` section and a `wifi-vlan`
section to the wifi-iface named in its `iface` list; **one without `iface` applies to every
VAP**. `ap.uc` writes each station as a `vlanid=<vid> <mac> <key>` line of hostapd's
`wpa_psk_file` (and `<key>|mac=…|vlanid=…` into `sae_password_file` for SAE), each VLAN as a
`<vid> <ifname>-<name>` line of `vlan_file`, and emits `vlan_no_bridge` etc. only with
`dynamic_vlan` set. netifd puts the `<ifname>-<name>` netdev into the bridge of the VLAN's
`network`. Both upstream APs run `wpad-mbedtls`, whose binary has
`Assigned VLAN ID %d from wpa_psk_file`. The claim is gated on that string plus `vlanid=` in
`ap.uc` (`sysinfo.ppsk_supported`).

openUF writes a `wifi-station` per key and a `wifi-vlan` per VLAN (tied to the VAP by `iface`),
and `dynamic_vlan=1` on the VAP. With the per-VLAN-bridge backend each key's VLAN gets the
`br-openuf<id>` a tagged SSID uses (`ensure_vlan_network`); on this fork's DSA-only boards no
switch trunk is needed, so upstream's swconfig trunking of key VLANs has no counterpart here.
With the `vlan_filtering` backend a key joins the plan's `openuf_v<vid>` interface (or the
management interface for the Management VLAN). The push carries no bridge for a VLAN only a
key uses, so openUF adds every key's VLAN to the plan itself: tagged on the uplink like the
push's own VLANs, with an `openuf_v<vid>` interface (`netmodel.plan`'s `key_vids`). ⚠️ netifd
attaching a `wifi-vlan` netdev to a filtering bridge is the same mechanism as for a VAP, but
unverified. A key whose VLAN still has no network is left out, never provisioned onto the
VAP's own network. A client on a VLAN netdev is listed only by that netdev's station dump, so station
reporting, the blocker, the speed limit and l2guard include the netdevs netifd reports under
`interfaces[].vlans[].ifname`; Minimum RSSI kicks and Roaming Assistant requests go to the
VAP's own hostapd, since a VLAN netdev has no hostapd of its own. UID IoT also
passes this gate. It adds `aaa.<n>.wpa.psk_radius` = 0/1/2 (enum decompiled from 10.6.101,
**not seen on the wire**, no UniFi Identity in the lab); openUF skips a WLAN with `2` unless the
push names a RADIUS server for it (only with RADIUS MAC authentication on), and then writes `ppsk=1`. A key is refused unless it is 8–63 printable ASCII
characters or 64 hex digits, hostapd's own limits for a line of the file it lands in.

Lab (upstream, full `down -v` reset, claim from code via probe strings in the AP's
`ap.uc`/`hostapd` stubs): the device reported `wifi_caps` `0x10002c`, the push above arrived,
and the lab's UCI held per radio one `wifi-iface` (`dynamic_vlan=1`, `network=lan`), three
`wifi-station` sections (`vid` absent/20/30), two `wifi-vlan` sections (`network`
`openuf_vlan20`/`openuf_vlan30`), and both VLAN bridges. Turning PPSK off over REST removed all
of it, including the bridges. `handle_response failed` = 0 throughout. **Not yet run on
hardware:** a client joining with a VLAN key and landing on that VLAN
(`logread | grep "from wpa_psk_file"`, DHCP from the VLAN).

### `radio_table[]` entry

| Field | Notes |
|---|---|
| `name` | UCI device name (`radio0`) |
| **`radio`** | **The band** (`ng`/`na`), from `band_for_channel()` — channels 1-14 → `ng`, else `na`. Parsed by `com.ubnt.g.f.e.rYtJfMBbtgWvku`'s `String.toLowerCase()` factory, which has **no null guard**: omitting this field throws an NPE inside the controller's adopt processing on *every* inform, corrupting its UI-facing device cache (Devices list shows "No UniFi Devices Have Been Adopted" while Mongo says adopted). 60 GHz/6 GHz aren't disambiguable from channel number alone and are unsupported. |
| `channel` | Live negotiated channel from `iw dev`, more authoritative than UCI's value (frequently the literal `"auto"`, which the controller will not resolve to a number) |
| **`ht`**, **`tx_power`** | Not `htmode`/`txpower` |
| `disabled`, `builtin_antenna`, `builtin_ant_gain`, `max_txpower` | |
| `nss`, `is_11ac`, `is_11ax`, `is_11be`, `has_dfs`, `has_fccdfs`, `has_ht160`, `has_eht240`, `has_eht320` | Read directly off each entry by `PGOcbDWlbnYQdFW`'s `copyAttrsIfPresent`, **independent of `radio_caps`**. Derived by `sysinfo.radio_caps()` from `iw phy phyN info`. |
| **`radio_caps`** | A separate **integer bitmask**, not `nss`. See below. |
| **`radio_caps2`** | `0x3` on an SAE-capable radio (`0x1` WPA3, `0x2` FT with WPA3), `0` otherwise, plus `0x8` (Enhanced Open) where hostapd has OWE. See [Capability bitmasks](#capability-bitmasks). |
| `min_rssi`, `min_rssi_enabled` | `min_rssi` is **dBm** on the wire (the raw `stamgr` value - 95, the controller's own encoding) |
| **`athstats`** | Nested `{cu_total, cu_self_rx, cu_self_tx, cu_interf, satisfaction}`, plus `ast_txto`/`ast_cst` on ath9k radios. See below. |

**An empty `radio_table` blocks a large amount of downstream behavior.** The controller checks
`if (list3.isEmpty()) { … "Missing radio_table in inform…" }` and this is exactly the
"no radio found" condition that suppresses WLAN provisioning. Real OpenWrt hardware has genuine
`wifi-device` sections populated by the driver at boot, independent of any configured SSID.

**`radio_caps` MIMO bits.** The controller's Java side only ever passes this int through
verbatim (`uCthhvfQNZ2.put("radio_caps", uCthhvfQNZ3.getInt("radio_caps", 0))`); the decode into
`"1x1"`…`"4x4"` happens **client-side only**, in the Radios tab's `mimo: e7(radio.radio_caps)`.
Reverse-engineered by calling the live `e7` decoder through the webpack module registry with a
single-bit sweep:

| `nss` | bit |
|---|---|
| 1 | `0x8` |
| 2 | `0x10` |
| 3 | `0x20` |
| 4 | `0x4000000` |

Checked highest-first when multiple bits are set. It is **not** simply `radio_caps == nss`
(live-tested and refuted). Left at the default `0`, the MIMO column is blank *and* the
1x1–4x4 filter checkboxes exclude the radio outright rather than merely filtering it wrong.

**`athstats` is required for the "Avg. Interference"/"Avg. Airtime" columns.** The archiver
method `com.ubnt.service.system.x.htDMji` iterates `radio_table` — not `radio_table_stats`, not
`vap_table` — and:

```java
if (!uCthhvfQNZ.containsField("athstats")) continue;
```

then reads `cu_total`/`cu_self_rx`/`cu_self_tx`/`satisfaction`/`cu_interf` off that nested
sub-object. Sending the same four fields on `radio_table_stats` and `vap_table` (both real, both
used by other paths) leaves every archived bucket without them. Named after the legacy Atheros
`ath9k`/`ath10k` stats struct UniFi firmware historically exposed under this name.

**`athstats.satisfaction`** (UniFi Network 10.6.106, CFR decompile). The AP inform handler
(`com.ubnt.service.devmgr.iceUMDuewFNFLMOqti`, radio loop; the same code in
`IPBUmPKpJrymtFQry` and, for gateways, `unLiwXHYlFDg`) ends each radio with

```java
radioStats.put("satisfaction", radio.getX("athstats", Empty).getInt("satisfaction", -1));
```

so `-1` is the controller's own "no score". The 10.6 archiver
(`com.ubnt.service.system.v.fdwW`, radio_table loop) archives `cu_total`, `cu_self_rx`,
`cu_self_tx` and `satisfaction` as `<radio name>-<field>` and `<band>-<field>`, skipping only
`satisfaction == -1` (`getInt("satisfaction")`, whose default is 0, `ZMUWuPFvCIO.getInt(String)`).
Before this field was sent, every radio with `athstats` was archived at satisfaction 0. openUF
now sends the firmware's roll-up (`calc_radio_satisfaction`: the radio's VAP scores weighted by
their client counts, truncated), and `-1` for a radio without scored clients; see *The formula
is the firmware's*.

**athstats interference counters ("Possible interference"; `ast_txto`/`ast_cst` sent on ath9k since upstream fafe47f).** In the same loop, the handler diffs
`athstats` through `jJGDMIJ` (the "stat-helper-lastknown" cache) over the fields
`ast_txto`, `ast_cst`, `ast_ath_reset`, `fullqueue_stop`, `ast_be_xmit`: each is a cumulative
counter; a delta is reported only when the previous value is non-zero and the new one is
larger, alongside `time_delta` (seconds since the last inform for that radio). It then raises

```java
if (d > 5.0 && now - last_interference_at > 300
    && (delta.ast_txto / d > 10.0 || delta.ast_cst / d > 10.0)
    && vap_table has an entry with radio_name == this radio)
  -> EVT_AP_PossibleInterference {ap, radio, name, channel (from that vap)}
```

and stores the deltas of `ast_txto`, `ast_cst`, `ast_be_xmit` on the radio's
`radio_table_stats` entry. Upstream lab (10.4.57): a throwaway copy of openUF that sent `ast_txto` rising by 1000 per second
  made the controller set `radio_table_stats[].last_interference_at` (it is written only when
  the event fires) on both radios within 90 s, with a stored delta of 10000 per inform.

**Firmware (athbox `athstats`, firmware-confirmed for 4.0.15).** mcad fills `athstats` from
libubnt's `get_radio_stat_info` (the driver's `ath_stats`). The `athstats` tool prints the
same fields as "global txmit timeout interrupts" (`ast_txto`), "carrier sense timeout
interrupts" (`ast_cst`) and "beacons transmitted" (`ast_be_xmit`). These are raw counts since
the driver loaded; the controller computes the rates.

**openUF.** ath9k counts the same two hardware interrupts in debugfs
(`/sys/kernel/debug/ieee80211/phyN/ath9k/interrupt`, lines `GTT` and `CST`), and openUF
sends them as `ast_txto`/`ast_cst` (`sysinfo.radio_timeouts`). ath10k (its firmware stats
have a "TX timeout" count, but no carrier-sense one) and mt76 have no such pair, so their
radios send neither, as a radio that never timed out would. `ast_be_xmit` is not sent:
mac80211 keeps no count of beacons sent, and the column it affects is only sorted by it.
- **Live upstream (10.6, 2026-10-10).** Archer C5 2.4 GHz (ath9k): GTT 312203, CST 263611 after 69 days,
  about 0.05 per second together; over one minute CST +1 and GTT +0. The payload
  built on the AP carried both on that radio and neither on the ath10k one, and the controller
  stored a `radio_table_stats[].ast_cst` delta of 1 for it. AX3000T (mt76): nothing sent, as
  intended. At these rates the event stays quiet; it is meant for a radio that cannot get
  on air.

### `radio_table_stats[]` entry

Parallel to `radio_table` — the real controller's own split of static config vs. live stats.

`name`, `channel`, `cu_total`, **`cu_self_rx`**, **`cu_self_tx`** (two separate fields, not one
combined `cu_self`), `cu_interf`. (`spectrum_table` / `spectrum_table_time` travel on the
`radio_table` entry instead; see [Airtime Scan](#airtime-scan-spectrum-scan).)

All `cu_*` are percentages derived from `iw dev <ifname> survey dump`;
`cu_interf = max(0, cu_total − cu_self_rx − cu_self_tx)` — airtime busy for reasons other than
this radio's own tx/rx.

> **`cu_*` cover the last inform interval, not the radio's lifetime (upstream facf986, 2026-10-13).** The
> survey counters accumulate from radio bring-up, so `busy / active` is a lifetime average.
> Until then openUF sent exactly that. Upstream's Living room 2.4 GHz radio, up 11 h, reported
> 25% while it was measuring 15–17% over 10 s windows, and the Office 2.4 GHz reported 13.8%
> against 5–6%. A live spike or lull never showed.
> **Firmware-confirmed for 4.0.15** (`umac.ko`, MIPS disassembly):
> - `ieee80211_beacon_chanutil_update2` runs once per VAP per beacon. Every
>   10 × VAP-count calls (10 beacon intervals, ~1 s), it reads the MIB counters through
>   `ic_get_mib_cycle_counts_pct` (`ic+28348`: tx_frame, rx_frame, rx_clear, cycle).
> - It stores `round(Δcounter × 100 / Δcycle)` as three bytes at `ic+22788..22790`
>   (`(v × 256 / Δcycle × 100 + 128) >> 8`). Those are rx_clear, rx_frame and tx_frame,
>   in that order.
> - `ath_ioctl`'s athstats reply copies those bytes into `cu_total`/`cu_self_rx`/`cu_self_tx`,
>   and `mcad` forwards them.
> - The `ieee80211_sysctl_chanutil_{total,selfrx,selftx}` sysctls print the same bytes.
>
> openUF now keeps the in-use entry's counters per radio (`unifi/payload.lua` `windowed_cu`) and reports the
> delta since the previous inform, rounded the same way. That window is ~10 s, not ~1 s.
> The fallbacks:
> - The first reading, a channel change, or any counter going backwards (radio restart)
>   uses the counters as they stand.
> - A reading with no new active time repeats the last result.
>
> Live upstream 2026-10-13: Living 2.4 GHz 17% on the controller against 15–17% measured on the AP;
> Office 2.4 GHz 6% against 5–6%. The Living 5 GHz radio (ath10k, ch 36/80) shows 0% because
> it is 0.4–0.5% busy (2 clients, ~2 KB/s), not because of a reading fault.

> **`iw` survey field names.** The real binary prints `channel active time:`,
> `channel busy time:`, `channel receive time:`, `channel transmit time:` — *not*
> `channel time:`/`channel time busy:`/etc. Patterns must be anchored to line start so
> `channel busy time:` doesn't also match inside `extension channel busy time:`, which `iw`
> emits on wider channels.

> **The operating channel's entry is not first — pick it by `[in use]`.** `survey dump`
> emits one entry per channel the phy supports, in the phy's own frequency order, so the
> operating channel sits wherever it falls: measured live on 2026-08-02, entry **11 of 13**
> for a 2.4GHz radio on ch11 and **3 of 24** for a 5GHz radio on ch44. Every other entry is
> a scan dwell carrying only a few milliseconds of accumulated time (3–146 ms observed).
> Deriving `cu_*` from `stats[1]` therefore divided a busy figure by a ~3 ms active time and
> reported a genuinely 24%-busy 2.4GHz channel to the controller as **100%**, and a 1.9%-busy
> 5GHz channel as **75%** — which is what made both APs look like they were drowning in
> interference. The same wrong entry also fed the noise floor used to convert Minimum RSSI
> back to dBm. Fixed by flagging `in_use` in `sysinfo.radio_stats()` and selecting it in
> `inform.lua`'s `_in_use_survey()`; the test fixture now mirrors the real ordering, and
> reverting the selection fails 4 tests.

`spectrum_table[]` entries carry `channel`, `center_freq`, `width`, `utilization`,
`interference` (field names recovered from two independent Lombok DTO constant pools).
`channel`/`center_freq`/`utilization` come mechanically from survey dump; `interference` is
best-effort — see [best-effort fields](#best-effort-and-unverified-fields). Layout and
`spectrum_table_time` units: see [Airtime Scan](#airtime-scan-spectrum-scan).

### VAP, device and radio fields (upstream 8b0ed77, 2026-10-10)

Audit F11: firmware keys that openUF did not send, checked against what 10.6.106
reads. A key is only worth sending if something shows it.

| Key | Firmware (3.9.27 to 4.0.15) | 10.6.106 consumer | openUF |
|---|---|---|---|
| `sys_stats` | `prepare_system_stats`: `/proc/loadavg` read with `%s %s %s` (default `0.00 0.00 0.00`) and sent as strings; `json_integer` of sysinfo `totalram`, `totalram − freeram`, `bufferram` | Stored whole on the device. UI: the device panel's **Load Average** row (`loadavg_1 / 5 / 15`, hidden when absent) and the device comparison's load column. `mem_*` have no UI reader | Sent. `/proc/meminfo` `MemTotal`, `MemTotal − MemFree`, `Buffers`, times 1024 (load averages left out when `/proc/loadavg` cannot be read) |
| vap `extchannel` | `prepare_vap_array`: signed byte from `fill_chextoffset` (driver getparam 0x76, chextoffset), set only when non-zero | Copied into `radio_table_stats[].extchannel` (`getInt`, 0 when absent). UI: a 2.4 GHz radio's centre channel is `channel + 2 * extchannel` | Sent from `iw dev <if> info`: the side of the primary's partner in its 40 MHz half (`sysinfo.ext_offset`; above 40 MHz the block is halved around the primary). |
| vap `bw` | Not among the 4.0.15 firmware's vap keys | Copied into `radio_table_stats[].bw` (0 when absent) | Not sent: no firmware evidence for its unit |
| `isolated` | Sent | Ignored: derived from `uplink == "down"` | Not sent |
| `countrycode_table` | Sent | UI warns when the site country is missing from it; absent = no warning | Not sent: no list of supported countries on OpenWrt |
| `antenna_table`, radio `current_antenna_gain`, `builtin_ant_gain` | Sent | No `antenna_table` = `antenna_id -1`, `antenna_gain = builtin_ant_gain` (0 when absent); EIRP is tx power + gain | Not sent: OpenWrt has no antenna gain to report, and 0 keeps EIRP = tx power instead of inventing one |
| radio `has_restricted_channels`, `min/max_chan_cntr_frq` | Sent | UI drops channels outside the range when `has_restricted_channels` | Not sent: absent means no restriction, which is true here |
| `model_display` | Sent | UI reads it on neighbour (scan) rows only | Not sent |
| `mac_filter_rejections`, vap `wifi_tx_latency_mov` | Sent | No reader in the controller or UI | Not sent |

`anomalies_bar_chart` and `reasons_bar_chart` went out with the satisfaction port.

**Live upstream (10.6.106, both its APs).** `stat/device` holds `sys_stats` for both (for example
`loadavg_1 "0.08"`, `mem_total 123625472`, `mem_buffer 0`: OpenWrt reports `Buffers: 0 kB`).
The Living room AP's panel shows **Load Average 0.09 / 0.13 / 0.17**, matching `/proc/loadavg`.
`radio_table_stats[].extchannel` reads `1` on both 5 GHz radios (channel 36 and 100, 80 MHz)
and `0` on the 20 MHz 2.4 GHz radios. A 40 MHz 2.4 GHz channel was not tried live: the site
runs 20 MHz there.

### STUN wake-up (upstream aeac179, 2026-10-10)

How the controller makes a managed AP inform at once when it has something for it, instead
of waiting for the next heartbeat. The fork had its own client (`unifi/stun.lua`) before
upstream's; the controller and firmware facts below are upstream's, and the fork took the
firmware's cadence and its inform-on-a-changed-mapping from them.

**Controller (10.6.106 jar, CFR).**
- The `stunService` bean is chosen by `stun.type`, default `local`. That is a STUN server on
  UDP 3478 (jstun, classic RFC 3489). It accepts only attributes 2 (RESPONSE-ADDRESS) and 3
  (CHANGE-REQUEST), and it rejects a Binding Request that has no CHANGE-REQUEST. The
  Binding Response carries MAPPED-ADDRESS (the request's source), CHANGED-ADDRESS and
  SOURCE-ADDRESS, 56 bytes in all.
- mgmt_cfg is built whole by one builder, and that builder always appends `stun_url`
  (`stun://<host>:3478/`). A `mgmt_cfg` without it therefore means no STUN.
- The connection request is sent from the device manager whenever it queues a command
  for a device in state CONNECTED, and whenever a config change bumps `cfgversion`. It
  needs `connect_request_ip` present and `connect_request_port` > 0 (`getInt`, which
  also parses a string); otherwise the debug log says "does not have STUN capability". The
  STUN socket then sends 20 bytes to that address: type `0x8888`, length 0, the rest zero.
  The simulator variant puts a MAC at offset 4.

**Firmware (mcad `stun_init`/`stun_send`/`stun_recv`, firmware-confirmed for 4.0.15).**
- `stun_init` opens one UDP socket with SO_REUSEADDR, bound to `0.0.0.0:0`, with a
  persistent read event.
- `stun_send` runs on a timer. It sends only when `/var/run/ipready.br0` exists, mcad's
  state is 2 (managed) and a `stun_url` is set. The packet is 28 bytes: type 1, length 8,
  an all-zero transaction id, then CHANGE-REQUEST (3), length 4, value 0. After a full send
  the next one is due in 30 s; after a failure, a partial send or a not-ready state, in 5 s.
- `stun_recv`:
  - A `0x8888` packet of at least 20 bytes is logged as `stun_connection_request` and
    triggers an inform 10 ms later (reason `stun`), unless an inform is already running.
  - A `0x0101` Binding Response is walked attribute by attribute. A MAPPED-ADDRESS with
    family 1 (IPv4; family 2, IPv6, is also accepted) is compared with the stored address.
    If it changed, it is logged as "stun info changed", stored, and an inform is triggered
    at once.
  - A receive error re-initialises the socket.
  - Nothing checks the sender or the transaction id.
- The inform carries `connect_request_ip` (`json_string`) and `connect_request_port`
  (`sprintf "%d"`, then `json_string`) while the stored port is non-zero.

**openUF (`unifi/stun.lua`, `inform.lua` `_wait`).**
- The same 3489-compatible request with CHANGE-REQUEST 0 (the fork adds the RFC 5389 magic
  cookie and a random transaction id, which a 3489 server reads as the first bytes of its
  16-byte id), on the firmware's timing: every 30 s, 5 s after a send that failed.
- A connection request, or a new or changed MAPPED-ADDRESS, ends the idle wait at once.
- Runs only while adopted, unless `option stun '0'`. Where the firmware believes any sender,
  openUF believes a wake or a binding answer only from the address `stun_url` resolves to,
  checks the transaction id, and starts at most one wake inform per 2 s.
- Binds a stable local port (`stun_local_port`, 3478) so the controller's stored address
  survives a daemon restart, and reports the socket's own port with the device IP until a
  Binding Response arrives (the firmware sends nothing until then).
- `stun_url` is persisted in `state.json`; until a mgmt_cfg has named one, the inform host on
  port 3478 is assumed, and a mgmt_cfg without it keeps the last one.

**Live upstream (UCG Ultra, 10.6.106, both its APs; upstream's own STUN client).**
- Before any push, the firmware's 28-byte request sent from .3 to `192.0.2.1:3478` was
  answered with 56 bytes, MAPPED-ADDRESS `192.0.2.3:<the probe's port>`.
- After a Force Provision of each AP, `stun_url stun://192.0.2.1:3478/` landed, and the
  controller recorded `connect_request_ip` 192.0.2.3 / 192.0.2.4, with ports matching each
  AP's `netstat` socket, stored as strings.
- On-device counters, with the controller's heartbeat at about 15 s:

| AP | command | `0x8888` arrived | inform SYN |
|---|---|---|---|
| Living room (.3) | `set-locate` at 108.05 | 108.22 | 109.78 |
| Living room (.3) | `unset-locate` at 113.06 | 113.24 | 114.58 |
| Office (.4) | `set-locate` at 121.05 | 121.25 | 121.48 |
| Office (.4) | `unset-locate` at 125.05 | 125.17 | 125.40 |

  Times are seconds of one minute; the command times come from the browser, the others
  from the AP. On the Archer C5, the 1.3–1.6 s between wake and SYN is the time the slow
  ath79 takes to build the payload before it POSTs.

### Airtime Scan (`spectrum-scan`)

Established upstream (a684980, 2026-10-10) on lab 10.4.57 (CFR decompile plus REST), on UAP
firmware 3.9.27 to 4.0.15, and on a real UCG Ultra with an Archer C5.

- **Gate.** REST `cmd/devmgr {"cmd":"spectrum-scan","mac":…}` (`devmgr/b/g/qxLeipRTLsKkMM`)
  throws `api.err.InvalidTarget` unless `supportSpectrumScan()` (`wifi_caps` `0x10`) holds
  and the AP is wired. `stat/spectrum-scan` (`stat/hhFgUVZPT`), which the UI reads results
  from, skips any AP without the same bit. openUF claims it: every driver has the channel
  survey the sweep reads.
- **`spectrum_scanning`.** The controller sets it to `true` itself when it queues the cmd
  and refuses another request while it stays true (`api.err.SpectrumScanInProgress`).
  Every stats inform overwrites it with the device's own value (`PGOcbDWlbnYQdFW`), the
  inform that collects the cmd included. openUF queues the sweep as chunked jobs (see
  *Chunked sweeps* under [Quick scan](#quick-scan)); the follow-up inform runs the first
  chunk and says `true` while chunks remain, and the inform after the last chunk carries
  the results and `false`. Edge case: where the phy's channel list cannot be read the sweep
  is one whole-band chunk, and no inform says `true`.
- **"Scanning..." stays until a reload.** The Environment tab's panel holds the AP object
  it loaded with; nothing a device reports reaches it. Frontend behaviour.
- **`spectrum-cfg` is a whole replacement `system_cfg`, ignored on purpose.** Every WLAN is
  replaced by one hidden open `vport-<serial>` SSID and every radio gets
  `radio.N.rfscan=enabled`, `channel=auto`; the generator (`config/eWivisHeQsnaqDtx`)
  carries no scan parameter. UniFi firmware restarts onto it (`rc stop; rc start
  spectrum.cfg`), runs `ubntrfclient` (Qualcomm spectral analysis) per radio and restores
  with `spectrum-scan-restore`: its clients lose the AP for the scan. openUF keeps the WLANs
  up and reads the channel survey (`iw … survey dump`) instead, which every driver has (mt76
  has no spectral scan). `utilization` is busy/active time over a short listen per channel
  and `interference` is the noise floor, so the figures are coarser than a UniFi AP's.
- **Dwell: one scan per channel, 200 TU, home in between.** Measured upstream on both of its
  APs as the survey's active time on an off-channel after one scan:

  | Radio | default sweep | `passive` | `duration 200` | `duration 500` |
  |---|---|---|---|---|
  | Archer C5 ath9k (2.4 GHz) | 79 ms | 119 ms | 219 ms | 518 ms |
  | Archer C5 ath10k (5 GHz) | 46–146 ms | 146 ms | 196 ms | 496 ms |
  | AX3000T mt76 (2.4 GHz) | 79–130 ms | 112–159 ms | 213–259 ms | 512–569 ms |
  | AX3000T mt76 (5 GHz) | 79–116 ms | 116–125 ms | 205–230 ms | 506–515 ms |

  All three drivers honour `duration`, though only the ath10k phy lists `SET_SCAN_DWELL`;
  `passive` with `duration` is refused by iw. A whole sweep never returns to the operating
  channel between channels, so a spectrum-scan chunk scans each of its channels on its own
  (`iw dev <if> scan ap-force freq <f> duration 200`) with 0.3 s back home in between
  (`provision.SPECTRUM_DWELL_TU` / `SPECTRUM_HOME_S`), and chunks stay `SWEEP_CHUNK_GAP`
  apart. Upstream's client impact for the same per-channel pattern (one continuous pass):
  210–330 ms round trips for ~7 s while a 2.4 GHz client's radio scanned, 1 of ~150 pings
  lost, still associated. quick-scan and scan sweeps keep the default dwell. ⚠️ The
  chunked form has not been run on hardware.
- **The table travels in `radio_table`, not `radio_table_stats`.** The controller builds
  its own `radio_table_stats` from the inform's `radio_table` entries and reads
  `spectrum_table`/`spectrum_table_time` there, beside `athstats` and `scan_table`
  (`PGOcbDWlbnYQdFW`). Sent in `radio_table_stats`, they were dropped and
  `stat/spectrum-scan` returned empty tables after a real scan.
- **`spectrum_table_time` is an age, in seconds.** The controller stores
  `now − spectrum_table_time` and the UI shows the stored value as the scan's epoch; an
  epoch here would read as a 1970 scan.
- **One entry per (channel, width).** The UI chart averages the entries whose `width` equals
  the chart's width over each bonded block's 20 MHz channels. openUF lists each 20 MHz
  survey reading once per width the band offers (`unifi/payload.lua` `spectrum_table`):
  20/40 on 2.4 GHz, 20/40/80 elsewhere, and up to the configured width when wider. It sends
  no `interference_type`.
- **Confirmed upstream on the real UCG Ultra.** Scan Now on the Archer C5 delivered the
  cmd, the sweep ran, and `stat/spectrum-scan` returned 81 entries on 5 GHz (27 channels ×
  20/40/80) and 26 on 2.4 GHz (13 × 20/40); the chart drew the 20/40/80 MHz rows.

### `vap_table[]` entry

| Field | Notes |
|---|---|
| `extchannel` | Secondary 20 MHz channel side: `1` above, `-1` below. Only when non-zero, as the firmware sends it. See [VAP, device and radio fields](#vap-device-and-radio-fields-upstream-8b0ed77-2026-10-10). |
| `name` | UCI section name |
| **`essid`** | Not `ssid` |
| **`id`** and **`wlanconf_id`** | Both carry the wlanconf ObjectId from `aaa.<n>.id`. **Mandatory.** See below. |
| **`radio`** | The **band** (`ng`/`na`), same enum as `radio_table`. Sending `radio0` here logs `WARN stat - unexpected radio[radio0] while processing stats` on every inform and silently drops that vap's stats aggregation. |
| **`radio_name`** | The UCI device name (`radio0`) — a separate, real field on the same DTO. This is what `get_ifname_for_radio()` needs. |
| `encryption`, `disabled`, `bssid`, `channel`, `tx_power`, `usage` | `usage` is `"user"`, or `"uplink"`/`"downlink"` for the wireless uplink's two VAPs, which carry no `id` and are named with the controller's devname — see [Wireless uplink](#wireless-uplink-mesh--ported-from-yesrabopenuf-2026-10-03) |
| `num_sta` | Coexists with the nested `sta_table` on the real DTO |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `tx_retries`, `tx_dropped` | The UI's "Air Stats" panel. `iw` exposes these only per-station, so they're summed across connected stations while building `sta_table`. `rx_dropped`/`rx_errors`/`tx_errors` have no source in `iw` output at all — left unset rather than invented (802.11 ARQ retry/failure counters are inherently TX-side only). |
| `avg_client_signal` | Mean `signal` of associated clients, dBm. Omitted entirely when the VAP has no clients. |
| `cu_total`, `cu_self_rx`, `cu_self_tx`, `cu_interf` | Mirrored from the radio |
| `sta_table[]` | Nested — see below |

**`id` is mandatory or the entire VAP is discarded.** `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD`
(vapInformProcessor) filters the raw `vap_table` *before* any per-station processing runs. For a
`usage=user` VAP it requires a non-`"unknown"` `id`, then re-looks it up via
`configCache.get(siteId, id)` to attach `wlanconf_id`/`ap_mac`/`site_id`/`is_guest`/`is_wep`.
A missing `id` is checked with `!"unknown".equals(id)` and drops the VAP **silently** —
no log line, no error, taking the nested `sta_table` and every wireless client with it.
The `"Inconsistent vap"`/`"Invalid id"` warn paths only fire on an actual lookup *failure*.

**"Air Stats" needs growing counters, not just non-zero ones.** The widget renders a
rate/delta between informs. Static counters produce a zero delta even when the absolute value
is correct — which is why `iw-mock.sh`'s fake counters must increase monotonically.

**A client's "TX Retries" is the controller's delta of `tx_retries` (upstream 70c6498, 2026-10-13).** Every
client showed "TX Retries 0.0%". On each inform the controller diffs the wireless client's
counter keys: `tx_bytes`, `rx_bytes`, `tx_packets`, `rx_packets` (`devmgr.KrlpWXOulbN`) plus
`wifi_tx_attempts` and `tx_retries` (`devmgr.HCKpgcBFPLu`). It keeps the positive deltas
(`wcvb`), adds them to the client's stored totals and **overwrites**
`wifi_tx_retries_percentage` with `wifi.k.bLwwMKkr`: Δretries ÷ (Δretries + Δattempts +
Δdropped) × 100, rounded to 0.1 (`devmgr.TtZhv`). openUF sent no per-station `tx_retries`, so
Δretries was always 0. `wifi_tx_dropped` is read from the same delta but is not in the diffed
key list, so its delta is 0 whatever is sent. openUF sends it anyway as the lifetime count.
**`wifi_tx_attempts` excludes retries.** Firmware 4.0.15 sends no `wifi_tx_attempts` at all, so
the controller is the only source. Every rate it computes from the field (client, `stat.ap`
`tx_retries_percentage_max`, per band) uses retries + attempts + dropped as the denominator.
The disconnect-time session archive also fills `wifi_tx_attempts` from `wifi_tx_packets`.
openUF used to send `tx_packets + tx_retries`, which counted the retries twice. It now sends
`tx_packets`, per station, per VAP and per radio, and the radio's `tx_retries_pct` uses the
same denominator.
✅ Live upstream on both its APs and the 10.6 controller: one inform after the deploy, 8 of 13 wireless
clients had non-zero `tx_retries` in `stat/sta`, with percentages from 4.2 to 15.3 (on both
mt76 and ath9k/ath10k clients). The client panel showed "TX Retries 7.4%" for a 2.4 GHz phone.

**mt76 retry counters can read as 2^32 − 1 (upstream c0a2047, 2026-10-13).** Upstream's Office AP's (AX3000T, mt76)
Air Stats showed 47,270,605,212 tx packets on 2.4 GHz, 50 % / 33 % retries and 49.4 % drops.
`stat.ap` held `ng-tx_retries` = 11 × 2^32 + 2.75 M and `na-tx_retries`/`na-wifi_tx_dropped`
≈ 2^32. The 5-minute report pinned one jump at 2026-10-13 02:55 UTC: `tx_retries` and
`wifi_tx_dropped` both +4294967366 (2^32 + 70) in the same bucket. The controller (CFR,
`devmgr/wcvb`, the client and VAP delta helper) keeps a delta only when it is positive and the
last value is non-zero. A counter that goes down costs nothing, but one reading near 2^32 adds
2^32. `stat.ap` is cumulative, so the jump stays.
Source: mt76 as shipped in OpenWrt 25.12.5 (`kmod-mt7915e` 2026.03.19~39c960c3) adds
`FIELD_GET(MT_TX_FREE_COUNT, info) - 1` to the u32 `tx_retries`, and that plus the failure bit to
`tx_failed`, with no guard for a count of 0 (`mt7915/mac.c`, tx-free path). Upstream later made it
`count ? count - 1 : 0`. A fresh station's counters can then read 4294967295. openUF now reads
both as signed 32-bit and floors them at 0 (`sysinfo.u32_count`). The same source gives the
real drop count: `tx_failed − tx_retries` (`satisfaction.dropped`). It feeds the VAP/radio
`tx_dropped`/`wifi_tx_dropped` and the WiFi Experience drop term. Before, openUF counted every
failed attempt as a drop (≈ retries) in the VAP totals, though not in satisfaction. The WED path
reports both counts from firmware, so there the difference floors at 0.
✅ Live on the Office AP, after the deploy: Home IoT 181 dropped against 6,118 retries (before:
6,134 against 5,958), 5 GHz 0. ⚠️ The values already accumulated stay in `stat.ap` until the
device is re-adopted.

### `sta_table[]` entry (nested inside each `vap_table` entry)

Nested, **not** a flat top-level `user_table`.

| Field | Notes |
|---|---|
| `active`, `mac`, `ap_mac`, `channel`, `radio` | `active` is always `true` — an entry only exists while `iw station dump` lists the station |
| `serialno` | Only on the wireless uplink's VAPs: the device behind the link (the parent on `usage=uplink`, a child on `usage=downlink`), which is how the controller resolves a backhaul station to a device |
| `signal`, `rssi` | `signal` is `iw`'s dBm. `rssi` is the **SNR** in dB over the radio's in-use survey noise, floored at −96 as the firmware does (`signal = rssi + max(noise, −96)`; upstream 074b070). See *Station fields* below |
| `noise` | The radio's in-use survey noise floor (dBm), sent unclamped as the firmware does (the −96 floor applies only to `rssi`/`signal`, so below −96 dBm `rssi + noise` is less than `signal`), left out when the survey has none. Read as plain data by the wireless-client model and copied into the WiFiman reply (below) |
| `chwidth` | The client's channel width as a **code**: 0/1/2/3/4/5 = 20/40/80/160/240/320 MHz (10.6.106 width enum `com.ubnt.i.g.a.b.RxFvcetMTlkSFFxK`, looked up by code). The per-client ingest `devmgr.FrAskVY` stores `getOptionalInt("chwidth")` through it as the client's `channel_width` (MHz). openUF sends the wider of the last tx and rx frame's width from `iw station dump` |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets` | **Raw cumulative counters.** The vapInformProcessor computes its own `tx_bytes-d`/`rx_bytes-d`/`bytes-d`/`bytes-r` deltas server-side keyed by `time_delta` — never send a pre-computed rate here. |
| `tx_rate`, `rx_rate` | **Kbps** (`iw` reports Mbit/s, so ×1000) |
| `uptime`, `idletime` | `iw`'s "connected time" / "inactive time", both in seconds |
| **`tx_mcs`**, `rx_mcs` | Not `tx_mcs_index` (that name is only the ucore-message JSON name for a different internal event). Absent for legacy pre-11n rates. |
| `nss` | Read directly by the controller, no derivation |
| `radio_proto` | Read only by the **disconnect-time** archive path (`TtZhv`) |
| **`is_11n`, `is_11ac`, `is_11ax`, `is_11be`** | What the **live** display actually uses — see below |
| **`tx_retries`**, `wifi_tx_attempts`, `wifi_tx_dropped`, `wifi_tx_retries_percentage` | Lifetime counters. `attempts = tx_packets` (retries not included); dropped is `satisfaction.dropped`; percentage = retries ÷ (retries + attempts + dropped). The controller replaces the percentage with its own from the deltas: see below |
| `satisfaction`, `satisfaction_now`, `satisfaction_reason`, `anomalies` | The firmware's own formula — see below |
| ~~`capacity`, `throughput`, `linkscore`, `multicast`~~ | **Not sent** (upstream e50bdc3, 2026-10-11). UniFi firmware's `fill_stainfo_json` sends none of the four (firmware-confirmed for 3.9.27 to 4.0.15). The 10.x controller reads `capacity`/`throughput`/`linkscore` only in `devmgr.c.KHUkYjHujLgFBD`'s `active_sta_table` builder, which runs only for a mesh **uplink** VAP's entry (it also maps `airmax.link_quality`/`link_capacity` onto them). `multicast` is read per client as a sub-document (`getX`), and a number came back `null`. On the live 10.6 controller none of the four showed up in `stat/sta` or `stat/device`. openUF used to send a tx-rate proxy, a byte-rate delta and two `0` placeholders |
| `name` | Omitted — controller/admin-assigned, no local source |
| `ip` | IPv4 from `/proc/net/arp`. Left out when the AP has no entry. The controller never takes `0.0.0.0` |
| `hostname` | From `/tmp/dhcp.leases` (only when the AP runs dnsmasq). Left out otherwise |
| `ipv6_addresses` | **List of strings**: the client's global and ULA addresses from `ip -6 neigh show`, sorted, each listed once. Link-local, multicast and `::`-prefixed addresses are left out. The key is left out when there are none |

**`ip`, `hostname`, `ipv6_addresses` (10.6.106, CFR, 2026-10-03).** What the AP-side station ingest
does with each:
- `ip` → the client's live `ip`, behind a gate. `KgsqveYxhunEIqEM.UGwcHSHUGpYtqo(sta, entry)`
  copies it when it is not `"0.0.0.0"` **and** (`lQpZCpDnmwdxigXWEwA()` **or**
  `!cYmHnpPBht.NvfcKfHPI()`). `lQpZCpDnmwdxigXWEwA()` is `device.isGateway() && device.isUbios()`
  (the reporting device is itself a UniFi OS gateway), never true for an AP.
  `cYmHnpPBht` is a record whose `toString` names its components
  `trafficStatsAreProcessedByGatewayOnly;ipIsUpdatedByGatewayOnly`. `NvfcKfHPI` is
  `ipIsUpdatedByGatewayOnly`, built by `CNSMptQSEDMQtIKop.QKCZObbCHdbHQrHY(site)` as "any `dev` in
  the site with `isUbios() && consideredConnected()`" (state CONNECTED or PROVISIONING). So **an
  AP's `ip` sets the client's live IP only while the site has no connected UniFi OS console**.
  With a UDM or UCG adopted, the gateway owns it.
- `ip` → `last_ip`, `ipv6_addresses` → `last_ipv6`, **ungated**. `URbVkSXx` (~line 635) writes
  `last_ip` on the client's station doc and on its `user` record whenever the entry's `ip` is
  non-blank, not `0.0.0.0` and differs from the stored one. It writes `last_ipv6` whenever
  `getStringList("ipv6_addresses")` is non-empty and not `equals` the stored list. The
  comparison is order-sensitive, so openUF sorts the list to avoid a rewrite every heartbeat.
- `ipv6_addresses` → the station's live `ipv6_addresses`, ungated. The AP processor
  `MwArZjlvuVhguZnuxGE` (extends `FrAskVY`) puts `FrAskVY.mMOyBNMxMsHkxh(entry)` there. That is
  the entry's list, re-sorted by `com.ubnt.net.e.DXjFpHAhtGlwvsEEcf`'s comparator, which puts
  addresses matching `^(fe80).+|^ff.+|^(f[cd]00).+|^(::).+|(.+FF:FE.+)` (case-insensitive) after
  the rest, and shorter strings first among those that don't match. **The controller does accept link-local.** It only
  sorts it last. openUF leaves it out anyway: it is not an address the client is reached at.
- `hostname` → the station doc and the `user` record when non-blank (`URbVkSXx` ~line 389/481),
  and via `eZFpi` with `hostname_source = "uap"`, **unless** the station's `hostname_source` is
  already `"ubios"` (a UniFi OS gateway's hostname wins).

Not live-confirmed: the docker lab has no wireless stations, and no hardware run has been made.
`ip -6 neigh show` was recorded from busybox on `openwrt/rootfs:x86-64-openwrt-25.12` (the
`tests/fixtures/ip_6_neigh.txt` source, MACs rewritten). The format is
`<addr> dev <if> lladdr <mac> [router] ref N used a/b/c probes N <STATE>`, and FAILED entries
carry no `lladdr`. Busybox `ip neigh` supports `show`/`flush` only, which is all that is used.
| `is_11r` | `true` when the client negotiated a Fast Transition AKM, left out otherwise, as the firmware sends it. See *Per-client flags* below |
| `state` | Bitmask; the controller reads only `0x10` (power save). `16`/`0` from mac80211's `PS_STA` flag, only on a phy without `AP_LINK_PS`. See *Per-client flags* below. Left out without debugfs |
| `authorized`, `1x_identity`, `ack_rssi`, `ccq`, `satisfaction_real`, `dhcpend_time`, `tx_retry_burst_count` | **Not sent**: no faithful OpenWrt source. See *Per-client flags* below |

The attribute list `KHUkYjHujLgFBD` copies verbatim off each incoming entry is exactly:
`"channel", "radio", "name", "signal", "rssi", "tx_rate", "rx_rate", "tx_packets",
"rx_packets", "tx_bytes", "rx_bytes"`.

**Per-client flags** (10.6.106, CFR). The per-client ingest for a UAP,
`devmgr.MwArZjlvuVhguZnuxGE.FLYOgasYTlg` (and its twin `devmgr.VSWuF`), reads off each
incoming entry:

```java
int n = sta.getInt("state");
client.put("powersave_enabled", (n & 0x10) != 0);
client.put("is_11r", sta.is("is_11r", false));
if (sta.containsField("1x_identity") || client.containsField("1x_identity"))
    client.put("1x_identity", sta.getString("1x_identity", ""));
```

`iceUMDuewFNFLMOqti`'s static list copies `ack_rssi`, `anomalies`, `ccq`, `dhcpend_time`,
`satisfaction_real`, `satisfaction_reason` and `tx_retry_burst_count` (among others) as plain
data, and `URbVkSXx` raises a client event when a non-zero `tx_retry_burst_count` changes. The
client model (`service.l.e.MarvlyZH`) reads `is_11r`/`powersave_enabled` as optional booleans,
`ccq`/`satisfaction_reason` as ints, `anomalies` as a long. What openUF does with each:

| Field | Status |
|---|---|
| `is_11r` | ⚠️ **Sent**, unit-tested only. True when the AKM the client negotiated is a Fast BSS Transition one. `hostapd_cli all_sta` runs once per BSS for it (it used to feed the old satisfaction ceiling too), and its per-station WPA MIB prints `AKMSuiteSelector=00-0f-ac-<n>` (hostapd `wpa_get_mib_sta`: hex OUI, decimal suite). FT suites: 3, 4, 9, 13, 16, 17, 19, 25. The selector has been read by hand on both real APs, through `hostapd_cli sta <mac>`, which prints the same per-station record as `all_sta` (*802.11r was configured, advertised, and not working* above: "3× FT-SAE, 3× SAE, 1× PSK"). This parser has not run on hardware. Semantics are openUF's choice, since the firmware's meaning was not read: an FT AKM is negotiated on the client's first association in the mobility domain too, so `true` means "this client uses 802.11r", not "the last roam was fast". Sent only when true, as the firmware sends it (`fill_stainfo_json` emits it only when its flag is set; upstream 074b070) |
| `state` | ⚠️ **Sent**, unit-tested only. The controller reads only bit `0x10`, which matches net80211/madwifi's `IEEE80211_NODE_PWR_MGT` (the station is in power save right now). Neither `iw station dump` nor hostapd's all_sta/`get_clients` reports power save. mac80211 does, as the station's `PS_STA` flag in debugfs: `/sys/kernel/debug/ieee80211/<phy>/netdev:<ifname>/stations/<mac>/flags`, one set flag per line. That is a file read per client, with no fork. The phy comes from `/sys/class/net/<ifname>/phy80211/name`. The BSS netdev is tried first, then the netdev iw lists the station on (a key-VLAN station's directory stays under the BSS it was added on). openUF sends `16` or `0`, and leaves `state` out when no file is found. Per driver (upstream, read-only on both its APs, 2026-10-10): ath9k (no `AP_LINK_PS`) showed `PS_STA` on one of four stations in each of ten 1 s samples; ath10k and mt798x both set `AP_LINK_PS` in the phy's debugfs `hwflags` and never showed it (0 of 13 stations over 10 s on mt798x), so `false` there would be a guess and openUF leaves `state` out on such a phy. ⚠️ `powersave_enabled: true` has not been seen end to end |
| `authorized` | The controller reads it only for a guest client while the site's guest access has `portal_enabled` (`MwArZjlvuVhguZnuxGE.lQpZCpDnmwdxigXWEwA`, flags set in `iceUMDuewFNFLMOqti`). It means *passed the hotspot portal*: `authorized` true with no guest record makes the controller unauthorize the client, and false with a record makes it re-authorize. Absent is read as `true`. hostapd's `[AUTHORIZED]` (the 4-way handshake finished) is a different thing. openUF sends the `authorize-guest` ledger's answer on a portal WLAN and `true` elsewhere ([Guest portal](#guest-portal-hotspot-what-the-controller-pushes-and-expects)) |
| `1x_identity` | **Not sent.** hostapd would have it (all_sta's `dot1xAuthSessionUserName`), but openUF never provisions a WPA-Enterprise WLAN (no RADIUS server reaches the wire), so no openUF BSS can hold an EAP client. Sending an empty string would make the controller store a blank identity |
| `ack_rssi` | **Not sent.** The candidate is iw's `last ack signal`/`avg ack signal`, which read a constant −95 dBm for every client on real hardware (see `fix(sysinfo): report each client's RSSI, not the ack signal`). The controller subtracts `rssi` from it for its wifi-experience stats, so a fixed value would be worse than none |
| `ccq` | **Not sent.** madwifi's Client Connection Quality has no mac80211/iw counterpart |
| `anomalies`, `satisfaction_reason` | **Sent**: the firmware formula's anomaly bitmask and limiting-term bit (see *The formula is the firmware's*). ⚠️ On a site with a UniFi gateway, 10.6.106 lists `anomalies: -1` for every client although the payload carries 0: see *Station fields* |
| `satisfaction_real` | **Not sent.** No format was read |
| `dhcpend_time` | **Not sent here.** It needs the DHCP timing the STA tracker collects (*Client connection and roaming history*), which is outside this field set |
| `tx_retry_burst_count` | **Not sent.** It raises a controller event when it changes. UniFi's burst definition is unknown, and iw has only lifetime retry counters |

**Why the `is_11*` booleans matter more than `radio_proto`.** The live, still-connected client
display is computed by `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex`, which
**ignores the `radio_proto` string entirely**:

```java
private static jRsSex lhPagEPcc(UCthhvfQNZ uCthhvfQNZ) {  // 2.4GHz (ng) path
    if (uCthhvfQNZ.is("is_11be", false)) return BE;
    if (uCthhvfQNZ.is("is_11ax", false)) return AX;
    if (uCthhvfQNZ.is("is_11n",  false)) return NG;
    if (uCthhvfQNZ.is("is_11b",  false)) return B;
    return G;   // fallthrough when none are set
}
```

Sending only `radio_proto` leaves every live client showing `"g"` (2.4 GHz) or `"a"` (5 GHz),
while `nss` — read directly, no derivation — works immediately. Both must be sent.

**Generation/NSS derivation** from `iw`'s own bitrate line tokens (format strings confirmed via
`strings /usr/sbin/iw`):

| Token | Generation | NSS |
|---|---|---|
| bare `MCS N` | `n` | `floor(N/8)+1` (HT MCS layout: 0-7 = 1 stream, 8-15 = 2, …) |
| `VHT-MCS` / `VHT-NSS` | `ac` | read directly |
| `HE-MCS` / `HE-NSS` | `ax` | read directly |
| `EHT-MCS` / `EHT-NSS` | `be` | read directly |
| none (legacy) | falls back to the band: `a` on `na`, `g` on `ng` | 1 |

Never `b` — real dual-band 11n+ hardware doesn't negotiate down to 802.11b-only rates.

**`satisfaction` is a device-computed field.** The controller's `wifi_experience_score` is a
straight passthrough — `com.ubnt.service.l.e.AcrQJeJCScLn`:
`wifi_experience_score = doc.getOptionalInt("satisfaction")`. The wireless-client model
(`com.ubnt.service.l.e.AQODNNoMmBlFpWXX`) reads `satisfaction`, `satisfaction_now`,
`satisfaction_real`, `satisfaction_reason`, `anomalies` (`getOptionalLong`),
`wifi_tx_attempts`, `wifi_tx_retries_percentage`, `tx_mcs`, `ccq`, `noise`, `nss` as **plain
data**; the controller computes nothing itself beyond a running `satisfaction_avg` accumulator.
Sending nothing renders as "No Experience", correctly.

**The formula is the firmware's (firmware-confirmed for 4.0.15, 2026-10-10).** UAP BZ2 4.0.15 is
plaintext; `libubnt.so.1.0.0` exports `calc_sta_satisfaction`, `calc_vap_satisfaction`,
`calc_radio_satisfaction`, `calc_ap_satisfaction` and `fill_stainfo_json` (offset → JSON key).
3.9.27 has none of them. Decoded from the MIPS code, a client's score is the lowest of six
integer terms:

| Term (reason bit) | Input (`fill_stainfo_json` key) | Score | Anomaly bit when |
|---|---|---|---|
| signal (0x1) | `rssi` = SNR in dB; `signal` is emitted as `rssi + max(noise, −96)` | < 5 → 0; 5–14 → 5·snr + 15; ≥ 15 → min(snr + 75, 100) | < 50 |
| phy_rate (0x2) | `tx_rate`, `rx_rate` (kbps): ⌊tx/2⌋ + ⌊rx/2⌋, or the non-zero one; both 0 → 100 | ≤ 6000 → 10, ≤ 12000 → 25, ≤ 18000 → 50, ≤ 24000 → 70, ≤ 36000 → 75, ≤ 54000 → 80, ≤ 100000 → 85, ≤ 200000 → 90, ≤ 400000 → 95, else 100 | ≤ 12000 |
| tcp_packet_loss (0x4) | `rx_tcp_stats.stalls` + `tx_tcp_stats.stalls` ÷ an unexported u16 | 100 − 10·min(n, 10) | < 50 |
| tcp_latency (0x8) | `rx_tcp_stats.lat_avg` + `tx_tcp_stats.lat_avg` = s | s < 100 → 100, else 100 − (min(s, 600) − 100)/5 | < 50 |
| wifi_retries (0x10) | `tx_retries_mov` ÷ `tx_packets_mov` = p % (truncated) | retries > packets → 0; no packets → 100; p ≤ 25 → 100, else 100 − ⌊(100p − 2500)/75⌋; then − min(`tx_dropped_mov`, 100), ≥ 0 | < 50 (or retries > packets) |
| wifi_latency (0x80) | `wifi_tx_latency_mov.avg` = a | 100 − min(a, 20000)/200 | a ≥ 10000 |

`satisfaction_reason` is the bit of the term that set the score: 0x1 when signal < 100, else 0,
and each later term takes it only when strictly lower. `anomalies` ORs every term's bit
whichever won. 0x20 `poor_stream_eff` and 0x40 `sleepy_client` are chart keys the function never
sets. The `_mov` counters come from the driver (`umac.ko`, not stripped): `sta_stat_iter`, run by
a 60000 ms timer (`ubnt_sta_stat_timer_expired`), stores current − snapshot and re-snapshots, so
they are the last completed minute. The TCP terms come from the driver's own TCP inspection
(`ubnt_calc_tcp_stats`) and the latency term from `_ubnt_log_txtime`; mac80211 has neither, so
openUF scores them 100, which is what the formula gives with no TCP seen.

Roll-ups: a VAP's `satisfaction` is the truncated mean of its clients', capped at 100, **−1
with none**. A radio's (`athstats.satisfaction`) and the device's are Σ(clients × VAP score) ÷
Σ clients, truncated, −1 with none. `fill_wireless_info_full` also counts, per VAP, the clients
with each anomaly bit (`anomalies_bar_chart`) and each reason bit (`reasons_bar_chart`), each a
JSON object of the eight keys (`anomalies_bar_chart_keys`: weak_signal, low_phy_rate,
high_tcp_packet_loss, high_tcp_latency, high_wifi_retries, poor_stream_eff, sleepy_client,
high_wifi_latency; `reasons_bar_chart_keys`: signal, phy_rate, tcp_packet_loss, tcp_latency,
wifi_retries, stream_eff, sleepy_client, wifi_latency). mcad sends `satisfaction`,
`anomalies_bar_chart`, `reasons_bar_chart` and `avg_client_signal` per VAP,
`athstats.satisfaction` per radio and `satisfaction` at the top level.

Controller side (10.x jar, CFR): `devmgr/PGOcbDWlbnYQdFW` builds `radio_table_stats[].satisfaction`
from `radio_table[].athstats.satisfaction`, default −1 (openUF never sent it before, so every
radio read −1); the device doc copies top-level `satisfaction` only when present
(`copyAttrsIfPresent`), so an absent value kept the last score; the stat archiver
(`system/QDcGUYAmLvJwylXw`) treats a VAP's −1 as no data.

openUF's sources (`unifi/satisfaction.lua`, inputs from `openwrt/sysinfo.lua` via `report.lua`): SNR from `iw`'s `signal avg` (the last frame's `signal` without it) over the
radio's in-use survey noise; rates from `tx/rx bitrate` × 1000; the retry window from
`tx packets`/`tx retries`/`tx failed` deltas over ≥ 60 s; `tx failed` as drops except on mt76
(driver name `mt7*` from `/sys/class/net/<if>/device/driver`), where it counts failed attempts,
and the drops are `tx failed − tx retries` (table below; source in "mt76 retry counters" above).

Verified upstream 2026-10-10: ✅ lab (10.4.57) stores client `satisfaction`/`satisfaction_reason`/
`anomalies`, both VAP charts, `radio_table_stats` satisfaction 85/100 and the device's 90 =
(2·85 + 100)/3. ✅ Real controller (10.6.106), both APs: device 89/88, radios 98/83 and 84/100,
a client-less VAP −1, each client's score and reason. 10.6.106 lists `anomalies: -1` for
clients although the payload carries 0: the gateway overwrites it, see *Station fields* below.

Read-only side-by-side on both APs before the switch (40 samples, same `iw` reads): 5 GHz
clients 95–100 both ways; 2.4 GHz clients 100 → 75–85, all bound by phy_rate. A single-stream
HT20 client's top rate (72.2 Mbit/s) is ≤ 100000 kbps → 85, and an idle client's last rx frame
is often a 6–12 Mbit/s legacy one, which lowers the mean.

The estimator this replaced (min of downlink airtime efficiency and SNR, EWMA-smoothed, with the
per-station ceiling from `hostapd_cli all_sta`; the history below) was openUF's own design, not
UniFi's. A backhaul VAP's peers still feed neither the radio's nor the device's roll-up. What
changed in the numbers: see the README's WiFi Experience row.

**Station fields (upstream 074b070, 2026-10-10).** `fill_stainfo_json` (libubnt 4.0.15) emits, per station:
`mac`, `state` (u16 node flags), `state_ht` (flags & 0x8), `state_pwrmgt` (flags & 0x10),
`authorized`, `is_11b`/`is_11a`/`is_11n`/`is_11ac`, `is_11r` (only when its flag is set), `rssi`
(u8 SNR), `noise` (s16 dBm, unclamped), `signal` (`rssi + max(noise, −96)`), `tx_rate`, `rx_rate`,
`ccq`, `uptime`, `idletime`, `auth_time`, `dhcpstart_time`, `dhcpend_time`, `hostname` and `ip`
(when known), `tx_power`, the rx/tx counters, `1x_identity` (when set), `vlan_id`, `satisfaction`,
`satisfaction_reason`, `anomalies`, `wifi_tx_latency_mov`. Firmware-confirmed for 3.9.27 to 4.0.15.

What the 10.6.106 controller does with them (CFR on `internal-dependencies.jar`; the AP station
processor `devmgr/MwArZjlvuVhguZnuxGE` and the copy list in `devmgr/iceUMDuewFNFLMOqti`:
`ack_rssi, anomalies, anon_client_id, ccq, dhcpend_time, idletime, noise, nss, rx_rate, rssi,
satisfaction_now, satisfaction_real, satisfaction_reason, signal, tx_mcs, tx_power, tx_rate,
tx_retry_burst_count`, each copied when present):

| Field | Controller use | openUF |
|---|---|---|
| `rssi` | Read as SNR: mesh/uplink checks test `> 5`, the neighbour and uplink paths turn it into dBm with `rssi − 95`, the client-insight ranking (`wifi/k/rFCHnXVpfjjP`) uses it only when `> 0`, and the frontend falls back to a converted `rssi` where `signal` is missing | **Fixed**: was `signal` (negative dBm). Now SNR over the in-use survey noise, floored at −96 |
| `noise` | Copied; legacy `stat/sta` only (the v2 client API drops it) | **Added**, from the in-use survey entry |
| `state` | `powersave_enabled = (state & 0x10) != 0`, the only bit read; shown by the AI assistant's client summary | **Added**: 0x10 from mac80211 debugfs `stations/<mac>/flags` `PS_STA`, only on a radio whose `hwflags` lack `AP_LINK_PS`; absent elsewhere |
| `is_11r` | Copied as a boolean (`is("is_11r", false)`); `stat/sta` only, no 10.6 UI reader | **Added**, true when hostapd's `AKMSuiteSelector` is an FT suite (00-0f-ac-3/4/9/13/16/17/19/25) |
| `anomalies` | Copied, but see below | unchanged |
| `ccq` | Copied; no UI reader | Not sent: mac80211 has no CCQ |
| `dhcpend_time` | Copied; no UI reader | Not sent: no UI effect, and the firmware's unit (the struct field at 0x3c) is undecoded |
| `tx_power` | Copied; the UI's `tx_power` readers are all per radio | Not sent: the per-station value's source is undecoded |
| `1x_identity` | Client doc + `last_1x_identity` | n/a: openUF skips WPA-Enterprise WLANs |
| `vlan_id` | Not read (the client's `vlan` comes from the network) | Not sent |
| `ack_rssi`, `tx_retry_burst_count`, `channel_width` | Read by 10.x; not in 4.0.15's list | Not sent: no reference firmware to match (current builds are encrypted) |

Power save by driver, read-only on both APs (2026-10-10): ath9k (no `AP_LINK_PS`) showed
`PS_STA` on one of four stations in each of ten 1 s samples. ath10k and mt798x both set
`AP_LINK_PS` and never showed it, 0 of 13 stations over 10 s on mt798x with IoT clients
associated, so `false` there would be a guess and `state` is left out (the controller then reads
`powersave_enabled: false` either way).

**`anomalies: -1` on a UniFi-gateway site is the controller's.** Each client's record is written
by every device that reports it, last writer wins (`URbVkSXx`, stamping `_last_seen_by_<type>`).
The gateway's host pass (`ykWHwBYcfNAYxrjv` → `yChBbiXeSTK`) puts
`anomalies = port.getInt("anomalies", -1)` on every host behind a port, with no −1 guard
(`satisfaction` has one). The only hosts it skips are UniFi devices' own MACs and BSSIDs
(`CNSMptQSEDMQtIKop`), not their clients, so a real UniFi AP's clients get the same −1. Live,
10.6.106: 17 of 17 WiFi clients read −1 with `_last_seen_by_ugw` newer than `_last_seen_by_uap`,
and earlier the one client whose AP report was newest read 0. The lab has no gateway and keeps
the AP's value.

Verified upstream 2026-10-10 on both its APs against the real 10.6.106 controller: `stat/sta` shows `rssi`
45/44 for clients at −51/−48 dBm (noise −106 → floored −96 on ath10k, −92 on mt798x), `noise` −106 sent raw (2026-10-13: firmware 4.0.15
`fill_stainfo_json` stores the radio noise s16 unclamped and applies the −96 floor only to `signal`),
and `is_11r: true` on the six clients whose hostapd AKM is 00-0f-ac-9 or -4. No 2.4 GHz client
was on the ath9k radio during the check, so `powersave_enabled: true` has not been seen end to
end; the reader was checked against live debugfs.


**Per-driver tx counters (hardware, 2026-09-27).** `iw station dump`'s `tx retries` and
`tx failed` don't mean the same thing on every driver, and neither tracks end-to-end loss. The
firmware formula reads `tx retries` per frame (which mt76's failed-attempt count matches) and
`tx failed` as frames dropped (which mt76's does not, so it is ignored there). Each check pinged
a client from the AP 150 times (1/s) and
diffed the station's counters across the run:

| driver (`/sys/class/ieee80211/phyN/device/driver`) | Δ tx packets | Δ tx retries | Δ tx failed | ICMP lost |
|---|---|---|---|---|
| `mt798x-wmac` (mt76, AX3000T 2.4 GHz), Google Home Mini at −36 dBm | 227 | 74 | 74 (33 %) | 0 / 150 |
| same AP, a clean client at −61 dBm | 1884 | 1 | 1 | 0 / 150 |
| `ath9k` (Archer C5 2.4 GHz), the same Mini at −54 dBm | 325 | 129 | 3 (0.9 %) | 0 / 150 |
| `ath10k_pci` (Archer C5 5 GHz), lifetime only | 480383 | 115379 | **0** | not tested |

- mt76: `tx retries` equals `tx failed` exactly on every station. Both count **failed
  transmission attempts**, not lost frames: in a 30 s window a −71 dBm client logged 43 failed
  on 34 packets. The power-saving Mini's 33 % were attempts made while it dozed, then re-sent
  and delivered, hence no loss. (An earlier reading here took them for filtered power-save
  frames; the count above exceeding packets rules that out.)
- ath9k: `tx retries` counts every retry attempt, and can exceed tx packets. `tx failed` stayed
  small, but with no loss on the link it can't be shown to measure loss.
- ath10k: `tx failed` is never reported (0).

_History: the estimator before the firmware formula. The notes below explain the airtime terms it used; `tx duration` and the `all_sta` ceiling are no longer read._

**Per-station airtime and the link it measures (hardware, 2026-09-27).** `iw station dump`'s
`tx duration` (µs) is mac80211's per-station airtime, filled by drivers that call
`ieee80211_sta_register_airtime`. The ath9k, ath10k_core and mac80211 modules on the Archer C5
(kernel 6.12.94) all import it. It was present on every station of the AX3000T (mt76) and the
Archer C5's ath10k radio; the ath9k radio had no station to read. Whether retries are included:
- ath9k: yes, from source. `ath_tx_count_airtime()` adds `duration × (ts_longretry + 1)` plus
  every earlier rate's `duration × count`.
- mt76: yes, on hardware (table below: 4× the airtime per frame on the lossy client).
- ath10k: ⚠️ unknown. It passes the firmware's per-PPDU `tx_duration` from tx completions,
  and whether the firmware counts retries in it isn't documented.

AX3000T 2.4 GHz (ch 11, noise −83 dBm, ~12 % busy). Airtime was sampled over 8 minutes.
Loss and latency are from pings sent from a remote host every second for 10 minutes; the
path adds ~64 ms.

| client | signal | bytes/frame | Δfailed/Δpackets | µs of airtime per frame | uplink rate | ping loss | p50 |
|---|---|---|---|---|---|---|---|
| dishwasher | −71 | 97 | 88.8 % | **503** | MCS 3 | **7.8 %** (17.7 % over 1 min) | **142 ms** |
| robot vacuum, docked | −62 | 97 | 1.5 % | 127 | MCS 3 | 0.3 % | 66 ms |
| Google Home Mini (power save) | −36 | 129 | 47.7 % | 171 | MCS 7 | 0 (1-min test) | — |
| laptop | −61 | 953 | 0.4 % | 222 | MCS 7 | — | — |
| phone | −45 | 111 | 1.5 % | 123 | — | 0.2 % | 64 ms |
| the AP itself | | | | | | 0.5 % | 64 ms |

The dishwasher's tx rate stayed at MCS 7 (the rate-vs-ceiling score read 93, then 86) while
89 % of attempts failed. Rate control on mt76 doesn't step down for it. Airtime per frame
tracked the loss and the rate didn't. For small frames a clean link costs ~110 µs of fixed
overhead per frame on 2.4 GHz. Aggregated 5 GHz traffic ran at 38–43 µs per ~945-byte frame.

**The per-frame cost on 5 GHz (yesrab fork fd08b79, hardware there, 2026-10-03; ported
here 2026-10-04).** On the fork's AP (mt76), a −43 dBm HE80 2×2 laptop at HE-MCS 11 with
2.6 % retries spent **266 µs per unaggregated 782-byte frame** (interactive traffic, one
frame per PPDU) and scored 49 "Poor" under the 110 µs figure, while a phone beside it,
aggregating ~30 frames a PPDU at 38 µs each, scored 97. The fork's reading: mt76's
`tx duration` counts the HE preamble, the BlockAck and the RTS/CTS the driver adds on wide
channels, so an unaggregated frame simply costs more there. The fixed cost is now per band:
110 µs on 2.4 GHz (`ng`), 250 µs on 5 GHz (`na`, and `6e`, which this port adds; the fork
checks `na` only, and `band_for_device` maps 6 GHz radios to `na` anyway). Not re-measured
here: the 266 µs, the 2.6 % retries and the RTS/CTS are the fork's hardware, not ours.

Checked against 802.11 timing, the number holds but the "band" reasoning only holds as a
proxy. The band's own timing is nearly the same: the slot is 9 µs on both (2.4 GHz ERP/HT
with short slot; 5 GHz OFDM); SIFS is 16 µs on 5 GHz and 10 µs plus a 6 µs signal extension
on 2.4 GHz; DIFS is 34 against 28 µs. If anything the 2.4 GHz band is the dearer one: with
an 802.11b station present, ERP protection adds a CTS-to-self at a DSSS rate (192 µs long
preamble plus 112 µs for 14 bytes at 1 Mbit/s), the slot reverts to 20 µs and DIFS to 50 µs.
What does differ is the PHY and the driver:
- preamble: HT-mixed is 36 µs (1 SS) / 40 µs (2 SS); VHT 40/44 µs; HE SU is 20 µs legacy +
  RL-SIG 4 + HE-SIG-A 8 + HE-STF 4 + one HE-LTF per stream (8 µs at 2× LTF, 1.6 µs GI;
  16 µs at 4×), so 52–68 µs for 2 SS, plus a packet extension of 0–16 µs;
- RTS/CTS at 24 Mbit/s: 28 + 28 µs plus two SIFS = 88 µs; at 6 Mbit/s, 52 + 44 + 32 = 128 µs;
- the compressed BlockAck at 24 Mbit/s: 32 µs.

So an unaggregated HE80 frame with RTS/CTS is about DIFS 34 + RTS/CTS 88 + preamble 52 +
PE 16 + one 13.6 µs data symbol + SIFS 16 + BlockAck 32 ≈ **252 µs**, which matches the
fork's 266 µs with its 2.6 % retries; the same frame without RTS/CTS is ≈ 164 µs. An HT20
frame on 2.4 GHz is DIFS 28 + preamble 36 + ~4 µs of data + signal extension 6 + SIFS 10 +
ACK 28 + 6 ≈ 118 µs, against the ~110 µs measured (whether mt76's figure includes DIFS
and backoff is not known; backoff would add ~68 µs on average at CWmin 15). The extra
~140 µs is therefore the HE preamble and the RTS/CTS, which follow the client's PHY and
the driver's protection policy, not the band. ⚠️ Consequences, not corrected here because
there is no hardware measurement to calibrate a per-PHY figure against: an HT or VHT
client on 5 GHz without RTS/CTS (true cost ~120–170 µs) is now judged against 250 µs, so
it can spend up to ~1.5–2× its real per-frame airtime before the term moves; and an HE
client on 2.4 GHz is still judged against 110 µs, though its preamble alone is ~52 µs.

**The per-band figure after upstream's re-send gate (merged 2026-10-10).** Upstream's
changes below (a window judged only when re-sending; the station's own clean cost per frame as
the baseline) supersede most of what the per-band figure was for: the fork's 2.6 %-retry laptop
now scores 100 on a clean window whatever the figure. The per-band figure is kept as the *floor*
of the per-station baseline (upstream floors it at 110 µs everywhere), so a 5 GHz client's
re-sending window before it has a clean one is judged against 250 µs, and a clean window can't
set a baseline below it. Unit-tested (`test_inform_json.lua`), not re-measured on hardware.

**Airtime on a clean link (hardware, 2026-10-08).** The 110 µs figure scored clean links
Poor once the usteer sync stopped reaching clients (4f1a13a). Until then, every client got
~16 KB/s of large frames that filled each airtime window (controller history: a 2.4 GHz sensor's
tx fell from 48 MB/h to 1 MB/h in the deploy hour, and its score dropped from 88–92 to ~40 in the
same hour). Without the sync, a window holds only the client's own frames:

| client (office AP, mt76) | Δ frames | re-sends | µs of airtime per frame | ping |
|---|---|---|---|---|
| HT sensor, 2.4 GHz, −59 dBm, 89-byte pings | 194 | 14 (7 %) | 255 | 0 / 60 lost, avg 2.4 ms |
| VHT laptop, 5 GHz, −53 dBm, ~1.2 KB frames | 2487 | 13 (0.5 %) | 257 | 0 / 40 lost (power-save RTT up to 135 ms) |

Some of the laptop's airtime is not airtime at all. Over 60 s, mt76 charged it 711 ms of
`tx duration`, while the radio's survey `channel transmit time`, beacons included, rose by
478 ms in the same minute. The station sum on the same AP's 2.4 GHz radio stayed plausible
(96 ms of 423 ms). Its windows scored 7–60, and a busy-traffic gate couldn't tell these apart,
since the share is computed from the same counter. So a window's airtime is judged only when the
driver re-sent ≥ 20 frames per 100 in it. A cleaner window counts as 100. All three drivers report
`tx retries` (ath10k: no `tx failed`). Read-only replay over 3 minutes against the deployed build:

- **Office:** the laptop went from 28–89 to 100 and the sensor from 31–49 to 90–92. The dishwasher, vacuum and weak
  phone were unchanged. They are bound by SNR and uplink.
- **Living room:** a new client at −43 dBm went from 27 to 100.
- Every other client was the same or higher.

**A station's own clean cost per frame (hardware, 2026-10-09).** Some clients take far more than
110 µs per frame on a clean link. A 2.4 GHz IoT client on the office AP (mt76, MCS 7, ~100-byte frames)
took 200–440 µs per frame in windows with 0–4 % re-sends, and 3300 µs per frame in two windows
with none (its tx rate read 1 Mbit/s at times). The Mini, the vacuum and the dishwasher took 107–132 µs
per clean frame. In 20-frame windows a client re-sending ~10 % of frames crosses the 20 % gate in
about one window in eight (binomial), and such a window scored 30–50 against 110 µs, although its
re-sends had added little airtime. So a re-sending window is now judged against the station's own fixed
cost per frame: from each clean window, its airtime less its payload at the ceiling, per frame, floored
at 110 µs. The median of the last 5 is the baseline, so one odd window moves nothing, and without a
clean window yet the 110 µs model applies. Read-only probe of the new code over 4 minutes: the
baseline settled at 180–410 µs. One window that re-sent frames cost about twice that and scored
55 % (17 % against 110 µs), so the downlink term dipped only to 91. The client's score then followed
its SNR (18–21 dB, 78–92). Replay against the deployed build: its lows went from 76 to 82. Clients
whose clean frames cost less than 110 µs (the Mini, an AC unit with 760-byte frames) keep the model and
scored the same. The dishwasher's clean frames cost ~127 µs, so its lossy windows still score ~25.

**The uplink rate is not scored (hardware, 2026-10-09).** After the change above, the uplink
term was the binding term only for phones. On the controller, a Pixel 9 sat at 55–56 for two hours at
−72 dBm, where SNR alone gives 90. A read-only sample of every client's `rx bitrate` (every 10 s
for 3 minutes, both APs, with frame counts and sizes) showed:

| client | AP, band | signal | SNR | uplink MCS |
|---|---|---|---|---|
| Pixel 9 | office, 5 GHz HE (mt76) | −62 dBm | 30 dB | HE 3, 2 streams, 80 MHz (288 Mbit/s); scored 63 |
| laptop (HE) | office, 5 GHz HE | −60 dBm | 32 dB | HE 8–9 |
| Pixel 9 | living room, 5 GHz VHT (ath10k) | −55 dBm | 40 dB | VHT 6–8; scored 75–84 |
| speaker | living room, 5 GHz VHT | −61 dBm | 34 dB | VHT 9 |
| realme phone | living room, 5 GHz VHT | −68 dBm | 26 dB | legacy 6 Mbit/s or HT 130 Mbit/s; scored 66 from one sample |
| 2.4 GHz clients | office, HT 20 MHz (noise −77 dBm) | −34 to −70 dBm | 43 → 7 dB | MCS 7 down to 2–3, falling with SNR |

- **Phones:** they send 2–5 MCS below a neighbour at the same signal while their downlink is
  clean (no re-send window). That is the phone's rate choice, not a failing link.
- **2.4 GHz:** the uplink rate falls with SNR, so it re-measures what the coverage term already
  scores. The vacuum it was added for (uplink MCS 3) is now SNR-bound at ~60, as is the dishwasher.
- **The input:** `rx bitrate` is the last frame's rate. Even in a window of ≥ 20 frames, a 6 Mbit/s
  legacy frame or a 20 MHz HT frame often decides the sample.
- **Coverage elsewhere:** a weak uplink shows in SNR, since `signal` is the client's own signal as
  heard by the AP. Interference at the client shows in the downlink re-sends.

So the score is the worse of downlink airtime and SNR. Read-only replay over 3 minutes against the
deployed build:

- **Living room:** the Pixel 9 went from 75–84 to 100, the realme from 75–83 to 82–100 (its dip
  came from a judged re-send window), and a Pixel 3 from 90–91 to 91–99.
- **Office:** the HE laptop went from 94 to 100. The other clients stayed within ±4, sampling jitter
  between the two concurrent probe processes. Removing a term from a minimum can only raise the score.

Both ath10k and mt76 report a per-station `rx duration`, which would average the uplink over all
frames instead of the last one. It would still mark the phones down, since they really do send
at those rates, so it is not used.

### `port_table[]` entry

Processed only when `Device.isSwitch()` is true for the reported model —
`hasFeature(UiHQyVmgX) || hasFeature(yojQKHv)`. The model registry
(`com.ubnt.data.dhdeXcHqLRBKMUZk`) registers `U6IW` as device type `uap` with **5 ethernet
ports** and the switch feature, matching reality (a U6-InWall has a built-in 4-port downstream
switch). A plain AP like `U6MP` is not a switch. So for the model openUF impersonates, this is
not optional: an empty `port_table` means zero wired clients can ever appear.

One entry per `cfg.net.ports`. Each entry carries `port_idx` (1-based), `name`, `media`,
`up`, `enable`, `speed`, `full_duplex`, `is_uplink`, `speed_caps`, `port_poe`, `poe_caps`
and `rx_bytes`/`tx_bytes`/`rx_packets`/`tx_packets`/`rx_errors`/`tx_errors`. Where those
facts come from depends on what the board can be asked:

**Per-socket (swconfig board, modelmap field `{idx, swport}`).** One entry per physical
socket. `up`/`speed`/`full_duplex`/`pvid` and the ARL table come from a single
`swconfig dev <sw> show` (`sysinfo.switch_status`), and `is_uplink` is set on the socket the
default gateway's MAC was learned on (`sysinfo.uplink_phys_port`) — detected, never declared,
because on an AP the cable is in whichever LAN socket the installer used. Counters are the
switch's own per-port MIB (`RxGoodByte`/`TxByte`; there are no per-port packet or error
counts, and an AR8327 with `ar8xxx_mib_poll_interval: 0` has no MIB at all), falling back on
the uplink entry only to the CPU netdev's `sysinfo.interfaces()` counters — everything the
CPU sent or received crossed that socket. Other sockets report `0` rather than a fabricated
share of the same total.

The two shapes mix within one board, per port: an entry with no `swport` falls through to
the netdev source below even when the switch answered. That is not a fallback but the right
answer for a socket wired to its own MAC and PHY rather than to the switch — the
TL-WDR3500's WAN socket is a second `ag71xx` surfacing as `eth1`, so sysfs there describes
that socket and not the CPU's link.

**Netdev (no switch, no swconfig, or no identifiable uplink — modelmap field
`{idx, ifname, uplink}`, defaulting to `{wan_cpueth=uplink, lan_cpueth=lan}`).** `up` from
sysfs `carrier`/`operstate`, `speed`/`full_duplex` from sysfs, counters from
`sysinfo.interfaces()`, `is_uplink` from the modelmap. On a swconfig board every one of
those describes the *CPU port* — the internal SoC↔switch link, always 1000/full — which is
why this is the fallback and not the default. Confirmed live: a TL-WDR3500 reported GbE on
an uplink whose socket had negotiated 100baseT, and the gateway's own Ports view said FE for
the same cable.

**On a DSA board the netdev path is not a fallback — it is the right source.** There is no
`swconfig` binary at all, and none is wanted: each socket is its own netdev (`wan`, `lan2`,
`lan3`, `lan4` on a Xiaomi AX3000T — no `lan1`, since DSA names ports from the device tree
rather than the case labels), so sysfs already describes that socket's own cable. The one
thing sysfs cannot say — which socket faces the controller — comes from the bridge instead
of an ARL table: `bridge fdb show br br-lan` names the port each MAC was learned on, and
`sysinfo.uplink_bridge_port` looks up the default gateway's there. Same discipline as the
swconfig path (measured, never declared), different source. Filter on `master` *and*
`permanent`: the port's own address arrives as `<mac> dev wan master br-lan permanent`, a
master line like any other, and counting it puts the AP's own socket MAC in its client list.

Verified live on an AX3000T against a real UCG Ultra: four ports rendered, port 1 flagged
uplink at GbE with no `mac_table`, port 2 at **FE** with its host, port 3 disconnected, port
4 at GbE with its host and the controller's own IP for it. The FE/GbE split is the thing
worth noting — the netdev path reported two different negotiated speeds on one board, which
is exactly what the swconfig CPU-port path could never do.

**Non-uplink ports additionally carry `mac_table[]`** — `{mac, ip, hostname, age, uptime,
vlan}`, where `vlan` is present only for a socket openUF has assigned to a VLAN and is what
places the client on the right *network* (see the `isqI` selection rule above; absent means
1),
joined with `/proc/net/arp` for IPs and `/tmp/dhcp.leases` when present for hostnames
(optional — an AP is usually not the DHCP server; `hostname` stays absent rather than
invented). The host list itself is per-socket from the ARL table
(`sysinfo.switch_mac_table`, multicast/broadcast MACs filtered on the address bit), or
`sysinfo.mac_table(ifname)` off `bridge fdb show dev <ifname>` on the netdev path (dynamic
`master br-lan` entries only; `self`/`permanent` and multicast/broadcast filtered).
`bridge fdb` can only ever say "behind the CPU port", so on a switch board it cannot place a
host on a socket — that is what the ARL adds. Sockets whose `pvid` is not the management
VLAN carry no `mac_table` either: the Archer C5's WAN socket is live and has learned a host,
but it sits on VLAN 2 with its CPU port down, so that host is not on the LAN it would be
listed in.

Ports flagged `is_uplink: true` are skipped by the controller for client creation, since that
port faces the controller's own network.

**An uplink port must carry no `mac_table` at all — not even the gateway.** Reporting just
the one MAC on the other end of the cable is tempting: openUF knows it (finding it is how the
uplink socket is identified), a real UniFi gateway visibly does it on its own uplink port, and
it would fill the Ports view's Connection column, which is otherwise blank or stuck on a
retained "last seen device". It would also invert the topology map. The controller matches
every MAC on a port against its adopted devices, and a port carrying exactly one known device
files that device into this one's `downlink_table` (`wRSpUfdrmMXnppHBKZ`):

```java
bl9 = !is_uplink && device.isUplinkMac(neighbour);
if (!bl9) downlink_table.add(neighbour, port);
```

The `isUplinkMac` guard that would prevent it is ANDed with `!is_uplink`, so it disables
itself on exactly the port where it is needed — the gateway would hang beneath every AP that
reported it. A real gateway escapes this because its upstream is the ISP's router, which is
not an adopted device and never reaches that branch; openUF cannot tell the two cases apart
from the device. Verified on the live site: with both APs silent on their uplinks, each AP's
`downlink_table` is empty and the gateway's holds both APs, which is the correct shape.

A blank Connection column on an uplink port is therefore intended. `last_connection` is only
recomputed when a port reports exactly one MAC (`wefewPevorbc`: `if (list.size() > 1) return
existing`), and is never touched at all when the port sends no `mac_table` field — which is
why a stale value there persists until cleared with the Ports view's **Clear Last Seen
Device**.

Two exclusion filters prevent double-reporting: the device's **own** MACs, and any MAC
currently associated as a wireless station — a wireless client bridged into `br-lan` genuinely
appears in the bridge FDB too.

**Wired hosts will never show per-client traffic**, by design. `TtZhv` reads only
`mac`/`ip`/`hostname`/`age`/`uptime` off each `mac_table` entry; there is no per-client byte
counter anywhere in the wired-client wire protocol. A wired client's traffic is attributed via
its switch port's own counters.


### The WiFiman reply (`:8900/proxy/`), and what iOS needs from it

**Confirmed on hardware 2026-10-03** (UCG Fiber, Network 10.6.106, WiFiman 2.13 on Android and
iOS, three openUF APs). WiFiman calls `https://<default gateway>:8900/proxy/` (Android 2.13:
`We/j`, port default 8900 in `We/i$b`, host = the interface's gateway). On the console that port
is `/usr/bin/wifiman-proxy`, which forwards to the Network application's
`/v2/api/site/default/wifiman` with a token. The reply is built by
`com.ubnt.service.wifiman.RxFvcetMTlkSFFxK` straight from the calling client's record:
`channel`, `channel_width` (`getIntOrNull`), `rx_rate`/`tx_rate`, `signal`, `noise`,
`radio_proto`, `satisfaction`, `radio`, plus the uplink topology and `nearest_neighbors`
(the AP-to-AP store below).

iOS cannot read the RSSI itself, so iOS WiFiman takes its signal from this reply; Android reads
its own and works regardless. With openUF sending neither `chwidth` nor `noise`, the reply for a
client at 192.0.2.33 came back complete except `"noise": 0` and **no `channel_width`**, and iOS
showed *Signal Data Unavailable* / *Floor Plan Unavailable* ("Connect to a network served by
UniFi Gateway Console"). Captures on the console's bridge showed the phone reaching `:8900`
(and the `:8901` speed test) every time, so the gateway was never the problem. Adding `noise`
alone changed nothing (reply `-92`, still unavailable). Answering discovery probes (below)
changed nothing. Adding `chwidth` made the reply carry `"channel_width"`, and both views worked.

### Discovery probes (UDP 10001)

Captured 2026-10-03 from the console's bridge while iOS WiFiman opened its Signal tab: the
phone sent `01 00 00 00` and `02 00 00 00` from an ephemeral port to `255.255.255.255:10001`
and to `233.89.188.1:10001`. The UCG Fiber answered every **v1** probe with a v1 packet
(`01 00 <len>` + TLVs, the same TLV numbering as the v2 announce: 0x0b hostname, 0x0c/0x15
platform, 0x03/0x16 firmware, 0x0a uptime, 0x17 default, 0x01/0x02/0x2f/0x32 addresses), unicast
**from port 10001** to the probe's source address and port, and answered no v2 probe. openUF
only broadcast, from a random port, and so never answered. `announce.lua` now does what the UCG
does; all three APs were seen answering unicast, broadcast and multicast probes. It is not what
WiFiman needed (above).

### AP-to-AP neighbours (`is_unifi` scan entries)

10.6.106 `com.ubnt.service.aS.qikih` (scan ingest): an entry with `is_unifi` is resolved by
`serialno` (or a Ubiquiti-OUI BSSID) to a device, accepted while `age <=
inform.interval + 10` (`devmgr.OWIoHe`, default 100 s; the rogue path's cutoff is 30 s), and
written to the `peer-scan-cache` (`aS.eevUQSYcUHYjkbIHTHo`, Caffeine `expireAfterWrite` 3600 s).
`com.ubnt.service.wifi.LUdHVFmmB` lists, for a client's AP, the cached sightings that AP made of
other devices (signal type `AP_AP`): WiFiman's `nearest_neighbors`. The sighting record
(`aS.LUdHVFmmB`) copies `model` and `model_display` **from the reporting AP's scan entry**, not
from the resolved device, so a sibling entry without them reaches WiFiman nameless. openUF's
sibling packets (v3) carry each AP's `model`/`model_display` and tagged entries get them.
Confirmed on hardware 2026-10-03: the reply's neighbours went from no name to
`"model_display": "U6-IW"` / `"U6-Pro"`; `model` stays absent in the reply. On 2026-10-03 the three
APs' scan caches held 0–9 BSSes each and no sibling, because they sit on different channels;
the one neighbour listed came from an overlapping 2.4 GHz channel. Hence the sibling BSSID
exchange and the idle-radio sweep (README).

### `scan_radio_table[]` entry

Backs Insights → AirView → **Environment** (`GET /api/s/default/stat/rogueap`). Built from
`iw dev <ifname> scan dump` — the kernel's already-cached BSS list, cheap and non-disruptive,
unlike the `spectrum-scan` cmd's real scan trigger.

Nested shape (confirmed against `PGOcbDWlbnYQdFW`, which reads a top-level `scan_radio_table`
array and hands each entry's nested `scan_table` to the ingestion service — not a flat list):

```
scan_radio_table[] = { radio, name, scan_table[] }
```

Per `scan_table[]` entry — the consumer DTO `com.ubnt.service.aO.bLwwMKkr` (literally named
`"PeerScan"` in its own builder's `toString`) confirms the full field list:

| Field | Notes |
|---|---|
| `mac`, `bssid`, `essid`, `channel`, `freq`, `signal`, `rssi`, `security` | |
| `radio`, `radio_name` | |
| **`band`** | A field **distinct from `radio`** but taking the identical enum values. The Environment tab's list selector applies an *unconditional* filter upstream of every visible sidebar filter: `A.filter(A=>!!T.R?.[A?.band]?.[A?.bw>0?A.bw:m.L?.[A?.band]])`. `T.R[undefined]` is `undefined`, so an entry without `band` fails silently for every row — indistinguishable from "no data", regardless of filter state. |
| **`bw`** | Channel width MHz. The "Ch. Width" cell reads it directly and renders nothing when falsy: `renderCell:({bw:A})=>A?…:null`. Parsed from `iw`'s `BSS operating channel width: N MHz` (only present for HE/VHT-capable neighbours), defaulting to `20` — legacy-safe and valid on both bands. |
| **`age`** | **Elapsed seconds, not an absolute timestamp.** The ingestion code reads `getInt("age")` and computes `last_seen = report_time − age` itself; it also **silently drops any entry with `age >= 30`** as a staleness guard. Sending an absolute timestamp under either key yields an empty result with no error. Parsed from `iw`'s `last seen: N ms ago`. |

**`essid` is decoded from iw's escaping.** `iw` prints every SSID byte that isn't printable
ASCII as `\xNN`. That covers all UTF-8 bytes, a backslash, and a leading or trailing space.
Passed through as-is, a hotspot with an accented name showed up in the tab as literal
escapes (seen live 2026-09-27), e.g. `Caf\xc3\xa9 Guest`. The controller's evil-twin check (`essid ∈ site SSIDs`) would also
miss a site SSID written that way. Decoding is unambiguous because iw escapes the backslash
too. An empty or NUL-filled (hidden) SSID is sent with no `essid`, and the tab shows the BSSID.

**Three Environment columns are the controller's, not the AP's** (10.6 bundle
`react-app-wrapper`, column list `Wt`):

- **Standard** (`WIFI_STANDARD`) renders `jt[row.radio.toUpperCase()]`, a fixed map whose
  English strings are `NA` "802.11n/a/be", `NG` "802.11n/b/g/be", `6E` "802.11ax/be",
  `NA_AC` "802.11n/a/ac", `NA_AX` "802.11n/a/ac/ax" and `AD` "802.11a/d". It describes no
  neighbour's PHY. The scan ingest (10.6 jar, `com.ubnt.service.aS.qikih`) overwrites every
  row's `radio` with the **parent** `scan_radio_table[].radio` before storing it, whatever
  the row sent. Only for the pseudo-radio `scan` does it use the row's `band` instead. So a
  stored `radio` is always a band name (`na`/`ng`/`6e`), and every 5 GHz row reads
  "802.11n/a/be", even a 2014 802.11ac router, on a real UniFi AP too. The `NA_AC`/`NA_AX`
  keys are unreachable through `stat/rogueap`. Sending a per-row standard is impossible, and
  renaming the parent radio would mislabel every row the same way and break the
  consumers keyed on `na`/`ng` (Radio AI's band filter, `kFACvOhX`). Established 2026-10-13.

- **AP** (`AP_COUNT`) is not a per-row field. Rows are grouped by `essid`, and the cell shows
  `children.length + 1` only on a group's parent row. A BSS alone under its name is blank, on
  a real UniFi AP as well.
- **Vendor** renders `oui`, which the controller fills from the BSSID. No AP sends it, and
  `PeerScan` has no such field. It stays blank for locally-administered BSSIDs (random or
  virtual, so no vendor exists) and for OUIs missing from the controller's database. Live:
  23 of 42 rows resolved. Of the 19 blanks, 14 were locally-administered BSSIDs and 5 came
  from two universal OUIs (`84:78:48`, `b8:fb:b3`) that the controller doesn't know.

#### Enriching it without scanning — 802.11k beacon reports

`scan dump` reads the kernel's **passive** BSS cache, which fills only from beacons the
radio overhears on the channel it already serves. Measured 2026-09-02: 6 BSSes on a 2.4 GHz
radio on ch 11, 1 on a 5 GHz radio on ch 44, and **0** on the Archer C5's 5 GHz radio. An
active sweep on the same board found 21 BSSes across 8 channels on 2.4 GHz — but cost 12%
packet loss to an associated client for the ~3 s it ran, against a 0% baseline.

Ubiquiti's own documentation names the way out: Channel AI "scans the surrounding wireless
environment using **neighbor reports and automated RRM scans**". In an 802.11k beacon
measurement the *client* leaves the channel and reports back, so the AP never stops serving.
`openuf/rrmscan.lua` implements exactly that, and nothing else.

Delivery mechanics, all established live:

| | |
|---|---|
| Request | `ubus call hostapd.<iface> rrm_beacon_req '{"addr":…,"mode":1,"op_class":115,"channel":255,"duration":50}'`. mode 1 is *active*; mode 2 (beacon table) reports from a cache that may be empty. `channel: 255` means every channel in the operating class |
| Response | Arrives asynchronously as a ubus **notification** on the per-BSS object. `ubus listen` catches broadcast events and receives **nothing at all** here — a listen across two requests captured 0 notifications while a `ubus subscribe hostapd.<iface>` over the same window captured 22 |
| Fields used | `bssid`, `channel`, `rcpi`, `rep-mode`. RCPI is the 0.5-dBm scale anchored at −110 dBm (802.11-2020 9.4.2.38), so **dBm = rcpi/2 − 110** — checked against a sighting of the client's own AP at rcpi 124 → −48 dBm |
| Fields refused | A non-zero `rep-mode` means incapable/refused/late and must not be published; captured examples also carry an all-zero BSSID on channel 0 |
| Parsing hazard | `start-time` holds a raw 64-bit TSF that real clients emit past what a double represents (`-7160986498777481216` captured), so the payload is matched field-by-field rather than JSON-decoded |

What one request actually returned: **15 BSSes at once**, across 2.4 GHz channels
1/3/4/6/7/9/10/11 *and* 5 GHz channels 36/44/48 — from a client associated on a 5 GHz
radio. Clients ignore the requested operating class's band restriction, so one report
enriches **both** radios; the merge therefore keys on the reported channel's band, never on
the interface the request left by.

Client support is a lottery and this can only ever supplement the passive cache. Of 13
clients surveyed across two APs: 9 advertised no 802.11k at all (`rrm=0`), 3 advertised
beacon-active + beacon-passive and answered in full, and 1 advertised **beacon-table only**,
acknowledged every request (`BEACON-REQ-TX-STATUS … ack=1`) and never sent a report —
hostapd itself refuses a passive request for such a client with "does not support passive
beacon report". Table-only is therefore not treated as capable.

When a report carries no frame body (see below), two fields deserve care on the way into
`scan_table`, and they are handled differently:

- **`bw` is set to 20.** Not a guess: every AP occupies at least its 20 MHz primary. It also
  cannot safely be omitted — the tab's unconditional filter indexes
  `T.R[band][bw>0 ? bw : <per-band default>]`, and a falsy `bw` falls through to a default
  this build may not define, which drops the row silently. 20 is confirmed to render.
- **`security` is left absent.** There is no floor to fall back on, and writing `open` states
  in the operator's rogue-AP view that a neighbour is unencrypted when nothing measured it.
  Observed live: four WPA2 neighbours all rendered as "open" before this was removed. With
  the field absent the cell renders blank, the sidebar's Security filter disappears (no
  values to offer), and the rows still render — confirmed.

Verified end to end 2026-09-02 on the Archer C5's 5 GHz radio, whose passive cache held
**zero** BSSes: after one beacon request the controller's Environment tab listed **four**,
at −53/−69/−81/−81 dBm on ch 36/44/48 — one of them `00:00:5e:00:53:05`, the *other* AP's
5 GHz BSS, which this radio cannot hear from another room but the client could.

#### The frame body: hostapd's control socket, not ubus (2026-10-12)

The AirView WiFi Scanner showed 5 GHz rows named by their BSSID, with no Security, at 20 MHz.
A real scan had reported the same BSSIDs with SSID, `wpa2` and 80 MHz. The next 802.11k report
for each BSSID replaced that record. Read-only captures on both APs, OpenWrt 25.12,
`wpad-mbedtls 2025.08.26~ca266cc2`:

- **ubus has no body.** The `beacon-report` notification carries `address`, `op-class`,
  `channel`, `start-time`, `duration`, `report-info`, `rcpi`, `rsni`, `bssid`, `antenna-id`,
  `parent-tsf` and `rep-mode`, and nothing else. OpenWrt's current `ubus.c` adds a base64 `report`
  with the whole element. This build does not have it: 11 notifications were captured and none carried it.
- **The control socket has it.** `rrm.c` also emits `BEACON-RESP-RX <sta> <token> <rep_mode hex>
  <report hex>` to attached monitors. A `hostapd_cli -i <bss>` caught one from a client on the
  Archer's 5 GHz BSS. Subelement 1 (Reported Frame Body, 205 bytes) held the fixed fields
  (capability `0x1011`, privacy set) and then these elements: SSID, rates, Country, RSN (AKMs
  PSK, FT-PSK, PSK-SHA256, SAE, FT-SAE), RM capabilities, HT capabilities, HT operation (primary 36),
  extended capabilities, VHT capabilities, VHT operation (width 1, centre 42, so 80 MHz) and
  Tx power envelope. Subelement 2 (Reported Frame Body Fragment ID) was `01 80`: fragment 0
  with the *more* bit set. The body was cut, and the vendor elements at the end of the beacon were lost.
- **Why clients send it.** `rrm_beacon_req` includes no Reporting Detail subelement (ubus
  takes `addr`, `mode`, `op_class`, `channel`, `duration`, `bssid`, `ssid` only), and an absent
  Reporting Detail means level 2, all fixed fields and elements.
- **`hostapd_cli -a <script>`** runs `<script> <ifname> <event words…>` for each event, verified
  on the Archer: `$1=phy0-ap0 $2=BEACON-RESP-RX $3=<sta> <token> <mode> <hex>`. About 0.9 MB RSS per process.
- **The fixed `channel` field can be the centre channel.** Several 5 GHz BSSes were reported with `op-class 81`
  or `129` and `channel 42`, including the Archer's own BSS on 36. The HT operation element's
  primary channel is the reliable one.

- **What a client actually sends varies.** Four bodies captured after the deploy, from one client
  on the Archer:
  - 205 bytes, fragment 0 with the more bit set.
  - 218 bytes, the same.
  - 218 bytes with a vendor element mid-list and Country after Tx Power Envelope. The beacon's
    element order does not survive.
  - **32 bytes holding only the SSID and one vendor element**, privacy set, no fragment
    subelement. This is a filtered body.
  The rest of a fragmented body came as a **separate report for the same BSSID**: fragment 1,
  its body starting mid-beacon. A first parser rule read "privacy, no RSN, not flagged as cut"
  as `wep`, and the 32-byte body went out as WEP at 20 MHz.

openUF (`rrmscan.parse_report`) therefore treats anything missing from a body as unknown and
takes each field only from an element that is present:
- essid: the SSID element (empty or NUL means hidden, nil).
- security: `wpa2` for RSN, `wpa` for the WPA vendor element, `open` when the privacy bit is
  clear. Never `wep`.
- bw: VHT operation on 5 GHz and HT operation on 2.4 GHz, through `sysinfo.channel_width`, the
  same decision as the scan cache. A 5 GHz body without VHT operation gives no width, and the
  merge's 20 MHz floor applies.
- channel: the HT operation primary.
A continuation fragment returns nil, so it can't take its BSSID's place ahead of fragment 0.

**This AP and its siblings.** Clients report the AP they sit on and its siblings like any
other BSS. Live: the Archer listed its own BSSIDs at −11 dBm, and the office AP
listed the Archer's 5 GHz BSS. Once the SSID is filled in, a sibling carrying a site SSID
without `is_unifi` triggers the controller's rogue check. That happened live: *"This third-party access
point is broadcasting your network's SSID"* on the Archer's BSS, as reported by the office AP. The
tag cannot come from a report, because the identity element is a vendor element at the end of the beacon,
past the cut. So the merge skips this AP's own BSSIDs (`vap_table`) and usteer's
remote-node BSSIDs (`ubus call usteer remote_info`). If usteer is not answering, a reported BSS carrying
one of this site's SSIDs is sent without `essid`, so it can't raise a false alert. An evil twin that only a client
ever saw is then not flagged.

What a real UniFi AP does (firmware-confirmed for 3.9.27 to 4.0.15, BZ2 4.0.15 `/bin/mcad`
`prepare_scan_array`): it sends the driver's scan list (`libubnt` `get_scanlist` →
`parse_scan_results`) with no BSSID filter. The only entry it drops is one on the other
band, decided from the entry's mode string. Siblings therefore reach the controller, tagged
`is_unifi`/`serialno` from their vendor element. The controller's scan ingest (10.6
`qikih`) sends a row with `is_unifi` down the UniFi-device path and never stores it as
a `stat/rogueap` row. A radio does not hear its own beacons, and the other radio's BSSes
are on the other band, so the AP's own BSSIDs never appear. On a real UniFi site, the WiFi Scanner
shows no row with the site's own SSIDs unless a third party broadcasts one. openUF matches
this: passive and 802.11k rows tag siblings `is_unifi` (see the sibling note above), and
802.11k rows skip the AP's own BSSIDs. Rows with site SSIDs that were stored before 2026-10-13 00:00 stay
in the scanner's 1-day window until they age out.

**Two copies of each report (2026-10-13).** hostapd's `rrm.c` emits the control-socket line
first and the ubus notification second. They reach the event file through different
processes (`hostapd_cli -a` and the `ubus subscribe` loop) and often land in different
10-second drains. openUF's per-BSSID cache kept whichever came later, so the bodiless ubus
copy replaced the named record. Live in the WiFi Scanner, every row of one office-AP report
went out unnamed at 20 MHz on the centre channel 42. A bodiless record now keeps the essid,
security, width and primary channel that a body proved for the same BSSID and band. It
still updates the level and time.

**Not every client writes RCPI into the RCPI field (2026-10-13).** One office 2.4 GHz client
wrote signed dBm. It reported its own AP as `0xbf`, which is −65 dBm read as signed and
−14.5 dBm read as RCPI, while `iw station get` measured it at −71 dBm. Every neighbour it
reported came out between −11 and −26 dBm. The same byte goes to both the control socket and
ubus. openUF now decides per station which way it writes the byte, using the one BSS whose
true level is known: the station's own AP, which every captured report includes. The
station's report for that BSSID (`iw dev <if> info`) is compared with hostapd's
`signal avg` for the station (`iw dev <if> station get`). If the signed reading is within
12 dB and the RCPI reading is more than 20 dB off, the station is treated as signed. If the
RCPI reading is within 12 dB, it is treated as standard. Otherwise the sample decides nothing.
The decision lasts for the daemon's lifetime and applies to that station's ubus reports too.
An uncalibrated station is read the standard way (the capture `rcpi_to_dbm` was checked on:
124 → −48 dBm for a client on the Archer). After the fix, the office client's neighbours came out at −67 to
−84 dBm.

`is_rogue` is much narrower than the tab name suggests: set true only when a neighbouring BSSID
broadcasts the **same essid as one of the site's own configured networks** (an evil-twin check
raising `EVT_AP_DetectRogueAP`). Ordinary neighbours correctly have `is_rogue: false` and still
appear in the Environment list.

**The controller never checks a scanned BSSID against its own devices' `vap_table`s**
(10.6.101, `com.ubnt.service.aS.rhAW`, the scan-ingest loop; the only vap_table lookup in that
class feeds the wireless-uplink candidate list). Whether a BSS is "ours" is the **reporting AP's**
call, made per entry:

| Entry fields | Controller outcome |
|---|---|
| `is_unifi: true`, `serialno: <device MAC>` (or, without `serialno`, a BSSID in a Ubiquiti OUI it can map back) | Device looked up in the site. If adopted: recorded as a UniFi neighbour, **not** stored as a rogue — the row leaves the Environment list. Otherwise: rogue check below, but skipped when the MAC is a known device |
| no `is_unifi` | `is_rogue = essid ∈ site SSIDs` |

Real UniFi APs learn `is_unifi`/`serialno` from a Ubiquiti vendor IE in each other's beacons.
openUF had nothing equivalent, so on a two-AP site **all six** sibling BSSes were `is_rogue:
true` and AirView flagged one as *"a third-party access point broadcasting your network's
SSID"* (only the row whose OUI resolved to a vendor name showed the warning). openUF now beacons
its own vendor IE on every VAP — `dd 0d 02:6f:55 6f:55:46 01 <identity MAC>` via hostapd's
`vendor_elements` — reads it back from the kernel's scan cache over nl80211 (ucode's
`nl80211` module, which OpenWrt's wifi scripts are built on), and tags matching entries
`is_unifi` + `serialno`. Not from `iw`: OpenWrt's default iw build strips the printer for
unknown vendor elements, so the element never appears in `iw scan dump` output, `-u` or not —
verified live on both boards, where the same cache read over nl80211 held it. The OUI is deliberately not
a Ubiquiti one: a real UniFi AP would parse our layout as its own. 802.11k-reported
entries are left untagged — a beacon report carries no SSID, so they can never be flagged.
The yesrab fork saw the same on their mt7986 board (2026-09-28, `40ed2ce`, upstream's code):
after a forced re-push, `vendor_elements` was in both hostapd configs and on all three VAPs.
They had no second AP on the build, so no `is_unifi` tag from it.

openUF **reads** this element, though (`sysinfo.peer_match_ucode`): OUI `00:15:6d`, subtype
`00 01 01`, then the TLVs walked from body offset 11 to the first `81 06`, whose MAC becomes the
entry's `serialno`. The flags are ignored. Seen live 2026-10-11 from the living-room AP: a
neighbour's current-firmware UniFi AP beacons exactly this layout, with flag `0x40` on its
second BSS (not in 4.0.15) and a TLV `0x89` after `0x81` (36 bytes of ASCII, a UUID). Both of
its BSSes then went out in a real heartbeat payload with `is_unifi: true` and its base MAC as
`serialno`, which is the BSSID minus one, as `0x81` carries the device MAC. That AP is
not in this site, so the controller falls back to its SSID check for it. The ucode cannot run in CI or the lab;
`tools/peer-ie-vectors.lua` runs the generated matcher against 12 vectors in an OpenWrt
25.12 rootfs image.

**The UniFi AP's own element** (firmware-confirmed for 4.0.15). `umac.ko`'s
`ieee80211_add_ubnt_ie` writes it into every beacon and `libubnt`'s scan parser reads it back;
`mcad` then reports the parsed fields per scan entry (`is_ubnt`, `is_unifi`, `serialno`,
`is_default`, `is_locating`, `is_isolated`, `is_vport`, `is_vwire`, `is_meshv3`):

```
dd <len> | 00 15 6d (OUI) | 00 01 01 (UniFi AP) | <flags> | 01 02 <system id, 2 bytes>
         | 81 06 <serialno: the device MAC, 6 bytes>
         | [84 40 <64 bytes>]            only on a vport VAP of an unadopted (default) AP
         | [82 01 <x>] [83 <n> <bytes>]  only on a vwire VAP; the parser skips both
flags: 0x01 default (unadopted)  0x02 locating  0x04 vport  0x08 vwire  0x10 isolated  0x20 meshv3
```

The parser accepts only OUI `00:15:6d` with a body of at least 11 bytes, takes subtype
`00 01 01` as `is_unifi`, starts the TLVs at offset 13, and logs any tag other than
`81`-`84`. `mcad` formats `serialno` with `%02X` six times, so 12 uppercase hex digits. `00 00 00` and
`00 01 00` are other Ubiquiti products (`is_ubnt` only, system id at offset 10). openUF still
beacons its private element, not this one: a real UAP parsing an openUF beacon would take
the flags at face value, and `is_vwire`/`is_vport` feed its wireless-uplink choice
(`find_serialno_vwire_in_uplink_wds_iface_scan_records`).

### `lldp_table[]` entry

Field names from the real DTO (`OXMua`): `chassis_descr`, `chassis_id`, `local_port_name`,
`local_port_idx`, `is_wired`, `port_id`, `port_descr`.

- `chassis_descr` comes from `chassis.descr`, **not** `chassis.name` — System Description and
  System Name are different LLDP TLVs.
- `local_port_idx` is read from `/sys/class/net/<port>/ifindex` — this is *our own* local
  interface, not something lldpctl reports about the neighbour, so it is a local sysfs lookup
  rather than a protocol field. Omitted when unavailable.
- `is_wired` is unconditionally `true` — LLDP is inherently a wired-link protocol.

### Best-effort and unverified fields

These are explicitly approximations, flagged as such in the code. Listed here so nobody mistakes
them for measured values.

| Field | Status |
|---|---|
| `sta_table[].satisfaction` | The firmware's formula (see *The formula is the firmware's*). Its TCP-loss, TCP-latency and WiFi-latency terms are always 100: mac80211 has no source for them |
| `spectrum_table[].width` | Each 20 MHz reading is repeated once per width the band offers; the UI averages them over a bonded block. No live-scan source measures a bonded block directly |
| `spectrum_table[].interference` | Noise-floor dBm passed through; `iw survey dump` has no interference metric of its own. Falls back to the pre-sweep reading for any frequency whose post-scan noise comes back `0` (see [the first real-hardware run](#the-first-real-hardware-run)) |
| `radio_table[].builtin_antenna` = `true`, `.builtin_ant_gain` = `3` (dBi) | **Constants — no software source exists for either.** Not inert: the controller adds the gain to TX power to display EIRP, so a board with different antennas reports a wrong EIRP. Change them in `ucihelper.RADIO_DEFAULTS` if your hardware differs. |
| `radio_caps().has_fccdfs` | Mirrors `has_dfs`; `iw` exposes no separate FCC-DFS indication |
| `radio_caps().has_eht240` / `.has_eht320` | Hardcoded `false` — openUF has no 802.11be target hardware to derive them from |
| `port_table[].media` = `"GE"`, `.enable` = `true`, `.speed_caps` = `0`, `.port_poe` = `false`, `.poe_caps` = `0` | Constants. The PoE ones are honest for every target board (none source PoE); `media`/`speed_caps` are unmodelled. `speed`/`full_duplex`/`up` **are** measured — per physical socket via swconfig where the board has a switch, else from sysfs |
| `port_table[].rx_packets`/`tx_packets`/`rx_errors`/`tx_errors` on a per-socket entry | `0`. swconfig's per-port MIB exposes byte counters only (`RxGoodByte`/`TxByte`), and the CPU netdev's packet/error totals belong to every socket at once. A downstream socket's `rx_bytes`/`tx_bytes` are likewise `0` on a driver with no MIB (AR8327 with polling off) rather than a share of the CPU total |
| `serial` | Derived from the device MAC with the colons stripped — a real AP's serial is a separate factory value openUF has no equivalent of |
| `spectrum_scanning` | True while a `spectrum-scan` sweep still has chunks to run (see [Quick scan](#quick-scan), *Chunked sweeps*); the inform after its last chunk says false. No controller reading of it has been decompiled |
| `quickscan_scanning` | True from a `quick-scan` cmd until the inform that carries its results (see [Quick scan](#quick-scan)): through the wait for the controller to see it, then through the sweep's chunks |
| `lldp_table[].is_wired` = `true` | LLDP is inherently a wired-link protocol |
| `model` / `platform` / `version` / `required_version` / `bootrom_version` | The emulated UniFi identity from `ufmodel/*.lua` — deliberately not the host hardware. This is the point of the project, not an accidental approximation |
| `fw_caps` = `0x100110` (`0x100000`: RADIUS DAS), `wifi_caps` = `0x1C` + `0x20`/`0x100000` where supported, `wifi_caps2` = `0xF0` | Claimed capability bits, each derived from the controller's own bytecode and confirmed live — see [Capability bitmasks](#capability-bitmasks). openUF claims only bits whose features it actually implements |
| `ucihelper` `wps_device_name` / `ap_setup_locked` | Standards-based rather than Ubiquiti-derived — see the beacon row in the [feature matrix](#feature-matrix) |
| ~~`usteer.lua`'s `USTEER_DEFAULTS`~~ | ✅ **Resolved 2026-09-10.** Verified against the installed package (usteer 2025.10.04) on the Archer C5. `band_steering_threshold` is a real option — it is in the init script's own list of keys fed to `ubus call usteer set_config`. The named `local` section is read too: the loader does `config_foreach uci_usteer usteer`, which visits every section of type `usteer`, named or anonymous. `network` is read from `uci get usteer.@usteer[-1].network`, the last section of that type — openUF's — so both writes reach the daemon. **Corrected 2026-09-27 (upstream):** reaching the daemon is not the same as doing anything. usteer's source (`policy.c` `below_assoc_threshold`) reads `band_steering_threshold` only when `load_balancing_threshold` is non-zero, and it is 0 on both upstream APs (`ubus call usteer get_config`). So openUF's 5/0 toggle switched nothing. The real switch is `band_steering_interval` (`band_steering.c`: 0 disables, otherwise a BSS Transition request to each steerable 2.4 GHz client every interval). Its default in 2025.10.04 is 120000 ms, read live on both upstream APs, so a running usteer always steers. Before its Roaming Assistant port this fork stopped the daemon whenever Band Steering was off, so the inert toggle had no visible effect here: steering on came from the default interval, and off from the stopped daemon. Now usteer also runs for Roaming Assistant with Band Steering off. openUF writes `band_steering_interval=0` for off (so a usteer that runs for Roaming Assistant, or anyway, does not steer) and deletes it for on, so the daemon default that steered a real client (#25) applies, and removes the old threshold. |

Everything not listed above is measured from the running system. Several fields
*used* to belong in this table and no longer do — `max_txpower`, `tx_power`,
`nss`, per-client `signal`, `hostname`, and `port_table[].speed`/`full_duplex`
were all constants or misparsed values until the first real-hardware run
surfaced them; they are now read from `iw`, sysfs and `/proc`.

### WPA3 was silently downgraded to WPA2 — the radio must claim the SAE bit — FIXED

Before `radio_caps2` was sent (see below), a WLAN set to **WPA2/WPA3** in the UI
reached openUF as plain WPA2, and nothing anywhere said so. The captured
`system_cfg` contained no `sae`, no `wpa3`, just:

```
aaa.1.wpa=2
aaa.1.wpa.key.1.mgmt=WPA-PSK
aaa.1.pmf.status=enabled     aaa.1.pmf.mode=1
```

openUF applies that faithfully, so hostapd runs
`wpa_key_mgmt=WPA-PSK FT-PSK WPA-PSK-SHA256` and every client — WPA3-capable
ones included — associates with AKM `00-0f-ac-2`/`-4`/`-6`. Never `00-0f-ac-8`
(SAE).

This is **not** the controller's WLAN being misconfigured. Its REST API confirms
the wlanconf really does carry `wpa3_support: true`, `wpa3_transition: true`.
The downgrade is per device, in `com.ubnt.service.config.ubntconf.QSAkfnbfInKJ`:

```java
if (wlanconf.isWpa3()) {                      // wlanconf field wpa3_support
    if (!radio.CVir()) {                      // radio lacks the SAE capability
        if (wlanconf.isWpa3LegacyEnabled())   // wlanconf field wpa3_transition
            return downgrade(wlanconf, radio);          // ← silent WPA2
        log.warn("SAE cannot provision {} to {}", name, mac);
        return null;                                     // WLAN dropped entirely
    }
```

So a **transition-mode** WLAN degrades quietly, while a **WPA3-only** WLAN would
be dropped from the device altogether with that one server-side log line.

`CVir()` tests **bit `0x1` of `radio_caps2`** — see the next section for the
field-level trace. openUF used to send `radio_caps` (the MIMO column:
`0x8`/`0x10`/`0x20`/`0x4000000` for 1x1…4x4) and **no `radio_caps2` at all**, so
the bit was clear and every WPA3 WLAN was downgraded on every openUF device.
That is fixed: `radio_caps2 = 0x1` now ships on each SAE-capable radio (`0x3` since
2026-09-27, adding FT with WPA3; see [Capability bitmasks](#capability-bitmasks)).

The emission side is gated separately, on the WLAN alone
(`com.ubnt.service.config.j.rYtJfMBbtgWvku`: `isWpa3() || band == 6E`), and
produces `wpa3.support=enabled` + `wpa3.transition=enabled|disabled` — the keys
openUF's `_parse_wifi_system_cfg` would need to read, since **SAE never arrives
as a `wpa.key.<n>.mgmt` value**. `SECURITY_MAP`'s `wpa3` → `sae` and
`wpa2/wpa3` → `sae-mixed` entries were unreachable for exactly as long as the
capability bit was missing; both are now exercised on real hardware. (An earlier note in this document read the
PMF keys as the controller's way of signalling WPA3-mixed for a madwifi-driver
model. That was wrong — PMF is just PMF, and the real signal is these two keys.)

### The capability is `radio_caps2` bit `0x1` — RESOLVED

`CVir()` is a bit test, and tracing which field backs it settles the whole
question. The chain, all from the 10.4.57 bytecode:

```
config gen (QSAkfnbfInKJ)   calls radio.CVir()
CVir()                      = (1 & ZPjpXpgFhJSgqk().orElse(0)) == 1
ZPjpXpgFhJSgqk()            -> impl field iBjnA          (com.ubnt.g.f.e.jRsSex)
iBjnA                       <- builder field SuUD
SuUD                        <- setter rMxwXnPhhdotvjERKoA(int)
that setter is called with  getInt("radio_caps2")        ← the wire field
```

`radio_caps` lands somewhere else entirely — builder `kJeOrfqt` → impl
`DbisCuTqoItCGd` → accessor `FJaWnIAautY()`, which is the MIMO column and
nothing more. **The two capability integers are not interchangeable, and the one
that gates WPA3 is the one openUF never sent.** It arrived as `0` on every
inform (the parser's `getInt` default), `0` fails the bit test, and so every
WPA3 WLAN was silently downgraded on every openUF device.

**Confirmed live end-to-end, 2026-08-01, real hardware.** Sending
`radio_caps2 = 0x1` (gated on `sysinfo.sae_supported()`) flipped the very next
config push:

```
aaa.1.wpa.key.1.mgmt=SAE          (was WPA-PSK)
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled
aaa.1.wpa3.ft.status=disabled
aaa.1.sae.anti_clogging=5   aaa.1.sae.sync=5
```

and both APs came up controller-driven, no manual step:

```
UCI:     encryption='sae-mixed'  ieee80211w='1'  ieee80211r='1'
         sae_sync='5'  sae_anti_clogging_threshold='5'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
```

Note the push also carries `wpa3.ft.status=disabled` alongside `ft.status=enabled`
— the exact disagreement case described in the [`aaa.<n>` table](#aaan--per-ssid-security-and-behavior).

#### What was wrong before, and why

Three earlier claims in this document are now retracted:

1. *"`wpa3_supported` is the gate."* It is not read at all — see below.
2. *"`radio_caps`/`radio_caps2` bit `0x1` were both set live with no effect."*
   The conclusion was wrong. Whatever that experiment actually set, sending
   `radio_caps2 = 0x1` from the radio-table builder works reproducibly on both
   APs. Suspected cause: the config was never regenerated, so no push followed
   — a device-state change alone does not trigger one. Clearing the stored
   `cfgversion` and restarting forces a full push, which is how this was tested.
3. *"The capability comes from the controller's model registry, so no payload
   field can unlock WPA3."* The model registry exists —
   `getModel().radiosByBand().getOrDefault(band, EMPTY_DEVICE_MODEL_RADIO)`,
   with the U6-InWall's entry mapping `BAND_NA→2400`, `BAND_NG→570` — but it
   returns `com.ubnt.g.f.VVyiC`, a **different type** from the device radio DTO
   `com.ubnt.g.f.e.VVyiC` that `CVir()` is invoked on. It is not on this path.
   Checking the receiver type is what broke the deadlock.

`wpa3_supported` genuinely is inert, and that part stands: the only class
carrying the literal (`com.ubnt.net.k.aI.jRsSex`, a record of `wpa3Supported` /
`band6GHzSupported` / `oweSupported`) is **constructed, never parsed** — built
from an injected `com.ubnt.service.wifi` service, ignoring the device parameter
— and reading the persisted device back confirms it: `radio_caps` round-trips
verbatim while `wpa3_supported` and `owe_supported` come back `undefined`.
openUF still sends it, because it is truthful and another version may read it,
but it unlocks nothing.

### What a transition-mode push looks like

Reconstructed from the emitters rather than captured, since no openUF device can
provoke one. Two classes produce it — `com.ubnt.service.config.eWivisHeQsnaqDtx`
for the WLAN block (prefix recipe `aaa.`, so keys are `aaa.<idx>.…`) and
`com.ubnt.service.config.ubntconf.OXMua` for the SAE sub-block — both behind the
same gate, `com.ubnt.service.config.j.rYtJfMBbtgWvku`:
**`isWpa3() || radioBand == 6E`** (that second clause is why 6 GHz always gets
WPA3). The key-mgmt method in full:

```java
String mgmt = "WPA-PSK";
if (gate(wlan)) {
    mgmt = "SAE";                       // replaces — never appended
    OXMua.emit(sb, wlan, "aaa." + i);   // the sae.* / wpa3.ft.status block
}
emit("aaa." + i, "wpa.key.1.mgmt", mgmt, "wpa.psk", wlan.getWpaPreSharedKey());
```

For a WPA2/WPA3 WLAN with PMF Optional and 802.11r on, that yields:

```
aaa.1.wpa=2                       # stays 2 — WPA3 never makes this 3
aaa.1.wpa.1.pairwise=CCMP         # the legacy flag is inverted under WPA3, so never "TKIP CCMP"
aaa.1.wpa.key.1.mgmt=SAE          # replaces WPA-PSK; both never appear together
aaa.1.wpa.psk=<psk>
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled     # "disabled" here means WPA3-only
aaa.1.wpa3.ft.status=enabled
aaa.1.pmf.status=enabled  aaa.1.pmf.mode=1  aaa.1.pmf.cipher=<cipher>
aaa.1.ft.status=enabled
```

plus, only when the site actually sets them: `sae.anti_clogging` / `sae.sync`
(each when > 0), `sae.groups.<n>.group` with `sae.has_groups=enabled` (from
`sae_groups`), `sae.psk.<n>.psk`/`.mac`/`.id`/`.vlan` (SAE private PSKs), and
`wpa3.enhanced_192=enabled` for EAP with Enhanced 192-bit.

**The structural trap:** `SAE` *replaces* `WPA-PSK` — the wire never carries
both, so the AKM set alone cannot distinguish transition mode from WPA3-only.
Only `wpa3.transition` does. Reading the AKM by itself provisions a mixed WLAN
as pure WPA3 and locks out every WPA2 client.

### The device side works — verified end-to-end

With the capability bit in place the controller sends transition mode of its own
accord, and openUF provisions it correctly on real hardware:

```
UCI:     encryption='sae-mixed'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
         sae_require_mfp=1  sae_pwe=2  sae_groups=19 20 21
```

Live clients then split exactly as transition mode intends — a Pixel 9
negotiated `00-0f-ac-9` (FT-SAE) while older devices stayed on `00-0f-ac-2`
(WPA2-PSK) on the same SSID.

`wpad-mbedtls`, OpenWrt 25.12's ath79 default, does support SAE
(`sae_password`, `sae_groups`, `psk-sae` in `ap.uc`), so claiming it is honest
on that hardware.

### Fixtures must be verbatim command output

Three of the bugs found on real hardware were invisible to a green test suite
because the fixtures under `tests/fixtures/` were *tidier than reality*:

- `iw_station_dump.txt` had no `avg ack signal:` lines, so nothing caught an
  unanchored `signal:` pattern matching them and reporting every client at the
  ack value instead of its RSSI.
- `iw_phy_info_*.txt` carried an `HT TX Max spatial streams:` line that real
  ath9k/ath10k never emit, hiding that an HT-only radio has no source for `nss`
  at all and always fell back to 1x1.
- `iw_dev_info.txt` omitted the `ssid` and `multicast TXQ` blocks real output
  carries.

A fixture is a *recording*, not an illustration: paste real output from a real
device, including the lines that look irrelevant. The ones that look irrelevant
are exactly where unanchored patterns go wrong.

---

## Capability features claimed 2026-10-10 (decompiled, not yet seen on the wire)

Every key below was read from the 10.6.106 controller's own generator or ingest code
(`internal-dependencies.jar`, CFR 0.152, extracted on a case-sensitive volume), **not**
from a capture: none of it has been seen on the wire, and none of it has run on hardware.
Each consumer is unit-tested (`tests/test_capsfeatures.lua`, every key path
mutation-tested); the tier each one reached beyond that is named with it.

### MAC-based VLANs (`aaa.<n>.accept_mac.*`)

`com/ubnt/service/config/ubntconf/fdwW`, called from `VAZShipWTNxlo` (the UAP generator)
with the list of every WLAN's `aaa` index:

```java
if (n == 1) rx.NvfcKfHPI("accept_mac.status", "enabled");
rx.NvfcKfHPI("accept_mac." + n + ".mac", entry.getValue());
rx.NvfcKfHPI("accept_mac." + n + ".vlanid", String.valueOf(entry.getKey()));
...
private boolean kCNoUwYXLXMAUl(hyFnQ d) {
    return d.supportsMacBasedVlans() && this.kCNoUwYXLXMAUl.kCNoUwYXLXMAUl(d.getSiteId()); }
```

The entries are the site's clients with `virtual_network_override_enabled`
(`service/bz/DXjFpHAhtGlwvsEEcf`), grouped by the override network, `vlanid` being that
network's `getVlan()` (its tag, or `1` for the untagged LAN, `data/qfbKhmmodhjMTf`). The
site gate (`service/bz/bWpcUrDmeyjdNnrWeZ`) wants a UniFi OS gateway that supports it and
**every** AP/switch with clients claiming `supportsMacBasedVlans()` =
`hasFirmwareCapability(Integer.MIN_VALUE)`, bit 31. The same file emits
`switch.vnet.<n>.name/vlan/mac.<k>` for switches; an AP never gets it.

**Bit 31 on the wire.** The controller keeps capability masks as Java `int`s. The inform
ingest copies `fw_caps` with `getInt` (`Number.intValue()`, `devmgr.iceUMDuewFNFLMOqti`
and friends), but the device DTO's builder takes it through a Jackson setter with an
`int` parameter (`com/ubnt/i/b/l/XtugNwLHsUnnZrF`, `@JsonProperty("fw_caps") void
setFirmwareCapabilities(int)`), which Jackson refuses to fill from 2147483648 or more. So
openUF sends a mask with bit 31 as its signed 32-bit value (`report.signed32`, e.g.
`0xA0501110` goes out as `-1605365488`); every path reads that back bit for bit.

**OpenWrt side** (`ucihelper.macvlan_plan`). hostapd's `accept_mac_file` takes
`<MAC> <VLAN id>` lines and several `accept_mac_file` lines add up
(`hostapd_config_read_maclist`). `hostapd_check_acl` consults the accept list *first* and
returns its VLAN with the accept; with `macaddr_acl=0` everyone else is still accepted. The
VLAN must be in the BSS's `vlan_file` (`hostapd_vlan_valid`), which 25.12's `ap.uc`
(`iface_vlan`) builds from `wifi-vlan` sections, and `ap.uc` writes `dynamic_vlan` /
`vlan_no_bridge` only when `vlan_possible` (PSK, SAE, EAP, or an allow filter). openUF
writes the list to `/etc/openuf/macvlan-<section>.list` (flash: hostapd reads it at boot),
names it with a raw `accept_mac_file=` line, sets `dynamic_vlan=1` and adds one `wifi-vlan`
per VLAN. Because the accept list wins, a MAC refused by the WLAN's deny filter or by Lock
to Access Point, a MAC not on an allow filter, and every entry of a WLAN with RADIUS MAC
authentication (an accept would skip the RADIUS check) are left out, as are entries on the
WLAN's own VLAN and open/OWE WLANs. The VLANs go to the `vlan_filtering` plan like a PPSK
key's. **Tier:** unit; the generated hostapd config (accept list with VLAN ids + `vlan_file`)
parses cleanly in 25.12's `wpad-openssl` (rootfs, up to driver init). Not run on hardware.

### Multicast Suppressor (`wireless.<n>.multicast.suppressor`)

`VAZShipWTNxlo`:

```java
if (wlan.isMulticastSuppressorEnabled() && device.supportsMulticastSuppressor() && n4 == 0)   // n4: isServiceWlan()
    OWIoHe.kCNoUwYXLXMAUl(sb, "wireless." + n8, "multicast.suppressor", yaXSmtLge.kCNoUwYXLXMAUl(true));   // "enabled"
```

`com/ubnt/service/config/ubntconf/EYFcHmSpOqr` (the blocker's generator):

```java
if (!wlan.isBroadcastAndMulticastFilterEnabled() && !aggressive(device, wlan)) return empty;
kp = new kp().kCNoUwYXLXMAUl("wireless." + n + ".bcfilt.status", true);
if (aggressive(device, wlan)) kp.kCNoUwYXLXMAUl("wireless." + n + ".bcfilt.bypass_types", "ARP|NSNA|DHCPV4|DHCPV6");
// bcfilt.<k>.mac: the WLAN's exceptions + every site device MAC + the gateway's LAN peer MACs
aggressive = device.supportsMulticastSuppressor() && wlan.getMulticastSuppressorMode() == AGGRESSIVE && !wlan.isServiceWlan();
```

Modes (`com/ubnt/i/b/aL/eevUQSYcUHYjkbIHTHo`): `off`, `conservative`, `aggressive`; the
React form maps an old `bc_filter_enabled` to Aggressive. The UI text: "Limits multicast and
broadcast traffic to reduce WiFi airtime usage. Conservative prevents storms; Aggressive
blocks all except DHCP and ARP, unless a device is allowlisted." The site feature
(`service/as/RxFvcetMTlkSFFxK`) is on once **any** AP claims `wifi_caps2` `0x400000`. So
Aggressive is fully specified by the wire; Conservative carries no parameter.
openUF: Aggressive = the blocker plus one accept per bypass type ahead of the drop;
⚠️ Conservative = a per-VAP limiter on group-addressed frames (200/s, burst 400), a reading
of "prevents storms". **Tier:** unit + container with real `nft` 1.0.9: every rule rc 0,
rebuilt twice identically, torn down by an empty list; with real bridged traffic between
two network namespaces, Aggressive passed 5/5 broadcasts to UDP 67 and 0/5 to UDP 9999,
and Conservative passed 401 of a 2000-frame burst and 50/50 after a 2 s pause. The ARP and
ND accepts load but were not traffic-tested (no ARP/ND sender in the container).
2026-10-11: the exemptions now come first, then the limiter, then the allowlist drop, and the
DHCP matches carry `ether type ip`/`ip6`. Re-run in a privileged container (nft 1.0.9):
every rule rc 0, an identical table after a second run, and with the table loaded a UDP
datagram to UniFi's AP-to-AP group `239.254.127.63:48000` crossed the bridge between two
wired ports 5 of 5 times (every rule is `oifname`-scoped to a VAP).

### WLAN Schedule (`wireless.<n>.schedule_*`)

`VAZShipWTNxlo`:

```java
bnjutafutalctv_0 b = bnjutafutalctv_0.kCNoUwYXLXMAUl(wlan.getScheduleWithDuration());
if (wlan.hasScheduleWithDuration()) {
    if (device.supportWlanScheduleInvert()) OWIoHe.kCNoUwYXLXMAUl(sb, string, "schedule_invert", "enabled");
    else b = b.NvfcKfHPI();                        // the complement, per day
}
b.kCNoUwYXLXMAUl().forEach((day, list) -> { ... "schedule_" + day.toString().toLowerCase()
    + (device.supportMultiBlockWlanSchedule() ? "." + i : "") = start + "-" + end ... });
```

with `wireless.<n>.schedule_enabled` in the WLAN's main array. Days are `sun`..`sat`
(`com/ubnt/i/e/n/unLiwXHYlFDg`), times `HHmm`, `2359` the end of the day
(`service/at/rpnnqsiu_0`), blocks crossing midnight split per day. The complement
(`service/at/bnjutafutalctv_0.NvfcKfHPI`) turns a day's blackout blocks into the gaps
between them, a day without blackout into `0000-2359`, and drops a day blacked out end to
end. The 10.6 UI calls it a "WiFi Blackout Schedule" ("Specify times when this WiFi
instance should be disabled"). Hence: without invert, blocks are ON times and a day without
blocks is off; with invert, blocks are OFF times and a day without blocks is on.
openUF claims both bits and implements both readings (`unifi/schedule.lua`); the device
side (`openwrt/wlansched.lua`) is described in USAGE § 6. 25.12's `hostapd.uc`
`iface_reload_config` adds or removes a single BSS when only the BSS list changed, so the
`disabled` flip plus `wifi reload` leaves the radio and the other WLANs up (read in the
25.12 `hostapd.uc`, not observed). Lua's `os.date` follows `/etc/TZ` with no `TZ` in the
environment (checked in the 25.12 rootfs), and follows a change to it within the same process:
`/etc/TZ` rewritten between two `os.date` calls of one `lua` process, the second came out
in the new zone (2026-10-11), so a pushed timezone needs no daemon restart. openUF fails open
(an enabled schedule with no valid block is ignored) and acts on no schedule while
`os.time()` is before 2024. **Tier:** unit; TZ behaviour in the 25.12 rootfs.

### Hotspot 2.0 / Passpoint (`aaa.<n>.hs20.*`)

`com/ubnt/service/config/ubntconf/LsyaJoEysWb`:

```java
boolean hs = wlan.is("hotspot2conf_enabled", false);
if ((hs || VsCpQiCuGEvNvUNmH.OSEN == wlan.getSecurityOrOpen()) && !device.supportHotspot2()) {
    log.warn("Hotspot 2 cannot provision OSEN on {} to {}, hotspot2: {}", ...); return null; }
```

The keys come from `VAZShipWTNxlo`'s Enterprise branch (`aaa.<n>.hs20.status`, then
`access_network_type`, `internet`/`asra`/`esr`/`uesa`, `venue_group`/`venue_type`,
`disable_dgaf`, `deauth_req_timeout`, `t_c_filename`/`t_c_timestamp`, `osu_ssid`,
`gas_comeback_delay`/`gas_frag_limit`, `network_availability` = (v4 << 2) + v6,
`network_auth_type` + `network_auth_url`, `anqp_domain_id`, `hessid`,
`venue_name.<k>.*`, `hs20_domain_name_list`, `nai_realm.<k>.*` with
`eap_method.auth.<j>.id/val`, `<k>.roaming_consortium`, `3gpp.<k>.mcc/mnc`,
`friendly_name.<k>.*`, `capab.<k>.protocol/port/status` (protocol already an IP number),
`qos.*`, `metrics.*`, `icon.<k>.*`, and `aaa.<n>.osu.<k>.*`), plus
`wireless.<n>.dgaf_disable`. Every non-Hotspot Enterprise WLAN carries
`aaa.<n>.hs20.status=disabled`. The site's Passpoint flag is
`supportsHotspot2Passpoint()` = `supportHotspot2() && supportsRadSec()` (`fw2_caps`
`0x80000`). OpenWrt: 25.12's `wpad-openssl` passes `hostapd -vhs20` (exit 0); openUF writes
the block as raw lines (`openwrt/hotspot2.lua`), because 25.12's `ap.uc`
`iface_interworking()` overwrites `domain_name` with the 3GPP list and joins array options
onto one line. Online sign-up (OSU providers, icons) is not carried (hostapd dropped its OSU
server support); an OSEN WLAN is skipped (no OpenWrt encryption for it). RadSec: no
`radsecproxy` in the 25.12 feed and hostapd speaks RADIUS over UDP only, so `fw2_caps`
`0x80000` is not claimed and the site's Passpoint feature stays off.
**Tier:** unit; a hostapd config with every generated line (plus the WPA2-EAP/CCMP base)
parses with 0 errors in 25.12's `wpad-openssl`, including hostapd's own "WPA2-Enterprise/CCMP
is required for Hotspot 2.0" check, and a deliberately malformed `hs20_wan_metrics` is
reported, proving the parse ran. Not run on hardware.

### RADIUS Filter-Id (`aaa.<n>.filter_id`)

`VAZShipWTNxlo` (Enterprise branch):

```java
if (device.supportsRadiusFilter() && this.lWxsLKSR(device.getSiteId())) {   // the gateway runs SERVICES_RADIUS_SERVER
    rGUtaVWZlySeOK f = wlan.isUidWifi() ? rGUtaVWZlySeOK.UID_WIFI : rGUtaVWZlySeOK.WPA_EAP;
    OWIoHe.kCNoUwYXLXMAUl(sb, String.format("aaa.%d", n), "filter_id", f.kCNoUwYXLXMAUl()); }   // "uid-wifi" | "wpa-eap"
```

The enum (`com/ubnt/i/b/W/rGUtaVWZlySeOK`: `mac-acl`, `uid-vpn`, `uid-wifi`, `wpa-eap`,
`vpn`) is the vocabulary of the gateway's RADIUS accounts' `filter_ids` (the services an
account may use, `data/unLiwXHYlFDg`), so the AP names its service in the request. The
gateway's RADIUS server itself is not in this jar. openUF: `list radius_auth_req_attr
'11:s:<value>'` (RADIUS attribute 11, Filter-Id), an option in 25.12's
`wireless.wifi-iface.json` that `ap.uc` writes with the authentication servers;
hostapd parses `radius_auth_req_attr=11:s:uid-wifi` (rootfs, as above). **Tier:** unit.

### SNMP (`snmp.*`)

`com/ubnt/service/config/lwueNrOWUBYJX`, called by the UAP generator with prefix `""`,
key `"community"`, limit 256:

```java
boolean v12 = settings.isEnabled();
boolean v3 = settings.is("enabledV3", false) && device.supportsSNMPv3();      // fw_caps 0x4000
if (v12 || v3) { sb "snmp" status=enabled, version = v12&&v3 ? "all" : v12 ? "1_2c" : "3";
                 location / contact when set }
if (v12) sb "snmp.community" = settings.getString("community", "public");
if (v3)  sb "snmp.user.1.name" / "snmp.user.1.password";
```

No `status=disabled`: off is the absence of the block. The UniFi OS side of the same
setting (`config.tmTjAksIyMivqmlnYPu`) uses SHA authentication and AES privacy with one
passphrase, and gates on `fw_caps` `0x2000`; that path is a gateway's, not an AP's.
OpenWrt 25.12 ships `snmpd-ssl`/`snmpd-nossl` (43 KiB + `libnetsnmp` ~1.1 MiB) with a UCI
init script that turns `config v3` into `createUser`/`rouser`. **Tier:** unit + rootfs: the
UCI openUF writes, run through 25.12's real init script and `snmpd-ssl`, answered
`snmpget -v2c -c <community>`, refused `-c public`, and answered `-v3 -l authPriv -a SHA -x AES`.

### Radio AI neighbour isolation (`wifi_caps2` `0x200`)

`com/ubnt/service/system/XbYOtjBEpjeHWlUU` (the Radio AI run) sends
`{"cmd":"scan_band","band":...}` only to APs without `supportNeighbourInScan()`, and
`com/ubnt/service/bF/BNJuTaFuTalcTv` enables `RADIO_AI_NEIGHBOR_ISOLATION_{NG,NA,6E}` only
when every AP with a radio on the band claims it. The isolation matrix
(`devmgr.kFACvOhX`) is built from the peer-scan cache (`service/aS/eevUQSYcUHYjkbIHTHo`,
fed by `aS.qikih` from every inform's `scan_radio_table`): an entry tagged `is_unifi` with
`serialno`, `age` ≤ inform interval + 10 s, mapped to an adopted sibling and kept an hour,
whose channel must match the sibling's current one. Nothing new is reported by a claiming
AP: it is trusted to keep its regular scan table current. openUF's is: sibling sightings
from `idlescan.lua`'s half-hourly sibling scans and idle sweeps, tagged through the sibling
exchange. Claimed while `sibling_scan_interval` or `idle_scan_interval` is above 0.
⚠️ Only openUF siblings are tagged; a genuine UniFi AP is reported as a third-party BSS
(openUF does not parse Ubiquiti's own vendor element), so in a mixed site the matrix lacks
those pairs. Without the claim a site with an openUF AP had no isolation at all, and the
`scan_band` it got was ignored. **Tier:** decompile only.

### Roam reports (`association` / `sta_leave` / `sta_roam`; upstream ea0b5d6)

**Symptom (upstream).** Insights → AirView → Roaming on upstream's real UCG Ultra (2026-10-14) listed 69 events,
every one "Roaming / Success", with no failed roam and no Fast Roaming, Roaming Assistant or
Minimum RSSI tag. The activity was real; the detail was never sent.

**Decompile** (CFR, 10.4.57 and 10.6.106 `internal-dependencies.jar`; same logic, class names
differ). `WIFI_ROAMING` documents in `unifi_stat.wifi_connectivity_event` come from
`wifi/connectivity/c/AcrQJeJCScLn` (bean `wifiRoamingService`) by two paths:

1. **sta_table path.** A client's `ap_mac` changing between two heartbeats. It runs only when
   either AP lacks `supportsRoamTopologyStats()` = `hasWifiCapability2(8192)` (`wifi_caps2`
   `0x2000`). It always writes `successful=true`. Its tags come only from the cache path 2
   fills when an association carries no RSSI, so they were always null for openUF. **All 69
   events came from here.**
2. **Tracker path** (`devmgr/w/a/eirJvdtm`, bean `wifiRoamingDetector`). It runs on
   `STA_ASSOC_TRACKER` notifs, keeps the last event per (site, client) in a Caffeine cache for
   **10 s**, and pairs a departure from one AP with an arrival at another, in either order:
   - `sta_leave` (handler `QnvUxbsXyAJZ`/`gyWdIcvdh`): reads `vap`, `mac`, `avg_rssi`
     (`getInt`, required), `assoc_status` and `last_seen`. It also tells `staManager` the
     client left: when the client is still filed under this AP and BSSID, it is disconnected
     there at `receive_time - (last_inform_uptime - last_seen)`.
   - `sta_roam`: the same fields; processed **only if the sender claims `0x2000`**.
   - `association`: `vap`, `mac`, `auth_rssi` (dropped without it), `auth_algo`.
   - `fast_roaming` = `auth_algo == "ft"`. `assoc_status` bits (enum `VVyiC`): `16`
     KICKED_DUE_TO_MIN_RSSI, `8192` MOVED_DUE_TO_ROAMING_ASSISTANT.
   - `successful` = the departure was `sta_roam`, OR arrival minus departure ≤ 1000 ms. Both
     times are the controller's **receive time in whole seconds**; a departure that arrives
     after the arrival is a negative gap, so a success. Otherwise a failed roam with
     `disconnect_duration` = the gap.
   - Both ends must resolve `vap` against the sender's `vap_table` and share a `wlanconf_id`,
     and the two APs must differ.
   - Without `0x2000` the funnel handler (`lhuvxd`) also feeds every funnel `success` into
     the tracker as an arrival.

`0x2000` has exactly these three callers in 10.6.106 (sta_table path, `sta_roam` gate,
funnel feed). Claiming it without sending the reports would make roams vanish; sending the
reports without it would record every roam twice. openUF does both or neither
(here: `sta_events`).

**Reference firmware.** BZ2 4.0.15 (plaintext) has only the old success/failure tracker; the
three event types are newer than any readable build. It does show how a UniFi AP knows a
station left: its hostapd broadcasts an `iapp_key`-wrapped RRB frame on each association, and
the old AP drops the station (see [802.11r key holders](#80211r-key-holders-iapp_key)).
OpenWrt has no such message.

**How openUF's old AP knows (upstream hardware, 2026-10-14).** A station that roams by FT or simply
associates elsewhere says nothing to the AP it leaves. hostapd keeps it listed until its
inactivity timer or missing ACKs drop it, **6–40 s later** on both boards (Pixel-9 several
times, a Mac in normal use), which is outside the 10 s window. But the old AP's bridge
learns the station's address on its uplink when the new AP's hostapd announces it:

| Time | Event |
|---|---|
| 11:18:44 | Office (AX3000T) `AP-STA-CONNECTED … auth_alg=ft`; its fdb learns the STA on `phy0-ap0` at .660 |
| 11:18:44 | Living room (Archer C5) `bridge monitor fdb`: STA `dev eth1 master br-lan`, **while hostapd there still lists it** |
| 11:18:50 | Living room hostapd: "disconnected due to excessive missing ACKs" |

`bridge monitor fdb` piped through a shell `read` loop delivers each line within 10 ms on
both boards (a static test entry added and removed). The Archer C5's own timestamps are
garbage (`-16843009 usec`), so the collector stamps lines with `/proc/uptime`. DSA repeats
each entry as `self`, and a VLAN-aware bridge repeats it with `vlan 1`.

**openUF** (fork: `unifi/staevents.lua` roam reports, collector `openwrt/staphase.uc`):
- The collector, already subscribed to every hostapd BSS for the connection timing, also
  logs `assoc` (with `signal`), `sta-authorized` (with `auth-alg`) and `disassoc`/`deauth`
  to `/tmp/openuf-roam.log` the moment they happen, stamped with `/proc/uptime`, and runs
  `bridge monitor fdb` through a shell `read` loop (a buffered read in ucode could hold back
  the DSA/VLAN duplicates of a burst) appending to `/tmp/openuf-fdb.log`.
- `association` once hostapd reports `sta-authorized`, with the `assoc` signal as
  `auth_rssi` and `auth-alg` as `auth_algo`. A failed handshake is no arrival.
- `sta_leave` on hostapd's `disassoc`, with the heartbeat's signal as `avg_rssi`, the event's
  uptime as `last_seen`, and `assoc_status` from the existing departure-cause ledger
  (`lockap.departure_cause`: Minimum RSSI 16, Roaming Assistant 8192); a BSS Transition
  departure is also a `sta_roam`, queued first (see Roam topology below). Not sent for a
  station that moved to another BSS of the same AP.
- `sta_roam` when the station's address is learned on a port that is not one of this AP's
  BSSes while hostapd still lists it; hostapd's later drop is not reported again.
- The inform loop's idle wait reads both logs every 250 ms (`inform.ROAM_POLL_S`) and sends a
  roam report at once; the heartbeat diff no longer sends `association`/`sta_leave`, only the
  timed `success`.
- ⚠️ Unit-tested only on the fork: the ucode collector's new half and the fast path have not
  run on hardware.

Upstream's evidence for the same behaviour, from its own implementation (`assoctrack.lua`):

**Lab, 10.6.106, both AP containers claiming `0x2060`**, lines appended to each daemon's
collector file (so through the real fast path):

| Sent | Stored |
|---|---|
| old AP: fdb move to `eth0`; new AP: `assoc` + `sta-authorized` `ft` | Success, `fast_roaming: true` |
| old AP: `disassoc`; new AP 3.2 s later: `assoc` + `sta-authorized` `sae` | Failed, `disconnect_duration: 3000` |

An earlier lab run with hand-made payloads and no `0x2000` showed the tags: `assoc_status
8192` → `triggered_by_roaming_assistant: true`, `16` → `triggered_by_minimal_rssi: true`.

**Live, real UCG Ultra, 2026-10-14**, both APs reporting `wifi_caps2` `0x2060`:
- Pixel-9 banned 20 s on both Office radios at 11:39:47, reconnected (SAE) to the living room
  at 11:39:51: listed as **Failed Roaming, Office AP → Living room AP**.
- The same phone's band change within Office (FT, 11:39:15): no roam listed, as on a UniFi AP.
- The silent departure: a BTM request from Office (accepted, status 0) moved the Pixel to the
  living room at 11:46:57 (SAE). Office's hostapd kept listing it until its inactivity drop at
  11:47:13, outside the 10 s window, so only Office's fdb-triggered `sta_roam` can have paired:
  listed as **Roaming, Office AP → Living room AP, Success, 11:46:57**.
- Unprompted, 12:18:49: the Pixel FT-roamed from the living room to Office; the living room
  dropped it 13 s later. Stored `SUCCESS_ROAMING`, `fast_roaming: true`.
- Unprompted, 12:21:39: openUF's Roaming Assistant on Office steered the Pixel to the living
  room. Stored `fast_roaming: true`, `triggered_by_roaming_assistant: true`.
- ⚠️ Not yet seen live: the Minimum RSSI tag (unit tests plus the lab's hand-made payloads).

**10.6's roam fallback (not in 10.4.57).** One live record had no tags and a millisecond
timestamp: 11:47:33, a second copy of the 11:46:57 roam. 10.6.106 adds
`wifi/connectivity/c/rGUtaVWZlySeOK` ("Roam incident fallback"): every client move it infers
from heartbeats is held for 15 s (the tracker's 10 s + 5) keyed on (site, client, new AP), and
one the tracker did not confirm in that time is re-emitted as `rFCHnXVpfjjP`, which writes a
sta_table-path roam **with no `0x2000` check**. Here the Office AP's heartbeat still listed the
Pixel until hostapd dropped it at 11:47:13, so the controller saw it move back to Office and
away again, and nothing confirmed the second move. openUF now leaves a station out of its
heartbeat from its `sta_roam` until hostapd drops it, unless the station is heard from on this
AP after the move (`staevents.roamed_away`). Unit-tested; the live roams after the fix
(12:25:34, FT) produced no copy, but the old AP dropped the station within 5 s there, so the
long-listing case has not recurred on hardware yet.

### Roam topology: `sta_roam` and `assoc_status`

`devmgr/w/a/RPnnqSiu` feeds `event_type:"sta_roam"` to the roaming detector
(`devmgr/w/a/Cuhf`) only when `supportsRoamTopologyStats()`; `VsCpQiCuGEvNvUNmH:70` feeds a
verified `success` to it only when **not** claimed; `gyWdIcvdh` (sta_leave) feeds it
always. `Cuhf` treats `sta_roam` like `sta_leave` (the "left" half, 10 s cache) and reads:

```java
int n2 = ev.getInt("assoc_status");
.kCNoUwYXLXMAUl(has(n2, rFCHnXVpfjjP.KICKED_DUE_TO_MIN_RSSI.bitmask()))          // 16
.NvfcKfHPI(has(n2, rFCHnXVpfjjP.MOVED_DUE_TO_ROAMING_ASSISTANT.bitmask()))       // 8192
```

(enum `devmgr/w/a/rFCHnXVpfjjP`: `SUCCESS(0)`, `KICKED_DUE_TO_MIN_RSSI(16)`,
`MOVED_DUE_TO_ROAMING_ASSISTANT(8192)`). The "joined" half is an `association` with
`auth_rssi` (and `auth_algo:"ft"` for FT); a roam whose left half was a `sta_roam` counts as
seamless. A parallel firmware analysis decoded UniFi's `stahtd` bit names (`0x10` `rssikck`
… `0x1000` `lock2ap`); `0x2000` is the controller's own Roaming Assistant value, absent from
the 6.8.2 printer. openUF: every `sta_leave` carries `assoc_status` (0, 16 after a Minimum
RSSI kick, 8192 after a Roaming Assistant BSS Transition request or forced disassociation,
within 120 s, each action reported once); a client that left while its BTM request was still
inside its 10 s grace (last seen inside it) **and** that usteer sees associated to another AP
is also sent as `sta_roam` (same fields, its own `event_id`) just before the `sta_leave`,
which the station manager still needs (`sta_roam` does not reach it). Without that sighting
the departure keeps 8192 but is not claimed as a roam. Associations already carry
`auth_rssi`, so claiming `0x2000` costs no roam data. **Tier:** unit.

**Which of the pair the detector keeps (decompiled 2026-10-11).** Both events go through the
same "left" handler, `Cuhf`'s 5-argument `kCNoUwYXLXMAUl`, against one Caffeine cache keyed
by (site, client MAC). When the cache already holds a "left" record for the client, the new
one replaces it only if `kCNoUwYXLXMAUl(old, new)` holds: the new record has a value and a
**higher band** (6E > 5 GHz > 2.4 GHz) than the old. Neither `put` nor `putIfAbsent`: for the
same AP and band the **first** left event stays, and the record carries that event's
`event_type`. So the order matters, and `sta_roam` must precede its `sta_leave`, as
`staevents.roam_ingest` queues them (a unit test pins the order).

## UniFi Network 11.x (string-level, not decompiled)

**Source.** `unifi-native` 11.0.81-37038-1 for `uos-deb13-arm64`, fw-update channel `qa`:
`https://fw-download.ubnt.com/data/unifi-native/8530-uos-deb13-arm64-11.0.81-37038-1-0b745a73-fc68-4f54-8b2d-49fd446e2957.deb`.
It is a GraalVM native image, so CFR no longer applies: there are no classes to decompile.
The evidence is the exact Java string literals embedded in the image, compared with the same
literals in the 10.6.106 `unifi-native` image and with the 10.6.106 CFR decompile used
throughout this file (every literal of a decompiled class checked against both images).
Everything below is **string-level, not decompiled**: a literal that is still present says
the code that uses it is very likely still there, not that it behaves the same.

**Unchanged at literal level:**
- the inform protocol: TNBU framing, encryption, the rejection of a GCM downgrade, the
  http-only inform URL, the response `_type`s and the `mgmt_cfg` keys;
- every capability predicate openUF relies on (`supports*`/`has*` names), with the frontend's
  numeric capability enums identical;
- the UAP `system_cfg` generator's literals and section headers (`# unifi`, `# users`, ...);
- the WlanConf schema (byte-identical);
- U6-IW in the uidb. The uidb's only change is the duplicate `U7ENT` (sysid `0xa681`)
  removed; `catalog.lua` follows it.

**New:**
- an optional device identity key (`device_pubkey`), pinned trust-on-first-use, with alerts
  on a conflicting key. openUF sends none; nothing yet says it becomes mandatory;
- inform-body load shedding ("Shedding inform load: in-flight body budget ... exhausted",
  "Inform body memory budget exhausted"). 503 was already "Server is busy" in 10.6.106;
  openUF now backs off straight to its longest wait on a 503;
- `radio_table_stats` sanitisers ("Collapsed {} duplicate radio_table_stats entries",
  "Dropping radio_table_stats entries past {}"). openUF sends one entry per radio name;
- RadSec validation;
- Energy Saving / sleep-mode policies, mechanism unknown;
- HaLow (`ah` band) groundwork.

**Removed:** USG support, and the standalone server.

**Follow-ups that need a live controller:** a `setparam` diff on 11.0.83 against a 10.6.106
capture; the Radio AI operating-width check; and what Energy Saving actually sends.

## Feature matrix

Every controller-UI control exercised against a live openUF device. "Confirmed" means driven
through the real UI with the resulting wire payload captured or the effect verified.

| # | Control / feature | Wire mechanism | Status |
|---|---|---|---|
| 1 | Adopt (L2/SSH, L3/mgmt_cfg) | SSH `syswrapper.sh set-adopt`, or `authkey` in `mgmt_cfg` | ✅ Confirmed both paths |
| 2 | Baseline post-adopt inform | `setparam` + `mgmt_cfg` | ✅ Confirmed |
| 3 | SSID push (no VLAN) | `system_cfg` `aaa.*`/`wireless.*`/`radio.*` | ✅ Confirmed |
| 4 | VLAN-tagged network + SSID assignment | `aaa.<n>.br.devname = br0.<vlan>` | ✅ Confirmed. The switch trunk carries the CPU port and the uplink socket only — tagging the LAN sockets deafens untagged wired clients on `ar8216`-family switches, where the tag flag is one global per-port bitmask |
| 5 | Fast Roaming (802.11r) | `aaa.<n>.ft.status` only | ✅ Confirmed by byte-for-byte `system_cfg` diff, both directions |
| 6 | TX power / channel per radio | `radio.<n>.channel`/`.txpower`/`.txpower_mode` | ✅ Confirmed |
| 7 | Locate | `cmd:"set-locate"` | ✅ Confirmed, including the **LED hardware effect on a real board** (Archer C5, `dev.conf.led = "green:system"`): `locate_start` writes `trigger=timer` + 250/250 ms, `locate_stop` restores `trigger=none`, and the Manage → LED toggle drives `brightness` 1/0 |
| 8 | RF/spectrum scan trigger | `cmd:"spectrum-scan"` | ✅ Handler exercised **against real radios** — 27 channels on 5 GHz, 13 on 2.4 GHz, with genuine per-channel utilization and noise. The UI's trigger is Airtime Scan ("Scan Now"), which the controller only offers to an AP claiming `wifi_caps` `0x10`; openUF claims it (upstream a684980, where it was fired by a real UCG Ultra; see [Airtime Scan](#airtime-scan-spectrum-scan)). Before that the handler was invoked directly on the device. That run used a plain `iw dev <if> scan`, and the sweep was real. On 2026-09-25 plain and `scan ap-force` returned identical off-channel results on both boards (Archer C5 ath9k/ath10k, AX3000T mt76; mac80211 6.18 backports), so these kernels do not refuse a scan on a beaconing AP. The handler now uses `ap-force` as a guard and judges success by iw's exit status. |
| 9 | Firmware upgrade | `_type:"upgrade"` | ✅ Confirmed. openUF stores `upgrade_requested_version`/`_url` and logs — it never downloads, verifies, flashes, or reboots. Verified live: no side effects, device stayed Connected. The pushed `md5sum`/filename match Ubiquiti's real CDN artifact byte-for-byte. |
| 10 | Forget device / factory reset | `_type:"setdefault"` | ⚠️ UI action and server-side deletion work, but **no `setdefault` was ever dispatched on the wire**; handler unverified. See [open questions](#open-questions). |
| 11 | `fw.ver` acceptance | — | ✅ Accepted verbatim, no validation beyond storage |
| 12 | Restart | `_type:"reboot"` (top-level, **not** `cmd:"restart"`) | ✅ Confirmed; real container reboot observed |
| 13 | Device LED on/off | `mgmt_cfg` `led_enabled` | ✅ Confirmed both values live. It is the **effective per-device** value, not the site setting copied through (decompiled 10.6.101: the `mgmt_cfg` builder writes `led_enabled` from the LED-state resolver, which answers on for a device override "on", or "default" with the site's `mgmt.led_enabled` on, and off for "off" or a disabled AP). Models with an LED bar get `ledbar.status`/`ledbar.brightness`/`ledbar.color.*` in `system_cfg` instead (same resolution, plus brightness and colour); the U6-IW identity is not one of them, and none of the three hardware APs' unhandled ledgers has ever held a `ledbar.*` key. openUF switches every LED with it (`led.set_enabled()`: snapshot, then trigger `none` + brightness 0; on, the snapshot back). |
| 14 | IP Settings (DHCP/Static) | `system_cfg` `netconf.*`/`dhcpc.*`/`route.*` | ✅ Confirmed end-to-end: real kernel interface change, real route, informing from the new address, controller Overview reflecting it back |
| 15 | Power / PoE | `power_source`, `power_source_voltage`, `psu_table`, `power-monitor`, `total_max_power`, `led_state`, `outlet_table` — copied straight off the inform when present | 🔍 Not implemented. The "Power: -" element lives in the **Parent Device** subsection (properties of the upstream LLDP-linked switch), and this environment has no PoE switch. Field names confirmed; values/format not researched, and openUF has no local signal for a real PoE class. |
| 16 | Set Replacement Device / Load Configuration | **None** — controller-side Mongo document clone (`commonDeviceCloneConfigService`), then an ordinary adopt + `setparam` | ✅ Both confirmed live; zero product code needed. Replacement auto-adopts the target ~50 s after the source goes away. |
| 17 | Wired clients | `port_table[]` + per-port `mac_table[]` | ✅ Confirmed live: both fake hosts under Connection → Wired, on the correct port; Ports view renders them. Hosts are placed on the physical socket the switch learned them on (ARL table) as of 2026-08-02 — before that, real wired clients behind an AP were reported by nobody and the controller credited them to the gateway's port. Extended 2026-09-12: each socket is asked about its OWN bridge, a socket whose MAC learning is off is served by the `bridge openuf_learn` nft tap, and rows carry `vlan` (+ a tap-harvested `ip`) — which is what puts the client on the right **network**, not just the right port. See [`mac_table[].vlan`](#mac_tablevlan--how-a-wired-client-gets-its-network) |
| 18 | Per-port VLAN assignment | `fw_caps` bit `0x100`; controller pushes `switch.*` | ⚠️ Wire format fully mapped live 2026-07-19 (gate, per-VLAN table, per-port `pvid` + tagged/untagged/exclude matrix, teardown). The **controller side** is confirmed — it accepts the assignment and pushes an actionable table. Device-side apply is swconfig-only and unverifiable here (the validation AP has no switch). Note it was unreachable on both real boards until 2026-08-02: the only port they reported was the uplink, which is exactly the port that must never be reassigned |
| 19 | Client block / unblock | `cmd:"block-sta"` / `"unblock-sta"` | ✅ Confirmed live including real nftables enforcement and survival across a simulated reboot. Since 2026-10-11 the table is one `nft -f` transaction (forward drops plus an `input` chain for traffic to the AP itself), read back with `nft list set`; checked against nft 1.0.9 in a privileged container (first boot, replace, empty, idempotent). The disconnect is `ubus call hostapd.<vap> del_client` on every VAP (unit-tested only, no real hostapd here); it used to reach only the first VAP of each radio. A block also puts the MAC into hostapd's deny ACL on every BSS, re-checked every tick (see *A block refuses association*; upstream-confirmed in live hostapd, unit-tested here). |
| 20 | Environment / rogue-AP scan | `scan_radio_table[]` (+ 802.11k `rrm_beacon_req`) | ✅ openUF's payload and the controller's ingestion both confirmed correct (10/10 direct API polls), and ✅ **confirmed rendering** in the live Environment tab 2026-09-02 (AX3000T): the 30-minute window listed exactly the BSSes in that AP's own scan cache, with matching signals, and the spectrum chart drew them alongside `This AP`. Note what the `scan dump` source can and cannot see: the cache is filled **passively, from beacons the radio overhears on the channel it is already parked on**, so the list is neighbours on/adjacent to the operating channel and nothing else — 6 entries on a 2.4 GHz radio on ch 11, exactly 1 on a 5 GHz radio on ch 44. That is the deliberate trade for never dwelling off-channel. ✅ Closed 2026-09-02 with 802.11k client-assisted enrichment (`openuf/rrmscan.lua`) -- Ubiquiti's own Channel AI mechanism -- which took a 5 GHz radio's list from **0 neighbours to 4** without the AP leaving its channel; see [the section above](#enriching-it-without-scanning--80211k-beacon-reports). The tab's own display bug is [controller-side](#controller-side-ui-quirks). |
| 21 | Radios tab + client MIMO/generation | `radio_table` capability fields; per-station `nss`/`is_11*` | ✅ Confirmed live on four stations spanning HT/VHT/HE/legacy |
| 22 | Radios tab Avg. Signal / Interference / Airtime / MIMO | `vap_table.avg_client_signal`; `radio_table.athstats`; `radio_table.radio_caps` | ✅ All four confirmed live on a fresh reset (`-64`/`-50 dBm`, `3%`, `7%`, `2x2`), with bidirectional filter behavior verified |
| 23 | Minimum RSSI | `system_cfg` `stamgr.<n>.*`; outbound `min_rssi`/`min_rssi_enabled` | ✅ Wire format and field names confirmed. Enforcement follows the firmware since 2026-10-10 (hostapd refuses below threshold + 3 dB; kick after 30 s below). The refusal reaching hostapd's live config, and its teardown, are confirmed on real hardware; a refused or kicked client is unit-tested only. |
| 24 | Security tab WPA2/WPA3 protocol options | **None** | ℹ️ Not capability-driven from anything openUF sends. No security-capability field exists in the payload; `ucihelper`'s `SECURITY_MAP` (`wpa2`→`psk2`, `wpa3`→`sae`, `wpa2/wpa3`→`sae-mixed`, `wpa-enterprise`→`wpa2+ccmp`) is a one-way map of a choice the controller has already made. The dropdown's options come from the controller's own internal per-model database, keyed on the reported `model`/`platform`. Not fixable here. |
| 25 | Band Steering / BSS Transition / DTIM | `wireless.<n>.no2ghz_oui` / `aaa.<n>.bss_transition` / `wireless.<n>.dtim_period` | ✅ All three confirmed live by individual before/after `system_cfg` diffs, and ✅ **a real client steered 2.4 → 5 GHz** on the AX3000T 2026-09-02. The whole exchange is in the AP's log: the station associates on `phy0-ap0` (2.4 GHz, ch 11) at 05:33:23, and 72 s later `phy0-ap0: BSS-TM-RESP <sta> status_code=0 target_bssid=00:00:5e:00:53:05` — accepted, naming the **5 GHz** BSSID — followed in the same second by `phy1-ap0: associated` and `phy0-ap0: Prune association`. `auth_alg=ft` on both, so the move used fast roaming. usteer had been up since boot and was never restarted, so this was its own unprompted decision. Two negative results worth keeping: usteer's per-BSS `roam_events` counters stayed at 0 through it, so they do not count BTM-driven band steers; and every client that was *not* steered had a concrete reason visible in `ubus call usteer get_clients` / `hostapd get_clients` — either no 5 GHz sighting at all, or `rrm: [0,0,0,0,0]` with the BSS-Transition bit clear in `extended_capabilities`. "Nothing moved" is not evidence of a broken steerer. |
| 26 | Show AP Name in Beacon | `wifi_caps2` bit `0x40` → `wireless.<n>.advertise_ap_name` | ⚠️ Wire protocol and capability gating confirmed live, both directions. **The OpenWrt side does not work and is not implemented.** openUF writes `wps_device_name` + `ap_setup_locked` (both valid wifi-iface options — confirmed present in the schema and in `/usr/share/ucode/wifi/`), but OpenWrt emits the WPS/WSC block that carries `device_name` only under `if (config.wps_possible && length(config.config_methods))` (`ap.uc:227`), and `config_methods` is populated solely from `wps_pushbutton`/`wps_label`. openUF sets neither, so WPS never activates and no WSC Device Name IE reaches a beacon. Verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, same gate on both; no live BSS conf carries any WPS key. Turning WPS on to broadcast a name trades a real security surface for a cosmetic feature — deliberately not done. |
| 27 | SAE Anti-clogging / Sync Time | `aaa.<n>.sae.anti_clogging` / `.sae.sync` | ❌ **Not applicable on OpenWrt.** Key names, integer shape and `isWpa3()` gating are confirmed via an unambiguous decompiled method body, and the emitting (true WPA3) case could not be live-diffed — forcing pure WPA3 tripped the [config-sync issue](#config-sync-can-get-stuck-after-informs-stabilise). It does not matter: `sae_anti_clogging_threshold` and `sae_sync` are real hostapd config keys but are **not** wifi-iface UCI options. Verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, against all three places an option can be declared — the wifi-iface schema, `/usr/share/ucode/wifi/` and `hostapd.sh`'s `config_add_*` lists. Neither name appears in any of them, on either board, so openUF's writes were stored in UCI and dropped in silence. Both writes removed; the wire keys are no longer parsed either, since nothing could consume them. |
| 28 | PMF (802.11w) / Multicast Enhancement | `aaa.<n>.pmf.status`/`.pmf.mode`; `wireless.<n>.mcast.enhance` | ✅ Confirmed live by `system_cfg` diff. PMF is what actually carries WPA2/WPA3 transition intent on this model. |
| 29 | Channel width | `radio.<n>.ieee_mode` → `wifi-device.htmode` | ✅ Confirmed live both directions: `11nght20`↔`11nght40` follows the per-AP 2.4 GHz Channel Width control, and the pushed value reaches UCI (`radio0` `HT20`, `radio1` `HT40`). Previously parsed by nothing, so width never applied. |
| 30 | IoT Optimization: Lock 2.4 GHz to Channel 6 | `radio.<n>.channel` (no dedicated key) | ✅ Confirmed live end-to-end: the toggle changes the 2.4 GHz radio's `channel` from `auto` to `6`, and UCI `radio0.channel` follows (verified 11 → 6, so it is not a coincidence of the default). |
| 31 | IoT Optimization: DTIM Interval Lock | `wireless.<n>.dtim_period` (no dedicated key) | ✅ Confirmed live end-to-end: pins the 2.4 GHz vap's `dtim_period` to `3` (REST `iot_dtim_lock` → `dtim_ng: 3`), which reaches UCI. |
| 32 | IoT Optimization: Force WiFi 4 Mode | `wireless.<n>.iot` + `wireless.<n>.qbssload` | ✅ Wire signature confirmed live by before/after diff, and both keys now reach UCI (`openuf_iot=1`, `bss_load_update_period=0`). **The hostapd side of `bss_load_update_period` is not verified on real hardware** — it is hostapd's own option name (0 suppresses the QBSS Load IE), assumed to pass through OpenWrt's wifi-iface schema. The rest of the mode is carried by keys openUF already applied. |
| 33 | Proxy ARP / Client Isolation | `aaa.<n>.proxy_arp` / `wireless.<n>.l2_isolation` | ✅ Confirmed live 2026-07-18 by REST-toggling `wlanconf.proxy_arp` + `l2_isolation` and diffing `system_cfg`: exactly these two keys flipped `disabled`→`enabled`, on **both** the 2.4 GHz and 5 GHz entries of the WLAN, nothing else moved. Both are always present on their block, so "off" is explicit. `proxy_arp` had been visible in the Force WiFi 4 Mode diff all along but was never parsed. |
| 34 | Minimum Data Rate Control | `wireless.<n>.minrate_data` (+ `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg`) | ✅ Confirmed live 2026-07-18 by REST-setting `minrate_setting_preference=manual` + `minrate_ng_data_rate_kbps=12000` and diffing: `minrate_data`/`beacon_rate`/`mgmt_rate` 1000→12000, `minrate_cck_rates.status` true→false, `pureg` 0→1. Separately confirmed **not band-gated** — enabling `minrate_na` (24 Mbps) made the same keys appear on the 5 GHz entries. **The OpenWrt side is radio-level**, not per-BSS (verified in OpenWrt's `hostapd.sh`: these are `hostapd_common_add_device_config` options), so openUF aggregates a radio's VAPs to the most permissive floor. Note `beacon_rate` is passed to hostapd **verbatim in 100-kbps units** while `basic_rate`/`supported_rates` are divided by 100 by `hostapd_add_rate` — openUF converts only the former. Not verified on real hardware. |
| 35 | Multicast and Broadcast Blocker | `wireless.<n>.bcfilt.status` + `bcfilt.<k>.mac`/`.status` | ✅ Wire format confirmed live 2026-07-18 across four diffs (on with one MAC, with two MACs, on with an empty list, off). Two keys already on the wire were **excluded** as candidates by the same diffs: `radio.<n>.bcmc_l2_filter.status` (sits at `enabled` with the control off) and `wireless.<n>.multicast.inspect` — neither moved. ✅ Enforcement confirmed on real hardware 2026-09-02 (AX3000T, nftables 1.1.6, kernel 6.12), measured with counter-only probe rules carrying the same predicate: broadcast sourced onto the VLAN from a second AP and flooded out the IoT VAP matched the drop rule **14 of 14** times with that sender absent from the allow-list, and **0 of 15** times after adding it through the controller — both halves of the control, and the `bcfilt.<k>.mac` parse, end to end. ⚠️ Requires `kmod-nft-bridge`: the drop rule is openUF's only bridge-family `meta` match, `nft_meta_bridge` is absent from stock filogic and ath79 images alike, and without it the kernel returns a bare `Could not process rule: No such file or directory` **only for that rule** — table, chain and allow-list set all build, so the control appeared enabled everywhere while filtering nothing. `firewall.lua`'s block-sta matches on `ether saddr` alone, needs no module, and worked throughout, which is what hid this. |
| 36 | Hide WiFi Name | `wireless.<n>.hide_ssid` (+ duplicate `aaa.<n>.hide_ssid`) | ✅ Confirmed live 2026-07-18 by toggling the control in the UI and diffing `system_cfg`: exactly those two keys flipped `false`→`true`, on both band entries of the WLAN, nothing else moved. Always present, so "off" is explicit and is written back out as `hidden=0`. Note the `true`/`false` vocabulary rather than `enabled`/`disabled`. Previously **documented in USAGE.md as already applied, but no code read or wrote it** — the same doc-vs-code drift as `use_only_unifi_wlan`. |
| 37 | MAC Address Filter | top-level `macacl.<m>.*`, joined on `wireless.<n>.devname` | ✅ Confirmed live 2026-07-18 by enabling the control with one allow-listed MAC and diffing `system_cfg`: the whole `macacl` section appeared at once, keyed by devname (`ath0`/`ath2`) and numbered independently of `wireless.<n>`, so **the devname join is mandatory**. Two keys already on the wire were **excluded** by the same diff: `wireless.<n>.mac_acl.status`/`.policy` (sit at `enabled`/`deny` with the control off) and `aaa.<n>.radius.macacl.status` (the separate RADIUS MAC Authentication control). → OpenWrt `macfilter` + `maclist`, whose allow/deny vocabulary matches the controller's 1:1. Enforced by hostapd itself, so no openUF-side ruleset is involved. |
| 38 | WiFi Speed Limit | top-level `qos.vap.<m>.*`, joined on `wireless.<n>.devname`; a client's own profile as `rate-update` | ✅ Wire format confirmed live 2026-07-18 (kbps; the discriminator is the presence of `maxspeed`; needs a profile to exist). **Per client**, both directions queued (firmware-confirmed for 4.0.15; corrected 2026-10-11 from "per-VAP aggregate"). openUF: one HTB class per client per direction (upload on an IFB), live on both APs 2026-10-11: a phone held 1.97 Mbit/s up under 2 and 4.5 down under 5. See "`qos.*` — WiFi Speed Limit" |
| 39 | Ports view Connection column on an **uplink** port | `port_table[]` with **no** `mac_table` field on `is_uplink` ports | ✅ Blank (or a retained stale value) is the CORRECT state, verified 2026-09-12. Reporting the one MAC on the other end of the cable is tempting — openUF knows it, since finding it is how the uplink socket is identified, and a real UniFi gateway visibly does it on its own uplink port — but it would invert the topology map: the controller files a known device seen alone on a port into this device's `downlink_table`, and the `isUplinkMac` guard against that is ANDed with `!is_uplink`, so it disables itself on exactly the port where it is needed. The gateway would hang beneath every AP that reported it. A real gateway escapes it only because the ISP's router is not an adopted device. Live proof of the correct shape: both APs' `downlink_table` empty, the gateway's holding both APs. The stale text persists because `last_connection` is never recomputed when a port sends no `mac_table` field (and only ever recomputed when a port reports exactly **one** MAC) — clear it with the Ports view's **Clear Last Seen Device**. |
| 40 | Roaming Assistant | `wifi_caps2` bit `0x20` → `wireless.<n>.btm_disassoc.status`/`.threshold` | ✅ Wire format, gate and teardown confirmed live in the lab (10.4.57) and against a real UCG Ultra (Network 10.6), 2026-09-26: the keys arrive on the 5 GHz WLAN entry only, and switching off removes openUF's stamp on both APs. **Steering confirmed on real radios:** a client at −80 dBm on one AP, heard at −52 by the other, got a BTM request, answered `BSS-TM-RESP status_code=4` (refused), was disassociated 16 s later by openUF, and reassociated on the other AP within 1 s at −61 dBm. Its hostapd `extended_capabilities` did not advertise BSS Transition, yet it answered, so the capability bytes do not predict which clients reply. It stayed put for all 30 one-minute samples, with no further actions. The no-better-AP rule is unit-tested only: no qualifying client was present. |
| 41 | Auto-channel exclusions / DFS for Auto | `wifi_caps2` bit `0x10` → `radio.<n>.blklst` / `radio.<n>.acsdfs` | ⚠️ Gate, keys and value formats from the 10.6.106 decompile only; not yet seen on the wire. Mapped to UCI `channels` / `acs_exclude_dfs` while the channel is Auto, stamped and torn down when the keys go; unit-tested through `wlan.parse` + `apply_config`. hostapd applies `chanlist` to the primary channel only, so a wide channel can still cover an excluded secondary. See [`radio.<n>.blklst` / `acsdfs`](#radionblklst--radionacsdfs--auto-channel-exclusions-and-dfs). |
| 42 | Wireless uplink (mesh) | `wifi_caps` `0x1`+`0x800` → `mesh.*`, `wireless.<n>.usage=uplink\|downlink` `wds=enabled` → `openuf_bh_dl_*` (hidden `wds 1` AP) / `openuf_bh_ul_*` (4-address `sta`, wired-first); reported as `usage`-typed VAPs, `uplink` = the uplink VAP's name, each peer by `serialno` | ⚠️ Ported from yesrab/openUF, who verified it end to end on their hardware against 10.6.106. Opt-in (`wireless_uplink`); unit-tested only here, not run in the lab or on this project's (wired) APs. Only the management network crosses the hop. See [Wireless uplink](#wireless-uplink-mesh--ported-from-yesrabopenuf-2026-10-03) |
| 43 | MAC-based VLANs (Virtual Network Override) | `fw_caps` bit 31 (sent signed) → `aaa.<n>.accept_mac.*` → `accept_mac_file` + `wifi-vlan` | ⚠️ Decompiled 10.6.106; unit + hostapd config parse (rootfs). See [MAC-based VLANs](#mac-based-vlans-aaanaccept_mac) |
| 44 | Multicast Suppressor | `wifi_caps2` `0x400000` → `wireless.<n>.multicast.suppressor` (+ Aggressive `bcfilt.bypass_types`) | ⚠️ Decompiled; unit + real nft and bridged traffic in a container. Conservative's threshold is openUF's own |
| 45 | WLAN Schedule | `fw_caps` `0x1000` + `0x400000` → `wireless.<n>.schedule_<day>.<i>`, `schedule_invert` | ⚠️ Decompiled; unit only |
| 46 | Hotspot 2.0 / Passpoint | `fw_caps` `0x800000` → `aaa.<n>.hs20.*` → raw hostapd lines | ⚠️ Decompiled; unit + hostapd config parse. RadSec (`fw2_caps` `0x80000`) not claimed |
| 47 | RADIUS Filter-Id | `fw_caps` `0x20000000` → `aaa.<n>.filter_id` → `radius_auth_req_attr 11:s:` | ⚠️ Decompiled; unit + hostapd parse |
| 48 | SNMP Monitoring | `snmp.*` (v3 behind `fw_caps` `0x4000`) → `/etc/config/snmpd` | ⚠️ Decompiled; unit + real `snmpd-ssl` in the 25.12 rootfs |
| 49 | Radio AI neighbour isolation | `wifi_caps2` `0x200` (no keys; the regular `scan_radio_table`) | ⚠️ Decompiled only |
| 50 | Roam topology | `wifi_caps2` `0x2000`; `sta_roam` + `assoc_status` events | ✅ Upstream live on a UCG Ultra (ea0b5d6: Fast Roaming, failed roam, Roaming Assistant tag); ⚠️ the fork's event-driven port is unit-tested only. See [Roam reports](#roam-reports-association--sta_leave--sta_roam-upstream-ea0b5d6) |

---

## Open questions

- **`setdefault` is never dispatched.** Clicking Remove deletes the device server-side and
  flips the UI to "ready to adopt", but no `setdefault` reaches the wire and `state.json` keeps
  `adopted: true` with the old authkey. Whether a real `setdefault` is sent under different
  circumstances (e.g. only over SSH for L2-discovered devices, mirroring how initial adopt
  differs by discovery method) is unconfirmed. openUF's handler is untested but there is no
  evidence it is wrong.
- ~~**`linkscore` and `multicast`** have no known source or reference.~~ ✅ Resolved upstream
  2026-10-11: the firmware sends neither, and the controller reads them only off a mesh uplink.
  They are no longer sent, and neither are `capacity` or `throughput` (see the sta_table field
  table).
- **`bootrom_version`** has no counterpart in the device schema. Probably ignored.
- ~~**openUF's `usteer` config option names**~~ — ✅ resolved 2026-09-10, verified against the
  installed package; the option names and the named `local` section are both correct.
  The option openUF toggled was inert, though. See the corrected `USTEER_DEFAULTS` row: the
  switch is now `band_steering_interval` (2026-09-27).
- ~~**hostapd's acceptance of `wps_device_name`/`ap_setup_locked`**~~ — ✅ resolved
  2026-09-10: the option names are valid, but OpenWrt never emits the WPS block that would
  carry them (see feature 26). The feature is now documented as not implemented.
- **SAE anti-clogging / sync time** cannot be applied on OpenWrt at all:
  `sae_anti_clogging_threshold` and `sae_sync` are real hostapd keys but are declared in no
  wifi-iface schema, no ucode generator and no `hostapd.sh` `config_add_*` list, on either
  board. openUF no longer writes them (see feature 27).
- **The 2026-10-10 capability features** (§ above) need their first live captures:
  `accept_mac.*` with a client override set, `multicast.suppressor` in both modes, a
  schedule with `schedule_invert`, an `hs20` block, `filter_id`, `snmp.*`. Whether the
  controller accepts a negative `fw_caps` everywhere it reads one (the DTO path argues it
  must) is settled by the first inform after the claim: the device stays Connected and
  the site offers Virtual Network Override. On hardware: a client landing on its override
  VLAN, a scheduled SSID going down and up without the radio's other WLANs bouncing, a
  Hotspot 2.0 BSS answering ANQP, roam records showing "triggered by Roaming Assistant".
- **PoE self-reporting** could be reopened if the validation environment ever gains a real
  switch container, or if a non-Parent-Device UI surface for those fields is found.

---

## Dead ends — do not re-attempt

- **Extracting the AP→controller protocol from U6-InWall firmware.** The official image
  (`v6.8.2+15592`, pulled from `fw-update.ubnt.com`, md5
  `0fec04452cadd2d025777d36ab2974ea`) is a **kernel-only OTA delta**. Its GPT has 5 partitions
  of which only `HLOS` has data; there is no system/rootfs/application partition at all.
  `HLOS.img` is at flat 8.0 bits/byte entropy across ~95% of the file (computed per-1MB block,
  not eyeballed from a binwalk graph), with no compression magic and zero `strings` hits for a
  kernel banner, driver names, or any of `scan`/`spectrum`/`rssi`/`noise`/`channel`/`bssid`.
  Only the last ~1.3 MB is plaintext, and that is device-tree blobs. The inform-client binary
  simply is not in this artifact. Untried alternatives if this ever matters: a pre-2023 build
  that might predate encrypted/kernel-only packaging; pulling the binary off a live owned
  device over SSH; or a LAN packet capture between real hardware and a real controller.
- **Chasing `wait_for_initial_inform` as a thing in itself.** It is downstream of
  [the GCM gate](#the-gcm-provisioning-gate). Editing it in Mongo does nothing (the process
  never re-reads), and restarting the controller to force a reload introduces a separate
  "Offline" artifact.
- **Looking for a manual RF-scan trigger in 10.4.57's UI.** There isn't one — AirView is fed
  entirely by passive, continuously-collected stats. Settings search for "spectrum" returns
  nothing, and no `_type:"cmd"` arrives on its own while the page is open.
- **`strings` on concatenated Java class files on macOS.** `0xCAFEBABE` is both the Java class
  magic and the Mach-O fat-binary magic, so macOS `strings` chokes. Extract printable-ASCII
  runs in Python instead.
- **Deleting a stale wireless client record and waiting for it to reappear.** The pattern works
  for wired clients but wireless ones never came back (45+ s). Recreate the WLAN instead.
