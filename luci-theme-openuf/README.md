# luci-theme-openuf

openUF's LuCI theme, inspired by the look of the UniFi Network Application
10.x, for OpenWrt 25.12 and later. It lives next to openUF because the two go well
together: an access point that the UniFi controller already treats as one of
its own can now look like one when you open its web interface too. The theme
itself has no dependency on openUF and works on any OpenWrt device with LuCI.

<!-- screenshots -->

## What it looks like

The layout copies UniFi Network's:

| UniFi Network | luci-theme-openuf |
|---|---|
| App bar: console name with a status dot, the *Network* app tab, the UniFi wordmark, theme toggle and avatar | App bar: hostname with a status dot, the LuCI mode as the app tab, the distribution name, LuCI's indicators (*Unsaved Changes*, *Refreshing*), the colour-scheme toggle, and an avatar menu with *Log out* |
| Icon rail down the left | LuCI's top-level categories (Status, System, Services, Network, VPN, Statistics...) as icons, and at its foot a power button whose menu, opened by a click, reboots the device, resets it to its defaults or leads to *Backup / Flash Firmware*, each only where the user may; the rail expands to show labels |
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
switched off; on a phone the list folds away behind *Details*, leaving the
squares. The dashboard gets a *Ports* card with the strip and a short
list, and the Status overview's own *Port status* is drawn the same way. It
reads DSA ports (`board.json`, netifd) and swconfig switches alike, with their
VLANs from `bridge-vlan` or `switch_vlan`; the code is
`htdocs/luci-static/resources/view/openuf-theme/ports.js`, reusable by any view.

### The dashboard's system resources

luci-mod-dashboard was reworked in September 2026 (LuCI master and the 25.12
branch); 24.10 and older 25.12 feeds still ship the dashboard from before.
The theme styles both, and they show the router's resources differently:

- **Reworked** (a row of figures, live charts, detail tabs): *CPU usage* and
  *Memory* figures (a *Load average* one can be added under *Layout*), the
  *System load* chart (CPU and memory over five minutes), and the
  *Resources* tab (load, CPU per core, memory used, buffered, cached, swap).
  It shows no storage: disk and temp space are on *Status → Overview*
  (*Storage*, beside its *Memory* bars).
- **Before the rework** (Internet, System, DHCP and Wireless cards): no CPU,
  memory or storage at all; they were only ever on *Status → Overview*. The
  theme adds a *System resources* card under Internet and System: CPU usage
  (the busy share between two refreshes, from `/proc/stat`), load average,
  memory used (what the kernel cannot reclaim, as the reworked dashboard
  counts it) with buffers and cache, swap where there is any, and disk and
  temp space as *Status → Overview* shows them. The reworked dashboard never
  shows it, having its own.

Like the *Ports* card, the *System resources* card shows only under this
theme.

### System and Kernel Log

*Status → System Log* and *Kernel Log* show the log a row per line instead of
LuCI's text box: the time, the severity as a chip (the facility too, in the
System Log), the process and the message, red for errors, orange for
warnings, blue for notices and grey for debug, the rows of errors and
warnings tinted, and a count of each under LuCI's filters, which keep working
as they are. New lines are added as LuCI polls, the end of the log stays in
view if it was, a copy across rows gives the log's own lines, and *Raw*
brings LuCI's text box back.

### Switch/VLAN config

*Network → Switch/VLAN config* is the theme's copy of LuCI's page (added to
luci-mod-network in May 2026), in its place: the same port tiles, VLAN rows
and labels, on a bridge with VLAN filtering. LuCI's own page refuses a bridge
with anything but Ethernet or DSA ports in it, which is every VLAN-aware bridge
on an access point, where netifd puts each SSID in the bridge with its
network's VLAN. This copy leaves wireless members out of the ports instead,
names them under the description, and never changes them: their VLAN is set
on their wireless network. Bridges with other virtual members (tunnels, VLAN
sub-interfaces) are still refused. The page appears where LuCI's would, and
also on LuCI builds without it.

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

*System → openUF Theme* (also *Theme settings* in the avatar menu) holds the
theme's own settings, each choice a card with a small drawing of it:

| Setting | UCI (in `/etc/config/luci`) | Values |
|---|---|---|
| Interfaces layout | `luci.openuf_theme.interfaces` | `list` (default), `settings`, `cards` |
| Wireless layout | `luci.openuf_theme.wireless` | `list` (default), `settings`, `cards` |
| Port Manager on Interfaces | `luci.openuf_theme.port_manager` | `1` (default), `0` |
| Colour scheme | `luci.main.mediaurlbase` | `/luci-static/openuf` (follow the system), `/luci-static/openuf-light`, `/luci-static/openuf-dark` |

*Save & Apply* reloads the page, and every page reads the settings as it
loads, so a change shows at once. From a shell, `uci set
luci.openuf_theme.wireless=cards && uci commit luci` does the same. The package's
uci-defaults hook adds the `openuf_theme` section (type `internal`) with the
defaults where it is missing and leaves existing choices alone.

The colour scheme is also the three entries under *System → System →
Language and Style*:

- **openUF** follows the browser's colour scheme, and the button in the app bar
  cycles *follow system → light → dark*; the choice is remembered per browser.
- **openUFLight** and **openUFDark** pin one scheme for everybody and hide the
  button.

## Install

### From the openUF feed (OpenWrt 25.12 and later)

```sh
wget -O /etc/apk/keys/openuf.pem https://fonix232.github.io/openUF/openuf.pem
apk add -X https://fonix232.github.io/openUF/apk/packages.adb luci-theme-openuf
```

Installing selects the theme; `apk del luci-theme-openuf` switches LuCI back to
Bootstrap. The package is architecture-independent, and needs only
`luci-base`: it works with or without openUF.

**Updates and firmware upgrades.** With openUF installed, its package already
lists the feed, so `apk upgrade` updates the theme too. Without openUF, add the
feed to your own feed list so `apk upgrade` sees it:

```sh
echo https://fonix232.github.io/openUF/apk/packages.adb >> /etc/apk/repositories.d/customfeeds.list
```

A firmware upgrade replaces the image, and the theme with it: reinstall it
afterwards (`apk update && apk add luci-theme-openuf`); until then LuCI falls
back to Bootstrap on its own. When you run `owut upgrade` by hand, leave it out
of the image request (`-r luci-theme-openuf`), as the ASU server cannot build
packages from this feed.

### Building it

The stylesheets are written in SCSS under `scss/` and compiled with Dart Sass
into `htdocs/luci-static/openuf/` (compressed). The compiled files are
committed, so the package itself builds without Node. After changing
`scss/`, rebuild them and commit both; CI fails when they differ:

```sh
cd luci-theme-openuf && npm ci && npm run build   # or: npm run watch
```

The theme is a package in openUF's feed. In a buildroot or SDK with the feed
added (see the top-level README), `make package/luci-theme-openuf/compile`;
`.github/scripts/sdk-build.sh` builds it with openUF's other packages inside
the official SDK container, which is what the feed's CI publishes.

### Straight from a checkout

To try changes on a device without building a package, `install.sh` copies
the files over SSH (it needs `tar` on both ends, which every OpenWrt has):

```sh
sh luci-theme-openuf/install.sh root@192.168.1.1
sh luci-theme-openuf/install.sh --uninstall root@192.168.1.1
```

Run on the device itself, it installs locally. It does what the package's
post-install would: unpacks the files, registers the three theme entries,
selects openUF on a first install, and drops LuCI's caches. Do not mix it with
the package on one device; `apk del` would not know about files it did not
install.

## Testing

`test/run.sh` needs only Docker and Node with Playwright:

```sh
sh luci-theme-openuf/test/run.sh
```

It boots the official `openwrt/rootfs` image (which ships LuCI, uhttpd and
rpcd, so nothing comes from the package feeds), adds luci-mod-dashboard,
luci-app-uhttpd and luci-app-usteer from LuCI's sources (with a fake usteer
daemon, `test/fixtures/usteer.uc`) and a two-radio wireless config so the
Wireless pages have something to show, gives it switch ports
(`test/add-ports.sh`: veth pairs lan1-lan4 and wan, made from the host with
`nsenter`, some with link and some without, in a VLAN-filtering `br-lan`
that also holds a stand-in SSID, `wl0-ap0`;
`UF_PORTS=0` leaves them out), log lines of every severity for the System and
Kernel Log (`test/add-logs.sh`, with a stand-in `dmesg` where the container
may not read the kernel's log), and installs the theme: this checkout via
`install.sh`, or, with `UF_APK` naming a built `.apk`, the package via `apk`,
which is how the feed's CI tests exactly what it publishes. Then it drives
LuCI in headless Chromium: it signs in, visits every page the menu offers,
and fails on any script error, failed asset, page that never finishes
loading, or layout wider than the window, and checks that the port panel
shows the five ports, with and without link, that *Switch/VLAN config*
shows `br-lan`'s four ports and names `wl0-ap0` without making it a port,
that the rail's power menu
opens on a click only and closes again (nothing in it is carried out), and
that the dashboard has its system resources: the reworked one's own, or,
before the rework, the theme's card, once, with a CPU figure; and that both
logs are drawn a row per line, with severities, and *Raw* brings the text
box back. It then saves
designs on *System → openUF Theme* until each has been on Interfaces and on
Wireless, and checks both pages in each, wide and at phone width: only that
design's stylesheet loaded, its script's marks on LuCI's rows, no sideways
scroll, and the Port
Manager there, or gone once switched off. Screenshots of the main views,
in light, dark and at phone width, land in `test/out/`. It then walks the
menu again with the CSS that only Chromium ships (`field-sizing`,
`scroll-initial-target`, scroll-driven animations, `scrollbar-color`) taken
out of the stylesheets, as Firefox and Safari see it, so the fallbacks for them
are checked too (`test/compat.cjs`; `UF_COMPAT=0` skips it).

CI runs it three times, on what devices run:

| Target | `OPENWRT_IMAGE` | `LUCI_BRANCH` | `UF_PORTS` |
|---|---|---|---|
| 25.12, the release the feed is built for | `openwrt/rootfs:x86-64-25.12.5` | `openwrt-25.12` | `0` |
| SNAPSHOT (no LuCI in the image; `run.sh` installs it from the snapshot feed, which needs internet) | `openwrt/rootfs:x86-64` | `master` | `1` |
| luci-mod-dashboard before its rework (September 2026), as 24.10 and older 25.12 feeds ship it | `openwrt/rootfs:x86-64-25.12.5` | `a8c110bed82375b69eb3881b2e54e617520e8c7d` | `0` |

The port checks (the Port Manager, *Switch/VLAN config*) run on SNAPSHOT only:
on GitHub's runners the 25.12 image's netifd stops answering once
`add-ports.sh` reloads the network, and every page's network calls then time
out. CI's runner user gets the ports through password-less `sudo`.

`LUCI_BRANCH` takes a branch, a tag or a full commit id.

`sh test/run.sh --setup` leaves the container running instead, and
`test/shoot.cjs` takes full-page screenshots of any pages you name, which is
the loop to work on the theme in:

```sh
UF_PORT=8080 sh test/run.sh --setup
# edit, then
UF_REMOTE_SHELL="docker exec -i" sh install.sh luci-theme-openuf-test
NODE_PATH=$(npm root -g) node test/shoot.cjs --schemes light,dark,phone admin/network/firewall
```

## Where things live

| Path | What |
|---|---|
| `ucode/template/themes/openuf/header.ut` | The page frame. Reads `luci.openuf_theme`, puts the choices on `<html>` (`data-uf-interfaces`, `data-uf-wireless`, `data-uf-port-manager`; anything unknown reads as the default) and, on Interfaces or Wireless, links that page's design stylesheet after `cascade.css` |
| `scss/cascade.scss` → `htdocs/luci-static/openuf/cascade.css` | Everything shared: `scss/base/` (the tokens and components) and a partial per page in `scss/pages/`; `pages/_network.scss` holds only what Routing, DHCP, DNS and Diagnostics need. `scss/abstracts/` is the build-time toolkit (breakpoints, mixins) |
| `scss/network/interfaces-DESIGN.scss`, `wireless-DESIGN.scss` → `htdocs/luci-static/openuf/network/…css` | A design, one page each: the interface list, the Devices and global tabs and the interface, device and bridge VLAN dialogs; or the radios, their networks, the associated stations and the wireless and scan dialogs. What a design's two pages share is in its `scss/network/_DESIGN-*.scss` partials |
| `htdocs/luci-static/resources/view/openuf-theme/network/interfaces-DESIGN.js`, `wireless-DESIGN.js` | Each design's script: it only marks LuCI's nodes (which fact a row holds, column titles, a state) for its stylesheet, again after every redraw. `menu-openuf.js` loads the chosen one and calls its `enhance()`; without it the page keeps LuCI's rows |
| `htdocs/luci-static/resources/menu-openuf.js` | Navigation (app bar, rail, secondary column, tabs), the design loader, and the Port Manager card above the Interfaces view |
| `htdocs/luci-static/resources/view/openuf-theme/ports.js` | The port model (DSA and swconfig) and the strip and list |
| `htdocs/luci-static/resources/view/openuf-theme/logs.js`, `scss/pages/_logs.scss` | The System and Kernel Log a row per line, over LuCI's textarea, which it follows on each write; `menu-openuf.js` loads it on those two views only |
| `htdocs/luci-static/resources/view/openuf-theme/switch-vlan.js`, `bridgevlan.js`, `switch-vlan.css` | *Network → Switch/VLAN config*: copies of LuCI's `view/network/switch-vlan.js`, `tools/bridgevlan.js` and `switch-vlan.css` (luci-mod-network, Apache-2.0), with wireless bridge members left out rather than refused. The theme's `menu.d` entry puts the page in place of LuCI's |
| `htdocs/luci-static/resources/view/dashboard/include/25_ports.js` | The dashboard's Ports card |
| `htdocs/luci-static/resources/view/dashboard/include/21_openuf_resources.js` | The System resources card of the dashboard before its rework; its styles are in `scss/pages/_dashboard-classic.scss` |
| `htdocs/luci-static/resources/view/openuf-theme/settings.js` | *System → openUF Theme*; its menu entry is `root/usr/share/luci/menu.d/luci-theme-openuf.json` |
| `root/usr/share/rpcd/acl.d/luci-theme-openuf.json` | What the port panel reads, `/proc/stat` for the System resources card's CPU usage, and the settings page's access to `luci` |
| `root/etc/uci-defaults/30_luci-theme-openuf` | Registers the three theme entries and the settings' defaults |

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

## Earlier name

Before its first release the theme was called `luci-theme-unifi`. Installing
`luci-theme-openuf` on a device that has the old one (from this repository's
`install.sh`) moves it over: the colour scheme, the Interfaces and Wireless
designs and the Port Manager setting carry across, and the old theme entries,
settings page and files go. If the old name was installed as a package,
`apk del luci-theme-unifi` it afterwards.

## License

Apache-2.0, like LuCI and the Bootstrap theme whose template structure and
selector coverage it follows. The rest of openUF is MIT.
