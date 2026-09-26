# openUF vs. UniFi Network 10.6 — gap analysis

Baseline: `jonasevcik/openUF` `main` @ `12b4db0` (= v0.9.2 + 1), compared against
**UniFi Network Application 10.6.106**, the build that runs on UniFi OS 5/6 consoles (the
reference console here is a UCG Fiber on UniFi OS 6.0.x running `unifi-native 10.6.106`).

Sources of truth, in order of weight:

1. **Live captures** against a disposable 10.6.106 controller
   (`lscr.io/linuxserver/unifi-network-application:10.6.106`), driven both by a protocol
   probe and by upstream openUF itself running in `tools/validation/ap`.
2. **The 10.6.106 controller bytecode** (`unifi_sysvinit_all.deb` → `internal-dependencies.jar`,
   decompiled with jadx). Class names are obfuscated, so references below name the role
   (the inform servlet, the inform handler, the mgmt-config generator, …) rather than the
   class.
3. A real 10.6 device payload (`mca-dump` on the UCG Fiber) for field shapes.

Severity: **Blocker** = adoption or a core function fails on 10.6; **High** = a controller
feature silently does not work; **Medium** = degraded behaviour/UX; **Low** = cosmetic or
edge case.

Status column: `open`, or the branch/commit that closes it in this fork.

---

## 1. Protocol gaps (spec vs. implementation)

| # | Sev | Gap | Evidence | Status |
|---|---|---|---|---|
| P1 | **Blocker** | **`inform_ip` is never sent.** Without it the controller takes the *host part of `inform_url` verbatim* (no DNS resolution) and requires it to parse as an IP literal. Any hostname inform URL — including openUF's own default `http://unifi:8080/inform` — is rejected with HTTP 400 on the adoption inform and on every inform after it. Upstream documents a controller-side workaround (Inform Host Override) for its Docker lab only; real devices send `inform_ip`. | Live: `ERROR inform - dev[3e:35:…] invalid inform_ip unifi` → 400, device stuck in ADOPTING. Decompile: inform handler → `inform_ip` else `urlUtils.host(inform_url)` → `isIpLiteral()` else `Invalid`. | fixed on `feat/network-10.6-parity` (sends `inform_ip`, resolved and cached) |
| P2 | **High** | **The controller's bridge/VLAN topology is ignored.** Every full push describes the AP's L2 completely: `vlan.<n>.{devname,id}` (uplink sub-devices), `bridge.<n>.{devname,port.<m>.devname}` (one bridge per network), `netconf.<n>.*` (link state/addressing), `dhcpc.1.devname` (where the management address lives) and the `switch.*` port matrix. openUF derives VLANs only from `aaa.<n>.br.devname` = `br0.<vid>`. Consequences: **Management VLAN** (device → Settings) is not implemented at all — the push moves management to `br0` ⊃ `eth0.<vid>` and re-homes untagged WLANs into a new `br-trunk` bridge, which openUF cannot parse (`br-trunk` has no VID); tagged trunk ports are refused on DSA; a board whose bridge already uses `vlan_filtering` is not supported (see §3). | Live capture, §4 of this document. | fixed on `feat/network-10.6-parity` (`netmodel.lua`, vlan_filtering backend; bench-verified) |
| P3 | Medium | **Pre-adoption HTTP 404 is treated as a failure** and backs off exponentially to 60 s. A pending device is *supposed* to get 404 (the controller creates the pending record and answers 404 until adopted). Effect: a new device appears up to 60 s late and adoption completes up to 60 s after the click. | Inform servlet: unknown device → `UGwcHSHUGpYtqo` sentinel → 404. Live log: `POST failed: HTTP 404` then backoff. | fixed on `feat/network-10.6-parity` |
| P4 | Medium | **`noop.interval` / `immediate` ignored.** The controller computes a per-device next interval (`inform interval service`, raised under load — upstream saw 16–19 s) and can request an immediate re-inform; openUF always waits 10 s. | noop builder: `interval = device.nextIntervalSeconds`; servlet next-inform = 0 when `immediate`. | fixed on `feat/network-10.6-parity` |
| P5 | Medium | **STUN channel not implemented** (answers yesrab's *Investigation 3*). The device is meant to keep a STUN binding to `stun_url` and report its mapped address as `connect_request_ip` / `connect_request_port` in every inform. To make the device inform *now* (Apply, Locate, Reconnect, block), the controller's STUN service sends a 20-byte STUN-shaped header with **message type `0x8888`**, length 0 (optionally the device MAC in bytes 4–9) to that address. Without it every controller action waits for the next heartbeat. | STUN server class: `DatagramSocket` on 3478, `conn_request` queue, `integerToTwoBytes(34952)`. Live: `connect_request_ip: null` on the adopted openUF device. | fixed on `feat/network-10.6-parity` (`stun.lua`; bench-verified through NAT) |
| P6 | Medium | **`setparam.blocked_sta` ignored.** It is the site's *complete* blocked-client list (newline-joined MACs), pushed on every reconnect and every full provision. openUF only tracks one-shot `block-sta`/`unblock-sta` commands, so blocks/unblocks issued while the AP was offline (or after `state.json` loss) never converge. | Default blocked-sta generator: `tQQf(site,blocked=true).mac` joined with `\n`; sent in `FLYOgasYTlg()` and on "blocked_sta config provision" at connect. | fixed on `feat/network-10.6-parity` |
| P7 | Medium | **No notification informs.** `mgmt_cfg` advertises `capability=notif,notif-assoc-stat`. Real APs send out-of-band informs with `inform_as_notif=true`, `notif_reason` (`event`, `setparam`, `cmd`, `cmd-provision`, `cmd-upgrade`, `crashlog`, `trace`, `recovery`) and `notif_payload`. The AP handler consumes `message_type = STA_ASSOC_TRACKER` payloads — per-client `event_type` (connect / sta_roam / sta_leave / failure), `auth_delta`, `assoc_delta`, `wpa_auth_delta`, `radius_auth_delta`, `ip_delta`, `traffic_delta`, `auth_rssi`, `avg_rssi`, `ip_assign_type`, `arp_reply_gw_seen`, `dns_resp_seen`, `*_failures` — which feed the client connection timeline, roaming detection and the WiFi connectivity/failure insights. All of that is blank for openUF APs. | AP handler registers a `STA_ASSOC_TRACKER` message handler; notif dispatch in the inform handler. | fixed: `staevents.lua` sends `association`/`success`/`sta_leave` from station diffs; `success` carries measured phase deltas (hostapd via `staphase.uc`, DHCP/DNS via nftables) and wrong passphrases go out as `failure` |
| P8 | Medium | **`cmd: kick-sta` ("Reconnect Client") is a no-op.** hostapd `del_client` is available. | stamgr → `new cmd{cmd:"kick-sta", mac}` to the station's AP. | fixed on `feat/network-10.6-parity` (hostapd ubus `del_client`) |
| P9 | Low | **`sys_stats` not sent** (`loadavg_1/5/15`, `mem_total`, `mem_used`, `mem_buffer`). PROTOCOL-VALIDATION says the controller "would not have recognized" it — on 10.6 it does: the gateway's own inform carries both `sys_stats` and `system-stats`, and the controller stores `sys_stats` verbatim (it is `{}` on openUF devices). | `mca-dump` on UCGF; device record after adoption. | fixed on `feat/network-10.6-parity` (plus `system-stats.mem` from MemAvailable) |
| P10 | Low | **Authkey rotation refused after adoption.** The controller pushes `authkey=` in `mgmt_cfg` whenever the key that decrypted the inform ≠ `x_authkey`. In 10.6 that is practically only after default-key use, but accepting a rotation that arrives over the *current, secret* key is safe and is what firmware does. | inform handler "[device authkey] updating"; decrypt key list = `[x_authkey, default]`. | fixed on `feat/network-10.6-parity` |
| P11 | Medium | **`cfgversion` is echoed before the push is applied**, `cfgversion_effective` is never sent, and there is no immediate re-inform after a setparam. The controller cannot tell a failed apply from a successful one (it compares `cfgversion_effective` to mark "last config applied successfully"), and provisioning completes one interval late. | inform handler reads `cfgversion_effective`. | fixed: `cfgversion_effective` sent; a failed apply keeps the old `cfgversion` (bounded retries); a rolled-back plan is not reported as applied |
| P12 | Low | **Identity fields not sent:** `sysid` (controller falls back to `model`), `netmask`, `architecture`, `kernel_version`, `board_rev`, `fingerprint` (SSH host key, pinned by the controller for SSH/debug), `internet` (gates upgrade offers; defaults true), `inform_min_interval`, `hash_id`/`anon_id`/`guid`. | inform handler copies these into the device record. | partly: `sysid`, `netmask`, `architecture`, `kernel_version`; `fingerprint` deliberately not sent (a wrong value breaks the controller's SSH pinning) |
| P13 | Low | **Unhandled verbs.** `cmd`: `authorize-guest`/`unauthorize-guest` (hotspot), `quick-scan`/`scan_band`, `clear-counters`, `send-crashlog`/`clear-crashlog`, `build-ssh-session`/`close-ssh-session`/`ssh-sdp-answer` (browser debug terminal over WebRTC), `mesh-halt`. `syswrapper.sh` over SSH: `11k-scan`, `dfs-reset`, `refresh-walled-garden`, `schedule-action`, `upgrade <url>`/`upgrade2`, `unpair`. | Constant pool of the devmgr/API command classes. | partly: `quick-scan`, `11k-scan`, `upgrade`/`upgrade2` (to owut); the rest is recorded in the unhandled ledger |
| P14 | Low | **Port numbering vs. the U6IW registry.** The registry has five ports: 1–4 downstream (`PoE Out + Data`, `Data`×3) and **5 = `PoE In + Data` (the uplink)**. Modelmaps put the uplink on `port_idx` 1, so the UI labels the uplink "PoE Out + Data". | `switch.port.<n>.name` in every push. | `modelmap/auto.lua` numbers the uplink 5; hand-written maps open |
| P15 | Info | Controller *responses* are never compressed on 10.6 (flags are always `0x01` or `0x09`); the inflate path only matters for foreign controllers. Requests may use zlib, snappy or nothing. | Inform servlet encoder. | — |
| P16 | Info | GCM is one-way: after the first GCM inform the controller sets `x_aes_gcm` and rejects CBC from that device ("tried to downgrade"). An image rebuilt without a GCM-capable `lua-openssl` therefore strands an adopted AP — relevant to custom builds (see `contrib/asu`). | Inform servlet `aesGcmInformEncryptionOnly`. | — |
| P17 | Info | A device that informs with the default key while the controller holds it as adopted is rejected with 404 ("used default key in CONNECTED state") and drifts to INFORM_ERROR; re-adopting from INFORM_ERROR is allowed. This is why the sysupgrade keep-list for `/etc/openuf/` matters. | inform handler default-key branch. | — |

### What upstream already gets right on 10.6.106

Confirmed live against 10.6.106 with upstream `main`: L3 pending → Adopt → "skip SSH
adoption" → `mgmt_cfg` authkey → GCM → `system_cfg` → CONNECTED; `set-adopt` over SSH
matches the controller's `/usr/bin/syswrapper.sh set-adopt %s %s`; default key constant;
`switch.*` matrix format; the `system-stats` shape; `blocked-sta`/`unblock-sta` and
`set-locate`/`unset-locate` verbs; `setdefault` on Forget.

---

## 2. README claims vs. code

| # | README says | Code says | Fix |
|---|---|---|---|
| D1 | *SAE Anti-clogging / SAE Sync Time — ⚠️ Implemented from a decompile* | No `sae_anti_clogging` / `sae_sync` anywhere; the writes were removed because no wifi-iface UCI option carries them. | Implemented on the branch through `hostapd_bss_options`, which both wifi stacks pass through; README updated. |
| D2 | *Controller responses may be zlib-compressed; openUF decompresses them* | 10.6 never compresses responses (P15). Harmless, but the claim steers debugging the wrong way. `inform.lua`'s header also says packet version is "always 0" while `PKT_VERSION = 1` is sent. | Corrected (README + `inform.lua` header). |
| D3 | *Both adoption paths complete to **Connected*** | Not with a hostname inform URL, which is the shipped default (P1). The Docker-lab doc treats the Inform Host Override as a lab quirk; it is needed on every 10.6 controller until P1 is fixed. | Closed by P1. |
| D4 | Quick start `apk add …` list | Omits `kmod-sched-act-police` (the README's own Speed Limit row calls it required) and `kmod-leds-gpio`; `install.sh` covers both. | Aligned. |
| D5 | (install.sh) installs `coreutils-stat` "for state-file change detection (`stat -c %Y`)" | `inform.lua` compares file *contents* and never forks `stat`. Dead dependency on flash-constrained boards. | Dropped. |
| D6 | *Tested end-to-end against 10.4.57* | 10.6.106 adopts and provisions, with the P1 caveat. | Updated. |
| D7 | Per-port VLAN on DSA: *Native VLAN only* | Accurate — but the README does not say that trunk ports, Management VLAN and boards that already run `vlan_filtering` are unsupported. | Closed by P2 (vlan_filtering backend) and documented. |
| D8 | Test suite | 690/691 pass under Lua 5.1 in the Alpine validation image; `handle_response persists IP settings before the WiFi pass can raise` fails wherever a real `nft` exists but is not permitted (the test assumes `nft` is absent). | Fixed: the test injects a raising `usteer` (the real dependency was the `uci` module, not `nft`). |

---

## 3. Deployment-blocking compatibility gaps (this network)

The target APs (2× Linksys E8450 / MT7622+MT7915, 1× Netgear WAX220 / MT7986, OpenWrt
SNAPSHOT, DSA) all run a single **VLAN-filtering** bridge (`switch`, `vlan_filtering 1`,
`bridge-vlan` 1/2/3/12) with management on `switch.1`. Against that layout upstream openUF:

- **Reports no IP.** `announce.get_ip()` hops port → bridge → port sub-interfaces; the
  address lives on the *bridge's* VLAN sub-device (`switch.1`), which is never tried. The
  payload goes out with `ip = 0.0.0.0`.
- **Cannot attach tagged SSIDs.** It creates `br-openuf<vid>` holding `<uplink>.<vid>`; on
  a port that is already a member of a VLAN-filtering bridge the 8021q sub-device and the
  bridge fight over the tagged frames.
- **Has no modelmap for any of the three boards**, and the shipped `generic-dualband-ap`
  assumes swconfig `eth0`/`eth1`.
- **Cannot take over the bridge.** There is no code path that replaces an existing bridge
  layout with one derived from the controller, which is what "the controller fully manages
  the AP's bridge" requires.

**Status on `feat/network-10.6-parity`:** all four are addressed. `announce.get_ip()` now
also tries the bridge's own VLAN sub-devices; `bridge_backend = "auto"` selects the
vlan-filtering backend for exactly this layout, which attaches SSIDs to `br-lan.<vid>`
(no 8021q sub-devices) and takes the `switch` bridge over; `modelmap/auto.lua` covers the
boards (E8450: sockets `wan`+`lan1-4`, uplink detected, identity = the current bridge MAC;
WAX220: `eth0`, identity = the label MAC, because `eth0`'s MAC is random per boot). The
takeover was run against this exact layout (`tools/validation/openwrt/ap/network.bifrost`).
Deploying needs `ip-bridge` on the APs (uplink detection; not installed today).

---

## 4. The 10.6.106 bridge topology wire format (captured)

Four WLANs (untagged, VLAN 2, 3, 12), Port VLAN enabled, port 2 native VLAN 3 with VLAN 2
excluded. Uplink devname is `eth0`, VAPs are `ath<n>`:

```
vlan.status=enabled
vlan.1.devname=eth0 / vlan.1.id=2        # uplink 8021q sub-devices, one per tagged network
vlan.2.devname=eth0 / vlan.2.id=3
vlan.3.devname=eth0 / vlan.3.id=12
bridge.1.devname=br0                     # untagged network: uplink + its VAPs
bridge.1.port.1.devname=eth0
bridge.1.port.2.devname=ath0
bridge.1.port.3.devname=ath4
bridge.2.devname=br0.2                   # one bridge per tagged network
bridge.2.port.1.devname=ath1
bridge.2.port.2.devname=ath5
bridge.2.port.3.devname=eth0.2
…
netconf.<n>.devname=<every bridge, sub-device and VAP> / .up / .promisc / .ip=0.0.0.0
dhcpc.1.devname=br0                      # where the management address lives
aaa.<n>.br.devname=br0 | br0.<vid>       # the only thing openUF reads today
switch.status=enabled / switch.vlan.status=enabled
switch.vlan.<m>.id / .mode (untagged|tagged) / .status
switch.port.<n>.name / .opmode / .pvid
switch.vlan.<m>.port.<n>.mode=untagged|tagged|exclude
```

Setting **Management VLAN = 50** (device → Settings) changes the topology, not just an
address:

```
vlan.2.id=50                             # 50 joins the uplink sub-devices
bridge.1.port.1.devname=eth0.50          # br0 = management bridge, now ONLY eth0.50
bridge.5.devname=br-trunk                # new: untagged uplink + untagged-network VAPs
bridge.5.port.1.devname=ath0
bridge.5.port.2.devname=ath4
bridge.5.port.3.devname=eth0
aaa.1.br.devname=br-trunk                # untagged WLANs move to br-trunk
dhcpc.1.devname=br0                      # unchanged: br0 now means "VLAN 50"
```

So the controller sends a complete, declarative L2 model; implementing "the controller
manages the bridge" means realising *this* model, not deriving VLANs from WLANs.

---

## 5. yesrab/openUF fork (16 ahead, 80 behind upstream at merge-base `677f732`)

About half of the 16 commits are hand re-implementations of upstream work (DSA socket
learning, the nft MAC tap, `rrmscan`, the AX3000T map, the iw 6.17 scan parsing, the
sysupgrade keep-list, the heartbeat probe) squashed into fork commits — hence the merge
conflicts. Upstream already has all of those. What is genuinely theirs:

| Change | Generic? | Recommendation |
|---|---|---|
| `sysconf.lua` — applies the controller's `system.timezone`, `ntpclient.*` and `cron.*` (the nightly `syswrapper.sh 11k-scan`) to UCI/crontab, reversible, command allow-list | Yes | **Port**, behind an opt-out (sites with a local NTP server may not want the ubnt pool). **Ported (`controller_system`).** |
| `unhandled.lua` — bounded, redacted ledger of every `_type`/`cmd`/key the daemon did not act on (`/etc/openuf/unhandled.json`) | Yes | **Port.** Cheap and it is how new controller verbs get noticed. **Ported.** |
| `l2guard.lua` — the controller's `ebtables.*` hardening (BPDU drop, no VLAN-tagged frames from Wi-Fi clients) as an nftables bridge table on VAP netdevs | Yes | **Port**, optional (needs `kmod-nft-bridge`). **Ported (`l2guard`).** |
| `syswrapper.sh 11k-scan` verb | Yes | Port with `sysconf.lua` (the cron job calls it). **Ported; it asks a client for an 802.11k report instead of scanning off-channel.** |
| `update.sh` + `/tmp/openuf-status` health file + `tools/deploy.sh` — in-place update with backup, health wait and rollback | Yes | **Port.** Also what an image-rebuild flow needs to verify a fresh install. **Ported (`openuf-update`, release + sha256 aware).** |
| `debug_caps`, `debug_payload_extra`, `debug_dump_requests` research switches | Yes | Port (research tooling, logged loudly when active). **Ported.** |
| Radio policy (`dev.conf.radio.<band>.htmode_floor/htmode_max`, auto-channel constraints) | Mechanism yes, values board-specific | Port the mechanism; the JioRouter values stay with those maps. **Ported.** |
| `country_override` | Yes (small) | Port — useful when the site country and the board's regdomain must differ. **Ported.** |
| Coreutils-stat removal | Yes | Port (D5). |
| `setup.sh` guided installer (board detection, modelmap selection/generation, non-interactive flags) | Partly | Take the **board-name → modelmap** and **generate-for-DSA** ideas; the interactive shell UI is not needed for image builds. `contrib/asu` generates maps from `/etc/board.json` instead. |
| `generic-singleband-ap.lua` | Yes | Port. **Ported.** |
| `ufmodel/uhdiw.lua` (UAP-IW-HD identity) | Yes, unvalidated | Port after a test-controller adoption (cheap to validate). **Superseded: `ufmodel = "auto"` produces UHDIW (and every other registry AP) from the catalogue.** |
| `archer-a7-v5.lua`, `jiorouter-*.lua` | Board-specific, unvalidated | Only if those boards are in use. |
| `tools/stun-probe.lua`, REVERSE-ENGINEERING.md Investigation 3 | — | Superseded by P5 (the mechanism is now known). |
| `CLAUDE.md` / `AGENTS.md` / `.vscode` | — | Skip. |

---

## 6. What the controller's model catalogue offers

`dl/uidb/uidb.json` and `dl/firmware/bundles.json` ship in every Network release and describe
every adoptable model: `shortnames`, `sysid`, `deviceCapabilities`, `hybrid` (`uap+usw`),
port counts, per-band radios (`maxPower`, `maxSpeedMegabitsPerSecond`, `gain`), chipset and
`minimumFirmwareRequired`; `fw-update.ui.com` gives the current firmware per platform. That is
enough to pick the closest UniFi identity for a board automatically (ports, bands, Wi-Fi
generation, chipset family → which config generator the controller uses) and to report a
firmware version that does not trigger upgrade offers. Today openUF hardcodes `u6iw` and a
version string per ufmodel.

---

## 7. Findings made while fixing (10.6.106 behaviour worth knowing)

- **Provisioning is deduplicated.** The controller keeps (per device, 10 min, renewed
  on every access) a checksum of the last `system_cfg` + `blocked_sta` + `mgmt_cfg`
  (minus `cfgversion`) and the `cfgversion` the device reported when it was sent. If
  the device's reported version has moved on but the config is identical, it logs
  "Skipping provisioning of device[…], config unchanged" and just adopts the reported
  version -- **even for Force Provision**. A device that echoes `cfgversion` without
  applying the push (P11) therefore never receives that config again until something
  in it changes. Seen on the bench after a netmodel bug; the fix is to change any
  setting.
- **"Upgradable" is string inequality.** A device is upgradable whenever its `version`
  is not character-for-character the catalogue's current version for the model.
  Reporting anything else (e.g. the OpenWrt revision) means a permanent Upgrade badge
  and, with auto-upgrade on, nightly upgrade attempts. openUF now learns the catalogue
  version from the controller's own `upgrade` commands.
- **What the STUN wake is used for.** Upgrades (manual, scheduled, custom URL) and
  missed-heartbeat recovery; Locate, Reconnect and config changes simply wait for the
  next inform. The STUN service is a classic RFC 3489 server (jstun) that **drops any
  Binding Request without a CHANGE-REQUEST attribute** and any attribute other than
  CHANGE-REQUEST / RESPONSE-ADDRESS; it answers with MAPPED-ADDRESS.
- **A known wired client keeps its first network.** When a socket's native VLAN
  changes, the host behind it is reported with its new `vlan` straight away, but the
  controller keeps it in the network it was first seen on until it is forgotten or
  reconnects. On the bench, a client that came up before its port was moved to VLAN 3
  stayed "Default" until Forget, and was then re-filed as IoT / VLAN 3 / port 2.
- **OpenWrt's Lua is 5.1 "double int32" (LNUM).** `string.format("%x")` (and `%d`)
  reject values from 2^31 up. Caught by the real-netifd bench, not by the unit tests.
- **Docker is a poor switch.** The Docker bridge reflects a client's broadcasts back
  into an AP container, teaching the AP's bridge the client's MAC on the uplink; and
  Docker Desktop's kernel loads `br_netfilter` in every namespace, sending bridged
  frames through fw4. The bench (`tools/validation/openwrt`) uses a veth "cable" and
  turns `br_netfilter` off.

## 8. What `feat/network-10.6-parity` adds

| Area | Files |
|---|---|
| Controller-owned bridge: one vlan-filtering bridge realising the controller's L2 model (Management VLAN, WLAN VLANs, trunk ports), takeover/recreation of foreign bridges, automatic rollback | `openuf/src/openwrt/netmodel.lua`, hooks in `inform.lua`/`ucihelper.lua`, `syswrapper.sh netmodel-retry` / `netmodel-restore` |
| Protocol: `inform_ip`, pending 404, `interval`/`immediate`, `blocked_sta`, `kick-sta`, key rotation, `sys_stats`, `sysid`, MemAvailable, immediate re-inform, IP refresh | `inform.lua`, `sysinfo.lua`, `ucihelper.lua`, `ufmodel/u6iw.lua` |
| STUN wake-up channel | `openuf/src/unifi/stun.lua` |
| IP detection on `<bridge>.<vid>` management | `announce.lua` |
| DSA boards without a hand-written map; stable identity MAC | `openuf/src/openwrt/board.lua`, `dev.conf.net.identity_mac` |
| OpenWrt upgrades through UniFi (owut), catalogue-version learning | `openuf/src/openwrt/upgrade.lua` |
| Image builds (firmware-selector / owut / ASU API / ImageBuilder) | `openuf/contrib/asu/` |
| Real-netifd test bench | `openuf/tools/validation/openwrt/` |
| Client connection/roaming events (`STA_ASSOC_TRACKER` notification informs) | `openuf/src/unifi/staevents.lua` |
| Applied-config reporting (`cfgversion_effective`, bounded re-push) | `inform.lua` |
| Explicit cipher from `wpa.1.pairwise`; SAE anti-clogging/sync via `hostapd_bss_options` | `ucihelper.lua`, `inform.lua` |
| Identity from the controller's own model registry | `openuf/tools/uidb-catalog.py`, `openuf/src/unifi/catalog.lua`, `openuf/src/unifi/modelmatch.lua`, `openuf/src/unifi/identity.lua` |
| yesrab/openUF ports: unhandled ledger, controller timezone/NTP/cron, L2 hardening, in-place updater, debug switches, radio policy, `country_override`, single-band generic map | `unhandled.lua`, `sysconf.lua`, `l2guard.lua`, `update.sh`, `openuf/tools/deploy.sh`, `ucihelper.lua`, `modelmap/generic-singleband-ap.lua` |
| Ready-to-adopt AP mode on first boot | `openuf/contrib/asu/openuf-firstboot.sh` |
| OpenWrt packages `openuf` and `luci-app-openuf` from a signed feed (apk, OpenWrt 25.12+) built by CI with the official SDK; settings in UCI (`/etc/config/openuf`) with LuCI Status / Settings / Unhandled messages pages; reinstall after firmware upgrades; migration from tarball installs | `openuf/Makefile`, `openuf/files/`, `openuf/src/config.lua`, `openuf/src/migrate.lua`, `luci-app-openuf/`, `.github/workflows/feed.yml` |
| Tests: 819 (upstream 691), all green under Lua 5.1, run from `openuf/` | `openuf/tests/`: `test_netmodel.lua`, `test_stun.lua`, `test_upgrade.lua`, `test_staevents.lua`, `test_modelmatch.lua`, `test_unhandled.lua`, `test_sysconf.lua`, `test_l2guard.lua`, `test_config.lua`, `test_migrate.lua`, `test_package.lua`, additions elsewhere |
