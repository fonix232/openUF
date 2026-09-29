# openUF

[![Tests](https://github.com/fonix232/openUF/actions/workflows/test.yml/badge.svg)](https://github.com/fonix232/openUF/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Lua 5.1+](https://img.shields.io/badge/Lua-5.1%2B-blue.svg)](https://www.lua.org/)

openUF is a Lua daemon that makes an OpenWrt device appear as a **Ubiquiti UniFi access point** to a UniFi Network Application controller — by default the UniFi model closest to the hardware, picked from the controller's own model registry (a 5-socket WiFi 6 router becomes a U6-InWall, a 1-socket WiFi 6 AP a U6-Pro). The controller can then adopt the device, push SSID, VLAN and bridge configuration, and display live client, connection and radio statistics — all without genuine Ubiquiti hardware.

This is [fonix232/openUF](https://github.com/fonix232/openUF), a fork of [jonasevcik/openUF](https://github.com/jonasevcik/openUF) that tracks UniFi Network 10.6 and adds the controller-owned bridge, connection events, automatic identity and OpenWrt image builds.

<p align="center">
  <img src="docs/img/unifi-topology.jpg" alt="UniFi topology view: a real Cloud Gateway Ultra with two openUF access points below it, carrying the network's 20 wired and wireless clients">
</p>

<p align="center"><em>The controller's topology view: two openUF access points under a real UniFi Cloud Gateway Ultra, and all 20 clients on the network, 18 of them behind the openUF APs. Click for full resolution.</em></p>

<table>
<tr>
<td width="50%"><img src="docs/img/unifi-device-detail.jpg" alt="UniFi device list and the detail panel of an openUF access point"></td>
<td width="50%"><img src="docs/img/unifi-clients.jpg" alt="UniFi client list showing clients associated to openUF access points"></td>
</tr>
<tr>
<td><em>Both openUF APs online as model <code>U6 IW</code>, with radios, uplink port, firmware version, 38 days of uptime and live throughput.</em></td>
<td><em>The controller's client list — most of these clients are associated to the two openUF APs on a controller-pushed SSID, with band, channel, WiFi generation and per-client experience.</em></td>
</tr>
</table>

Those are screenshots of the author's live network taken from a real UniFi Cloud Gateway Ultra; every hostname, MAC address, IP address, SSID and ISP name in them was rewritten to a consistent fake value in the browser before capture.

Tested end-to-end against **UniFi Network Application 10.4.57** — both a self-hosted Docker controller and a real UniFi Cloud Gateway Ultra adopting a TP-Link Archer C5 v1 running openUF, with real clients associating to the pushed SSID — and against **10.6.106** (the build UniFi OS 5/6 consoles run) on a real-netifd OpenWrt bench; see [docs/GAP-ANALYSIS-10.6.md](docs/GAP-ANALYSIS-10.6.md) for what 10.6 changed and what this fork does about it.  The identity validated end to end is **U6-InWall** (model `U6IW`); `ufmodel = "auto"` picks another registry model when the hardware is closer to it.  openUF emulates a UniFi **access point** only — gateway (USG) and switch (USW) emulation are not implemented and not planned.

Most rows below marked ✅ were verified by driving the real controller UI against a live openUF device and reading back the resulting wire capture; [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) records the evidence, including where a claim rests on decompiling the controller rather than a live capture.

## What it does

### Adoption and transport

| Feature | Status |
|---|---|
| L2 UDP discovery (port 10001) | ✅ Working |
| TNBU inform protocol | ✅ Working — AES-128-CBC and AES-128-GCM |
| AES-128-GCM | ✅ Working — **required**: 10.4.57 will not finish provisioning a device until it receives a genuine GCM inform. Needs a GCM-capable `lua-openssl` build |
| L2 adoption (SSH `syswrapper.sh set-adopt`) | ✅ Working — completes to **Connected** |
| L3 adoption (`set-inform`, no SSH) | ✅ Working — the controller skips SSH entirely and delivers the new authkey in the `setparam` `mgmt_cfg`. The controller chooses this path when it has *not* discovered the device via broadcast, which is what `config.l2_announce = false` is for — same-subnet devices that can't accept an SSH login need it. **Hostname inform URLs work**: openUF sends `inform_ip` (the resolved controller address); without it 10.6 rejects every inform from a device whose URL is not an IP literal (`invalid inform_ip`, HTTP 400) |
| Pending adoption | ✅ HTTP 404 before adoption is the controller's normal answer; openUF keeps its regular cadence instead of backing off, so a new device appears and adopts within one interval |
| Controller wake-up (STUN) | ✅ openUF keeps a binding to the controller's `stun_url` and reports `connect_request_ip`/`_port`; the controller's `0x8888` connection request makes it inform at once (10.6 uses it for upgrades and missed-heartbeat recovery). Verified through NAT on the bench |
| Inform cadence | ✅ Follows the controller's `interval` and `immediate` instead of a fixed 10 s, and re-informs straight after applying a push |
| Zero-touch bootstrap adoption | ✅ Optional (`option ssh_adopt '1'`, or `SSH_ADOPT=1` in image builds) — a temporary `ubnt/ubnt` account, non-root, whose forced shell runs nothing but 10.6's `/usr/bin/syswrapper.sh set-adopt <url> <key> [<mac>]` (a MAC must be this AP's). Dropbear's TCP forwarding is switched off while it is usable, and it locks itself at adoption. Only needed where the controller adopts over SSH: L2-discovered devices, and same-subnet devices whose netmask it knows — which is why openUF withholds `netmask` until it is adopted, keeping adoption on the inform channel by default |
| Forget device / factory reset | ✅ Working (`syswrapper.sh reset-inform`) |
| Restart / reboot command | ✅ Working |
| Applied-config reporting | ✅ `cfgversion_effective` names the last push that applied without an error, which is what the controller's "last config applied successfully" is computed from. A push that fails to apply keeps reporting the previous `cfgversion`, so the controller sends it again after its 10-minute dedupe window (twice, then it is acknowledged so it cannot cycle); a network plan that was rolled back is not reported as applied |
| Firmware upgrade requests | The Ubiquiti image is never fetched. By default the request is stored and its `version` learned, so the device reports the catalogue's current version (10.6 calls anything else "upgradable"). Opt-in `upgrade_mode = "owut"` turns Upgrade / Custom Upgrade / the controller's schedule into an **OpenWrt attended sysupgrade** of this board; `advertise_updates` raises UniFi's own "Upgrade available" badge while `owut check` finds a newer build. See `openuf/upgrade.lua` and [contrib/asu](contrib/asu/README.md) |

### WiFi provisioning

| Feature | Status |
|---|---|
| Controller-pushed SSID provisioning | ✅ Working (UCI); only `openuf_`-prefixed sections are created or deleted |
| Exclusive-WLAN mode (`use_only_unifi_wlan`) | ✅ Working — default `true` disables hand-configured SSIDs so the radios carry only what the controller pushed; reversible (openUF stamps what it disabled) |
| WPA2 / WPA3 / WPA2-WPA3 mixed security | ✅ Working — derived from the pushed AKM set plus `wpa3.support`/`wpa3.transition`. The cipher is always written explicitly from the pushed `wpa.1.pairwise` (`psk2+ccmp`, `sae+ccmp`, `sae-mixed+ccmp`; GCMP/CCMP-256/GCMP-256 when the controller asks): left out, OpenWrt picks it from the board and the htmode, and some releases picked GCMP-256, which many clients cannot join. Requires `radio_caps2` bit `0x1` on each radio, which openUF sends when hostapd can really do SAE — without it the controller silently downgrades every WPA3 WLAN to WPA2. **WPA-Enterprise (802.1X) is not supported**: the wire protocol carries no RADIUS server, port or secret, so such a WLAN is skipped with a log line rather than mis-provisioned as a keyless WPA2 SSID |
| Enhanced Open (OWE), incl. transition mode | ⚠️ Lab-confirmed on the wire (upstream's lab), not yet on hardware: no OWE BSS has been brought up on a real AP. Needs `radio_caps2` bit `0x8`, which openUF claims when `hostapd -vowe` passes and OpenWrt 25.12's ucode wifi generator knows `owe_transition`. Without the bit the controller drops an OWE WLAN and sends a transition one as plain open. Transition mode is written as one `owe_transition=1` section, with a bare `encryption=owe`: the generator pairs the two BSSes only for exactly `owe`, so the cipher suffix every other security type gets would break it. OpenWrt then names the hidden OWE BSS `<ssid>OWE`, where UniFi firmware reuses the SSID |
| PMF / 802.11w (`ieee80211w`) | ✅ Working — from `aaa.<n>.pmf.status`/`pmf.mode`. PMF is just PMF: the WPA3-transition signal is `wpa3.support`/`wpa3.transition`, not these keys |
| Fast Roaming (802.11r) | ✅ Working — **verified on real hardware** by forcing a roam and watching for `auth_alg=ft` with no EAPOL 4-way, both between radios on one AP and between two APs. Both the WLAN-level `ft.status` and the SAE-only `wpa3.ft.status` are read; FT is enabled if either asks for it, since OpenWrt cannot enable 802.11r for one AKM alone. On a **WPA3-only** WLAN the controller sends FT only to a radio claiming `radio_caps2` bit `0x2`, which openUF sets alongside `0x1` (⚠️ lab-confirmed on the wire; an FT-SAE roam on a WPA3-only WLAN is not yet verified on hardware). openUF sets the mobility domain (derived from the SSID, so every AP agrees without coordination) but deliberately leaves `ft_psk_generate_local` alone — pinning it broke fast roaming for every WPA3 client, see USAGE § 3 |
| VLAN-tagged SSIDs | ✅ Working — verified end-to-end on real hardware with a client on a tagged IoT network. From `aaa.<n>.br.devname` (`br0.<vlan>`), the wire's only VLAN signal: openUF builds a `br-openuf<id>` bridge holding the tagged uplink sub-device, joins the VAP to it. No switch trunk is needed: with bridge VLAN filtering off the switch passes tags through, and the sub-device on the uplink socket takes its VID before the bridge sees it — but that sub-device and the bare uplink are then one physical port on one switch with **one hardware FDB**, so openUF sets `learning '0'` on the tagged port; left learning, the switch files the upstream router's MAC under the VLAN bridge and blackholes every *wired* client's traffic to the gateway while WiFi clients, which take the software path, stay fine |
| Private Pre-Shared Keys (several passphrases on one SSID, each on its own VLAN) | ⚠️ Lab-confirmed upstream on the wire and through to UCI, not yet on hardware: no client has joined with a VLAN key on a real AP; in this fork unit-tested only. Needs `wifi_caps` bit `0x100000`, which openUF claims when the ucode wifi generator writes per-station VLANs (`vlanid=` in `ap.uc`, 24.10+) and hostapd is built with VLAN support. Without the bit the controller skips the WLAN entirely. Each key becomes a `wifi-station` section (any MAC) and each VLAN a `wifi-vlan` section bridged into the same `br-openuf<id>` a VLAN-tagged SSID uses (with the `vlan_filtering` backend: the plan's interface for that VLAN, which openUF adds to the bridge for a VLAN only a key uses); a key on a VLAN-1 network puts its client on the WLAN's own network. A key whose VLAN openUF cannot build is left out, never downgraded to the untagged LAN. A UID IoT WLAN whose keys come from RADIUS only (`psk_radius=2`) is skipped, as WPA-Enterprise is |
| Channel and TX power per radio | ✅ Working (Low/Medium/High/Custom; channel **Auto** is written through as UCI `channel=auto`, i.e. hostapd ACS picks on the AP; TX power **Auto** deletes the `txpower` option so the driver default applies again) |
| Radio enable / disable | ✅ Working — Transmit Power → **Disabled** arrives as `radio.<n>.status=disabled` (plus `wireless.<n>.status` on each of that radio's WLANs) → UCI `disabled`. Only an explicit value is written, so a push that omits the key leaves a hand-disabled radio alone |
| Device identity vs. management MAC | ✅ openUF identifies by `dev.conf.net.lan_cpueth`'s MAC but reports the IP of the bridge that port is enslaved to. Where those are different netdevs — DSA boards, where `lan_cpueth` names a socket carrying the label MAC while `br-lan` inherits the conduit's — the AP claims an address that ARP attributes to a different MAC, and the gateway raises an IP conflict against a correctly configured network. `ucihelper.ensure_bridge_identity` pins the bridge to the identity MAC at startup, only when they differ. **Verified on real hardware** |
| Channel width per radio | ✅ Working — from `radio.<n>.ieee_mode` (`11nght20`/`11naht40`/…), which carries the **band and the width and nothing else**: its `ht` is Atheros-era vocabulary, not a request for 802.11n (a real U6-InWall runs `11naht40` as HE40). openUF takes the width from the wire and the PHY generation from `iw phy`, then clamps down to what the radio really supports — a WiFi-6 identity also invites HE pushes at n/ac hardware, which hostapd would refuse to start on |
| IoT Optimization: Lock 2.4 GHz to Channel 6 / DTIM Interval Lock | ✅ Working — both are controller-side shortcuts that arrive as an ordinary `radio.<n>.channel=6` and `dtim_period=3`, needing no dedicated handling |
| IoT Optimization: Force WiFi 4 Mode | ✅ Wire protocol confirmed live (`wireless.<n>.iot` + `qbssload`); most of the mode arrives as ordinary keys (2.4 GHz-only, WPA2, PMF/BSS-transition/proxy-ARP off). Its one distinct effect, suppressing the QBSS Load IE via `bss_load_update_period`, is not verified against real hardware |
| BSS Transition (802.11v) | ✅ Working (`bss_transition`) — needs a full `wpad` build |
| Band Steering | ✅ Working via `usteer` — requires the `usteer` package and a full `wpad` build (see Quick start). A real client was observed being moved 2.4 → 5 GHz by an accepted 802.11v BSS-Transition request; clients that stay put are the ones with no BSS-Transition support or no 5 GHz sighting. Off writes `band_steering_interval=0`, so a usteer that runs for Roaming Assistant (or anyway) does not steer, and stops the daemon when Roaming Assistant is off too; that 0 reaching the running daemon is ✅ confirmed on hardware by upstream with the same logic (not re-run on this fork). Until 2026-09-27 openUF toggled `band_steering_threshold`, an option usteer ignores here: on worked only through usteer's default interval. The AP's own Band Steering setting (device panel) is supported too: Prefer 5G is ✅ confirmed on hardware by upstream as far as the wire and the running daemon go (a real UCG Ultra pushes it, and usteer's steering interval turns on). ⚠️ A client steered by it alone has not been observed yet. Balance has no usteer equivalent and is ignored with a log line |
| Airtime Fairness | ✅ On confirmed on hardware upstream (both APs, all four radios: pushed by a real UCG Ultra, written and read back); in this fork unit-tested only. ⚠️ Off is lab-confirmed only. **Check the device's Airtime Fairness setting after upgrading:** a controller may hold it off from before openUF claimed the bit, and the first push then turns the kernel's fairness off. The device panel's Airtime Fairness switch reaches openUF only with `wifi_caps` bit `0x20`, which openUF claims where mac80211's per-phy `airtime_flags` exists in debugfs. On is the kernel's own default (every client gets an equal airtime share), so only Off changes anything: openUF writes 0 to `airtime_flags` and the scheduler stops charging airtime, i.e. plain round-robin. The setting is kept in `state.json` and reapplied at startup, since debugfs resets on reboot. hostapd's `airtime_mode` is not used: none of its modes switch the scheduler off |
| Auto 802.11 DTIM Period | ✅ Working — Auto and Custom both arrive as a concrete `dtim_period` |
| Multicast Enhancement (multicast-to-unicast) | ✅ Working — from `wireless.<n>.mcast.enhance` |
| Multicast and Broadcast Blocker | ✅ Confirmed on real hardware. No hostapd/OpenWrt option exists for it, so it is enforced with nftables in a dedicated `bridge openuf_bcfilt` table: 14 of 14 broadcast frames from a non-allow-listed sender were dropped on the way out the VAP, 0 of 15 once that sender was allow-listed. **Needs `kmod-nft-bridge`** — the drop rule is a bridge-family `meta` match (as are the L2 hardening's) and a stock image has no `nft_meta_bridge`, in which case the table, chain and allow-list all still build and only the rule is rejected. **Blocks LAN→WLAN broadcast/multicast except from allow-listed source MACs — this breaks DHCP for wireless clients unless the DHCP server's MAC is on the list**, which is Ubiquiti's own documented behavior. The ruleset is rebuilt from UCI on every start, so it survives a reboot the controller does not re-push after |
| Minimum Data Rate Control | ✅ Wire protocol confirmed live (`wireless.<n>.minrate_data` + `beacon_rate`/`minrate_cck_rates.status`/`minrate_below_disable`). Applied per **radio** — OpenWrt's `basic_rate`/`supported_rates`/`legacy_rates`/`beacon_rate` are `wifi-device` options, so WLANs sharing a radio collapse to the most permissive floor. Turning the control off tears the options down again (marker-tracked, hand-tuned rates untouched) |
| Proxy ARP | ✅ Wire protocol confirmed live (`aaa.<n>.proxy_arp`) → `proxy_arp`. Needs a full `wpad` build (hostapd only compiles proxy-ARP support in with `CONFIG_PROXYARP`) |
| Client Isolation | ✅ Wire protocol confirmed live (`wireless.<n>.l2_isolation`) → `isolate` (hostapd `ap_isolate`) |
| Hide WiFi Name | ✅ Wire protocol confirmed live (`wireless.<n>.hide_ssid`, duplicated as `aaa.<n>.hide_ssid`) → `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | ✅ Wire protocol confirmed live. Arrives in a top-level `macacl.<m>.*` section keyed by **devname**, not by WLAN index, so it is joined on `wireless.<n>.devname` → `macfilter` + `maclist`. Allow/deny policy maps 1:1 onto OpenWrt's; enforced by hostapd itself |
| WiFi Speed Limit | ⚠️ Wire protocol confirmed live (top-level `qos.vap.<m>.*`, joined on devname; kbps; a **per-VAP aggregate** cap, not per-client). Needs a speed-limit profile to exist in site settings before the per-WLAN toggle emits anything. No hostapd/OpenWrt option expresses a throughput cap, so it is enforced with `tc` — HTB on egress for downlink, ingress policing for uplink. The generated commands are verified against real `tc`, but the on-air throughput is not (no real radios available). **Needs `tc-tiny` *and* `kmod-sched-act-police`**: the uplink half uses the `police` action, which is a separate module absent from some images — without it the download cap applies and the upload cap silently does not (install `tc-tiny` and `kmod-sched-act-police`; openUF logs it by name if `tc` still rejects the filter). The qdiscs are rebuilt from UCI on every start, so the cap survives a reboot |
| Roaming Assistant | ✅ Working — **verified on real hardware**: a client stuck at −80 dBm on one AP was moved to the other AP (−61 dBm) and stayed there for the 30 min watched. Per WLAN, 5 GHz. A weak client gets an 802.11v request toward an AP that hears it at least 8 dB louder (`roam_assist_diff_db`), then a disassociation if it stays; a client with no better AP is left alone. Needs `usteer` on every AP (see USAGE § 6). Leaving a client alone when no better AP exists is unit-tested only: no such client was present during the hardware run |
| Minimum RSSI | ✅ Working — per **radio**, not per WLAN; enforced by deauthenticating clients below the threshold (a one-shot kick, not a persistent block). Disabling it in the controller stops the enforcement (the wire signals disable by omitting the whole `stamgr.<n>` block) |
| Show Access Point Name in Beacon | ❌ **Not implemented on the OpenWrt side.** The wire protocol and its `wifi_caps2` bit `0x40` gating are confirmed live, and openUF writes `wps_device_name`/`ap_setup_locked` — but a beacon never carries the name. OpenWrt emits the whole WPS/WSC block, `device_name` included, only when `config_methods` is non-empty, which needs `wps_pushbutton` or `wps_label`; openUF sets neither, so WPS never activates. Verified 2026-09-10 on an Archer C5 and an AX3000T (both 25.12.5): the gate is `/usr/share/ucode/wifi/ap.uc:227`, and no live BSS config carries a single WPS key. Enabling WPS to broadcast a name is a real security surface for a cosmetic feature, so this is left unimplemented deliberately |
| WLAN Schedule | ❌ **Not implemented.** The controller emits a scheduled WLAN's `wireless.<n>.schedule_<day>` keys regardless of any capability bit, but openUF parses none of them, so the SSID stays up around the clock. Two `fw_caps` bits change that wire format and are deliberately not claimed until the schedule is built: `0x1000` (several time blocks per day as `schedule_<day>.<i>`; without it, blocks collapse onto one key and the last one wins) and `0x400000` (`schedule_invert`; without it the controller inverts the schedule itself). See PROTOCOL-VALIDATION.md § Capability bitmasks |
| SAE Anti-clogging / SAE Sync Time | ✅ Working — `aaa.<n>.sae.anti_clogging`/`sae.sync` (sent only for WLANs that really run SAE) become `sae_anti_clogging_threshold`/`sae_sync` through `list hostapd_bss_options`, which both OpenWrt wifi stacks pass to hostapd verbatim. Neither is a wifi-iface option, so writing them as options (as upstream once did) was stored and silently dropped |

### Reporting and statistics

| Feature | Status |
|---|---|
| Wireless client statistics | ✅ Working — per-client traffic, signal, MIMO/generation, TX MCS (`vap_table[].sta_table`) |
| Client connection and roaming history | ✅ Associations, connections and departures are sent the way UniFi APs send them: as `STA_ASSOC_TRACKER` notification informs (`association`, `success`, `sta_leave`), which is what the controller builds a client's connection timeline and its roams between APs from. Derived by diffing the station list between heartbeats, with iw's connected time dating each association. Each connection is timed for the WiFi Connectivity view: association and the key handshake from hostapd's ubus notifications (a small ucode collector stamps them), the first DHCP ACK and DNS answer from nftables. A `success` is sent only once that first DNS answer has been seen, which is what the controller counts a connection by, and wrong-passphrase attempts go out as `failure` events. Off with `sta_events = false` |
| Radio statistics | ✅ Working — channel utilization, avg. signal/interference/airtime, per-VAP "Air Stats" |
| WiFi Experience / satisfaction score | ✅ Working — device-computed, confirmed rendering live. An estimate (Ubiquiti's own formula is undocumented): the worst of downlink airtime efficiency (ideal ÷ actual airtime, as Aruba/Aerohive score client health), uplink rate against the client's ceiling, and SNR. ✅ Airtime tracks ping loss on mt76 (hardware), and ath9k counts retries in it (source). ⚠️ Unconfirmed: whether ath10k firmware counts retries in airtime, and HE (Wi-Fi 6) client ceilings |
| Ethernet port statistics (`port_table[]`) | ✅ Working — one entry per socket, each with the link speed and duplex that socket actually negotiated: every socket is its own netdev, so sysfs answers per socket. Which socket is the uplink is detected from the bridge FDB (`bridge fdb show br br-lan` names the port each MAC was learned on), so it follows the cable; where it cannot be detected the board's declared uplink is flagged instead. Byte, packet and error counters come from each socket's own netdev. Anomaly, STP and Profile are controller-side or USW-only — they read `-` for a real UniFi gateway's ports too |
| Wired client statistics (`port_table[].mac_table`) | ✅ Working — hosts are placed on the socket they are really plugged into, from the bridge FDB, where each socket is its own bridge port. Each socket is asked about **its own** bridge, not the uplink's, so a socket openUF has moved into a VLAN bridge still reports its hosts; where that socket has MAC learning off (see per-port VLAN below) the FDB has nothing to say and the hosts come from an nftables tap instead. The uplink socket reports none. The AP's own MACs and its wireless stations are never reported as wired clients. Rows carry `vlan` (from the bridge the socket sits in) and an `ip` harvested with them, which is what puts the client on the right *network* as well as the right port: the controller matches a wired client to a network by the row's `vlan`, defaulting to 1, and never sees an ARP entry for a VLAN the AP holds no address on |
| Environment / rogue-AP scanning (`scan_radio_table`) | ✅ Working — confirmed rendering live in the Environment tab. Read from the kernel's passive BSS cache, so on its own it lists only neighbours on the radio's **own** channel; openUF never dwells off-channel behind a client's back |
| Sibling-AP recognition (no false "impersonator" warnings) | ✅ Implemented — the controller takes the scanning AP's `is_unifi`/`serialno` tag as the only proof a BSS is the site's own. openUF APs beacon a vendor element with their device MAC and tag each other; without it every other openUF AP was flagged as a third-party AP broadcasting your SSID. openUF ↔ openUF only |
| RF environment enrichment (802.11k beacon reports) | ✅ Working — the same mechanism Ubiquiti's Channel AI describes as *"neighbor reports and automated RRM scans"*. openUF periodically asks one 802.11k-capable **client** to sweep and report back; the client goes off-channel, the AP never does. Took a 5 GHz radio's Environment list from **0 neighbours to 4**, including an AP it cannot itself hear. Off with `rrm_enrichment = false` |
| LLDP topology announcement | ✅ Working (via `lldpd`) — **set `lldpd.config.cid_interface` to your LAN network**, or the controller shows the wrong Parent Device: lldpd's default chassis ID is some other interface's MAC, which the controller can't match to the MAC openUF is adopted under. See [USAGE](USAGE.md#7-lldp-topology) |
| RF/spectrum scan | ⚠️ Best-effort trigger only (`spectrum-scan`, `quick-scan`) — the result-reporting wire format is unconfirmed |
| Unhandled-protocol ledger | ✅ Every response type, command, field and config key openUF did not act on is kept, redacted and bounded, in `/etc/openuf/unhandled.json` — how a new controller verb gets noticed |

### Device management

| Feature | Status |
|---|---|
| Locate (LED identify blink) | ✅ Working — blinks the board's status LED: the one OpenWrt lights once boot is done (the device tree's `led-running`), found on its own (USAGE § 3). When it stops, the LED goes back to what the LED setting says: its own state, or dark. A restart between the controller's `set-locate` and `unset-locate` keeps what to put back; a reboot ends the blink by itself |
| Device LED (the site's switch and the per-device Default/On/Off) | ✅ Working — a switch over **all** of the board's LEDs, not one. Off: every LED dark. On: every LED does exactly what OpenWrt configured again — the status LED, the netdev/switch triggers from `/etc/config/system`, the radios' activity triggers — restored from a snapshot openUF takes before its first change after each boot. While off, an LED something else relights (LuCI's LED page) goes dark again within a minute. Persisted, so it survives a reboot. The off/on round trip is ✅ verified on hardware (E8450, WAX220: every LED's trigger and settings back as they were); ⚠️ not yet driven from the controller with this version |
| Client block / unblock | ✅ Working — enforced via nftables, persists across restarts, and **converges on the controller's `blocked_sta` list** (the site's complete block list, sent on every reconnect), so blocks issued while the AP was offline still apply |
| Reconnect client (`kick-sta`) | ✅ Disconnects the station through hostapd's ubus object (no `hostapd-utils` needed), allowing it straight back |
| IP Settings (DHCP / static) | ✅ Working — reconfigures the device's own management interface, including the DNS servers (`resolv.nameserver.<k>.ip` → `/etc/resolv.conf`, in the controller's primary/secondary order). DNS is applied on the static path only; on DHCP the lease supplies it. A static address is re-applied on every start, so it survives a reboot the controller never re-pushes it after |
| Per-port VLAN assignment | ⚠️ Wire format fully mapped live (`switch.*`: device-level gate, per-VLAN table, per-port `pvid` plus a tagged/untagged/`exclude` matrix joined on `port_table[].port_idx`); requires reporting the `hasOWRTSwitch` capability bit and ticking **Port VLAN** on the device. `bridge-vlan` is deliberately not used: the assigned socket is moved out of `br-lan` and into that VLAN's `br-openuf<id>` bridge — the same L2 a tagged SSID on the same VLAN already uses, since they are one broadcast domain. `br-lan` keeps the uplink and the management address and nothing ever runs with `vlan_filtering`, so a wrong answer cannot strand the AP. The socket the uplink cable is in is never touched (detected at runtime, and every port is refused when it cannot be), and it is reversible — unticking the device-level **Port VLAN** box puts `br-lan`'s original port list back. A moved socket also gets **MAC learning turned off** (`openuf_brport<vid>_<socket>`): the VLAN bridge is software-only but the socket shares one address table with the uplink, and an entry learned there makes the switch resolve the reply in hardware to a port outside the uplink's bridge and drop it — outbound stays perfect, so nothing else reveals it. **Verified on real hardware** (full DHCP handshake captured at three points, with and without); Native VLAN only (a tagged-only port is refused out loud). Because that empties the socket's bridge FDB, openUF also installs a `bridge openuf_learn` nftables tap that harvests source MACs *and* IPv4 addresses on the moved socket, so the port keeps reporting its wired clients and they still land on the right network — the socket's bridge cannot be hardware-offloaded, so every frame on it reaches the CPU where the tap sees it |
| Controller-owned config (`own_config`, default on) | ✅ The controller's networks and WLANs are the AP's: when the bridge is taken over, every other interface on it (and any L3 interface left on a socket, like a stock `wan`/`wan6`) is deleted, and the board's own SSIDs are deleted rather than disabled. The originals are saved once to `/etc/openuf/network.pre-openuf` / `wireless.pre-openuf`; `syswrapper.sh netmodel-restore` puts both back. `syswrapper.sh reprovision` has the controller re-send its full config (e.g. after an openUF update) |
| Controller-owned bridge (`bridge_backend = "vlan_filtering"`) | ✅ **Verified on real netifd** (bench, 2026-09-25). The controller's whole L2 model — `bridge.*`/`vlan.*`/`netconf.*`/`dhcpc.*` and the `switch.*` port matrix — is realised as **one vlan-filtering bridge**: management on `br-lan.<vid>` including a **Management VLAN**, one interface per WLAN VLAN (the untagged network included once management is tagged), and full per-port membership (native + tagged + excluded, i.e. trunk ports). Any bridge already holding the sockets is **taken over and recreated**; interfaces that used it are re-pointed and keep their VLANs. Every change is **rolled back automatically** unless the controller is reached within `bridge_rollback_timeout` (180 s); a plan that stranded the AP is not re-applied. `auto` picks this whenever the uplink already sits in a vlan-filtering bridge. DSA only |
| Controller system settings | ✅ The site's timezone, NTP servers and the nightly `syswrapper.sh 11k-scan` cron job are applied to UCI and the crontab, reversibly (`controller_system`; `{ntp = false}` keeps a local NTP server). `11k-scan` asks a client for an 802.11k beacon report — the AP itself never goes off-channel |
| L2 hardening (`ebtables.*`) | ✅ Unit-tested; not yet seen enforced on hardware. The controller's BPDU and VLAN-tag drops for Wi-Fi clients, re-expressed as an nftables bridge table on the AP-mode VAPs only (`l2guard`; needs `kmod-nft-bridge`, see USAGE § 6). Rebuilt at start and whenever the VAP list changes; a factory reset removes it |
| Board radio policy | ✅ `local.lua` can floor or cap the pushed channel width and keep ACS off DFS channels (`dev.conf.radio.<band>`), and `country_override` programs a different regulatory domain while still reporting the controller's — for drivers that cannot run DFS |
| LuCI pages | ✅ **Services → openUF** (`luci-app-openuf`): **Status** (daemon and heartbeat, adoption and applied-config state, the identity presented — catalogue model, sysid, firmware — the port map, network ownership and upgrade survival), **Settings** (every option in `/etc/config/openuf`, a standard LuCI form with Save & Apply and rollback; a change restarts the daemon, a switched-off feature drops its nft table or cron job, and a setting that changes what the controller provisions has it send its configuration again) and **Unhandled messages** (the ledger). Served by a ucode rpcd backend that never returns the adoption key |
| Packaging and updates | ✅ OpenWrt packages (`openuf`, `luci-app-openuf`, architecture-independent) for OpenWrt 25.12 and later, from a signed apk feed built by CI with the official SDK; updates arrive with `apk upgrade`; the package reinstalls itself after a firmware upgrade that keeps settings; `tools/deploy.sh` installs a local build on test APs |
| Set Replacement Device / Load Configuration | ✅ Working — both are controller-side clones; no device-side protocol involved |
| Power / PoE reporting | Not applicable — the flagged UI field belongs to the upstream parent device, not the AP |
| Speed test | Not applicable — gateway-only feature in current UniFi Network |
| USG / USW emulation | Not implemented, not planned |

## Supported hardware

A **DSA** board on **OpenWrt 25.12 or later**, dual-band, with **at least 16 MB flash** and
roughly **5 MB free on `/overlay`** after the stock image. 8 MB is not enough: the AES-GCM
backend (`lua-openssl`) pulls in `libopenssl3` at ~4.35 MB, and adoption cannot complete
without GCM.

There is nothing to configure per board. openUF describes the device from the device
itself (`openwrt/board.lua`): the sockets and LED from `/etc/board.json` (which OpenWrt's own
`board.d` scripts write), the uplink from the socket the gateway's MAC is learned on, a
stable identity MAC (the MAC the network already knows the AP by — not a socket MAC, which is
random per boot on e.g. a Netgear WAX220), and the radios from `/etc/config/wireless`. It
then presents itself as the closest UniFi access point in the controller's own model
registry (`unifi/identity.lua`, against `unifi/catalog.lua`, generated by
`tools/uidb-catalog.py`): a 5-socket WiFi 6 board is a U6-IW, a 1-socket one a U6-Pro, an
802.11ac router a UAP-IW-HD. Ports are numbered the way that model's registry entry does (a
model with a built-in switch has its uplink on the last port, "PoE In + Data"; a plain AP on
port 1). Both choices are kept in `/etc/openuf/modelmap-auto.json` and
`/etc/openuf/ufmodel-auto.json`, so nothing moves under an adopted device; `/etc/openuf/local.lua`
can correct what the description got wrong.

Known-working:

- **Linksys E8450 / Belkin RT3200** and **Netgear WAX220** (mediatek/filogic, 802.11ax):
  adopted by a UCG Fiber on Network 10.6, with the controller owning the bridge, VLANs and
  WLANs
- **Xiaomi Mi Router AX3000T** (MT7981, 802.11ax): HE on both bands, 160 MHz on 5 GHz. Its
  four sockets are the netdevs `wan`/`lan2`/`lan3`/`lan4` (DSA names ports from the device
  tree, not the case labels), and it exposes **no status LED** (`/sys/class/leds` holds only
  the two mt76 radio LEDs) — **install `kmod-leds-gpio`** (9 KB) or Locate has nothing to
  blink

swconfig boards (the TP-Link Archer C5 v1, TL-WDR3500 v1 and WR1043ND v2 upstream openUF
had hand-written maps for) are no longer supported: their sockets are not netdevs, and all
three are 8 MB-flash devices that cannot run it from a stock 25.12 image anyway.

## Quick start

openUF is an OpenWrt package, `openuf`, with its LuCI pages in `luci-app-openuf`. Both
come from this repository's package feed, which CI builds with the official OpenWrt SDK
and signs.

OpenWrt 25.12 or later (apk):

```sh
wget -O /etc/apk/keys/openuf.pem https://fonix232.github.io/openUF/openuf.pem
apk add -X https://fonix232.github.io/openUF/apk/packages.adb luci-app-openuf
```

Install `openuf` alone on a device without LuCI. The package pulls in what it needs
(Lua with cjson, luasocket and lua-openssl for AES-GCM, `iw`, `lldpd`, nftables with
`kmod-nft-bridge`, `hostapd-utils`, `ip-bridge`), adds the feed to the device and
starts the service. Settings are in `/etc/config/openuf`, and on **Services → openUF →
Settings** in LuCI.

**A LuCI theme to match.** The same feed carries `luci-theme-openuf`, a LuCI theme inspired
by the UniFi Network look, with light, dark and follow-the-system schemes:
`apk add luci-theme-openuf` after the two lines above. It works with or without openUF; see
[luci-theme-openuf/README.md](luci-theme-openuf/README.md).

Then adopt it:

- **L2** (device and controller on the same subnet): it appears in the controller's
  device list; click **Adopt**. The controller adopts over SSH, so set a root password, or
  switch on the temporary `ubnt/ubnt` adoption account (`uci set openuf.main.ssh_adopt=1`).
- **L3** (different subnets, no SSH needed): `uci set openuf.main.inform_url=http://<controller>:8080/inform && uci commit openuf`,
  or `syswrapper.sh set-inform <url>`. It appears as Pending; click **Adopt**.

Optional extras, each for one controller feature: `usteer` (band steering), `tc-tiny` and
`kmod-sched-act-police` (WiFi speed limits), `luasec` (an `https://` inform URL),
`kmod-leds-gpio` on boards whose status LED needs it, and a full `wpad` build
(`wpad-wolfssl`, `-openssl` or `-mbedtls`; the default `wpad-basic-*` lacks 802.11v, so
BSS Transition and Band Steering fail with "unknown configuration item 'bss_transition'").

**Updates.** The package adds its feed to the device, so `apk upgrade` picks up new
versions with the rest of the system. The feed keeps the last five builds;
`apk add openuf=<version>` goes back to one.

**Firmware upgrades.** Packages only survive a firmware upgrade when they are built into the
image, and OpenWrt's image builder (ASU, owut, LuCI's attended sysupgrade) only builds
official packages. So the package keeps its settings, state, feed key and a small bootstrap
service across upgrades that keep settings (`/lib/upgrade/keep.d/openuf`); on the new image's
first boot the bootstrap reinstalls openUF from the feed, and the AP comes back still
adopted. The controller's Upgrade button (`upgrade_mode owut`) leaves openUF's packages out
of the ASU request by itself; when you run `owut upgrade` by hand, add
`-r openuf,luci-app-openuf`.

**Coming from a tarball install** (`install.sh`, `/opt/openuf`): install the package over
it. It stops the old service, moves `conf.lua`'s settings into `/etc/config/openuf`
(research-only table options go to `/etc/openuf/local.lua`), removes the old files and
keeps `state.json`, so the AP stays adopted.

**Building it into images:** [openuf/contrib/asu](openuf/contrib/asu/README.md) has the
package list and a first-boot script for firmware-selector, `owut` and the ASU API. A freshly
flashed board boots straight into **ready-to-adopt AP mode** — every socket in one
DHCP-managed bridge, no DHCP server or firewall, no SSIDs — and installs openUF from the feed
once it has a network.

See [USAGE.md](USAGE.md) for every setting, dependency details and troubleshooting.

## Repository layout

| Path | What |
|---|---|
| `openuf/` | The `openuf` package: `Makefile`, `src/` (the daemon, installed to `/usr/share/openuf`: `unifi/` is the controller's side — packets, crypto, identity, events — and `openwrt/` the device's — reading it and applying what the controller pushes), `files/` (init scripts, default UCI config, keep-list, feed key), `tests/`, `tools/`, `contrib/asu/` |
| `luci-app-openuf/` | The `luci-app-openuf` package: the LuCI views and their rpcd backend |
| `luci-theme-openuf/` | The `luci-theme-openuf` package: a LuCI theme inspired by the UniFi Network look, independent of the daemon, and its Docker/Playwright test lab (`test/`) |
| `.github/` | CI: tests, the package feed (`feed.yml`, published to GitHub Pages), releases |
| `docs/`, `USAGE.md`, `PROTOCOL-VALIDATION.md` | Documentation |

### How the daemon is organised

`openuf/src/` has two sides with one rule between them:

- **`unifi/`** is the controller's side: the TNBU packet and its crypto, the HTTP inform
  and STUN wake-up, discovery identity (`identity.lua` against the registry in
  `catalog.lua`), connection events, the payload's UniFi-specific pieces, and the parsers
  that turn what the controller pushes into plain tables — `wlan.lua` (radios and SSIDs),
  `ports.lua`, `network.lua` (the L2 model), `system.lua`, `hardening.lua`, `atf.lua`. It depends on
  nothing in `openwrt/`, runs no shell commands and loads no UCI or ubus binding;
  `tests/test_architecture.lua` enforces that.
- **`openwrt/`** is the device's side: `board.lua` describes the board from itself,
  `report.lua` reads the device into the inform payload, and `provision.lua` carries the
  parsed pushes and the controller's commands out through `ucihelper.lua` (WiFi),
  `netmodel.lua` (the bridge and VLANs), `sysconf.lua`, `l2guard.lua` and the rest.
- **`inform.lua`** is the loop between them: heartbeat, rollback window, state, status file.

The tables that cross between the two sides are declared in `openuf/types/contracts.lua`
for the Lua language server (`.luarc.json` points it there), so an editor with the Lua
extension completes and checks them.

The repository is an OpenWrt package feed: add it to a buildroot or SDK with
`src-git openuf https://github.com/fonix232/openUF.git` in `feeds.conf`.

## Local testing (no hardware required)

Everything below runs from the package directory, `openuf/`.

```sh
# Install Lua on macOS/Linux
brew install lua luarocks      # macOS
# or: apt install lua5.1 luarocks  # Debian/Ubuntu

# Install test dependencies
luarocks install --local lua-cjson

# Run unit tests (all pure Lua)
cd openuf
eval $(luarocks path --local)
lua tests/run_tests.lua

# Full end-to-end adoption round-trip against the Python controller stub
# (needs pycryptodome, luasocket and lua-cjson):
sh tools/simulate.sh --adopt

# Or drive it manually:
pip install pycryptodome
python3 tools/test_controller.py --adopt --verbose
# In another terminal, from src/ (modules load by name from the working
# directory):
cd src && lua inform.lua
```

On a real AP, `tools/heartbeat-probe.lua` reports what one inform actually costs
that board — every process spawned and file opened, per command and path — by
building its own payload in a throwaway process alongside the running daemon.
See [USAGE § 8](USAGE.md#measuring-what-a-heartbeat-costs-on-the-device).

## Protocol notes

openUF implements the **TNBU binary inform protocol**:

- HTTP POST to `/inform` at the controller's `interval` (10 s by default, clamped to 5–300 s), plus
  notification informs (`inform_as_notif`) for client events
- Binary header: `TNBU` magic + version + MAC + flags + 16-byte IV + data version + payload length
- Payload: JSON, AES-128 encrypted with the device's authkey — CBC, or GCM (with a
  40-byte AAD, 16-byte nonce) once the controller sets `use_aes_gcm`. Requests may be zlib-
  or snappy-compressed; 10.6 never compresses its responses (flags are always `0x01`/`0x09`),
  the bundled inflater only matters for other controllers
- Default pre-adoption key: `ba86f2bbe107c7c57eb5f2690775c712`
- Adoption: L2 — controller SSHes in and calls `syswrapper.sh set-adopt <url> <newkey>`;
  L3 — new authkey arrives in the `setparam` response's `mgmt_cfg`

Key reference material:
- [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) — this project's own findings from running openUF against a real self-hosted UniFi controller; supersedes the below where they disagree
- [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) — primary protocol reference; live Python daemon tested against real controllers
- [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol)
- [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering)

## License

MIT — see [LICENSE](LICENSE).
