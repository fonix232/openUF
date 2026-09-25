# Building OpenWrt images with openUF

Three ways to get openUF into an image, all built from the same two files:

- `packages.txt`, the packages openUF needs, including AES-GCM (`lua-openssl`), which
  a 10.x controller requires.
- `openuf-firstboot.sh`, the first-boot (uci-defaults) script. Edit its **Settings**
  block before you build.

| Where | What to do |
|---|---|
| [firmware-selector](https://firmware-selector.openwrt.org) | Pick the device, open **Customize installed packages and/or first boot script**, append `packages.txt` (space-separated) to the package list, paste `openuf-firstboot.sh` into **Script to run on first boot**, then **Request build**. |
| `owut` on a running device | `owut upgrade -a "$(grep -v '^#' packages.txt \| xargs)" -I openuf-firstboot.sh`. owut keeps everything else that is already installed. |
| ASU API, scripted | `./asu-build.py --from-device root@<ap> --inform-url http://<controller>:8080/inform`. This reads target, profile and version from the device, fills in the settings and prints the image URLs. Add `--dry-run` to see the request. |
| ImageBuilder | `PACKAGES="$(grep -v '^#' packages.txt \| xargs)"`, with the script at `files/etc/uci-defaults/99-openuf`. |

## What happens on the device

1. **First boot.** The script writes `/etc/openuf/bootstrap.{conf,sh}` and
   enables `/etc/init.d/openuf-bootstrap`. It puts both, plus openUF's state, on the
   sysupgrade keep-list. If owut is present, it registers the packages so future
   `owut upgrade` builds keep them. This part runs before the network is up.
2. **Bootstrap.** Once there is a route and DNS, the service downloads openUF (the
   latest release of `OPENUF_REPO` unless you pinned a tag, branch or mirror). It
   checks the sha256 against the pin, or against the release's published `.sha256`.
   It then runs `install.sh install` and, on a first install only, applies the
   settings:
   - `MODELMAP` (`auto` derives the ports, uplink, identity MAC and LED from
     `/etc/board.json`);
   - `INFORM_URL`;
   - `BRIDGE_BACKEND`;
   - `L2_ANNOUNCE`.

   It also points lldpd's chassis id at the management bridge and starts openUF.
3. **Every later image.** An `owut upgrade`, or a `sysupgrade` that keeps settings,
   restores `/etc/openuf/` (`state.json`, meaning adoption and authkey, plus
   `modelmap-auto.json` and the bootstrap) and `conf.lua`. The bootstrap then
   reinstalls the code on the image's first boot. The AP comes back **still adopted**,
   with the same port numbering and identity MAC. You don't need to re-adopt.

A **fresh flash that does not keep settings** starts over: the image needs the script
again, and the controller sees a new, pending device.

## Settings worth thinking about

- **`INFORM_URL`.** Set it for L3 adoption, where the device informs directly and
  the controller skips SSH. Leave it empty to rely on L2 discovery (`L2_ANNOUNCE=1`,
  in which case the controller adopts over SSH). Hostnames work: openUF sends
  `inform_ip`.
- **`BRIDGE_BACKEND=vlan_filtering`.** The controller then owns the AP's bridge. On
  the first provisioning push, any bridge that holds the board's sockets is replaced
  by one VLAN-filtering `br-lan`. It carries management (including a Management
  VLAN), the WLAN VLANs, and the per-port VLANs. Every change rolls back
  automatically if the controller is unreachable 180 s after it is applied.
  `auto` picks this whenever the uplink is already in a VLAN-filtering bridge.
- **`OPENUF_REF`.** Pin a tag for reproducible images. With `latest`, whatever is
  released on the day of the first boot gets installed.

## Requirements

- An OpenWrt release with `apk` or `opkg` and a DSA or swconfig board. `MODELMAP=auto`
  covers DSA boards; swconfig boards need a map from `openuf/modelmap/`.
- Roughly 5 MB free on the overlay, or build the packages into the image as above.
  `lua-openssl` pulls in `libopenssl3`.
- The controller must be reachable from the AP's management network.
