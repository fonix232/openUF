# openUF — Usage Guide

## 1. Dependencies

The `openuf` package depends on everything openUF cannot work without: `lua`,
`lua-cjson`, `luasocket`, `lua-openssl`, `luabitop`, `libuci-lua`, `iw`, `lldpd`,
`nftables`, `kmod-nft-bridge`, `hostapd-utils` and `ip-bridge`. The rest each enable one
controller feature and are left to you, because they cost flash a small board may not
have: `usteer`, `tc-tiny`, `kmod-sched-act-police`, `luasec`, `kmod-leds-gpio`,
`coreutils-stat`, `snmpd-ssl`.

One more is **required but not a package dependency**: a full `wpad` build. Stock images
ship `wpad-basic-*`, and no dependency can name "any full build" (every variant provides
`wpad`). Swap the basic build for the full one of the same crypto library in one
transaction, which changes nothing if the download fails:

```sh
apk add wpad-mbedtls '!wpad-basic-mbedtls'   # or -wolfssl / -openssl to match
/etc/init.d/wpad restart
```

Without it the service refuses to start (§ troubleshooting).

| Package | Purpose |
|---|---|
| `lua` | Lua 5.1 runtime |
| `lua-cjson` | Fast JSON encode/decode |
| `luasocket` | TCP client for HTTP POST to controller |
| `lua-openssl` | AES-128-CBC **and AES-128-GCM** — see the GCM note below |
| `luabitop` | bit operations for Lua 5.1 |
| `libuci-lua` | `require("uci")` — every radio and WLAN read and write goes through it. Not pulled in by `lua`. Without it the device adopts, reports its ports and statistics and looks perfectly healthy, while `radio_table` goes out **empty** and the controller has no radio to push a WLAN onto: pushes are accepted and no SSID is ever created. openUF says so at startup rather than leaving you to find it |
| `iw` | Radio and station statistics |
| `lldpd` | LLDP topology announcement and neighbor discovery |
| `openssl-util` | `openssl` CLI — last-resort AES-**CBC** fallback if `lua-openssl` is unavailable. This path cannot do GCM, so it is not sufficient to complete adoption on its own |
| `nftables` | Client block/unblock (`firewall.lua`) **and** the Multicast/Broadcast Blocker (`bcfilter.lua`). ~490 KB with its kernel modules — the first thing that won't fit on a small-flash board, which leaves both features unavailable (openUF logs that rather than pretending) |
| `kmod-nft-bridge` | The Multicast/Broadcast Blocker, the L2 hardening (`bridge openuf_l2guard`) the guest network restrictions (`bridge openuf_guest`) and the usteer sync filter (`bridge openuf_usteer`). `nftables` does not pull it in, and without `nft_meta_bridge` the bridge family has no `meta` expression — so the blocker's drop rule is rejected while its table, chain and allow-list set all build normally. Client block/unblock matches on `ether saddr` alone and does not need it |
| `hostapd-utils` | `hostapd_cli` — immediate deauth of a just-blocked wireless client, and the Minimum RSSI client kick. (Roaming Assistant talks to hostapd over ubus instead) |
| `tc-tiny` | `tc` — WiFi Speed Limit (`shaper.lua`). Busybox has no `tc`; without it the limit is recorded in UCI and never enforced |
| `kmod-sched-act-police` | The **upload** half of WiFi Speed Limit only. `police` is a tc *action*, a separate module from the ingress qdisc and absent from a stock filogic image. Without it the download cap applies and the upload cap does not — openUF logs which interface `tc` rejected and names this package rather than reporting the whole limit as applied |
| `coreutils-stat` | `stat` — only if your build has no `stat` applet (some do not). `inform.lua` uses `stat -c %Y` to notice an out-of-process `state.json` write, i.e. an SSH `set-adopt` or a manual `reset-inform`; without it those are ignored until restart. Enabling busybox's own `stat` applet is smaller |
| `snmpd-ssl` | SNMP Monitoring (Settings → System → SNMP): net-snmp's agent, configured by openUF from the controller's community and v3 user (`openwrt/snmp.lua`). 43 KiB plus `libnetsnmp-ssl` (~1.1 MiB). `snmpd-nossl` works for v1/v2c only: v3 needs AES privacy, so openUF claims `fw_caps` `0x4000` (SNMPv3) only with the ssl build. Without either, an SNMP push is logged once and ignored |
| `usteer` | Band Steering (Behavior Controls) — ubus-based client-steering daemon, driven by `usteer.lua`. Roaming Assistant needs it too, for its view of which AP hears a client how loudly |
| `wpad-mbedtls` (or `wpad-openssl`, `wpad-wolfssl`, `wpad`, `wpad-mesh-*`, `hostapd-*`) | Full hostapd build — **required, not optional.** The controller sends `aaa.<n>.bss_transition` with every WLAN, so openUF always writes `bss_transition`, and `wpad-basic-*` stops at "unknown configuration item 'bss_transition'" with the radio down. The init script checks the hostapd binary itself (`wnm_sleep_mode` is compiled in only with 802.11v; a grep for `bss_transition` is no test, since a basic binary carries `bss_transition_*` event names), so any full build counts, and it refuses to start on a basic one |

> **AES-GCM is required for adoption.** UniFi Network Application 10.4.57 will
> not finish provisioning a device until it has received a genuine
> AES-128-GCM-encrypted inform; a device that can only do CBC stays stuck at
> "Adopting" indefinitely. openUF's GCM support needs a `lua-openssl` build with
> AEAD/GCM available — the `openssl-util` CLI fallback above is CBC-only and will
> not get you adopted. See PROTOCOL-VALIDATION.md's "The GCM provisioning gate".

There is no Lua zlib binding in the OpenWrt 25.12 feeds. openUF therefore sends
inform payloads uncompressed and decompresses zlib-compressed controller
responses with a bundled pure-Lua inflater (`inflate.lua`), so no zlib
package is required.

Only required if your inform URL uses `https://` (uncommon — the UniFi default
is `http://…:8080/inform`): `apk add luasec` for the TLS client. Without it, an
`https://` URL fails with a clear error instead of connecting in cleartext.

---

## 2. Installation

openUF is two OpenWrt packages, both architecture-independent: `openuf` (the daemon) and
`luci-app-openuf` (its LuCI pages). They come from this repository's package feed, which
GitHub Actions builds with the official OpenWrt SDK and signs:

OpenWrt 25.12 or later (apk; 24.10 and its opkg are not supported):

```sh
wget -O /etc/apk/keys/openuf.pem https://fonix232.github.io/openUF/openuf.pem
apk add -X https://fonix232.github.io/openUF/apk/packages.adb luci-app-openuf
```

Install `openuf` alone on a device without LuCI. What the package puts where:

| Path | What |
|---|---|
| `/usr/share/openuf/` | The daemon (comment-stripped at build time; the repository keeps the comments) |
| `/etc/config/openuf` | Settings (§ 3) |
| `/etc/openuf/` | State: `state.json` (adoption, authkey, cfgversion), the auto-derived model files, the unhandled ledger, saved original network/wireless config |
| `/etc/init.d/openuf` | The service: two procd instances, `announce` and `inform`. Restarts on its own when `/etc/config/openuf` changes |
| `/etc/init.d/openuf-bootstrap` | Reinstalls the package after a firmware upgrade (below) |
| `/usr/bin/syswrapper.sh` | The controller-facing command (`set-inform`, `set-adopt`, …) |
| `/etc/apk/keys/openuf.pem`, `/etc/apk/repositories.d/openuf.list` | The feed, so updates arrive with the rest of the system's packages |
| `/lib/upgrade/keep.d/openuf` | What a firmware upgrade keeps |

The first install enables and starts the service and enables `lldpd`.

**Updating.** `apk upgrade` (or `apk upgrade openuf luci-app-openuf` for just these two);
the service restarts onto the new build. The feed keeps the last five builds, so
`apk add openuf=<version>` goes back to an earlier one.

**Firmware upgrades.** A package survives a firmware upgrade only when it is built into
the image, and OpenWrt's image builder (ASU: owut, LuCI's attended sysupgrade, the
firmware-selector) only builds official packages. So the package lists its settings, state,
feed and bootstrap service in `/lib/upgrade/keep.d/openuf`, which every upgrade that keeps
settings honours. On the new image's first boot the bootstrap waits for the network, then
installs `openuf` (and `luci-app-openuf` when LuCI is there) from the feed. The AP comes back
still adopted, with the same identity. The controller's Upgrade button (`upgrade_mode
owut`, § 6) tells owut to leave openUF's packages out of the ASU request; when you run
`owut upgrade` by hand, add `-r openuf,luci-app-openuf`, or the ASU server rejects the
build.

**Uninstalling.** `apk del luci-app-openuf openuf`. The service stops, the
temporary SSH adoption account and the controller's cron jobs go (§ 6), and `/etc/openuf/`
stays, so a reinstall finds the adoption again. Delete it by hand to forget the device.

**From a tarball install** (the `install.sh` era, code in `/opt/openuf`): install the
package over it. Before its files go in, the package stops the old service, keeps the old
`conf.lua` and removes the old code, init scripts, LuCI files and `sysupgrade.conf` lines.
The move into UCI then writes every setting that differs from the defaults to
`/etc/config/openuf` and the research-only table options to `/etc/openuf/local.lua`.
`state.json` is not touched, so the AP stays adopted.

**Building it yourself.** The repository is an OpenWrt feed. In a buildroot or SDK:

```sh
echo "src-git openuf https://github.com/fonix232/openUF.git" >> feeds.conf
./scripts/feeds update openuf && ./scripts/feeds install -p openuf -a
make package/openuf/compile package/luci-app-openuf/compile
```

`.github/scripts/sdk-build.sh` does the same inside the official SDK containers, and
`openuf/tools/deploy.sh <dir> <ap>...` installs what it built on test APs, one at a time,
stopping at the first that does not complete an inform.

---

## 3. Configuration

Settings live in UCI, `/etc/config/openuf`, section `main`. Change them on **Services →
openUF → Settings** in LuCI, or with `uci`:

```sh
uci set openuf.main.inform_url=http://10.0.0.1:8080/inform
uci commit openuf        # the service restarts on its own
```

Every option has a default (`/usr/share/openuf/config.lua`), so an empty section works.

### Hardware description (automatic)

There is nothing to configure per board: `openwrt/board.lua` describes the device from the
device itself, once, and keeps the result.

- **Sockets:** `/etc/board.json` (written by OpenWrt's own `board.d` scripts from the device
  tree): `network.wan.device`, then `network.lan.ports` (or `lan.device` on a one-port
  board).
- **Uplink:** the socket the default gateway's MAC is learned on (`bridge fdb show`), else
  board.json's WAN device.
- **Identity MAC:** the MAC the network already knows the AP by, the bridge the uplink sits
  in, else board.json's label MAC. Never a socket MAC: a Netgear WAX220's `eth0` gets a
  random one on every boot.
- **Status LED:** the one OpenWrt lights once boot is done (`get_dt_led running` in
  `/lib/functions/leds.sh`, from the device tree), else its boot LED, else the first of
  `status`/`power`/`system`/`run` in `/sys/class/leds`, blue, white or green preferred.
  Locate blinks it. The controller's LED setting is not tied to it: that switches every
  LED (§ LEDs below).
- **Radios:** every `wifi-device` in `/etc/config/wireless`. openUF never touches a radio it
  does not report.
- **Port numbers:** the chosen UniFi model's own layout (below). A model with a built-in
  switch takes its uplink on the last port ("PoE In + Data", port 5 on a U6-IW), a plain AP
  on port 1; the other sockets follow in board.json order. The controller stores per-port
  settings against these numbers.

The layout is written to `/etc/openuf/modelmap-auto.json` once the uplink could actually be
detected, and read back on every later start: numbering must not move under an adopted
device because someone moved a cable. Delete the file to derive it again.

DSA boards only: on a swconfig board (`which swconfig` finds a binary) the sockets are not
netdevs, and openUF no longer supports those.

To correct the description, set what is wrong in `/etc/openuf/local.lua`, which runs after it
with `dev` in scope:

```lua
dev.conf.led = "green:status"        -- the LED Locate blinks, from `ls /sys/class/leds`
dev.conf.hwassign = {"radio0"}       -- report only this radio
```

⚠️ **Check the LED is actually wired.** `/sys/class/leds` lists what the drivers registered,
not what the case has. A radio LED (`mt76-phy0`) is registered on every board whether or not
the pin goes anywhere, and a board whose LEDs are on GPIO needs `kmod-leds-gpio`, or its
real LEDs never register at all (both true of a Xiaomi AX3000T). Confirm by writing to it
and looking at the box:

```sh
echo none > /sys/class/leds/<led>/trigger; echo 1 > /sys/class/leds/<led>/brightness
```

### LEDs

The controller sends one LED setting per device, `led_enabled` in `mgmt_cfg`: the device's
own LED override (Default/On/Off) resolved against the site's Device LED switch. openUF
applies it to every LED the board has:

- **Off:** every LED in `/sys/class/leds` dark (trigger `none`, brightness 0). Before the
  first change after a boot, each LED's state is snapshotted to `/var/run/openuf-leds.json`:
  its trigger, the trigger's settings (a netdev LED's device and link/rx/tx modes, timer
  delays), brightness and colour.
- **On:** each LED is put back from that snapshot, and the snapshot is dropped. Nothing is
  taken from UCI here: OpenWrt's own `/etc/init.d/led turnon` puts back only the LEDs with a
  `system` `led` section or a diag.sh role, so a radio LED (`mt76-phy0` on `phy0tpt`) would
  stay dark after one off/on.
- **Never pushed:** the LEDs are not touched.

The snapshot is in tmpfs on purpose: it describes kernel state and lives exactly as long.
A restart of openUF finds it (the LEDs are dark by openUF's hand, not the board's); a
reboot clears it, and the board comes up in its own state before openUF applies the
setting again. While the setting is off, openUF checks once a minute for an LED that
something relit — saving LuCI's LED page restarts OpenWrt's `led` service — and darkens it
again, keeping its new state as the one to restore.

To change what an LED does, configure it in OpenWrt as usual (LuCI → System → LED
Configuration, or `/etc/config/system`); the controller's switch then turns that on and off.

**LEDs on the bridge.** A netdev LED the board configured on its own bridge — an E8450's
internet LED and a WAX220's LAN LED both watch `switch.1` on OpenWrt 25.12 — would name a
device that no longer exists once openUF's network model replaces that bridge, and stay dark.
While openUF's bridge is in place, such an LED is pointed at it the way interfaces are:
`<bridge>.<vid>` → `br-lan.<vid>`, the bridge itself → `br-lan`. The board's value is kept in
the section's `openuf_dev_orig` and goes back when the bridge does (a rollback of the first
takeover, `syswrapper.sh netmodel-restore`). The old bridge names come from
`/etc/openuf/network.pre-openuf`; the running LED follows at once, no `led` restart.

### Device identity

openUF presents itself as the UniFi access point closest to the board, chosen once
(`unifi/identity.lua`) and kept in `/etc/openuf/ufmodel-auto.json`: an adopted device never
changes model under the controller. The facts come from `/etc/board.json` (bands, PHY
generation, antenna count, maximum width, sockets); the candidates are `unifi/catalog.lua`,
the controller's own model registry. A board that describes nothing to match on presents as
a U6-IW, the identity validated end to end.

To pin a model yourself, write its code there before the first start (or re-adopt after):

```sh
echo '{"model":"UHDIW"}' > /etc/openuf/ufmodel-auto.json && /etc/init.d/openuf restart
```

Regenerate the catalogue after a controller upgrade:

```sh
# uidb.json and bundles.json are in the Network application package:
#   usr/lib/unifi/dl/uidb/uidb.json, usr/lib/unifi/dl/firmware/bundles.json
python3 openuf/tools/uidb-catalog.py --uidb uidb.json --bundles bundles.json --fw \
    > openuf/src/unifi/catalog.lua
```

`--fw` adds each model's current release version from fw-update.ui.com. It matters: the
controller calls a device "upgradable" whenever its version differs from the catalogue's,
character for character. openUF also learns the version from the controller's own upgrade
commands, so a stale one corrects itself after one upgrade round.

### Options

| Option | Default | What it does |
|---|---|---|
| `inform_url` | `http://unifi:8080/inform` | Where an unadopted device informs. Once adopted, the URL the controller assigned (in `state.json`) wins |
| `l2_announce` | `1` | L2 discovery broadcasts (below) |
| `discovery_replies` | `0` | Also answer clients' v1 discovery probes (needs `l2_announce`). Leave off: with it the UniFi app treats the APs as standalone devices and asks for their login |
| `ssh_adopt` | `0` | The temporary `ubnt/ubnt` SSH adoption account (§ 4) |
| `stun`, `stun_local_port` | `1`, `3478` | Let the controller wake the device for an immediate inform |
| `cfg_retries` | `2` | How often a push that failed to apply is asked for again (§ 6) |
| `use_only_unifi_wlan` | `1` | Take SSIDs the controller did not create off the air (§ 6) |
| `own_config` | `1` | Remove interfaces and SSIDs the controller did not ask for, keeping a copy (§ 6) |
| `bridge_backend` | `auto` | `vlan_filtering`, `bridges` or `auto` (§ 6) |
| `bridge_takeover`, `bridge_rollback_timeout` | `1`, `180` | Let openUF rebuild the management bridge, and roll back after this many seconds without the controller |
| `bridge_name`, `port_default` | `br-lan`, `all` | The management bridge; what a wired port without a profile carries besides the native VLAN (`all` tagged, or `none`) |
| `country_override` | — | Program this ISO country's regulatory domain instead of the controller's (the controller's is still reported). A legal decision — off unless set |
| `sta_events` | `1` | Client connection events as `STA_ASSOC_TRACKER` notification informs (§ 6) |
| `system_timezone`, `system_ntp`, `system_cron` | `1` | Apply the controller's timezone, NTP servers and nightly scan job. A site with its own NTP switches just `system_ntp` off |
| `l2guard` | `1` | The controller's `ebtables.*` hardening as an nftables bridge table on the VAPs |
| `guest_isolation` | `1` | The controller's guest-WLAN restrictions as an nftables bridge table on the guest VAPs (§ 6). The captive portal is not implemented |
| `rrm_enrichment`, `rrm_request_interval` | `1`, `600` | Ask 802.11k-capable clients for beacon reports (the neighbour list). A client with active/passive measurement is asked to look; a beacon-**table**-only client (most phones seen) is asked for its scan cache (mode 2) |
| `sibling_exchange` | `1` | Broadcast this AP's BSSIDs to other openUF APs on UDP 10011 and keep theirs (`/tmp/openuf-siblings.json`, 5 min), so a sibling a client reports over 802.11k is tagged as a UniFi neighbour. It also carries the clients this AP denies for Lock to Access Point, which is how the AP a client is locked to learns of the lock (§ Lock to Access Point). Runs in the `announce` process, which now starts when this or `l2_announce` is on |
| `sibling_scan_interval` | `1800` | Seconds between short scans of only the channels siblings announced (same band, not the radio's own): `iw scan freq <f>… ap-force`, a fraction of a second, **with clients associated**. `0` = never. A full idle sweep counts as one |
| `idle_scan_interval` | `1800` | Seconds between off-channel sweeps (`iw scan ap-force`, in the background) of a radio with **no associated client** on any of its interfaces; `0` = never. A radio with clients is looked at again a minute later. The sweep is what lets an AP hear siblings on other channels |
| `roam_assist_diff_db` | `8` | Roaming Assistant: how many dB louder another AP must hear a weak client before it is moved there (§ 6) |
| `wireless_uplink` | `0` | Offer the controller wireless meshing (`wifi_caps` `0x1`/`0x800`): a hidden backhaul BSS on the 5 GHz radio for other APs to join, and a station that joins one while this AP's cable is out (§ 6, Wireless uplink). ⚠️ Not yet confirmed on this project's hardware |
| `upgrade_mode` | — | `owut`: the controller's Upgrade button runs an attended sysupgrade (§ 6) |
| `advertise_updates`, `advertise_interval`, `version_scheme` | `0`, `21600`, — | Show newer OpenWrt builds in the controller (§ 6) |
| `state_file` | `/etc/openuf/state.json` | Where the adoption lives |
| `unhandled_file` | `/etc/openuf/unhandled.json` | The unhandled ledger (below); `off` keeps it in memory |
| `debug_dump_file`, `debug_dump_requests`, `debug_dump_max_bytes` | —, `0`, `4194304` | Protocol capture (below) |

Booleans take `1`/`0` (or `true`/`false`, `on`/`off`). A value that does not parse falls
back to the default and says so in the log.

A setting that changes what a controller push does (`use_only_unifi_wlan`, `own_config`,
the `bridge_*` options, `port_default`, `country_override`, `l2guard`, `guest_isolation` and the three
`system_*` options) also makes the daemon forget the cfgversion at its next start, so the
controller sends its whole configuration again and the change lands straight away. An
upgrade to a release that changes what a push writes does the same once, so the existing
WLANs get it without waiting for a change in the controller. A
feature switched off takes its state with it at the next start: the L2 and DNS-answer nft
tables are deleted and the controller's cron job is removed. The timezone and NTP servers
keep their last values.

`/etc/openuf/local.lua`, if it exists, runs after UCI is read, with `config` (the options)
and `dev` (the board description) as globals, and may change either. It is for what UCI cannot
express: the research-only table options `debug_caps` and `debug_payload_extra` (override
`fw_caps`/`wifi_caps`/`wifi_caps2`, merge extra payload fields; logged loudly at every
start), or a model-map tweak such as a radio policy:

```lua
dev.conf.radio = {
    na = {htmode_max = "HE80", acs_exclude_dfs = true},  -- a driver that cannot start DFS CAC
    ng = {htmode_floor = "HE20"},                        -- raise a controller's 802.11n default
}
```

`htmode_floor` never overrides a WLAN's Force WiFi 4 Mode, and the hardware clamp still runs
last. `acs_exclude_dfs` and `channels` only apply while the channel is Auto.

The controller has its own say over the same two options (Radio AI's channel exclusions and
5 GHz DFS switch, see § 6). A policy is an operator override and wins over the controller:
`acs_exclude_dfs = true` keeps ACS off DFS whatever the site says, `acs_exclude_dfs = false`
allows DFS even when the site has it off, and a `channels` list is used as written, with the
site's exclusions ignored (logged). Leave a key out of the policy to let the controller decide.

`l2_announce` — on by default; sends the UDP discovery broadcasts that make the
device appear in UniFi Discover with no `set-inform` at all, and answers the
v1 discovery probes clients such as WiFiman send when `discovery_replies` is also on (off by
default: the UniFi app then took the APs for standalone devices). Set it to `0`
to be adopted over L3 only (the `announce` process then sends and answers
nothing on port 10001; it still runs for `sibling_exchange`). The reason to turn it off isn't
noise: a controller that discovered a device via L2 adopts it *by SSHing in*,
so on a device that can't accept that login, adoption fails while the inform
loop looks perfectly healthy — see § 4.

`debug_dump_file` — opt-in, off by default. When set to a path (e.g.
`/var/log/openuf-informs.log`), every decrypted controller inform response is
appended verbatim, with a UTC timestamp, before it's dispatched. Used to capture
ground-truth payload shapes when validating field assumptions (`system_cfg`,
`cmd` dispatch, etc.) against a real UniFi controller — see
[PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

`debug_dump_max_bytes` — ceiling for that dump, default 4 MiB, `0` for none.
The dump is append-only and the inform loop writes to it every few seconds, so
left unattended it grows without bound — and its usual home is `/tmp`, which on
these boards is a RAM disk. One left on for five weeks reached 31.7 MB, 55% of a
59 MB tmpfs, on course to starve `state.json` writes and `apk` alike. Past the
cap the file **restarts** rather than rotating, leaving a marker line saying so:
a second generation would double the peak footprint on exactly the boards least
able to afford it, and a capture is read from its tail anyway.

The same flag also turns on a **dropped-key report** on stderr: one line per
config blob listing the keys no parser consumed, collapsed to key shapes with
counts, e.g.

```
inform: mgmt_cfg: 5 dropped key(s): capability x1, mgmt_url x1, report_crash x1, selfrun_guest_mode x1, stun_url x1
inform: system_cfg: 12 dropped key(s): switch.port.<n>.name x5, switch.vlan.<n>.id x4, ...
```

Most of what it lists is dropped deliberately (each case is explained in
PROTOCOL-VALIDATION.md's `system_cfg` section) — its value is showing you when
the controller starts sending something openUF has *never* seen, which is how
two whole features sat unnoticed in every capture for months. Key names and
counts only: these blobs carry passphrases and the adoption key, so no value is
ever logged.

The dropped-key report also feeds the **unhandled ledger**, always and not only in
debug mode: `/etc/openuf/unhandled.json` (`unhandled_file`; `off` keeps it in memory)
holds every response type, command, top-level field and config key shape openUF did not
act on, with a count, first/last seen and a copy of what arrived — secrets redacted by
field name, payloads capped at 2 KB, 150 entries at most.

---

## 4. Adoption flow

### SSH prerequisite

The controller SSHes into the device as `root` to run `syswrapper.sh set-adopt` during adoption.  **SSH must be accessible and the root password must be set** before clicking Adopt:

```sh
# On the OpenWrt device — set a root password if not already done
passwd root
```

Confirm SSH works from the controller's network before attempting adoption.  A fresh OpenWrt install often has a blank root password and SSH enabled; set the password first.

> **Security note:** openUF accepts a new `authkey` from the `mgmt_cfg` payload
> only while **not yet adopted** (needed for L3 adoption to complete at all — see
> the L3 section below and [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md)).
> Once adopted, that field is ignored — key rotation only happens via the SSH
> `set-adopt` path from that point on, matching real L2 hardware behavior.

#### Optional: zero-touch bootstrap adoption (`option ssh_adopt`)

Real Ubiquiti hardware ships a factory-default `ubnt`/`ubnt` SSH account
specifically so first adoption works without presetting anything — live testing
against a real controller (see PROTOCOL-VALIDATION.md) confirmed the controller's
SSH client tries exactly that account for L2-discovered, not-yet-adopted devices,
regardless of any admin-configured "Device SSH Authentication" credentials.
`option ssh_adopt '1'` sets up the same thing, scoped as tightly as this project
can manage:

```sh
uci set openuf.main.ssh_adopt=1 && uci commit openuf
```

- The account is **non-root**, a member of a dedicated `openuf` group with
  write access to `/etc/openuf` only — no other privilege, ever, even
  transiently.
- Its login shell (`/usr/share/openuf/hook/adopt-shell.sh`) is a forced-command wrapper
  that permits exactly one thing: running `syswrapper.sh set-adopt <url>
  <key>`. Any other command, or a plain interactive login attempt, is refused
  outright — the account can never be used as a general-purpose shell.
- Once the device is adopted, `inform.lua` locks the account (`passwd -l`) —
  it detects this within one poll interval (~10s) of the SSH-driven
  `set-adopt` writing new state. It re-enables the account automatically on
  a factory reset (`reset-inform`, or a controller-initiated "Forget Device"),
  so re-adoption after a reset works the same zero-touch way.
- This is entirely opt-in: with the option off (the default) the account is
  never created, and switching it off removes an account openUF created — the
  admin sets their own root password instead.

Removing the package removes the account too.

### L2 adoption (device and controller on the same subnet)

1. Install the package (the service starts on its own; `/etc/init.d/openuf start` otherwise)
2. The `announce.lua` process sends UDP broadcasts to port 10001 every 10 seconds
3. The device appears in **UniFi Discover** with model "U6IW"
4. Click **Adopt** in the controller
5. The controller SSHes into the device and runs:
   ```sh
   syswrapper.sh set-adopt http://<controller>:8080/inform <32-char-hex-key>
   ```
6. `syswrapper.lua` stores the new authkey and sets `adopted = true` in `/etc/openuf/state.json`
7. The device appears as **Connected** in the controller

> **The controller picks the adoption path from how it discovered the device,
> not from where it is.** A device it heard via L2 broadcast gets the SSH
> treatment above even when it sits on the controller's own subnet and informs
> perfectly — confirmed against a real UniFi OS gateway, which SSHed in three
> times on the Adopt click, failed (`Login attempt for nonexistent user`), and
> parked the device at **Connection Interrupted** while the inform loop kept
> running normally. If SSH can't succeed on your device, set
> `option l2_announce '0'` (`uci set openuf.main.l2_announce=0 && uci commit openuf`): with no broadcasts the
> controller treats it as L3-discovered and delivers the key over the inform
> channel instead. Forget any device record created while broadcasts were on
> first — the controller remembers how it found it.

### L3 adoption (device and controller on different subnets)

1. Manually point the device at the controller:
   ```sh
   syswrapper.sh set-inform http://<controller-ip>:8080/inform
   ```
2. The device starts sending inform packets to the controller
3. It appears as **Pending** in the controller
4. Click **Adopt**

> **No SSH is involved in L3 adoption.** For **L3-discovered** devices the
> controller explicitly logs `discovered via L3 inform, skip SSH adoption` and
> never attempts SSH at all — unlike the L2 flow documented above. It delivers
> the new `authkey` directly in the `mgmt_cfg` field of the `setparam` response
> sent right after the Adopt click — confirmed against a real controller
> (`linuxserver/unifi-network-application:10.4.57`), reproduced from a clean
> environment. openUF's `inform.lua` accepts this only while unadopted, matching
> `amd989/unifi-gateway`'s reference behavior. Adoption completes to
> **Connected** — provided the device can encrypt with AES-GCM (see § 1). An
> earlier version of this guide reported every newly-adopted device getting stuck
> at "Adopting"; that was the missing GCM backend, not a controller-side issue,
> and it is resolved — see [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

---

## 5. State file

Persistent state is stored at `/etc/openuf/state.json` — or wherever
the `state_file` option points, which the inform daemon, the L2 broadcaster
and `syswrapper.sh` all read, so all three agree on one file. Change it before
adoption: moving it afterwards leaves the authkey behind and the controller
stops recognising the device.

It is written through a sibling `.tmp` and renamed into place, so an
interrupted write can never leave a half-file behind. That matters because a
`state.json` that will not parse is read as "start from defaults" — the device
comes back up unadopted, with the well-known key. If that ever happens it is
announced on stderr rather than passed off as a fresh install.


```json
{
  "adopted":    false,
  "authkey":    "ba86f2bbe107c7c57eb5f2690775c712",
  "cfgversion": "",
  "inform_url": "http://unifi:8080/inform",
  "use_gcm":    false,
  "upgrade_requested_version": "",
  "upgrade_requested_url":     "",
  "blocked_stas": []
}
```

| Field | Description |
|---|---|
| `adopted` | `true` after successful adoption; `false` resets `authkey` to default on load |
| `authkey` | 32 hex chars (16-byte AES-128 key); default = pre-adoption key |
| `cfgversion` | Opaque string the controller uses to push config updates |
| `upgrade_requested_version` / `upgrade_requested_url` | Set when the controller sends an `upgrade` command; stored for visibility only — openUF never downloads or flashes firmware (see below) |
| `inform_url` | URL for the inform heartbeat (every 10 s, or the interval the controller's `noop` names). Seeded from the `inform_url` option on a first boot (or after a factory reset) and overwritten by the controller or by `syswrapper.sh set-inform`; once present here it always wins over the option |
| `use_gcm` | `true` when the controller has requested AES-128-GCM encryption (`use_aes_gcm=true` in mgmt_cfg) |
| `blocked_stas` | MACs blocked from the controller's Clients view; re-applied to nftables on startup so blocks survive restarts |
| `atf_enabled` | The AP's Airtime Fairness switch (`atf.mode`) as last pushed; absent until the controller sends one. Written to mac80211's `airtime_flags` again on every start, because debugfs resets on reboot and the controller does not re-push it |
| `dsa_brlan_ports` | `br-lan`'s port list as the board shipped it, snapshotted before per-port VLAN assignment first moves a socket; used to restore it (see § 6) |
| `ip_mode`, `static_ip`, `static_netmask`, `static_gateway`, `static_dns` | The last "IP Settings" push. `ip_mode` is `"static"` or `"dhcp"`; the `static_*` fields are set only in static mode and cleared on a revert to DHCP. `static_dns` is an array in the controller's primary/secondary order, written to `/etc/resolv.conf`. On DHCP, DNS is left to the lease and openUF does not touch `resolv.conf`. In static mode these are **re-applied on every start**, because the address is `ip addr` state that a reboot discards and the controller does not re-push it (a matching `cfgversion` gets a `noop` back, carrying no `system_cfg` at all) — the same reason `blocked_stas` and `led_enabled` are reconciled at startup |

To reset to factory defaults:
```sh
syswrapper.sh reset-inform
```

---

## 6. WiFi provisioning

When the controller pushes a config, `ucihelper.lua` applies it via OpenWrt UCI.  Only sections prefixed with `openuf_` are created or deleted.

`use_only_unifi_wlan` (default `true`) additionally sets `disabled=1` on every *other* `wifi-iface`, so the radios carry only what the controller provisioned.  openUF stamps each SSID it turns off with `openuf_autodisabled=1`; setting the option back to `false` re-enables exactly those and leaves everything else as-is, so an SSID you had disabled yourself is never switched back on.  Set it to `false` from the start to keep hand-configured SSIDs broadcasting alongside the controller's.

A `wifi-iface` whose `mode` is not `ap` — an 802.11s mesh point, or a station interface — is exempt regardless. Those are *links*, not SSIDs competing on the air, and one of them may be the AP's own uplink: switching it off would take the device off the network entirely. If an earlier openUF had already stamped one, it is switched back on.

Settings carried through from the controller:

| Controller setting | Applied as |
|---|---|
| SSID, passphrase, security | `wifi-iface` ssid/key/encryption |
| Hide WiFi Name | `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | `macfilter` (`disable`/`allow`/`deny`) + `maclist` |
| Lock to Access Point (a client setting) | The same `macfilter=deny` + `maclist`, on every AP except the one the client is locked to: the controller sends the lock as `type=lock2ap` entries of each WLAN's MAC filter, merged into a user deny list or taken out of a user allow list. The AP the client is locked to gets nothing for it. Needs `wifi_caps` `0x1000000`, which openUF always claims. On the AP the client is locked to, openUF stops steering it away (below) |
| WiFi Speed Limit | `tc` shaping per VAP, not a hostapd option. `openuf_ratelimit_down`/`openuf_ratelimit_up` on the section are the persisted record: `tc` state dies with a reboot, so openUF rebuilds the qdiscs from those two options on every start |
| WPA2 / WPA3 / WPA2-WPA3 mixed | `encryption=psk2`/`sae`/`sae-mixed`, from the pushed AKM set **plus** `wpa3.transition` — SAE replaces WPA-PSK on the wire, so the AKM alone cannot tell mixed from WPA3-only. Depends on openUF advertising `radio_caps2` bit `0x1` |
| Enhanced Open (OWE) | `encryption=owe` (bare, no cipher suffix), from `wpa.key.1.mgmt=OWE` with no `aaa.<n>.wpa`. **Transition mode** arrives as two VAPs per radio with the same SSID (open + hidden OWE, linked by `owe_devname`). openUF writes them as one section with `owe_transition=1`, and OpenWrt 25.12's ucode generator builds both BSSes from it, naming the hidden one `<ssid>OWE`. It does so only for `encryption` exactly `owe`, which is why no cipher is appended. Depends on openUF advertising `radio_caps2` bit `0x8`, which it does when `hostapd -vowe` passes |
| Private Pre-Shared Keys | One `wifi-station` section per key (`openuf_<vap>_psk<k>`: `iface` = the VAP's section, `mac` = `00:00:00:00:00:00`, `key`, `vid` unless the key's network is VLAN 1) and one `wifi-vlan` per VLAN (`openuf_<vap>_vlan<vid>`: `name`/`vid` = the VLAN id, `network` = `openuf_vlan<vid>`, or the `vlan_filtering` plan's `openuf_v<vid>`), plus `dynamic_vlan=1` on the VAP, from `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid`. OpenWrt turns them into hostapd's `wpa_psk_file` and `vlan_file`; the client's netdev is `<vap ifname>-<vid>`. The WLAN's own `wpa.psk` (a random passphrase the controller generates) stays the section's `key`. Needs a hostapd with VLAN support (the full `wpad-*` builds have it) and a `lan_cpueth` to build the VLANs on; with the `vlan_filtering` backend, openUF adds each key's VLAN to the bridge itself (tagged on the uplink, an `openuf_v<vid>` interface), since the push carries no bridge for a VLAN only a key uses. `psk_radius=2` (keys from RADIUS only) skips the WLAN |
| WPA-Enterprise (802.1X) | `encryption=wpa2+<cipher>` (WPA2), `wpa3+<cipher>` (WPA3, PMF required), `wpa3-mixed+<cipher>` (WPA2/WPA3), `wpa3-192+gcmp256` (192-bit), picked by `wpa3.support`/`wpa3.transition`/`wpa3.enhanced_192` (the akm is `WPA-EAP` for all of them). RADIUS from `aaa.<n>.radius.*`: `list auth_server` + `auth_port` + `auth_secret`, `list acct_server` + `acct_port` + `acct_secret`, `acct_interval` (interim updates), `nasid`, `auth_cache` (OKC), `dynamic_ownip=1` (NAS-IP-Address is the egress address, not hostapd's 127.0.0.1), `dynamic_vlan` 1/2 with one `wifi-vlan` per VLAN this AP already carries (`openuf_<vap>_vlan<vid>`, as for Private Pre-Shared Keys). OpenWrt takes one port and secret per list, so servers that differ from the first are left out. With Fast Roaming, `key` = the RADIUS secret: 25.12's `ap.uc` derives the FT key holders from `auth_secret ?? key`, but its schema has already renamed `auth_secret`, so without `key` the BSS fails with `FT_KEY_CANT_BE_DERIVED`. Skipped and logged when the push names no usable server. Needs a full `wpad` build |
| RADIUS CoA / Disconnect (DAS) | Per Enterprise WLAN: `dae_client=127.0.0.1`, `dae_port=<3800+n>`, `dae_secret`. The `announce` process listens on UDP **3799** (point the RADIUS server's CoA/Disconnect at the AP's address and 3799), accepts requests from the WLAN's accounting servers only, and relays each to the WLAN named by NAS-Identifier or Called-Station-Id SSID, else to every WLAN (first ACK wins). The plan is `/etc/openuf/das.json`, rewritten on provisioning |
| RADIUS MAC Authentication | `auth_server`/`acct_server` as above plus `list hostapd_bss_options 'macaddr_acl=2'` (a raw line, so it wins over a MAC filter's `macaddr_acl` and also applies on an Enterprise BSS, where `ap.uc` writes none). hostapd sends the MAC as `%02x` ×6 and as the password; any other `radius.macacl.format`, or the empty-password option, skips the WLAN. A UID IoT WLAN with keys from RADIUS only (`wpa.psk_radius=2`) gets `ppsk=1` (`wpa_psk_radius=2`) |
| PMF (802.11w) | `ieee80211w` (0 disabled / 1 optional / 2 required) |
| Fast Roaming (802.11r) | `ieee80211r`. The controller carries **two** toggles — `ft.status` for the WLAN and `wpa3.ft.status` for the SAE akm alone (SAE pushes only). OpenWrt has one switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK *and* FT-SAE together, so FT is enabled if **either** asks for it and a disagreement is logged. Both keys arrive `disabled` on a WPA3-only WLAN unless openUF advertises `radio_caps2` bit `0x2`, which it does wherever it advertises `0x1` |
| BSS Transition (802.11v) | `bss_transition` — **needs a full `wpad` build** |
| Band Steering | `usteer` config, not a hostapd option. On when any WLAN's Band Steering is on, or the AP's own setting is Prefer 5G |
| Roaming Assistant (per WLAN, 5 GHz) | `openuf_roam_assist=<dBm>` on the 5 GHz section (openUF's own marker, absent when off); enforced by openUF over hostapd's ubus, not by a hostapd option — see below |
| Airtime Fairness (device panel) | Not UCI: `/sys/kernel/debug/ieee80211/phy*/airtime_flags`, `3` (TX+RX, the kernel default) for on and `0` for off, from `atf.mode`. Kept as `atf_enabled` in `state.json` and rewritten at every start, because debugfs resets to `3` on reboot. Forgetting the device puts `3` back. Depends on openUF advertising `wifi_caps` bit `0x20`, which it does when that debugfs file exists |
| Auto/Custom DTIM Period | `dtim_period` |
| Multicast Enhancement | `multicast_to_unicast` |
| Minimum Data Rate | per-**radio** `basic_rate` / `supported_rates` / `legacy_rates` / `beacon_rate` |
| Multicast and Broadcast Blocker | nftables rules, not a hostapd option. `openuf_bcfilt`/`openuf_bcfilt_macs` on the section are the persisted record: the ruleset dies with a reboot, so openUF rebuilds it from those two options on every start |
| Multicast Suppressor (Conservative / Aggressive) | nftables, in the blocker's `bridge openuf_bcfilt` table. **Aggressive** arrives as the blocker (`bcfilt.*`, its allowlist filled by the controller with the site's device MACs) plus `bcfilt.bypass_types=ARP\|NSNA\|DHCPV4\|DHCPV6`: openUF accepts those (ARP, IPv6 neighbour solicitation/advertisement, UDP 67/68, UDP 546/547) ahead of the drop. **Conservative** arrives as `wireless.<n>.multicast.suppressor=enabled` alone: openUF reads it as storm control and drops group-addressed frames to the VAP beyond 200 per second (burst 400). ⚠️ That threshold is openUF's choice: the controller sends none. Recorded as `openuf_mcast_suppressor`/`openuf_bcfilt_bypass` for the startup rebuild. Needs `wifi_caps2` `0x400000`, always claimed, and `kmod-nft-bridge` |
| MAC-based VLANs (a client's Virtual Network Override, "VLAN Magic") | `aaa.<n>.accept_mac.<m>.mac`/`.vlanid` → `/etc/openuf/macvlan-<section>.list` (`<mac> <vid>` per line), named by `list hostapd_bss_options 'accept_mac_file=…'`, plus `dynamic_vlan=1` and one `wifi-vlan` per VLAN (`openuf_<vap>_vlan<vid>`, as for Private Pre-Shared Keys; VLAN 1 is the untagged network). hostapd accepts a listed client onto its VLAN and everyone else as before. Left out: a MAC the WLAN's deny filter or Lock to Access Point refuses, a MAC not on an allow filter, the WLAN's own VLAN, every entry on a WLAN with RADIUS MAC authentication (an accept-list hit would skip RADIUS), and open/OWE WLANs (OpenWrt sets up hostapd's VLAN bridging only for PSK, SAE and Enterprise). The list is on flash because hostapd reads it at boot, before openUF runs; it is rewritten only when it changes and removed when the override goes. Needs `fw_caps` `0x80000000`, claimed where hostapd has VLAN support (the PPSK probe) |
| WLAN Schedule | `openuf_schedule` on the section (the schedule, encoded) and `disabled=1` + `openuf_sched_off=1` while the schedule has the WLAN off. Checked once a minute on the device's local time (the controller's timezone, `system_timezone`); a change is one `wifi reload`, which on 25.12 adds or removes just that BSS. A WLAN the controller disabled is never brought up by its schedule. See below |
| Hotspot 2.0 / Passpoint | Raw hostapd lines in `list hostapd_bss_options` on the Enterprise section (`interworking=1`, `hs20=1`, `access_network_type`, `internet`, `venue_group`/`venue_type`, `venue_name`, `venue_url`, `hessid`, `domain_name`, `nai_realm`, `roaming_consortium`, `anqp_3gpp_cell_net`, `hs20_oper_friendly_name`, `hs20_conn_capab`, `hs20_wan_metrics`, `qos_map_set`, `ipaddr_type_availability`, `network_auth_type`, `disable_dgaf`, `anqp_domain_id`, GAS limits, Terms and Conditions filename/timestamp), from `aaa.<n>.hs20.*`. Not OpenWrt's `hs20`/`iw_*` options: 25.12's `ap.uc` overwrites `domain_name` with the 3GPP list and joins list options onto one line. Online sign-up (OSU providers, icons) is not carried; an OSEN WLAN is skipped. Needs `fw_caps` `0x800000`, claimed where `hostapd -vhs20` passes (the full `wpad-*` builds) |
| RADIUS Filter-Id | `list radius_auth_req_attr '11:s:<uid-wifi\|wpa-eap>'` on the Enterprise section, from `aaa.<n>.filter_id` (sent only while the gateway runs the RADIUS server). Every Access-Request then names the service, which the gateway's RADIUS accounts are scoped to. Needs `fw_caps` `0x20000000`, always claimed |
| Proxy ARP | `proxy_arp` — **needs a full `wpad` build** |
| Client Isolation | `isolate` (hostapd `ap_isolate`) |
| Group Key Update Period | `wpa_group_rekey` (seconds; `0` = never), from `aaa.<n>.wpa.group_rekey`. The controller sends `3600` unless the WLAN says otherwise; hostapd's own default is 86400 |
| TDLS Prohibit | `tdls_prohibit`, from `aaa.<n>.tdls_prohibit` |
| U-APSD | `uapsd` (25.12 maps it to `uapsd_advertisement_enabled`), from `wireless.<n>.uapsd`. **Off by default in the controller**, where OpenWrt defaults it on |
| 802.11k (per WLAN) | `ieee80211k`, from `aaa.<n>.11k.status`; OpenWrt derives `rrm_neighbor_report`/`rrm_beacon_report` from it. Band Steering or Roaming Assistant forces it on whatever the WLAN says |
| SAE groups | `list hostapd_bss_options 'sae_groups=<g> <g>'` on SAE WLANs, from `aaa.<n>.sae.groups.<i>.group` + `sae.has_groups=enabled`. Not a wifi-iface option |
| 802.11d (per WLAN in the controller) | per-**radio** `country_ie` (alias of `ieee80211d`): on if any enabled WLAN on the radio has it on, off if all say off. Off is applied on 2.4 GHz, and on 5/6 GHz only with `doth`/`ieee80211h` set to `0` (hostapd will not start 802.11h without 802.11d). The board's previous value is kept in `openuf_country_ie` (`none` = unset) and restored when no WLAN carries the key |
| Network / VLAN assignment | a per-VLAN bridge (`br-openuf<id>`) holding the tagged uplink sub-device (`eth1.<id>`), which the VAP joins. See below |
| Channel, TX power | `wifi-device` channel/txpower; the controller's **Auto** channel is written as the literal `channel=auto`, engaging hostapd ACS (the AP surveys the band at radio bring-up and picks the least-busy channel). **Auto** TX power *deletes* the `txpower` option (UCI has no auto value; absent = driver default/max), so reverting from a fixed dBm actually takes effect |
| Auto-channel exclusions / DFS (Radio AI, `radio.<n>.blklst` / `radio.<n>.acsdfs`) | Only while the channel is **Auto**. Excluded channels come off the `wifi-device` `channels` list (hostapd `chanlist`, stamped `openuf_channels`): on 2.4 GHz off the 1/6/11 plan, elsewhere written as the ranges between them (`1-51 53-55 57-233`). DFS off sets `acs_exclude_dfs=1`, stamped `openuf_acs_dfs`. Both are torn down when the keys go or the channel is fixed; a hand-set value without a stamp is left alone, and a board radio policy (§ 3) wins. Needs `wifi_caps2` `0x10`, which openUF claims. ⚠️ Not yet confirmed on the wire |
| Radio enable/disable (TX Power → Disabled) | `wifi-device` `disabled`; the radio's WLANs get `wifi-iface` `disabled` too, keeping their config for a later re-enable |
| Channel width | `wifi-device` htmode, from the radio's `ieee_mode` token, **clamped to what the radio can actually do** — see below |
| IoT Optimization: Lock 2.4 GHz to Channel 6 | nothing new — arrives as `channel=6` on the 2.4 GHz radio |
| IoT Optimization: DTIM Interval Lock | nothing new — arrives as `dtim_period=3` on the 2.4 GHz SSID |
| IoT Optimization: Force WiFi 4 Mode | `bss_load_update_period=0` (suppresses the QBSS Load IE) + an `openuf_iot` marker |
| Minimum RSSI | per-**radio**; enforced by openUF deauthenticating clients below the threshold, not by hostapd |
| Max Clients (Radios → load balancing) | per-**radio** `wifi-device` `maxassoc` (hostapd `iface_max_num_sta`) + an `openuf_maxassoc` marker |
| Per-port VLAN (Ports → *port* → Native VLAN) | the socket moved out of `br-lan` into `br-openuf<id>` — see below |

**Channel width is clamped to the hardware.** openUF presents itself as a
U6-InWall (802.11ax) whatever the host radios really are, so a controller will
happily push `ieee_mode=11nahe80` at an 802.11n/ac radio. Written to UCI
verbatim that produces a config file that looks perfectly correct and a hostapd
that refuses to start — no SSID on the air, and nothing in the config to explain
why. openUF therefore probes `iw phy` for each band's real PHY and maximum
width and clamps the request **downward only** (`HE80` → `VHT80` on an ac
radio, `HE40` → `HT40` on an n-only 2.4 GHz radio); a request the hardware can
already satisfy is never touched, and every clamp is logged:

```
openuf: radio0: controller asked for htmode HE80, hardware supports VHT80 -- clamped
```

If `iw` is unavailable or its output can't be parsed, the controller's value is
written through unchanged rather than clamped to a guess. The same probe supplies
each radio's real `max_txpower` (the ceiling the controller's TX Power slider
uses) instead of a static default.

**The PHY generation comes from the hardware, not from the wire.** What a real
controller actually sends is `radio.<n>.ieee_mode=11nght20` / `11naht40` — its
vocabulary is Atheros-era (the same push names the VAPs `ath0`/`ath1`/`ath2`),
and that `ht` is *not* a request for 802.11n. It is the only thing this key has
ever said: the **band** and the **width**. A real U6-InWall receiving `11naht40`
runs it as HE40. So openUF takes the width from the wire and the PHY from
`iw phy`, then clamps as above — a 2.4 GHz-capable ax radio given `11nght20`
gets `HE20`, an n-only one gets `HT20`. Reading the token literally pinned every
802.11ax radio to 802.11n permanently, which is invisible in the controller (it
shows the width, which was right) and visible only in `iw dev`. An explicit
`vht`/`he`/`eht` token, if one ever arrives, is honoured as written.

> **SSID punctuation is sanitized into the UCI section name.** A UCI section name may
> contain only `[A-Za-z0-9_]`, so an SSID of `Guest-WiFi` becomes the section
> `openuf_radio0_Guest_WiFi_<hash>` — the SSID *itself* is stored and broadcast unchanged.
> This matters because libuci enforces the rule **silently**: `set()` returns true,
> `commit()` returns true, and a section whose name contains anything else is discarded
> before it reaches `/etc/config`. An unsanitized character therefore costs the entire WLAN
> with nothing logged anywhere.
>
> The `<hash>` is four hex digits derived from the *original* SSID, and is appended only
> when the name had to be altered at all — `corp` stays `openuf_radio0_corp`. Without it,
> two SSIDs differing only in punctuation (`Guest WiFi` and `Guest-WiFi`) sanitized onto
> one section and the second silently overwrote the first.

**Fast Roaming (802.11r) and the `ft_psk_generate_local` trap.** openUF sets
`ieee80211r`, a `mobility_domain` derived from the SSID (so every AP computes the same one
with no coordination) and `ft_over_ds=0` — and deliberately does **not** set
`ft_psk_generate_local`. That option looks harmless and is not:

- It means "derive PMK-R0/R1 locally from the PSK", which only exists for **FT-PSK**. FT-SAE
  derives PMK-R0 from the per-session SAE PMK, which no passphrase can reproduce, so its
  PMK-R1 has to be pulled from the origin AP over an `r0kh`/`r1kh` key-holder relationship.
- OpenWrt only configures those key holders when `ft_psk_generate_local` is **0**, and only
  defaults it to 0 when nothing has overridden it. Setting it to 1 therefore silently
  disables fast roaming for every WPA3 client on a `sae-mixed` WLAN — which is most of them.

Left unset, `hostapd.sh` keys it on the auth type (`psk` → 1, anything else → 0) and, at 0,
derives wildcard key holders from `md5(mobility_domain/psk)`. That is deterministic, so
independent APs sharing an SSID and passphrase arrive at the same key — the same reasoning
behind the derived mobility domain. Worth knowing: that key is therefore derivable by anyone
who knows the passphrase, i.e. anyone already on the network; a real UniFi controller
distributes a random one instead.

**How to tell whether a transition was actually fast**, since nothing in the controller
shows it — force one and read the target AP's log:

```sh
hostapd_cli -i <vap> bss_tm_req <sta-mac> pref=1 \
    neighbor=<target-bssid>,0x0000,<op-class>,<channel>,7 \
    disassoc_imminent=1 disassoc_timer=30
logread | grep AP-STA-CONNECTED
```

`auth_alg=ft` **and no `EAPOL-4WAY-HS-COMPLETED`** is a real fast transition. `auth_alg=sae`
followed by a 4-way handshake is the fallback — the client roamed, it just paid full
authentication for it. `hostapd_cli -i <vap> sta <mac>` shows the negotiated
`AKMSuiteSelector`: `00-0f-ac-4` is FT-PSK, `00-0f-ac-9` FT-SAE, `00-0f-ac-8` plain SAE.
openUF reports the same selector to the controller as the client's `is_11r`. The client's
power-save flag (`state` bit `0x10`) comes from mac80211's debugfs
(`/sys/kernel/debug/ieee80211/<phy>/netdev:<vap>/stations/<mac>/flags`, line `PS_STA`). Without
debugfs mounted, `state` is not sent, and the controller shows power save as off.

**VLAN-tagged SSIDs** (assigning a WiFi network to a non-native network) need two
things on the AP, and openUF builds both:

1. a tagged sub-device on the uplink — `eth1.<vlan>`;
2. a **bridge** holding it, `br-openuf<vlan>`, which the VAP joins. This is the part
   that is easy to miss: point the VAP's network at the bare sub-device instead and
   netifd brings the interface up, `ip link` shows both netdevs, hostapd starts, and a
   client associates and gets *nothing* — because the VAP and the uplink are two
   separate masterless interfaces. Everything looks healthy except `ip link`'s missing
   `master`.

No switch trunk is needed. With bridge VLAN filtering off — the OpenWrt default, and the
state a `config bridge-vlan`-free `br-lan` is in — the switch passes tagged frames straight
through, and the sub-device on the uplink socket (`wan.<vlan>` on an AX3000T) takes its VID
before the bridge ever sees it.

Changing a network's VLAN id, or deleting the WLAN, tears the old bridge and interface
down again — only `openuf_`-prefixed sections are ever removed.

**Per-port VLAN assignment** must be switched on twice: once on the device
(Devices → *AP* → Settings → IP Settings → **Port VLAN**, which is what flips the wire's
`switch.status`/`switch.vlan.status` gates), then per port under **Ports**. Until the
device-level box is ticked the per-port VLAN controls stay greyed out and nothing reaches
the wire.

**It works by moving the socket, deliberately not via `config bridge-vlan`.**
The socket assigned to VLAN 10 is moved out of `br-lan` and into `br-openuf10` — the
bridge that already holds the tagged uplink sub-device `wan.10`, and the IoT VAP if a
tagged SSID sits on the same VLAN:

```
device on lan3 --untagged--> lan3 -> br-openuf10 -> wan.10 --tagged--> uplink -> gateway
```

That a wired port and a wireless client on VLAN 10 land in the *same* bridge is the point,
not a coincidence: they are one broadcast domain and the controller models them as one
network. `br-lan` keeps the uplink socket, the unassigned sockets and the AP's management
address, untouched.

> **This fork adds that route as a second backend** (`bridge_backend = "vlan_filtering"`,
> chosen automatically when the uplink already sits in a vlan-filtering bridge) -- see
> [Controller-owned bridge](#controller-owned-bridge-vlan_filtering-backend) below for how it
> answers both objections. The per-VLAN-bridge design described here stays the default
> everywhere else.

The `bridge-vlan` + `vlan_filtering` route was rejected for two reasons, both worth knowing
if you are tempted to add it:

1. `br-lan` carries the AP's own management address. Turning `vlan_filtering` on there means
   every VLAN — the management one included — must be declared exactly right, or the device
   is stranded at the far end of a cable. Nothing openUF does should be able to do that.
2. It would silently fight the tagged-SSID path. `wan.10` is an 8021q device on the `wan`
   **bridge port**, and `vlan_do_receive()` runs ahead of the bridge's `rx_handler`, so
   VLAN 10 frames are taken by `wan.10` before `br-lan` ever sees them. A `bridge-vlan`
   declaring VLAN 10 on `br-lan` would receive nothing while looking perfectly correct.

Scope on DSA: **Native VLAN only.** A bridge gives a port exactly one untagged home, which
is what a Native VLAN is and what an AP's downstream socket needs. A port given nothing but
*tagged* VLANs is refused with a log line rather than half-applied. (The controller's default
"Tagged VLAN Management: Allow All" marks every non-native VLAN tagged — that is a default,
not a request, and is not warned about.)

Reversibility on DSA is `st.dsa_brlan_ports`: `br-lan`'s port list exactly as the board
shipped it, snapshotted once before the first socket moves. Unticking **Port VLAN** puts it
back verbatim and returns the sockets from the VLAN bridges.

> Unticking the box is what triggers that teardown, and it needs a config push to act on —
> the controller sends one when you hit **Apply Changes**, not merely when the device
> reconnects. Note the off signal is an *absence*: a device that has had Port VLAN on and
> then has it unticked receives a `system_cfg` with no `switch.*` keys at all rather than
> the gates set to `disabled`. openUF treats that as off only while it holds a ledger, so
> there is something to undo.

> **Reassigning a port does not re-address the device plugged into it.** Moving a socket
> between bridges is invisible to the attached host: its link never drops, so it keeps the
> lease it already had — now on the wrong subnet — and simply goes quiet. Bounce the port
> (`ip link set lan2 down; ip link set lan2 up`) to make it re-DHCP. Verify the move by
> watching the counters rather than by waiting for the client to reappear —
> `cat /proc/net/dev` should show the socket's rx bytes and the tagged uplink's tx bytes
> climb by *the same amount*, which is the whole path proving itself.

**openUF turns MAC learning off on every socket it moves**, with a `config device` section
named `openuf_brport<vid>_<socket>`. This is not a tuning knob; without it the port is a
one-way street.

`br-openuf<vid>` is a *software* bridge — `wan.10` is an 8021q device the switch knows
nothing about — but the moved socket is still a real port on the same ASIC as the uplink,
and that ASIC has **one** address table. Let it learn the attached device against `lan2`
and a reply arriving VLAN-tagged on the uplink port *hits that entry*; since `lan2` is no
longer in the uplink's bridge port matrix, the switch resolves the frame in hardware and
drops it rather than passing it to the CPU, where the software bridge would have delivered
it. It is the same one-FDB hazard as the tagged uplink's own `learning '0'`, reached from
the other side.

The failure is brutal to diagnose because **outbound is perfect throughout**. Captured on
an AX3000T with an IKEA Trådfri hub on port 2, learning on: four DHCP DISCOVERs leave the
socket, arrive on `wan.10`, leave the uplink correctly tagged — and nothing comes back, not
even on the physical port, because a frame dropped in hardware never reaches the CPU to be
captured. Every counter, every log line and the controller all say the port move worked.
With learning off: DISCOVER → OFFER → REQUEST → ACK in 2 ms.

Two consequences worth knowing:

- The socket's hosts stop showing up in `bridge fdb show dev <socket>`, which is where every
  wired-host answer comes from — so `port_table` publishes an empty `mac_table` for that
  port and the controller credits the client to whoever else saw the MAC, which in practice
  is the gateway. **openUF works around this with an nftables tap** (below); you do not have
  to do anything, but it is why a `bridge openuf_learn` table exists on a board with an
  assigned socket.
- **A live reassignment converges slowly.** An entry the ASIC learned while the socket was
  still in `br-lan` is already there, cannot be deleted (`bridge fdb del … self` answers
  `No such file or directory`, `bridge fdb flush` answers `Not supported`) and does not
  clear on a link bounce. It ages out on its own — measured at ~140 s — and the port works
  from that moment. If a freshly moved port looks dead, wait three minutes before
  suspecting anything else.

### Where the hosts behind an assigned socket come from

With the FDB empty for that socket, openUF observes it somewhere else: a bridge-family
nftables rule that files each frame's source address into a dynamic set.

```
# nft list table bridge openuf_learn
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

It works for the same reason the original bug existed: the socket is in a bridge whose other
member is a software device, so it cannot be hardware-offloaded and **every one of its
frames reaches the CPU**. The rule has no verdict and the chain's policy is `accept` — it
observes and never decides. The 5 minute set timeout is the bridge's own FDB ageing time, so
a host disappears from the report exactly as long after unplugging as it used to.

One set and one rule cover every assigned socket, and the table is rebuilt from scratch
whenever an assignment changes, torn down when the last one goes, and reinstalled at openUF
startup (nftables keeps nothing across a reboot). The bridge FDB always wins where it has an
answer — the tap is a fallback for a socket the kernel cannot speak for, never a second
opinion about one it can.

A quiet device is reported a little later than it used to be: the FDB knew a host the
instant the bridge saw a frame from it, and so does the tap, but a device that transmits
once a minute is now invisible for up to that long after a restart. Nothing that talks more
often than the 5 minute timeout is affected.

### Why the tap also collects addresses

Reporting *who* is behind the socket is only half of it. The controller decides which
**network** a wired client belongs to by walking the site's layer-2 networks and keeping the
client only where the network's VLAN id matches the `vlan` on the reported row, defaulting
to 1. It does not use the port's configured native VLAN for this, and it does not use the
IP it already holds from the gateway.

So openUF reports two things it could not otherwise know for an assigned socket:

- **`mac_table[].vlan`** — read off the bridge the socket was moved into (`br-openuf<vid>`
  names its own VLAN), omitted for the management VLAN since the controller drops a `vlan`
  of 1 on arrival.
- **`mac_table[].ip`** — from the tap's `portips` set. The AP holds no address on that VLAN,
  so `/proc/net/arp` can never answer for a host behind the socket; without this the client
  is listed with no address of its own.

With both, an IoT device on an assigned socket shows up under the right port, at the right
link speed, with the right address, on the right network. Verified live against a UCG Ultra
running Network 10.6.

> Some attached devices still need a power cycle afterwards. A Trådfri hub put through
> several link bounces during this investigation stopped transmitting entirely — zero
> packets in 60 s on a live 100 Mbps link — and only a power cycle brought it back.

The port must not be the uplink — reassigning the uplink's VLAN would cut the device off
the network, so that is refused outright. The uplink is whichever socket the default
gateway is reached through (found in the bridge FDB); if that cannot be determined,
**every** port is refused rather than risking the wrong one.

Inspect the result with `uci show network` and `bridge link`.

LuCI's *Network → Switch/VLAN config* page shows "No managed switch found" on these APs:
it only takes a bridge whose members are all Ethernet or DSA ports, and the controller-owned
bridge also holds every SSID. `luci-theme-openuf` replaces it with a copy that leaves the
SSIDs out and shows the ports and VLANs. Port VLANs on an adopted AP are still the
controller's (*Ports* in UniFi): the next push that changes the network model rewrites what
the page changes.

**Band Steering** has two switches in the controller: the per-WLAN toggle, and the AP's
own setting in its device panel (Off / Prefer 5G / Balance). Either one turns steering on
for the whole AP, because usteer is a single daemon. Balance is not supported (see
Troubleshooting). Steering itself is `usteer`'s decision, not openUF's: openUF configures the daemon
(`usteer.local.band_steering_interval`: `0` when off, and the daemon is stopped unless
Roaming Assistant needs it; unset when on, so usteer's own default applies) and forces 802.11k neighbour reports plus
`bss_transition=1` onto every VAP, since usteer cannot work without them. Settings of your
own go in the device's own usteer section, not in `local`. `/etc/init.d/usteer` merges every
section into one config and sends each list option from each section, even an empty one,
and usteerd keeps the last copy, which is `local`'s. So openUF copies `ssid_list` and
`event_log_types` from the other sections into `local` (and `aggressiveness_mac_list`, see
§ Lock to Access Point), and restarts usteer only when the copy changes. An edit to them is
picked up on the next WiFi config push. `ubus call usteer get_config` shows what usteerd
actually uses. If a client is
not being steered, check `ubus call usteer get_clients` for a 5 GHz sighting of it and
`ubus call hostapd.<iface> get_clients` for its `rrm` bits and the BSS-Transition bit in
`extended_capabilities` — a client with neither cannot be steered by any AP, and usteer's
per-BSS `roam_events` counters do not increment for BTM-driven band steers, so they are
not a useful health check. A successful steer looks like
`BSS-TM-RESP <sta> status_code=0 target_bssid=<the 5 GHz BSSID>` in `logread`.

**Roaming Assistant** (Settings → WiFi → *WLAN* → Advanced, 5 GHz) moves a weak client to
an AP that hears it clearly better. It does nothing to a client that has no better AP to go
to. It is per WLAN and runs in openUF (`openwrt/roamassist.lua`), not in usteer, because
usteer's own roam trigger can only be switched on for the whole device. For each client on a
WLAN with it on:

1. Its signal has been below the WLAN's threshold for 30 s, it has been associated for at
   least 60 s, and it was not moved in the last 120 s.
2. Another openUF AP on the same SSID and band hears it at or above the threshold **and** at
   least `roam_assist_diff_db` (default 8) dB louder. usteer shares those readings
   between APs. If no AP qualifies, nothing is sent, and the client is looked at again after 30 s.
3. openUF sends an 802.11v BSS Transition request naming that AP. A client still associated
   10 s later is disassociated, with a 30 s ban on the weak BSS only, so it cannot bounce straight
   back. That is also how a client without 802.11v gets moved.

It needs `usteer` running on every AP (openUF starts it whenever Roaming Assistant or Band
Steering is on, with band steering itself left off when only Roaming Assistant asks) and a
full `wpad` build; like Band Steering, it forces 802.11k and `bss_transition=1` onto every
VAP while it is on. The AP never leaves its channel for this: the readings are the ones
usteer already shares between APs. Each action is logged: `logread | grep roamassist`.
A refusal is normal and not a failure: on real hardware a client at −80 dBm answered
`BSS-TM-RESP <sta> status_code=4`, was disassociated by openUF and reassociated on the other
AP within a second, at −61 dBm. Whether a client answers at all is not predictable from the
BSS-Transition bit in its `extended_capabilities` — that client did not advertise it.
usteer's readings are up to two minutes old, so a client that has just walked away can be
pointed at an AP that is no longer better. The disassociation then lets it pick for itself,
which is where a UniFi AP would leave it too.

The controller only sends this setting to a device that claims `wifi_caps2` bit `0x20`,
which openUF does. A device adopted before that claim gets it on its first start after the
upgrade: the release asks the controller for its whole configuration again.

| Setting | Meaning |
|---|---|
| `roam_assist_diff_db` | How much louder (dB) the other AP must hear the client. Default 8 |

The **Environment** tab (Insights → AirView) is fed from `iw dev <ifname> scan dump`, the
kernel's passive BSS cache. That cache is filled from beacons the radio overhears **on the
channel it is already serving**, so on its own the tab lists near-channel neighbours and
nothing else — openUF never dwells off-channel behind your clients' backs. Measured on an
AX3000T: 6 neighbours on a 2.4 GHz radio on ch 11, and exactly 1 on a 5 GHz radio on ch 44.
On the Archer C5's 5 GHz radio the passive cache held **nothing at all**.

Two fields in that view are read out of the beacon rather than out of a summary line,
because `iw` 6.17 — what both boards run — prints no summary line for either:

* **Ch. Width** comes from the neighbour's own HT and VHT operation elements. There is no
  `BSS operating channel width:` line on this `iw`, so before this every neighbour was
  reported at the 20 MHz default, two real 80 MHz APs included.
* **Age** also accepts `last seen: <n>s [boottime]`, which some entries carry *instead of*
  `n ms ago`. Those used to fall back to 0 — "seen this instant" — which keeps a long-gone
  AP in the view, since the controller drops anything with age ≥ 30 as stale.

**Sibling openUF APs are not rogues.** The controller takes the reporting AP's word for
which scanned BSSes belong to the site — it never checks its own devices' BSSIDs — so without
help every other openUF AP broadcasting your SSID showed up as *"a third-party access point
broadcasting your network's SSID"*. Each openUF VAP therefore beacons a small vendor element
carrying its device MAC (hostapd `vendor_elements`, which OpenWrt 25.12's wifi scripts pass
through), and a scan that hears it reports that BSS as a UniFi AP of the site; it then leaves
the Environment list, as a real UniFi AP's would. Only openUF APs recognise each other this
way — a mixed site's genuine UniFi APs are still reported as third-party by openUF and vice
versa.

The element is read back from the kernel's scan cache with ucode's `nl80211` module, which
OpenWrt's own wifi scripts depend on, and not from `iw`: OpenWrt's `iw` build does not print
vendor elements it does not know, `-u` or not. `uci get wireless.<section>.vendor_elements`
shows the element an AP beacons: `dd0d026f556f554601` followed by its device MAC.

openUF closes that gap the way Ubiquiti's Channel AI describes — *"neighbor reports and
automated RRM scans"* — rather than by scanning. Every `rrm_request_interval` seconds
(default 600) it asks **one** 802.11k-capable client for an active beacon measurement: the
*client* leaves the channel, sweeps, and reports what it saw, while the AP keeps serving.
One answer returned 15 BSSes across both bands at once, and a client sitting on 5 GHz
routinely reports 2.4 GHz too — so a single report enriches both radios. It took that
empty 5 GHz list from 0 neighbours to 4, one of them an AP the radio cannot hear at all.

| Setting | Meaning |
|---|---|
| `rrm_enrichment` | `true` by default. Set `false` to never send a beacon request. Switching it off also tears down the background collector on the next cycle, and `/etc/init.d/openuf stop` does the same |
| `rrm_request_interval` | Seconds between requests, across all radios and clients combined — they are asked one at a time, round-robin |

Reports are collected by a detached `ubus subscribe hostapd.*` child that parks them in
`/tmp/openuf-rrm.jsonl`; openUF drains and truncates that file on every inform. Because the
child is reparented to init it outlives the daemon, so openUF kills it explicitly — on
service stop, on uninstall, and when `rrm_enrichment` is turned off. If you ever find it
running with openUF stopped (`pgrep -f 'ubus subscribe hostapd'`), nothing is draining the
file and it will grow: `pkill -f 'ubus subscribe hostapd'` and delete it.

Only clients advertising **active or passive** beacon measurement are ever asked. Clients
advertising *beacon-table* only are skipped on purpose: the one real example acknowledged
every request at the MAC layer and never sent a report, and hostapd refuses a passive
request for such a client outright. In practice this is a minority of clients — of 13
surveyed across two APs, 9 had no 802.11k at all — so this supplements the passive cache
and never replaces it.

The request names the operating class the *client* can measure: 81 (2.4 GHz) for a station
on a 2.4 GHz BSS, 115 (5 GHz U-NII-1) for one on 5 GHz. A dual-band client answers 115 for
both bands, which is where the cross-band bonus above comes from — but a 2.4 GHz-only
client answers it with report mode `0x02`, *incapable*, and nothing else.

Capability bits are not a promise, either: a client can advertise every measurement mode
and still refuse them all. hostapd only notifies openUF when a report body arrives, so
such a station is indistinguishable from one that never answers — after two unanswered
requests it is left alone for six hours, then tried once more. Any report at all puts it
straight back into the rotation.

Rows sourced this way show a **blank WiFi Name and Security** (the controller renders the
BSSID instead of a name). That is deliberate: a beacon report carries a BSSID, a channel
and an RCPI, and nothing else. openUF will not invent a security mode it did not measure —
an earlier draft defaulted it to `open` and told the operator that four WPA2 neighbours
were unencrypted.

To see the machinery: `pgrep -f 'ubus subscribe hostapd'` is the collector that receives
the reports (hostapd delivers them as ubus *notifications*, so `ubus listen` shows nothing
— only `ubus subscribe` works), `logread | grep BEACON-REQ-TX-STATUS` shows requests going
out, and `/tmp/openuf-rrm.jsonl` is the spool, drained on every inform.

Use the controller's RF scan (`spectrum-scan`) when you want a real full sweep. It runs
`iw dev <if> scan ap-force` on every radio. (`ap-force` sweeps the same channels as a plain
scan on both tested boards, and it guards against a driver that refuses to scan on a
beaconing AP.) A radio where iw refuses logs `spectrum-scan: iw refused to scan <if>`, and
reports only the survey counters it already had.

Every such sweep runs in **chunks of four channels** (`iw dev <if> scan ap-force freq …`),
one chunk at most every 5 seconds, so a radio with clients is never off its channel for
more than about half a second at a time: a whole band in one go keeps an AP-only radio
silent for seconds, long enough for every client to give it up (seen on the yesrab fork,
whose chunking this is). The channel list is the radio's usable channels from
`iw phy#N info` (disabled ones left out); where it cannot be read the band is swept in one
go, as before. While a sweep is running the daemon informs every 5 seconds, whatever the
controller's interval, and `spectrum_scanning` is true until its last chunk.
`logread | grep swept` shows the chunks (`swept 4 channel(s), 2 passive on wlan1 (12
channel(s) left)`); a 5 GHz band is six or seven chunks, about half a minute. The
idle-radio sweep (`idle_scan_interval`) is not chunked: it runs only on a radio no client
is on.

A `quick-scan` (the RF view's Scan, the nightly 03:00 scan and Radio AI's prescan) runs the
same sweep, but on the radios of the band it names only (`scan-band` 0/1/2 = 2.4/5/6 GHz),
and not inside the command handler: the next inform reports `quickscan_scanning: true`, the
sweep starts once that inform has gone out, the flag stays true while its chunks run, and
the inform after the last chunk carries the results with the flag false. The controller sends it only to an AP claiming `wifi_caps2` `0x80`,
which openUF claims, so the AP also takes part in the controller's 03:00 sweep (while Radio
AI is off) and Radio AI's prescans (see PROTOCOL-VALIDATION.md, *Quick scan*). The pending scan
is held in memory: a daemon restart in between drops it, and the controller marks it done.

Radio AI's **neighbour isolation** (per band) needs every AP on the band to claim
`wifi_caps2` `0x200` ("neighbour in scan"). A claiming AP gets no `scan_band` command during
a Radio AI run: the controller builds its isolation matrix from the sibling sightings every
inform's `scan_radio_table` already carries (`is_unifi` entries, kept an hour). openUF's come
from the sibling scans and idle sweeps above, so it claims the bit while
`sibling_scan_interval` or `idle_scan_interval` is above 0. Only openUF siblings are tagged
as UniFi neighbours; a genuine UniFi AP nearby shows as a third-party BSS, and the matrix
lacks that pair.

The **Multicast and Broadcast Blocker** has no hostapd or OpenWrt equivalent — hostapd
can suppress group-addressed frames wholesale but has no notion of an allow-list — so
openUF enforces it with nftables, in its own `bridge openuf_bcfilt` table (separate
from the client-blocking `bridge openuf` table, which is rebuilt wholesale on every
block/unblock and would otherwise wipe these rules). Frames leaving a filtered SSID are
dropped unless the *sender's* MAC is allow-listed.

This needs **`kmod-nft-bridge`**, as does the L2 hardening below. The drop rule is
a bridge-family `meta` match, and `nft_meta_bridge` is a separate module that
`nftables` does not depend on — absent from a stock filogic *and* ath79 image alike. The
failure is quiet in the worst way: the table, the chain and the per-VAP allow-list set
are all created and populated, and only the drop rule is rejected, so the control reads
as enabled in the controller and `nft list table bridge openuf_bcfilt` shows a table that
filters nothing. openUF now logs `nft rejected the drop rule for <ifname> -- install
kmod-nft-bridge` when this happens.

> **This deliberately breaks DHCP for wireless clients unless you add the DHCP server's
> MAC to the excepted-devices list.** That is Ubiquiti's own documented behavior for
> this control, so openUF reproduces it faithfully rather than adding DHCP/ARP
> exemptions of its own — a silent exemption would be harder to debug than the
> documented breakage. Inspect the live rules with `nft list table bridge openuf_bcfilt`.

The **Multicast Suppressor** (WiFi → Advanced → Multicast Suppression, 10.6) lives in the
same table. Aggressive is the blocker with the controller's exemptions: ARP, IPv6
neighbour discovery and DHCPv4/v6 are accepted ahead of the drop, and the controller adds
every device of the site to the allowlist ("Aggressive blocks all except DHCP and ARP,
unless a device is allowlisted"). Conservative ("prevents storms") arrives with no
parameters at all, so openUF rate-limits group-addressed frames to each such VAP at 200
per second, burst 400 (`bcfilter.lua` `STORM_PPS`/`STORM_BURST`); traffic below that passes
untouched. Checked in a container against real `nft` and real bridged traffic: UDP
broadcasts to port 67 pass under Aggressive and to other ports are dropped, and a
2000-frame burst under Conservative delivers about 400.

### WLAN Schedule

The controller's schedule (WiFi → Advanced → WiFi Blackout Schedule) reaches the AP as
`wireless.<n>.schedule_<day>.<i>=HHMM-HHMM` blocks. openUF claims `fw_caps` `0x1000` (every
block of a day, not just the last) and `0x400000` (the blackout blocks as they are, with
`schedule_invert=enabled`; without it the controller sends their complement, the times the
WLAN is on). Both readings are implemented (`unifi/schedule.lua`).

- The section carries the schedule (`openuf_schedule`, e.g. `inv|mon=2200-2359|tue=0000-0700`),
  so nothing else is kept and a restart resumes it.
- The inform loop checks it once a minute. Off: `disabled=1` and `openuf_sched_off=1`. On:
  back to `disabled=0`, but only where that mark says the schedule took it down, so a WLAN
  the controller itself disabled stays down. One `wifi reload` covers every change; on
  25.12 hostapd removes or adds just that BSS and leaves the radio and its other WLANs up.
  The WLAN's speed limit (tc) is rebuilt once it is back.
- Times are the device's local time, which is the controller's timezone when
  `system_timezone` is on (`date` on the AP shows it). A device whose clock is not set
  (no NTP yet) follows whatever time it has.
- Removing the schedule rebuilds the section without it: the SSID comes back.

### SNMP Monitoring

Settings → System → SNMP sends `snmp.status=enabled`, `snmp.version` (`1_2c`, `3` or
`all`), `snmp.community`, `snmp.location`/`snmp.contact` and, for v3, `snmp.user.1.name`/
`password`, in every full push; SNMP off is the absence of the block. With `snmpd` installed
(`apk add snmpd-ssl`), openUF keeps the device's `/etc/config/snmpd` once in
`/etc/openuf/snmpd.orig` and rewrites it from the push: one read-only community
(`com2sec`/`com2sec6`, v1 and v2c groups, a read-all view), one v3 user (`config v3`: SHA
authentication and AES privacy, the password for both, as UniFi gateways are configured),
`sysLocation`/`sysContact`, and `snmp_version` for the init script. No community or user
the controller does not know about is left answering. snmpd restarts only when the push
changes (`snmp_applied` in `state.json`). Turning SNMP off restores the kept file and
restarts snmpd on it. Checked against 25.12's real `snmpd-ssl` in a container: the
controller's community answers, `public` does not, and v3 authPriv SHA/AES answers.

v1/v2c needs no capability bit; v3 is sent only to a device claiming `fw_caps` `0x4000`,
which openUF claims when `snmpd-ssl` is installed. The agent listens on UDP 161 on every
interface; an AP in the usual bridged setup has no firewall in front of it.

### Hotspot 2.0 / Passpoint

A Hotspot 2.0 WLAN is an Enterprise WLAN with `aaa.<n>.hs20.*` on top; the controller
drops it from the push unless the device claims `fw_caps` `0x800000`, which openUF claims
where hostapd is built with Hotspot 2.0 (`hostapd -vhs20`). openUF writes the whole block
as raw hostapd lines (table above); hostapd itself refuses Hotspot 2.0 on anything but
WPA2-Enterprise with CCMP/GCMP. The site's "Passpoint" feature additionally needs RadSec
(`fw2_caps` `0x80000`), which openUF does not claim: OpenWrt 25.12 has no RadSec client
(no `radsecproxy` package, and hostapd speaks RADIUS over UDP only), so Passpoint setups
that need RADIUS over TLS stay unavailable even though the WLANs are no longer dropped.

**Minimum Data Rate** is set per WLAN in the controller but OpenWrt's rate options
(`basic_rate`, `supported_rates`, `legacy_rates`, `beacon_rate`) are `wifi-device`
options, so two WLANs sharing a radio cannot each get their own floor. openUF applies
the most permissive of them — the lowest floor, CCK still allowed if any WLAN allows
it — because the stricter choice would silently lock clients out of a co-hosted WLAN
that was meant to admit them. Give a WLAN its own radio if it needs its floor enforced
exactly. Note also that the floor is enforced by making it the sole *basic* rate (a
station must support every basic rate to associate); the "advertising rates" sub-toggle
additionally trims `supported_rates`. Rate options openUF writes are stamped with an
`openuf_rates` marker on the radio section: turning the control off (the wire simply
omits every `minrate_*` key) tears down exactly the marked options, while rate options
you hand-tuned on an unmarked radio are never touched.

Minimum RSSI is a *radio* setting in the controller UI (Devices → AP → Radios), not a per-WLAN one, and the wire value is an offset from an assumed noise floor rather than a dBm figure — openUF converts it using a live noise reading. The controller signals *disable* by omitting the whole `stamgr.<n>` block from the next config push; openUF treats that as an explicit off and clears `minrssi_enabled` in UCI (the stored threshold stays parked for a later re-enable).

Max Clients sits in the same `stamgr.<n>` block (`loadbalance.status`/`loadbalance.maxsta`) and
is also per radio. openUF writes it to the radio's `wifi-device` section as `maxassoc`, which
OpenWrt turns into hostapd's `iface_max_num_sta`: one limit shared by every SSID on that radio,
as on a UniFi AP. Do not confuse it with `maxassoc` on a `wifi-iface`, which limits one SSID only.
openUF stamps the radio with `openuf_maxassoc=1` when it writes the limit. When the controller
turns the limit off, openUF deletes `maxassoc` only if that stamp is there, so a `maxassoc` you
set by hand on a radio is left alone. To check a limit is live:
`grep iface_max_num_sta /var/run/hostapd-phy*.conf`.

The reported **country code** comes from the wifi-device's UCI `country` option (the
regulatory domain OpenWrt programs), mapped best-effort from ISO alpha-2 to the numeric
code the controller expects; an absent or unrecognized regdomain falls back to 840 (US),
the value that used to be hardcoded for every deployment.

The **IoT Optimization** panel (Settings → WiFi → *WLAN* → IoT Optimization) is mostly controller-side sugar: two of its three toggles just set values the protocol already had — channel 6 on the 2.4 GHz radio, and DTIM 3 — so they need no dedicated support. "Force WiFi 4 Mode" additionally drops the WLAN's 5 GHz vap, pins WPA2, and turns off PMF, BSS Transition, proxy ARP, fast roaming and band steering; those all arrive as their ordinary keys. Note that it does *not* narrow the radio: the shared 2.4 GHz radio keeps whatever channel width it is configured for, so `htmode` is untouched.

To verify provisioned SSIDs:
```sh
uci show wireless | grep openuf_
```

To remove all provisioned SSIDs:
```sh
cd /usr/share/openuf && lua -e "dofile('ucihelper.lua').wlan_clear()"
# or simply reset-inform and re-adopt
```

### L2 hardening: BPDU and VLAN-tag drop on the SSIDs

Every full push also carries an `ebtables.*` block, the literal ebtables fragments stock
firmware replays. It amounts to two rules on every VAP:

- **BPDU drop, both ways.** Frames to the Bridge Group Address `01:80:c2:00:00:00`,
  where STP BPDUs go. With STP off (OpenWrt's default) the bridge *forwards* them, so
  without this rule a wireless client could inject BPDUs into the wired LAN.
- **VLAN-tag drop, inbound.** A wireless client may not send 802.1Q-tagged frames, so
  there is no VLAN hopping from the air.

`l2guard.lua` enforces both as nftables rules in a dedicated `bridge openuf_l2guard`
table, on the AP-mode VAP netdevs only (station and mesh interfaces are left out). The
controller's bridge-wide `--vlan-id <n>` rule is deliberately narrowed to the VAPs. On a
DSA board openUF's tagged uplink sits on the bridge itself (`br-lan.<vid>`), so a
bridge-wide tag drop would cut a tagged SSID's uplink.

The intent and the VAP list are recorded in `state.json` (`l2guard`), and the table is
rebuilt on every start. The daemon also re-reads the VAP list once a minute and rebuilds
when it changed. That covers an SSID added by a push whose `wifi reload` had not
finished yet, and wireless coming up after the daemon at boot. A factory reset
(`setdefault`, or `syswrapper.sh reset-inform`) removes the table, and so does
`option l2guard '0'` at the next start.

Needs **`kmod-nft-bridge`**: `iifname`/`oifname` in the bridge family live in
`nft_meta_bridge`. Without it every rule is rejected and openUF logs
`l2guard: nft rejected the … rule … kmod-nft-bridge`. Check with:

```sh
nft list table bridge openuf_l2guard
```

### Hairpin on SSIDs with Proxy ARP or Multicast Enhancement

OpenWrt forces `ap_isolate=1` on any BSS with `proxy_arp` or `multicast_to_unicast`
(`/usr/share/ucode/wifi/ap.uc`), whatever UCI `isolate` says. Two clients of that BSS
then reach each other only by hairpinning through the bridge. hostapd turns
`brport/hairpin_mode` on (and `proxyarp_wifi` for Proxy ARP) when it sets up the BSS.
A later reconfigure that re-adds the port to the bridge resets both flags to 0, and
nothing in OpenWrt sets them again. Same-radio clients are then cut off from each other
without any log line.

`l2guard.lua` checks every BSS in `/var/run/hostapd-<phy>.conf` once a minute (whatever the phy is called: `phy0` by default, `wl0` on the E8450) and writes a
flag back only when it has gone missing. Each correction is logged as
`l2guard: re-asserted hairpin_mode on <ifname>`. That line means the race happened. It is
not an openUF fault.

### Lock to Access Point

The controller enforces a client's lock with the MAC filter of every **other** AP (table
above). The AP the client is locked to receives nothing. Its usteer would still send the
client BSS Transition requests toward APs that refuse it, and kick it, and Roaming Assistant
would do the same, so the client would bounce. So each openUF AP keeps the push's lock
entries in `state.json` (`lock2ap`) and announces them to the other openUF APs
(`sibling_exchange`). Once a minute, a client that a sibling denies and this AP does not is
treated as locked here:

- **usteer:** `usteer.local.aggressiveness_mac_list` gets `<mac>,0` for it. Entries from the
  device's own usteer sections are carried over, because usteerd keeps only the last
  section's list, which is openUF's `local`. usteer reads a client's entry only when it first
  sees the client, so a changed list restarts usteer. Aggressiveness 0 stops the roam trigger
  (`roam_trigger_snr`) and band steering for that client. It does not stop `min_snr` kicks,
  load kicks or `assoc_steering`, so leave those off.
- **Roaming Assistant:** skips it.
- **Minimum RSSI:** still kicks it, as on a UniFi AP.

The log says `openuf: locked to this AP: <macs>` when the list changes. Check it with
`uci get usteer.local.aggressiveness_mac_list`, and on another AP with `uci show wireless |
grep maclist`. This only works between openUF APs: an openUF AP whose locked client's other
APs are real UniFi ones never hears of the lock.

### usteer's AP-to-AP sync stays off the air

usteerd tells the other APs what it sees by broadcasting its whole station table every
second to `255.255.255.255:16720` (or `ff02::4150` with usteer's `ipv6` option). It also
sends a short update for every MAC it has not seen before. The table lists every device
heard in a probe request over the last 120 s, so phones passing by make up most of it.
On a live two-AP site that came to 7 KB per message: five IP fragments, each copied by
Multicast Enhancement into one unicast frame per client. Every client received about
16 KB/s that only the other AP needs, which kept dozing phones awake and cost a weak
client about 1.5 % of the radio's airtime.

While openUF runs usteerd (`usteer.local.openuf_active=1`), `usteer.lua` installs the
`bridge openuf_usteer` table. Its postrouting chain drops these datagrams where they
leave through a VAP, whether this AP or the other one sent them. The later fragments carry no
UDP header, so they are matched as non-first fragments of a UDP broadcast. The other AP still
receives everything over the wired uplink. The table is rebuilt once a minute when the
VAP list changes, and removed when usteerd is stopped. It needs `kmod-nft-bridge`.
Check it with `nft list table bridge openuf_usteer`.

### Guest WLANs: the controller's guest restrictions

A WLAN the controller treats as a guest WLAN arrives with `wireless.<n>.is_guest=true`,
and the same `ebtables.*` block then carries the stock firmware's guest chains: each
guest VAP is hooked into `GUESTIN` (frames from guests) and `GUESTOUT` (frames to them),
filled from the site's guest-access settings (`allowed_subnet_<n>`,
`restricted_subnet_<n>`, `restricted_dns_enabled` / `restricted_dns_servers`).
`unifi/guest.lua` replays those rules in wire order and `guestguard.lua` builds them as
one nftables transaction in a dedicated `bridge openuf_guest` table, hooked on the guest
WLANs' VAP netdevs (found by SSID, plus their private-pre-shared-key VLAN netdevs). What
a guest gets, exactly as on a UniFi AP:

| Traffic from a guest | |
|---|---|
| DHCP (broadcast), ARP requests, EAPOL | allowed |
| DNS (UDP/TCP 53) | allowed; with **restricted DNS** on, only to the listed servers |
| Pre-authorization access (allowed subnets) | allowed, ahead of every drop |
| Post-authorization restrictions (restricted subnets), `224.0.0.0/4` | dropped |
| Other broadcasts, **all IPv6** | dropped |
| Everything else (the internet through the gateway) | allowed |

Towards guests: DHCP replies and ARP pass, other broadcasts, IPv4 multicast and IPv6 are
dropped. A device that claims `fw_caps 0x40000` gets the subnets as `ipset.*` sets
instead of inline rules; both forms are read (openUF does not claim the bit, so it gets
the inline form).

**Not implemented:**

- **The captive portal** (hotspot, vouchers, password, external portal, redirect to
  the controller). With a portal on, the controller's `GUESTIN` defaults to drop and
  the unauthorised guests are redirected. openUF has no authorisation flow, so it
  applies the restrictions above and leaves the default open: guests on a portal WLAN
  reach the internet **without seeing the portal**. The log says so at every push:
  `guest: the controller has a captive portal on for <SSID>; openUF does not implement it`.
- Allowed/restricted **hostnames** (`ALLOWED_DOMAIN_*`, `RESTRICTED_DOMAIN_IN`): on a
  UniFi AP dnsmasq fills those chains at runtime; here they stay empty.
- A **wired** guest network (`--logical-in br<n>`) — logged as not enforced.
- An SSID used by both a guest and a non-guest WLAN: the VAPs are matched by SSID and
  cannot be told apart, so it is refused and logged rather than guessed.

The restrictions and the guest VAP list are recorded in `state.json` (`guest`), rebuilt
on every start, and re-checked once a minute (a guest VAP that came up after the push).
A full push without a guest WLAN removes the table, as do a factory reset and
`option guest_isolation '0'` at the next start.

Needs **`kmod-nft-bridge`**. The table is applied all or nothing and then read back; a
refusal is logged as `guest network: nft refused the guest restrictions … NOT
restricted`, and no half-built table is left. Check with:

```sh
nft list table bridge openuf_guest
```

---

### Controller-owned bridge (`vlan_filtering` backend)

Set `option bridge_backend 'vlan_filtering'` (or leave it on `auto` on a board
whose uplink is already in a vlan-filtering bridge). From the first provisioning push on,
`netmodel.lua` realises the controller's own description of the AP's layer 2 --
`vlan.*`, `bridge.*`, `netconf.*`, `dhcpc.*` and the `switch.*` port matrix, captured in
[docs/GAP-ANALYSIS-10.6.md §4](docs/GAP-ANALYSIS-10.6.md) -- as:

| UCI section | What it is |
|---|---|
| `network.openuf_br` | the bridge (`bridge_name`, default `br-lan`) with every socket of the board, `vlan_filtering 1`, the identity MAC pinned |
| `network.openuf_bv<vid>` | one `bridge-vlan` per VLAN: the uplink carries VLAN 1 untagged and every other VLAN tagged; each downstream socket follows the `switch.*` matrix (native = `u*`, tagged = `t`, excluded = absent), or `port_default` while Port VLAN is off |
| `network.<lan_name>` | management, on `br-lan.<vid>` -- `br-lan.1`, or the **Management VLAN** -- with the pushed DHCP/static addressing written as UCI (so it survives reboots) |
| `network.openuf_v<vid>` | `proto none` on `br-lan.<vid>`, what a WLAN on that VLAN names as its network (VLAN 1 too, once management is tagged -- the controller's `br-trunk`) |

The two objections to vlan filtering above, answered:

1. **Stranding the AP.** Nothing is guessed: management is wherever the controller's
   `dhcpc`/`netconf` put it, and the uplink always carries every VLAN. And every change
   is applied with a **rollback**: the previous `/etc/config/network` is kept, and unless an
   inform succeeds within `bridge_rollback_timeout` seconds (180) it is restored and
   reloaded. A plan that lost the controller is remembered by fingerprint and not
   re-applied until the controller sends a different one (`syswrapper.sh netmodel-retry`
   forces a retry).
2. **Fighting the tagged-SSID path.** There is no tagged-SSID path to fight: this backend
   creates no `<uplink>.<vid>` sub-devices. A VAP joins `openuf_v<vid>` and netifd makes it
   a bridge port with that VLAN as its PVID.

**Takeover.** With `bridge_takeover = true` (the default) any bridge that holds one of the
board's sockets is replaced, together with its `bridge-vlan` sections. Interfaces that pointed
at it or at its VLAN sub-devices (`switch.3`) are re-pointed at `br-lan.<vid>` and their
VLANs kept in the table, so hand-made networks keep working; an L3 interface straight on a
socket (a stock `wan`) is disabled. The board's original config is saved once to
`/etc/openuf/network.pre-openuf`; `syswrapper.sh netmodel-restore` puts it back.

Trunk ports come for free (a socket can be native on one VLAN and tagged on others), and the
switch ASIC does the VLAN work, so none of the learning-off/nft-tap machinery above is used.
Wired clients are still reported per socket from the bridge FDB.

### Controller wake-up (STUN)

`stun.lua` keeps a binding to the controller's `stun_url` from a stable local port
(`stun_local_port`, 3478) and reports the address the controller saw as
`connect_request_ip`/`_port`. When the controller sends its connection request (a bare
`0x8888` STUN header), the daemon informs immediately. On 10.6 that happens for upgrades
and when a device misses a heartbeat. `option stun '0'` turns it off.

### OpenWrt upgrades through UniFi

See `openuf/src/openwrt/upgrade.lua`'s header and [openuf/contrib/asu](openuf/contrib/asu/README.md). In short:
`option upgrade_mode 'owut'` makes a controller upgrade run an attended sysupgrade of this
board, leaving openUF's own packages out of the ASU request (the package's bootstrap
reinstalls them on the new image); `option advertise_updates '1'` shows UniFi's "Upgrade available" badge while `owut check` finds
a newer build. By default the controller's catalogue version is learned from its own
upgrade commands and reported, so no stale version keeps the badge up.

### Client connection events

A UniFi AP reports every association, successful connection and departure as a separate
notification inform (`inform_as_notif: true`, `notif_reason: "event"`, a `notif_payload`
with `message_type: STA_ASSOC_TRACKER`). The controller builds a client's connection
timeline from them, and detects a roam by pairing one AP's `sta_leave` with another AP's
`association` for the same client. openUF diffs the station list between heartbeats and
sends up to eight events after each successful inform. A client that joins is an
`association` (with its RSSI, which the roaming detector needs) and a `success`; one that
leaves is a `sta_leave`, with `last_seen` in device uptime. Events queue while the
controller is unreachable (200 at most). `sta_events = false` turns them off.

Every departure carries `assoc_status`, the cause bits the controller's roaming detector
reads: `16` when openUF's Minimum RSSI kicked the client, `8192` when its Roaming Assistant
moved it (a BSS Transition request, or the forced disassociation after one), within the
last two minutes. They show in the roam records as triggered by Minimum RSSI or by Roaming
Assistant. A client that left on a BSS Transition request, before any forced
disassociation, is also reported as `sta_roam` just before its `sta_leave`; the controller
counts a roam whose left half is a `sta_roam` as seamless. openUF claims `wifi_caps2`
`0x2000` (roam topology stats) while events are on: the controller then reads `sta_roam`
and joins roams from `association` events, which carry `auth_rssi`, instead of `success`.

The `success` carries the connection's timing, which is what fills the WiFi Connectivity
view (Association, Authentication, DHCP, DNS and their latencies). The controller takes
cumulative microseconds from the client's first Authentication frame: `assoc_delta` to
association, `wpa_auth_delta` to the end of the key handshake, `ip_delta` to the DHCP ACK
and `traffic_delta` to the first DNS answer, and for an AP on firmware 6.2.1 or later it
counts a connection only when `traffic_delta` and `dns_responses` are there. openUF
measures them on the AP:

- the 802.11 steps from hostapd's ubus notifications (`auth`, `assoc`, `sta-authorized`,
  `key-mismatch`), stamped by a small ucode collector the service runs next to the daemon
  (`/usr/share/openuf/openwrt/staphase.uc`, writing `/tmp/openuf-phases.json`). It answers
  every notification with success at once: with usteer running, hostapd waits for each
  subscriber's answer to an `auth` or `assoc` and rejects the client on a non-zero one;
- the first DHCP ACK and DNS answer forwarded to each client from nftables (`table bridge
  openuf_ev`), whose timed sets date the packet by what remains of the timeout.

A connection with no DNS answer within a minute is not reported: the controller would drop
an unverified success anyway. A wrong passphrase is a `failure` (`auth_failures` when SAE
rejected it before association, `wpa_auth_failures` when the 4-way handshake did), one event
per client per minute with the count.

### Controller-managed system settings (timezone, NTP, nightly scan)

Every full `system_cfg` push also carries three blocks, which `sysconf.lua` applies, each
behind its own option (`system_timezone`, `system_ntp`, `system_cron`):

| Wire keys | Applied to | Undo trail |
|---|---|---|
| `system.timezone` (and its twin `locale.timezone`), a POSIX TZ string such as `CET-1CEST,M3.5.0,M10.5.0/3` | UCI `system.@system[0].timezone`, then `/etc/init.d/system reload`. The stale Olson `zonename` is moved aside, because it now names a different zone. The same zone in a less precise form keeps the board's string: the controller sends `GMT0BST,M3.5.0,M10.5.0` for London, an hour off OpenWrt's `GMT0BST,M3.5.0/1,M10.5.0` at each clock change | `openuf_timezone_orig` / `openuf_zonename_orig` on the same section (the first original is kept) |
| `ntpclient.status`, `ntpclient.<n>.server` | UCI `system.ntp.server` (a list, in slot order), then `/etc/init.d/sysntpd restart`. An explicit `ntpclient.status=disabled` puts the board's own list back | `openuf_ntp_orig` + the `openuf_ntp_managed` marker on `system.ntp` |
| `cron.<n>.job.<m>.schedule` / `.cmd` | A marked block in `/etc/crontabs/root` (`# openuf-cron-begin` … `# openuf-cron-end`), then `cron enable` + `restart`. Lines outside the markers are never touched. The block is removed once a push stops carrying jobs, when `system_cron` is switched off, and when the package is removed | the markers themselves |

Nothing is written when the pushed value already matches, so the identical pushes of
a steady state cost no flash writes. Malformed values (a timezone with a quote, a
server name with a space, a schedule that is not five plain fields) are logged and
refused.

**Cron runs only commands openUF provides.** The one the controller pushes today is
`syswrapper.sh 11k-scan` at `0 4 * * *`, the nightly neighbour scan. Anything else is
logged as `not a command this build provides` and never written: crond runs it as
root. The pushed `cron.<n>.user` is ignored, since that account does not exist here.

`syswrapper.sh 11k-scan` does not scan by itself. It leaves a dated request in
`/tmp/openuf-scan-request`, and the inform daemon consumes it on its next heartbeat by
making the next 802.11k beacon request due at once (with `rrm_enrichment` on): a client
sweeps and reports back, and the AP never leaves its channel. Upstream openUF answers
the same job with `iw dev <if> scan ap-force` on every radio. openUF deliberately asks a
client instead, because a measured off-channel sweep cost an associated client 12%
packet loss for the ~3 s it ran (PROTOCOL-VALIDATION, *Enriching it without scanning*). A request older than ten minutes (say, one left behind by a stopped daemon),
or dated more than a minute ahead, is discarded rather than served. You can run it by
hand:

```sh
syswrapper.sh 11k-scan
logread | grep 11k-scan   # "11k-scan requested -- asking a client for a beacon report now"
```

To take a board back from the controller's timezone, copy `openuf_timezone_orig` back
to `timezone` (`uci get system.@system[0].openuf_timezone_orig`). For NTP, copy
`openuf_ntp_orig` back to `server`, delete both stamps, and run `uci commit system`.
Switch the matching `system_*` option off first, or the controller re-applies its
values on the next full push. Three things take the marked cron block out: removing the
package, a controller *Forget* (`setdefault`) and `syswrapper.sh reset-inform`. All three
leave the timezone and NTP values in place: those are sane settings for the board either
way, and the originals stay stamped.

### Wireless uplink (mesh)

⚠️ Opt-in (`uci set openuf.main.wireless_uplink=1`), ported from yesrab/openUF and
**not yet confirmed on this project's hardware** (PROTOCOL-VALIDATION.md § Wireless uplink).

UniFi's mesh is a 4-address WDS link, not 802.11s: a parent beacons a hidden WPA2-PSK
network named `vwire-<16 hex>` with a site-wide key, and a child joins it with a 4-address
station, so the link is a transparent L2 pipe. With the option on, openUF claims
`wifi_caps` `0x1` (VWIRE) and `0x800` (MESHV3); the controller turns the device's
"mesh-connect" flag on by itself and every push then carries both ends, which openUF writes
as two `wifi-iface` sections on the 5 GHz radio:

| Section | What it is | When it is up |
|---|---|---|
| `openuf_bh_dl_<radio>` | the **downlink**: `mode ap`, `hidden 1`, `wds 1`, `psk2`, the sibling element (`vendor_elements`) | whenever the push carries it — a wired mesh-capable AP is a parent by default |
| `openuf_bh_ul_<radio>` | the **uplink**: `mode sta`, `wds 1`, same SSID and key | only while the wired uplink socket has no link |

Both join the management network (`lan`, or the `vlan_filtering` plan's management
interface), are rewritten on every push like the WLANs, carry `openuf_backhaul` and the
controller's devname (`openuf_devname`), and are kept out of the L2 hardening and guest rule
sets: a 4-address link carries other devices' frames and BPDUs by design. A push without the
`mesh.*` block (the option off again) removes both.

**The uplink policy** (`openwrt/backhaul.lua`, once per heartbeat) is wired-first. openUF
remembers the socket the gateway was last seen behind (`state.json` `backhaul_wired_port`;
the board's uplink socket until then). When that socket has had no link for two heartbeats
the station is enabled and the radio reloads; when the link is back the station is disabled
on the next heartbeat. The two uplinks are never up together: every UniFi push runs STP off,
so that would be a bridge loop. The mode in effect is `state.json` `backhaul_mode`, and
`logread -e backhaul` shows each switch. While the station is up, the radio's SSIDs follow
the parent's channel.

**What the inform reports.** While on the wireless uplink and associated, the top-level
`uplink` is the uplink VAP's name (the controller's devname, `ath4`), and that VAP's one
station is the parent's downlink BSS, its `serialno` the parent's MAC, taken from the BSS
actually joined: its sibling element in the station's scan cache, else the sibling exchange
(`sibling_exchange`, which announces every AP's BSSIDs, the hidden downlink included), and
only then the parent the last push named (`backhaul_parent`) — a child that boots straight
onto the air gets no push to name it. A downlink reports its children, each named from the bridge FDB behind its WDS
netdev intersected with the sibling APs this AP knows. Minimum RSSI, Roaming Assistant,
connection events and the Experience score never count a backhaul peer.

**Only the management network crosses the hop.** The downlink's children are parked by
hostapd on per-station netdevs (`<bss>.sta<N>`) in the management bridge, with no VLAN
membership; in the `bridges` backend the VLAN bridges ride `<uplink socket>.<vid>`, which has
no link on a wireless child, and in `vlan_filtering` the per-station netdevs join only the
bridge's default VLAN (1) — so there, with a Management VLAN set, not even management is
expected to cross (read from hostapd's and the kernel's behaviour, not observed). In the
`bridges` backend a wirelessly uplinked AP keeps its management address and informs, but its
VLAN-tagged SSIDs do not reach their networks. (yesrab/openUF's boards rode `br-lan.<vid>`,
which carried tags over the hop.)

**Turning it off** removes both sections with the next push. An AP that is on its wireless
uplink at that moment loses it: plug its cable in first.

If a child never associates, check `iw dev <station> info` says `4addr: on`, compare the two
sections' `ssid` and `key`, and see that the parent's
`/var/run/hostapd-<phy>.conf` has `wds_sta=1` for its downlink BSS.

### Config pushes that fail to apply

Every push is judged once all of its steps have run. If one raised an error (the WiFi
config, the network plan), openUF keeps reporting the **previous** `cfgversion`. The
controller only re-sends a config while the device reports a different version, and it
deduplicates identical pushes for ten minutes, so the push arrives again about ten minutes
later. After `cfg_retries` rounds the new version is echoed anyway, so a config the device
cannot apply stops cycling. `cfgversion_effective` always names the last push that applied
cleanly; the controller's "last config applied successfully" compares the two. A network
plan that is rolled back (§ Controller-owned bridge) sets `cfgversion_effective` back as well.

### Updating openUF in place

`apk upgrade` from the package feed (§ 2). From a development machine,
`sh tools/deploy.sh <dir> <ap>...` installs packages built with
`.github/scripts/sdk-build.sh` on each AP in turn, stopping at the first that does not
complete an inform.

For a test AP between packages, `sh tools/hotpatch.sh <ap>` copies this checkout's `src/`,
stripped as the package build strips it, into `/usr/share/openuf`: every `.lua` file is
compiled with the AP's own Lua first (one that does not load means nothing is replaced),
only the files that differ are replaced, the packaged originals go to
`/usr/share/openuf.pre-hotpatch` (the first time only), and the daemon is restarted and
waited on. Init scripts and `/etc/config/openuf` are left alone. `apk fix openuf` puts the
package back.

## 7. LLDP topology

`lldpd` must be running for topology announcements to work.  openUF queries `lldpctl -f json` and includes the neighbor table in each inform payload so the controller can render the upstream switch on its topology map.

Check LLDP status:
```sh
lldpctl          # show neighbors
lldpctl -f json  # JSON output (what openUF reads)
```

If `lldpd` is absent or returns no neighbors, `lldp.lua` returns an empty table — non-fatal.

The neighbour table is included in every inform, but `lldpctl` is only re-run
once a minute rather than on every 10-second heartbeat: `lldpd` advertises on a
30-second interval, so polling it faster only cost a process spawn and a JSON
decode. A topology change — a new neighbour, or a moved cable — can therefore
take up to a minute to show up on the controller's map. An *empty* answer is
never cached, so a device that starts before `lldpd` picks its neighbours up on
the very next heartbeat.

### Point lldpd's chassis ID at the same interface as `lan_cpueth`

```sh
uci set lldpd.config.cid_interface='lan'
uci commit lldpd && /etc/init.d/lldpd restart
```

**Without this the controller cannot place the AP on its topology map**, and shows
some unrelated device (here the ISP's uplink) as the AP's Parent Device.

The reason is that two different MACs are involved. openUF identifies the device
by the MAC of `dev.conf.net.lan_cpueth`, and that is the MAC the controller
adopts it under. `lldpd`, left to itself, picks its chassis ID from whichever
interface it likes — in practice the lowest-numbered one, i.e. `eth0`. The
upstream gateway therefore learns the AP as a neighbour under a chassis ID that
does not match any adopted device, and silently declines to join the two.

Whether that bites is pure luck of the board's port naming:

| Board | `eth0` | `lan_cpueth` | Default chassis ID | Topology |
|---|---|---|---|---|
| TL-WDR3500 v1 | LAN trunk | `eth0` | matches identity | resolves by accident |
| Archer C5 v1 | unused WAN socket | `eth1` | **`eth0`, wrong** | Parent Device wrong |
| Mi Router AX3000T | DSA conduit | `wan` | **`eth0`, wrong** | Parent Device wrong |

Setting `cid_interface` to the LAN network makes the chassis ID the same MAC
openUF reports, and the controller resolves the uplink immediately — confirmed
live: an Archer C5 went from no `uplink_mac` at all to
`Cloud Gateway Ultra, port 4` on the next LLDP advertisement.

On a **DSA** board name the socket, not the network: `br-lan` covers every
socket and carries `eth0`'s MAC, so `cid_interface='lan'` reproduces the very
mismatch it is meant to fix. Use the one `lan_cpueth` names —

```sh
uci set lldpd.config.cid_interface='wan'   # the AX3000T's uplink socket
uci commit lldpd && /etc/init.d/lldpd restart
```

**openUF closes the other half of this itself.** The same two-MAC split has a second
symptom that LLDP does not cover: openUF reports its IP from the *bridge* `lan_cpueth` is
enslaved to (a bridge member carries no address of its own), so on a DSA board it announced
itself under the socket's MAC while every frame it sent, and the ARP entry for the address
it reported, carried `br-lan`'s. The gateway sees one device claiming the IP and another
using it, and raises **"IP Address Conflict — multiple devices are using the same
address"** against a network that is perfectly configured.

`ucihelper.ensure_bridge_identity` runs once at daemon start and pins the bridge's
`macaddr` to `lan_cpueth`'s MAC when — and only when — the two differ, so identity, LLDP
and management traffic all agree, the way they do on a real UniFi AP. Boards where they
already match are untouched and no reload is issued. It logs what it
pinned; adoption is keyed on `lan_cpueth`'s MAC, which it never changes.

> If the board takes its management address by **DHCP**, the new L2 identity means a new
> lease and possibly a new address. The adoption survives and openUF reports the new
> address on the next inform, but expect the change.

Verify the two agree:
```sh
lldpcli show chassis | grep ChassisID          # lldpd's identity
grep -o '"mac":"[^"]*"' /etc/openuf/state.json # openUF's identity
```

---

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| An Auto radio never picks a DFS channel, or avoids channels nobody excluded | `uci show wireless.<radio>` — `openuf_acs_dfs=1` means the site's 5 GHz DFS switch is off (Radio AI; a site that never stored a choice sends off), `openuf_channels=1` with a `channels` list means the site excludes channels. No stamp: the value was set by hand or by a board policy in `local.lua`. `grep chanlist /var/run/hostapd-<phy>.conf` shows what hostapd got |
| Device doesn't appear in UniFi Discover | `announce.lua` not running, or UDP port 10001 blocked |
| Controller shows device as "Disconnected" | `inform.lua` not running, or wrong `inform_url` |
| Adoption fails with SSH error | SSH not reachable from controller, or root password not set — run `passwd root` on the device, or switch on the adoption account (`uci set openuf.main.ssh_adopt=1 && uci commit openuf`) |
| Device stays stuck at "Adopting" forever | No AES-GCM backend — `lua-openssl` missing or built without AEAD support. The CLI `openssl-util` fallback is CBC-only and will not work (see § 1) |
| Controller rejects device ("firmware incompatible") | Regenerate `unifi/catalog.lua` with `--fw` (§ 3); openUF also learns the version from the controller's upgrade commands |
| hostapd fails: "unknown configuration item 'bss_transition'" | A `wpad-basic-*` build is installed. Swap it for the full build in one transaction: `apk add wpad-mbedtls '!wpad-basic-mbedtls'` (a plain `apk add wpad-wolfssl` conflicts with the basic build and installs nothing), then `/etc/init.d/wpad restart` |
| openUF does not start; `logread` says "not starting: /usr/sbin/hostapd has no 802.11v" | Deliberate: with a `wpad-basic-*` build every controller-pushed WLAN would take its radio down, so the init script refuses and the device's own WiFi keeps working. Swap in a full build as in the row above, then `/etc/init.d/openuf start` |
| An Enhanced Open WLAN is missing from the AP, or a transition one is plain open | The radio does not claim `radio_caps2` bit `0x8`. Check `hostapd -vowe; echo $?` (must print 0; `wpad-basic-*` or `-mini` builds may lack OWE) and that `/usr/share/ucode/wifi/hostapd.uc` exists and mentions `owe_transition` (OpenWrt 25.12). Force Provision after fixing it |
| A WLAN with Private Pre-Shared Keys is missing, or a key does not work | Missing: openUF does not claim `wifi_caps` bit `0x100000` (the controller logs "PPSK is not supported … will be skipped"). `grep -c vlanid= /usr/share/ucode/wifi/ap.uc` and `grep -c "from wpa_psk_file" /usr/sbin/hostapd` must both be non-zero. A VLAN key does not work: `uci show wireless \| grep psk` should list it, `cat /var/run/hostapd-<ifname>.psk` should have its `vlanid=` line, and `logread \| grep "from wpa_psk_file"` shows the VLAN hostapd assigned. openUF logs a key it left out because the VLAN had no network |
| A power-saving client (phone, IoT) drains its battery faster after adoption, or a 2.4 GHz scan shows the AP without a country | The controller's own defaults: **U-APSD** and **802.11d** are off in a new UniFi WLAN (wlanconf `uapsd_enabled`, `country_beacon`), and openUF applies them (`uapsd '0'` on the section, `country_ie '0'` on the 2.4 GHz radio). Turn them on in the WLAN's settings. 802.11d stays on on 5/6 GHz regardless, while 802.11h is on |
| A WPA-Enterprise WLAN is missing | `logread -e openuf` / `/var/log/openuf.log` says why: "no usable RADIUS server on the wire" means the WLAN has no RADIUS profile in the controller, or every server in it lacks an IP or secret (the controller drops those). A RADIUS MAC authentication format other than the default skips the WLAN too |
| The UniFi app asks for a username/password on an AP's detail page and calls it standalone | `discovery_replies` is on: the app found the AP through its discovery reply, which lacks the console and device IDs a real adopted AP sends. `uci set openuf.main.discovery_replies=0 && uci commit openuf && /etc/init.d/openuf restart` |
| A RADIUS CoA/Disconnect gets no answer | `netstat -lnu \| grep 3799` must show the dispatcher (it needs `/etc/openuf/das.json`, written when the controller's RADIUS profile has CoA and accounting on). The request must come from one of the WLAN's accounting servers. `grep radius_das /var/run/hostapd-*.conf` shows the WLAN's listener; its secret is the first accounting server's |
| WPA-Enterprise clients are rejected | Check `/var/run/hostapd-<phy>.conf` for `auth_server_addr`/`auth_server_shared_secret`, and that the RADIUS server lists this AP's address as a client. A server left out for a different port or secret is logged ("RADIUS authentication server <k> left out"). With dynamic VLAN required, a VLAN this AP carries no other way is refused: give some WLAN or port that VLAN, or set the RADIUS profile's VLAN mode to optional |
| Band Steering has no effect | `usteer` not installed or not running — `/etc/init.d/usteer status` |
| Roaming Assistant never moves a weak client | Expected when no other AP hears it clearly better. Check `ubus call usteer get_client_info '{"address":"<mac>"}'`: another AP (`<ip>#hostapd.*`) on the same SSID and band needs a signal at or above the threshold and at least `roam_assist_diff_db` stronger. No remote entries at all means the usteer instances are not peering — both APs need usteer running on the same L2 network. `logread \| grep roamassist` shows every action. No `openuf_roam_assist` in `uci show wireless` at all means the controller never sent the setting |
| Log says `device Band Steering mode "equal" is not supported` | The AP's own Band Steering is set to Balance. usteer can only balance by rejecting associations, so openUF does not map it. Use Prefer 5G or the per-WLAN toggle |
| Clients are steered 2.4 → 5 GHz with Band Steering off | Check the AP's own Band Steering setting too: Prefer 5G turns it on whatever the WLANs say. usteer also runs for Roaming Assistant; with all three off openUF stops it, so something else started it. `ubus call usteer get_config` must show `band_steering_interval: 0`: any other value means usteer's default applies, and it steers. openUF writes the 0 on the next WiFi config push. Force Provision if it is missing |
| A WLAN Schedule has no effect, or switches at the wrong hour | `uci show wireless \| grep openuf_sched` shows the schedule the section carries and whether the schedule has it off. `date` must show the site's local time: the schedule follows the device clock and its timezone (`system_timezone`, NTP). A WLAN the controller disabled is never brought up by its schedule. `logread -e "WLAN schedule"` lists each switch |
| A client's Virtual Network Override has no effect | `cat /etc/openuf/macvlan-<section>.list` should list the client with its VLAN, and `grep accept_mac_file /var/run/hostapd-<phy>.conf` should name it. openUF logs an entry it left out: an open or OWE WLAN, RADIUS MAC authentication, a MAC filter that refuses the client, or a VLAN with no network on this AP. The site feature itself appears only when the gateway supports it and every AP and switch with clients claims `fw_caps` `0x80000000` |
| SNMP does not answer | `apk info -e snmpd-ssl`; `logread -e snmp`. `cat /var/run/snmpd.conf` should hold the controller's community (`com2sec`) and, for v3, a `createUser` line; v3 needs `snmpd-ssl` (the nossl build has no privacy, and openUF does not configure the user there) |
| A Hotspot 2.0 WLAN is missing | `hostapd -vhs20; echo $?` must print 0 (a full `wpad-*` build); otherwise openUF does not claim `fw_caps` `0x800000` and the controller drops the WLAN. An OSEN WLAN is skipped (logged) |
| Airtime Fairness switch does nothing | `ls /sys/kernel/debug/ieee80211/phy*/airtime_flags` must list a file per radio. Without it openUF does not claim `wifi_caps` bit `0x20` and the controller sends no `atf.*` at all (debugfs not mounted, or a kernel without `CONFIG_MAC80211_DEBUGFS`). `cat` it after a push: two flag names for on, none for off. A driver that does not schedule through mac80211 TXQs ignores the flags |
| A client shows poor WiFi Experience | The score is the worse of two terms, both read from `iw dev <ifname> station get <mac>`. **Downlink airtime**: Δ`tx duration` per Δ`tx packets` against the ideal: the client's own fixed cost per frame on a clean link (the median of its last 5 clean windows, floored at 110 µs on 2.4 GHz and 250 µs on 5/6 GHz; the floor until it has one) plus the payload at its ceiling rate. It is judged only in a window in which the driver re-sent at least 20 frames per 100 (Δ`tx retries` or Δ`tx failed`, whichever is larger): a weak or noisy link, or a power-saving client that dozes through them. A cleaner window counts as 100, because a clean link's airtime is mostly fixed per-frame cost, and mt76 can charge a station more `tx duration` than its radio transmitted. The 5 GHz floor covers an HE client's longer preamble and the RTS/CTS mt76 adds on wide channels; an HT/VHT client on 5 GHz without RTS/CTS really costs nearer 120–170 µs a frame, so for it the floor is lenient. The ceiling is the client's streams, width and top MCS from `hostapd_cli -i <ifname> all_sta`, capped by the AP's own, one MCS below the top. **Coverage**: `signal` minus the radio's noise (`iw dev <ifname> survey dump`, the `[in use]` entry, taken as at least −95 dBm): under 20 dB is below Excellent, under ~17 dB below Good. Retry and failure counters are not scored, since they mean different things per driver (see PROTOCOL-VALIDATION.md); they only decide whether a window's airtime is judged. Neither is `rx bitrate` (the uplink): it is the last frame's rate, and phones pick low uplink rates on clean links. Without `tx duration` the tx rate against the ceiling stands in, and a client with a legacy rate or no hostapd record is scored on SNR alone |
| Clients on the same radio can't reach each other (a Cast/Google Home stereo pair or speaker group falls apart, AirPlay or printers vanish) while other clients are fine | The WLAN has Proxy ARP or Multicast Enhancement on, so OpenWrt forces `ap_isolate=1`, and the radio's bridge port lost its hairpin flag in a reconfigure (§ Hairpin). `cat /sys/class/net/<ifname>/brport/hairpin_mode` must be `1` on every BSS whose `/var/run/hostapd-<phy>.conf` block has `ap_isolate=1`. openUF restores it within a minute and logs `re-asserted hairpin_mode`. On an older openUF, run `echo 1 >` on that file and on `proxyarp_wifi` |
| Idle clients score low on WiFi Experience, and every client receives the same ~16 KB/s even when nothing is using it | usteerd's broadcast sync, copied to each client by Multicast Enhancement (§ usteer's AP-to-AP sync). Compare a client's `tx bytes` in `iw dev <ifname> station dump` over 30 s across clients. `nft list table bridge openuf_usteer` must show three drop rules while usteerd runs. On an older openUF, the traffic reaches every client |
| No "Possible interference" events ever appear for an openUF AP | Expected: the controller raises them from the radio's tx-timeout and carrier-sense-timeout counters (`athstats.ast_txto`/`ast_cst`, more than 10/s over at least 5 s), and openUF has no faithful OpenWrt source for those, so it does not send them. Channel utilization and "Avg. Interference" (from `iw dev <ifname> survey dump`) are reported as usual |
| Locate does nothing | The board registered no usable status LED — set `dev.conf.led` in `/etc/openuf/local.lua` to a name from `ls /sys/class/leds` (§ 3) |
| LEDs stay dark with the LED setting on | `ls /var/run/openuf-leds.json`: present means openUF still holds them (a Locate running, or the setting still off as far as openUF knows — `grep led_enabled /etc/openuf/state.json`). Absent means they are in OpenWrt's own state: check the LED's section in `/etc/config/system` and `cat /sys/class/leds/<led>/trigger` |
| JSON decode error in controller logs | AES key mismatch — try `syswrapper.sh reset-inform` |
| `inform: parse error: ... inflate: truncated stream` | A compressed controller response arrived incomplete. One heartbeat is lost and the next retries, so an occasional line is harmless; a steady stream of them points at the link to the controller (an MTU or proxy problem), not at the device |
| Adopted device goes Offline and the log fills with `HTTP 400` | The identity MAC changed underneath the adoption — usually `dev.conf.net.lan_cpueth` now naming a different interface. openUF says so once per streak, naming the MAC it informs as. Forget the device in the controller and re-adopt, or point `lan_cpueth` back at the interface it was adopted under |
| Device adopts, reports ports and statistics, but no pushed WLAN is ever created | `libuci-lua` missing — every radio and WLAN read fails silently and `radio_table` goes out empty, so the controller has no radio to push onto. openUF says so at startup; `apk add libuci-lua` and restart |
| SSID not appearing after adoption | Check `uci show wireless`, check `loglevel` in `/var/log/openuf.log` |
| `lldp_table` empty | `lldpd` not running — run `/etc/init.d/lldpd start` |
| A wireless client shows no IP, hostname or IPv6 address | The AP knows a client's addresses only from its own caches: `cat /proc/net/arp` for the IPv4 address, `ip -6 neigh show` for the IPv6 ones (global and ULA only, link-local left out), and `/tmp/dhcp.leases` for the hostname, which exists only when this device runs the DHCP server. A bridged AP that never exchanges packets with the client has no entry, and its `sta_table` entry leaves the field out. With a UniFi OS gateway (UDM, UCG) connected in the site, the gateway sets the client's IP and its hostname wins over the AP's. Busybox `ip` lists the neighbour cache, so no extra package is needed |
| Wired clients reach LAN peers but not the gateway or internet, while WiFi clients on the same AP are fine (DSA boards) | The VLAN-SSID bridge shares the physical uplink with `br-lan`, so the switch's single hardware FDB learns the router's MAC against the tagged port. openUF sets `learning '0'` on that port to prevent it — check `bridge fdb show` for the router's MAC carrying `offload` on `<uplink>.<vid>` instead of the bare uplink, and confirm `network.openuf_brport<vid>` exists |
| Bootstrap account (`ubnt`) doesn't lock after adoption, or doesn't re-enable after a factory reset | `inform.lua` must be running for this — it's what detects the state change and runs `passwd -l`/`-u` (see § SSH prerequisite). Check `/var/log/openuf.log`. |

Log file: `/var/log/openuf.log`

For development testing without hardware, see `tools/test_controller.py`.

### Measuring what a heartbeat costs on the device

`tools/heartbeat-probe.lua` builds one real inform payload and reports every
process it spawns and every file it opens, broken down by command and path. It
builds its own payload in a throwaway process, so it is safe to run on a live,
adopted AP alongside `openuf`.

```sh
ssh root@<ap> 'cat > /tmp/heartbeat-probe.lua' < tools/heartbeat-probe.lua
ssh root@<ap> 'cd /usr/share/openuf && lua /tmp/heartbeat-probe.lua'
```

Read the **steady** figure, not the cold one: the first payload of a process
warms everything TTL-cached across heartbeats (the phy dump, the uplink lookup,
the LLDP neighbour list), so it overstates what openUF pays every ten seconds.
Add `payload` as an argument to also print the payload on stdout, which is how
you show a change is behaviour-neutral — build one before and after, and diff
them with the live counters (`time`, `uptime`, byte/packet counts, `signal`,
`tx_mcs`, `capacity`, `throughput`, `satisfaction_now`, `idletime`) scrubbed.

The probe measures the *build* half only. To confirm the daemon is still
informing, count outbound TCP connections — an AP originates almost nothing
else, so this rises once per heartbeat:

```sh
grep -A1 '^Tcp:' /proc/net/snmp | sed -n 2p | cut -d' ' -f6
```

Polling `netstat` for a connection to the controller does **not** work: a POST
is sub-second, and once-a-second sampling misses it on a perfectly healthy AP.
openUF logs nothing on success, so silence in `logread` is not evidence either.
