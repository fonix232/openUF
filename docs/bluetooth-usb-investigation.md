# Bluetooth setup over a USB adapter — investigation

> **Ported from the yesrab/openUF fork**, commit `2352928` ("Docs: investigation on
> Bluetooth setup over USB adapter and outline future steps", 2026-10-03), where it was
> *Investigation 4* in that fork's `REVERSE-ENGINEERING.md` (with backlog row 21 and a
> session-log row pointing at it). Paths and module names are adapted to this tree's layout.
>
> **This is an investigation, not a feature.** Nothing here is implemented in openUF: there
> is no Bluetooth code, no package, no config option and no capability bit for it. The fork
> parked it by choice; the plan below is gated on step 1 and nothing should be built before
> that step passes. Lab references ("AP2", the UCG Ultra) are the fork's lab, not ours.

**Status:** assessed 2026-10-03 (fork), nothing built. Not a pressing need, so parked; this
document exists so the next session starts at step 1 of the plan rather than at the
research. Nothing in this tree or in the reference repos (amd989/unifi-gateway,
jeffreykog/unifi-inform-protocol, fxkr/unifi-protocol-reverse-engineering) mentions
Bluetooth at all — it is a new track, outside the inform protocol.

## What Bluetooth is for on a real UniFi AP

Public evidence, read 2026-10-03:

- Ubiquiti's help article *Bluetooth APs in UniFi Network* names exactly two uses: adopting
  and keeping connected **Protect All-in-One Sensors** (up to 7 UP-Senses per AP; the U6
  In-Wall is on the list), and **Device Setup** — "your UniFi Network mobile app can detect
  the Bluetooth signal of *unadopted* UniFi APs, allowing you to instantly set them up with
  the tap of a button".
- The U6-IW datasheet lists "Management interfaces: Ethernet and Bluetooth". A U6IW identity
  with a Bluetooth radio is therefore consistent with the real device.
- There is **no beacon / iBeacon feature** in UniFi Network. The Purple.ai article that
  claims one is generic boilerplate ("the option might be named differently"), and no
  `ble.*` or `bluetooth.*` key has ever appeared in a push (the fork's unhandled ledger,
  `unifi/unhandled.lua`, was clean of them).

**What it would buy openUF:** the one thing that still needs a shell today. An openUF device
at a site with no local controller needs someone to log in and run `set-inform`; over
Bluetooth the installer taps the device in the app, the app hands it the inform target,
the device sends its first inform, and the **existing L3 adoption path**
(authkey delivered in the first `mgmt_cfg` while unadopted — see
[PROTOCOL-VALIDATION.md](../PROTOCOL-VALIDATION.md)) finishes the job. The controller never
learns how the inform URL got there, so nothing changes in its view after adoption.
Sensor bridging is **out of scope**: it needs a Protect console and the AP acting as a BLE
central relaying sensor data — same category as USG/USW emulation.

## What is already public

[zerotypic/unifi-ble-client](https://github.com/zerotypic/unifi-ble-client) reverse
engineered Ubiquiti's shared BLE library (`com.ubnt.ble.*`; the class names still say
AmpliFi) out of the UniFi **Protect** Android app v1.15.0 and drove a G3 Instant camera with
it. Its `doc/protocol.md` is the spec; the transport and crypto layers are fully described:

```
service UUID            per model (G3 Instant: 0c430d0c-00ef-4367-bc6f-ca7c51e6b61f; U6IW: unknown)
read  (notify)          d587c47f-ac6e-4388-a31c-e6cd380ba043        device -> host
write (with response)   9280f26c-a56f-43ea-b769-d5d732e1ac67        host -> device
discovery               BT name prefix per model + the service UUID in the advertisement

packet   2-byte length | crypto_secretbox_easy( 2-byte seq | 1-byte proto | data )
         nonce = seq (2 bytes) + 22 zero bytes; both sides start from a hard-coded DEFAULT_KEY
auth     proto 0, msgpack ["DHPK", false, 32-byte X25519 pubkey]  then  ["AUTH", "DH"]
         shared key = BLAKE2b-256( scalarmult || host_pub || device_pub )   (libsodium generichash)
api      proto 3, header part (JSON, zlib) + body part (JSON); HTTP-shaped {requestId, method, path}
         GET  /api/1.2/ap        wifi scan list (a camera thing)
         POST /api/1.2/manage    {"mgmt":{"hosts":[…],"protocol":"http","token":"…"},"wifi":{…}}
```

Caveats on that source: it is Protect-era (2020-ish), the per-model service UUID and name
prefix for any **AP** are not in it, the code mentions an alternative `"SRP"` auth type it
never saw used, and the MTU bug it works around is the camera firmware's, not something to
replicate.

## What it would change in openUF

- **Not a Lua module.** Lua on OpenWrt cannot open an `AF_BLUETOOTH` socket, and the crypto
  is libsodium's: XSalsa20-Poly1305, X25519, BLAKE2b with a 32-byte output. OpenSSL has no
  Salsa at all, and BLAKE2b-256 is a *different hash* from a truncated `blake2b512` (the
  output length is in the parameter block), which `lua-openssl` could not express anyway.
  So: a small C daemon, call it `openuf-bled`. It would sit beside `openuf/src/`, not in
  it — neither `unifi/` (no device I/O allowed there) nor `openwrt/` (Lua) fits a C binary.
- **No BlueZ.** `bluez-daemon` in the feed depends on glib2, dbus, libical, readline and
  ncurses — the end of a 16 MB board's free space (openUF's minimum, README § Supported
  hardware). Serve GATT without `bluetoothd`: the kernel mgmt socket (power, LE,
  connectable, add-advertising) plus an L2CAP socket bound to the ATT channel (CID 4),
  handling MTU exchange, Read-by-Group/Read-by-Type/Find-Information for discovery, Write
  Request and Handle Value Notification. bleno and PayPal's `gatt` did exactly this. Kernel
  side is only `kmod-bluetooth` + `kmod-btusb`.
- **Crypto with no OpenSSL involvement:** link the feed's `libsodium` (1.0.20), or vendor
  TweetNaCl plus the reference BLAKE2b — a few hundred lines, zero package dependencies.
  msgpack is needed for two fixed messages only (hand-roll it); JSON from libubox's blobmsg,
  which every device has; zlib is in base.
- **Handover costs nothing new.** On a valid `manage` the daemon runs the existing
  `syswrapper.sh set-inform <url>` (`openuf/src/hook/syswrapper.sh` → `syswrapper.lua`); the
  inform loop (`inform.lua`) is untouched. The daemon reads `adopted` from
  `/etc/openuf/state.json` (`state.lua`) and advertises **only while unadopted** — the
  mirror of the rule that the `mgmt_cfg` authkey is accepted only while unadopted.
- **Config and UI:** one option in `/etc/config/openuf` (e.g. `ble_setup`), on
  automatically when `/sys/class/bluetooth/hci0` exists, plus a `luci-app-openuf` toggle and
  a status line. The board description (`openwrt/board.lua`, from `board.json`) stays
  untouched — a dongle is not board truth. The presented identity (`unifi/identity.lua`
  against `unifi/catalog.lua`) probably stays untouched too — whether a real U6IW reports a
  Bluetooth field in its inform is unknown and is a short grep of the controller jar
  ([PROTOCOL-VALIDATION § Decompiling the controller](../PROTOCOL-VALIDATION.md#decompiling-the-controller)).
- **Packaging stops being arch-independent.** All three packages (`openuf`,
  `luci-app-openuf`, `luci-theme-openuf`) are `PKGARCH:=all` today; a C daemon is the first
  per-target artefact. Keep it its own package (`openuf-ble`, depending on `kmod-bluetooth`
  and `kmod-btusb`) so the base stays `all`, and grow the feed/release matrix to the targets
  shipped for.
- **Hardware fit.** The fork found USB on its JioRouter AX6000 boards (`&ssusb` is `okay`
  in the common dtsi) and on several swconfig boards this tree no longer supports, and
  **none on the Xiaomi AX3000T** — which is one of this tree's known-working boards. Checked
  here on 2026-10-04: the **Linksys E8450** (MT7622) has its xHCI controller enabled
  (`usb@1a0c0000` `okay`, a USB 2.0 and a USB 3.0 root hub, `xhci_mtk_hcd` loaded), so a
  dongle is an option there. The **Netgear WAX220** (MT7986B) has no Bluetooth at all: none in
  the SoC, no module on the board (no device-tree node, no Bluetooth power/reset GPIO, nothing
  in Netgear's datasheet, which lists one Ethernet port and a reset button), and its USB
  controller and the two spare UARTs are disabled in the device tree with no USB port fitted.
  USB on the other boards in README § Supported hardware has not been checked. OpenWrt builds
  `btusb` with Realtek and MediaTek firmware loading **on** and Broadcom **off**, so: CSR
  4.0 dongles (no firmware; beware the fake CSR clones with broken LE, the kernel has a
  quirk list) or RTL8761B with the `rtl8761b-firmware` package. Keep the dongle off a USB 3
  port next to the 2.4 GHz antennas.
- **Security model is the unadopted-device model, nothing better.** `DEFAULT_KEY` is
  public, so the Diffie-Hellman exchange is encrypted but **unauthenticated**: anyone in
  range with the app can point an unadopted device at their controller — exactly the trust
  level of `ubnt`/`ubnt` SSH on an unadopted real AP. Rules for the daemon: accept `manage`
  only while unadopted, serve no other endpoint, never put a PSK or an authkey on the air,
  go silent the moment the device is adopted.

## Plan (in order, cheapest first)

1. **Decompile the UniFi Network Android app** (`com.ubnt.easyunifi`) and confirm its
   Bluetooth client is the same library. Pull the AP entries: Bluetooth name prefix and
   service UUID for U6IW (and the other identities in `unifi/catalog.lua`), the AP-shaped
   `manage` payload, any device-info `GET` the app issues before offering adoption, and
   whether `"SRP"` is used for APs now. (The fork suggested jadx; mind the warning in
   PROTOCOL-VALIDATION § Decompiling the controller that jadx silently drops large method
   bodies — use CFR where a method matters.) **This is the gate: nothing is built until it
   passes.**
2. **Build the daemon against a USB-capable test AP with a dongle.** The real app is the
   oracle, the way the controller is for inform: is the device listed → does auth complete →
   does `manage` land and `set-inform` fire.
3. **Watch the handover end to end** against a real controller: first inform → authkey in
   `mgmt_cfg` → Connected. Then the factory-reset round trip (`reset-inform` must make it
   advertise again).
4. **Integrate and document:** init script (start only with an adapter and the option on),
   LuCI toggle, a README capability row, a USAGE section, and the evidence into
   PROTOCOL-VALIDATION under the confirmed-live rule.

## Open questions

- What `mgmt.token` means to a **Network** controller. In the camera flow it is a Protect
  NVR token the app fetched from the console; for an AP it may be nothing openUF needs, or
  the thing that lets the controller skip the "pending adoption" click. Step 1 answers it.
- How `hosts` + `protocol` become an inform URL (port 8080? `/inform` path implied?).
- Does a real AP keep advertising after adoption (with an "adopted" flag), or stop? The
  help article says *unadopted*; stopping is the safe default until a real one is observed.
- Does the app take the AP's identity MAC from the API or from the BD_ADDR? A dongle's
  address has nothing to do with the identity MAC `openwrt/board.lua` chooses.
- Does a real U6IW's inform carry a Bluetooth field the controller shows anywhere?

## Do not

- Reach for `bluez-daemon`/`bluetoothd`, even "just to prototype": its dependency set does
  not fit 16 MB boards and the raw-socket path is the proven one anyway.
- Try to do the crypto in Lua or through OpenSSL — see above, it is not a matter of effort.
- Buy Broadcom USB dongles for this; OpenWrt's `btusb` has their firmware patching off.
- Claim any capability bit for this. Nothing on the inform side is involved.
- Write a line of the daemon before step 1 has confirmed the Network app's protocol.

## Sources

[Bluetooth APs in UniFi Network](https://help.ui.com/hc/en-us/articles/10000263945111-Bluetooth-APs-in-UniFi-Network) ·
[U6-IW datasheet](https://dl.ui.com/ds/u6-iw_ds) ·
[zerotypic/unifi-ble-client](https://github.com/zerotypic/unifi-ble-client) and its
[protocol.md](https://github.com/zerotypic/unifi-ble-client/blob/main/doc/protocol.md) ·
[Purple.ai "Configure BLE on Ubiquiti Networks APs"](https://support.purple.ai/hc/en-gb/articles/12802080728989-Configure-BLE-on-Ubiquiti-Networks-APs) (ruled out) ·
OpenWrt `package/kernel/linux/modules/bluetooth.mk`, `packages/utils/bluez/Makefile`,
`packages/libs/libsodium/Makefile` (read by the fork from local checkouts, 2026-10-03).
