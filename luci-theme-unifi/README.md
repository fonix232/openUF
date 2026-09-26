# luci-theme-unifi

A LuCI theme with the look and feel of the UniFi Network Application 10.x, for
OpenWrt 25.12 and later. It lives next to openUF because the two go well
together: an access point that the UniFi controller already treats as one of
its own can now look like one when you open its web interface too. The theme
itself has no dependency on openUF and works on any OpenWrt device with LuCI.

<!-- screenshots -->

## What it looks like

The layout copies UniFi Network's:

| UniFi Network | luci-theme-unifi |
|---|---|
| App bar: console name with a status dot, the *Network* app tab, the UniFi wordmark, theme toggle and avatar | App bar: hostname with a status dot, the LuCI mode as the app tab, the distribution name, LuCI's indicators (*Unsaved Changes*, *Refreshing*), the colour-scheme toggle, and an avatar menu with *Log out* |
| Icon rail down the left | LuCI's top-level categories (Status, System, Services, Network, VPN, Statistics...) as icons, with a flyout of each category's pages on hover; the rail expands to show labels |
| Settings' secondary column | The active category's pages as a list, collapsible |
| Underlined tabs | LuCI's third-level pages and in-form tabs |
| White cards on a pale canvas, label/value rows | Every LuCI section, the status tables |
| Outlined blue secondary buttons, solid blue primary, toggles | LuCI's button classes; on/off settings (LuCI *Flags*) are drawn as switches |

It covers the core LuCI pages, **luci-mod-dashboard** and **luci-app-uhttpd**,
in light and dark, down to phone width, where the rail and the secondary
column become a drawer.

The router's own ports get UniFi's *Port Manager*, the port panel of a
device: a strip with a square per port, green with link (lime at Fast
Ethernet, blue from 2.5 GbE), grey without, outlined when disabled, a chevron
on the uplink and a bolt on a port giving PoE, with a legend and each port's
details on hover; under it a list of the ports with their link, speed and
duplex, the native VLAN and its network in the zone's colour, tagged VLANs and
traffic. It sits at the top of *Network → Interfaces* whichever design that
page has (choosing a port opens its bridge's VLAN settings) and can be
switched off. The dashboard gets a *Ports* card with the strip and a short
list, and the Status overview's own *Port status* is drawn the same way. It
reads DSA ports (`board.json`, netifd) and swconfig switches alike, with their
VLANs from `bridge-vlan` or `switch_vlan`; the code is
`htdocs/luci-static/resources/view/unifi/ports.js`, reusable by any view.

### Network designs

*Network → Interfaces* and *Network → Wireless* each come in three designs,
chosen independently (Interfaces as a list and Wireless as cards, say):

- **Device list** (`list`, the default): a compact row per interface, device
  or wireless network, as UniFi lists devices and clients: a state dot, the
  name in bold, aligned columns under titles, row actions as icons on hover.
- **Settings list** (`settings`): UniFi's *Settings → Networks* and *WiFi*: a
  card per list with *Create New* at its top right, a line per entry with its
  facts as chips (protocol, zone, security, band, channel) and quiet icon
  actions.
- **Device cards** (`cards`): a card per interface or radio like UniFi's
  device panel: an icon on a tile, a status chip, label/value rows and the
  traffic as a split bar.

### Settings

*System → UniFi Theme* (also *Theme settings* in the avatar menu) holds the
theme's own settings, each choice a card with a small drawing of it:

| Setting | UCI (in `/etc/config/luci`) | Values |
|---|---|---|
| Interfaces layout | `luci.unifi.interfaces` | `list` (default), `settings`, `cards` |
| Wireless layout | `luci.unifi.wireless` | `list` (default), `settings`, `cards` |
| Port Manager on Interfaces | `luci.unifi.port_manager` | `1` (default), `0` |
| Colour scheme | `luci.main.mediaurlbase` | `/luci-static/unifi` (follow the system), `/luci-static/unifi-light`, `/luci-static/unifi-dark` |

*Save & Apply* reloads the page, and every page reads the settings as it
loads, so a change shows at once. From a shell, `uci set
luci.unifi.wireless=cards && uci commit luci` does the same. The package's
uci-defaults hook adds the `unifi` section (type `internal`) with the defaults
where it is missing and leaves existing choices alone.

The colour scheme is also the three entries under *System → System →
Language and Style*:

- **UniFi** follows the browser's colour scheme, and the button in the app bar
  cycles *follow system → light → dark*; the choice is remembered per browser.
- **UniFiLight** and **UniFiDark** pin one scheme for everybody and hide the
  button.

## Install

### From the openUF feed (OpenWrt 25.12 and later)

```sh
wget -O /etc/apk/keys/openuf.pem https://fonix232.github.io/openUF/openuf.pem
apk add -X https://fonix232.github.io/openUF/apk/packages.adb luci-theme-unifi
```

Installing selects the theme; `apk del luci-theme-unifi` switches LuCI back to
Bootstrap. The package is architecture-independent, and needs only
`luci-base`: it works with or without openUF.

**Updates and firmware upgrades.** With openUF installed, its package already
lists the feed, so `apk upgrade` updates the theme too, and after a firmware
upgrade that keeps settings openUF's bootstrap reinstalls the theme along with
itself (and its owut integration leaves the theme out of the ASU image
request, which the ASU server could not build). Without openUF, add the feed to
your own feed list so `apk upgrade` sees it:

```sh
echo https://fonix232.github.io/openUF/apk/packages.adb >> /etc/apk/repositories.d/customfeeds.list
```

and reinstall the theme after a firmware upgrade (`apk update && apk add
luci-theme-unifi`); until then LuCI falls back to Bootstrap on its own.

### Building it

The theme is a package in openUF's feed. In a buildroot or SDK with the feed
added (see the top-level README), `make package/luci-theme-unifi/compile`;
`.github/scripts/sdk-build.sh` builds it with openUF's other packages inside
the official SDK container, which is what the feed's CI publishes.

### Straight from a checkout

To try changes on a device without building a package, `install.sh` copies
the files over SSH (it needs `tar` on both ends, which every OpenWrt has):

```sh
sh luci-theme-unifi/install.sh root@192.168.1.1
sh luci-theme-unifi/install.sh --uninstall root@192.168.1.1
```

Run on the device itself, it installs locally. It does what the package's
post-install would: unpacks the files, registers the three theme entries,
selects UniFi on a first install, and drops LuCI's caches. Do not mix it with
the package on one device; `apk del` would not know about files it did not
install.

## Testing

`test/run.sh` needs only Docker and Node with Playwright:

```sh
sh luci-theme-unifi/test/run.sh
```

It boots the official `openwrt/rootfs` image (which ships LuCI, uhttpd and
rpcd, so nothing comes from the package feeds), adds luci-mod-dashboard,
luci-app-uhttpd and luci-app-usteer from LuCI's sources (with a fake usteer
daemon, `test/fixtures/usteer.uc`) and a two-radio wireless config so the
Wireless pages have something to show, gives it switch ports
(`test/add-ports.sh`: veth pairs lan1-lan4 and wan, made from the host with
`nsenter`, some with link and some without, in a VLAN-filtering `br-lan`;
`UF_PORTS=0` leaves them out), and installs the theme: this checkout via
`install.sh`, or, with `UF_APK` naming a built `.apk`, the package via `apk`,
which is how the feed's CI tests exactly what it publishes. Then it drives
LuCI in headless Chromium: it signs in, visits every page the menu offers,
and fails on any script error, failed asset, page that never finishes
loading, or layout wider than the window, and checks that the port panel
shows the five ports, with and without link. It then saves designs on *System
→ UniFi Theme* until each has been on Interfaces and on Wireless, and checks
both pages in each, wide and at phone width: only that design's stylesheet
loaded, its script's marks on LuCI's rows, no sideways scroll, and the Port
Manager there, or gone once switched off. Screenshots of the main views,
in light, dark and at phone width, land in `test/out/`. It then walks the
menu again with the CSS that only Chromium ships (`field-sizing`,
`scroll-initial-target`, scroll-driven animations, `scrollbar-color`) taken
out of `cascade.css`, as Firefox and Safari see it, so the fallbacks for them
are checked too (`test/compat.cjs`; `UF_COMPAT=0` skips it).

`sh test/run.sh --setup` leaves the container running instead, and
`test/shoot.cjs` takes full-page screenshots of any pages you name, which is
the loop to work on the theme in:

```sh
UF_PORT=8080 sh test/run.sh --setup
# edit, then
UF_REMOTE_SHELL="docker exec -i" sh install.sh luci-theme-unifi-test
NODE_PATH=$(npm root -g) node test/shoot.cjs --schemes light,dark,phone admin/network/firewall
```

## Where things live

| Path | What |
|---|---|
| `ucode/template/themes/unifi/header.ut` | The page frame. Reads `luci.unifi`, puts the choices on `<html>` (`data-uf-interfaces`, `data-uf-wireless`, `data-uf-port-manager`; anything unknown reads as the default) and, on Interfaces or Wireless, links that page's design stylesheet after `cascade.css` |
| `htdocs/luci-static/unifi/cascade.css` | Everything shared: the tokens and components (the base), then a section per page (`/* ==== page: NAME ==== */`); `network` there holds only what Routing, DHCP, DNS and Diagnostics need |
| `htdocs/luci-static/unifi/network/interfaces-DESIGN.css`, `wireless-DESIGN.css` | A design, one page each: the interface list, the Devices and global tabs and the interface, device and bridge VLAN dialogs; or the radios, their networks, the associated stations and the wireless and scan dialogs |
| `htdocs/luci-static/resources/view/unifi/network/interfaces-DESIGN.js`, `wireless-DESIGN.js` | Each design's script: it only marks LuCI's nodes (which fact a row holds, column titles, a state) for its stylesheet, again after every redraw. `menu-unifi.js` loads the chosen one and calls its `enhance()`; without it the page keeps LuCI's rows |
| `htdocs/luci-static/resources/menu-unifi.js` | Navigation (app bar, rail, secondary column, tabs), the design loader, and the Port Manager card above the Interfaces view |
| `htdocs/luci-static/resources/view/unifi/ports.js` | The port model (DSA and swconfig) and the strip and list |
| `htdocs/luci-static/resources/view/dashboard/include/25_ports.js` | The dashboard's Ports card |
| `htdocs/luci-static/resources/view/unifi/settings.js` | *System → UniFi Theme*; its menu entry is `root/usr/share/luci/menu.d/luci-theme-unifi.json` |
| `root/usr/share/rpcd/acl.d/luci-theme-unifi.json` | What the port panel reads, and the settings page's access to `luci` |
| `root/etc/uci-defaults/30_luci-theme-unifi` | Registers the three theme entries and the settings' defaults |

A new design is a pair of stylesheets and a pair of scripts under those
names, its name in `header.ut`'s list, and a card on the settings page.

## For LuCI application authors

The palette is a set of `--uf-*` custom properties on `:root`, redefined under
`:root[data-darkmode="true"]`, the same attribute Bootstrap uses, so styles that
already key off it keep working. Bootstrap's own variables
(`--background-color-high`, `--text-color-medium`, `--primary-color-high`,
`--success-color-high`...) are mapped onto the palette, so applications that
style themselves with them follow this theme's colours in both schemes.

## Not affiliated with Ubiquiti

UniFi is a trademark of Ubiquiti Inc. This theme is an independent recreation
of a visual style in CSS; it contains no Ubiquiti code, fonts, logos or
images. The fonts are your system's own: it asks for *UI Sans* and *Inter*
first, so a machine that has either installed gets the closest match.

## License

Apache-2.0, like LuCI and the Bootstrap theme whose template structure and
selector coverage it follows. The rest of openUF is MIT.
