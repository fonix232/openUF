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

It covers the core LuCI pages and **luci-mod-dashboard**, in light and dark,
down to phone width, where the rail and the secondary column become a drawer.

Three entries appear under *System → System → Language and Style*:

- **UniFi** follows the browser's colour scheme, and the button in the app bar
  cycles *follow system → light → dark*; the choice is remembered per browser.
- **UniFiLight** and **UniFiDark** pin one scheme for everybody and hide the
  button.

## Install

### From a feed (buildroot or SDK)

openUF is a valid package feed as it stands:

```sh
echo 'src-git openuf https://github.com/fonix232/openUF.git' >> feeds.conf
./scripts/feeds update openuf luci
./scripts/feeds install luci-theme-unifi
make package/luci-theme-unifi/compile
```

The package is architecture-independent (`all`), so one build serves every
target. Installing it switches LuCI to the theme; removing it switches back to
Bootstrap.

### Without a buildroot

The theme is nothing but files, so `install.sh` can put it on a running
device over SSH (it needs `tar` on both ends, which every OpenWrt has):

```sh
sh luci-theme-unifi/install.sh root@192.168.1.1
sh luci-theme-unifi/install.sh --uninstall root@192.168.1.1
```

Run on the device itself, it installs locally. It does what the package's
postinst would: unpacks the files, registers the three theme entries, selects
UniFi on a first install, and drops LuCI's caches.

## Testing

`test/run.sh` needs only Docker and Node with Playwright:

```sh
sh luci-theme-unifi/test/run.sh
```

It boots the official `openwrt/rootfs` image (which ships LuCI, uhttpd and rpcd,
so nothing comes from the package feeds), adds luci-mod-dashboard from LuCI's
sources and a two-radio wireless config so the Wireless pages have something to
show, installs the theme with `install.sh`, and then drives LuCI in headless
Chromium: it signs in, visits every page the menu offers, and fails on any
script error, failed asset, page that never finishes loading, or layout wider
than the window. Screenshots of the main views, in light, dark and at phone
width, land in `test/out/`.

`sh test/run.sh --setup` leaves the container running instead, and
`test/shoot.cjs` takes full-page screenshots of any pages you name, which is
the loop to work on the theme in:

```sh
UF_PORT=8080 sh test/run.sh --setup
# edit, then
UF_REMOTE_SHELL="docker exec -i" sh install.sh luci-theme-unifi-test
NODE_PATH=$(npm root -g) node test/shoot.cjs --schemes light,dark,phone admin/network/firewall
```

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
