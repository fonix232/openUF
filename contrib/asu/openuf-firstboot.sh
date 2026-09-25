#!/bin/sh
# openUF first-boot script for OpenWrt image builds.
#
# Use it as:
#   * firmware-selector.openwrt.org -> "Customize installed packages and/or
#     first boot script" -> "Script to run on first boot (uci-defaults)"
#   * owut upgrade -I /path/to/openuf-firstboot.sh
#   * ImageBuilder: files/etc/uci-defaults/99-openuf
# together with the packages in packages.txt.
#
# uci-defaults run before the network is up, so this only lays down a small
# bootstrap service; the service waits for a route, downloads openUF, verifies
# it and installs it. The service and its settings live in /etc/openuf/ and are
# put on the sysupgrade keep-list, so every LATER image -- an `owut upgrade`, a
# sysupgrade with settings kept -- gets openUF reinstalled on its first boot
# with the device's state.json (adoption, authkey) and conf.lua intact. A fresh
# flash without kept settings needs this script in the image again.
#
# Edit the settings below before building. Nothing else needs changing.

# ─── Settings ────────────────────────────────────────────────────────────────
OPENUF_REPO="fonix232/openUF"   # GitHub owner/repo to install from
OPENUF_REF="latest"             # "latest" release, a tag ("v0.9.3"), or "branch:<name>"
OPENUF_SHA256=""                # optional: pin the tarball's sha256
OPENUF_URL=""                   # optional: full tarball URL (a mirror); overrides the two above
INFORM_URL=""                   # e.g. http://10.0.0.1:8080/inform (empty: L2 discovery only)
MODELMAP="auto"                 # auto (derive from /etc/board.json) or a map name
BRIDGE_BACKEND="auto"           # auto | vlan_filtering (controller owns the bridge) | bridges
L2_ANNOUNCE="0"                 # 1: broadcast L2 discovery (the controller adopts over SSH)
REGISTER_OWUT="1"               # 1: keep these packages in future `owut upgrade` builds
AP_MODE="1"                     # 1: a fresh board boots as an AP ready to adopt (below)
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p /etc/openuf

# ─── Ready-to-adopt AP mode ──────────────────────────────────────────────────
# A fresh OpenWrt is a router: sockets split into LAN and WAN, a DHCP server,
# NAT, and a default "OpenWrt" SSID. An AP waiting for its controller is none
# of those, so on a board openUF has never run on:
#   * every Ethernet socket joins ONE bridge -- any socket can be the uplink --
#     and the management address comes from DHCP on it
#   * no DHCP/RA server, no firewall/NAT, no wan/wan6 interfaces
#   * no SSIDs at all; the radios are enabled so the controller's WLANs can
#     come up the moment they are provisioned
# Never again after that: uci-defaults also run on the first boot of every
# LATER image (owut upgrade, sysupgrade keeping settings), when the network
# already belongs to the controller. state.json and the ap-mode marker are both
# on the sysupgrade keep-list below.
if [ "$AP_MODE" = 1 ] && [ ! -f /etc/openuf/state.json ] && [ ! -f /etc/openuf/ap-mode.done ]; then
	bj=/etc/board.json
	ports=$(jsonfilter -i "$bj" -e '@.network.lan.ports[*]' 2>/dev/null)
	[ -n "$ports" ] || ports=$(jsonfilter -i "$bj" -e '@.network.lan.device' 2>/dev/null)
	ports="$ports $(jsonfilter -i "$bj" -e '@.network.wan.device' 2>/dev/null)"
	if [ -n "$(echo $ports)" ]; then
		# Whatever bridge the defaults built goes; one owned by this script
		# replaces it under the same name, so `lan` keeps pointing at br-lan.
		for s in $(uci -X -q show network | sed -n "s/^network\.\([^.=]*\)=device$/\1/p"); do
			[ "$(uci -q get "network.$s.type")" = bridge ] && uci -q delete "network.$s"
		done
		uci set network.openuf_ap=device
		uci set network.openuf_ap.name=br-lan
		uci set network.openuf_ap.type=bridge
		for p in $ports; do uci add_list network.openuf_ap.ports="$p"; done
		uci set network.lan.device=br-lan
		uci set network.lan.proto=dhcp
		for o in ipaddr netmask ip6assign gateway dns; do uci -q delete "network.lan.$o"; done
		uci -q delete network.wan
		uci -q delete network.wan6
		uci commit network
	fi
	uci -q set dhcp.lan.ignore=1
	uci -q set dhcp.lan.dhcpv6=disabled
	uci -q set dhcp.lan.ra=disabled
	uci -q commit dhcp
	for svc in dnsmasq odhcpd firewall; do
		[ -x "/etc/init.d/$svc" ] && "/etc/init.d/$svc" disable
	done
	[ -f /etc/config/wireless ] || wifi config >/dev/null 2>&1
	for s in $(uci -X -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
		uci -q delete "wireless.$s"
	done
	for r in $(uci -X -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
		uci set "wireless.$r.disabled=0"
	done
	uci -q commit wireless
	date > /etc/openuf/ap-mode.done
fi
# An AP-mode DSA board: the controller owns the bridge from its first push
# (netmodel.lua). A swconfig board has no per-socket netdevs to filter.
if [ -f /etc/openuf/ap-mode.done ] && [ "$BRIDGE_BACKEND" = auto ] \
		&& ! jsonfilter -i /etc/board.json -e '@.switch' >/dev/null 2>&1; then
	BRIDGE_BACKEND=vlan_filtering
fi

cat > /etc/openuf/bootstrap.conf <<EOF
OPENUF_REPO='$OPENUF_REPO'
OPENUF_REF='$OPENUF_REF'
OPENUF_SHA256='$OPENUF_SHA256'
OPENUF_URL='$OPENUF_URL'
INFORM_URL='$INFORM_URL'
MODELMAP='$MODELMAP'
BRIDGE_BACKEND='$BRIDGE_BACKEND'
L2_ANNOUNCE='$L2_ANNOUNCE'
EOF

cat > /etc/openuf/bootstrap.sh <<'WORKER'
#!/bin/sh
# openUF bootstrap worker (installed by openuf-firstboot.sh). Installs openUF
# when /opt/openuf is missing -- first boot, or the first boot of a new image.
. /etc/openuf/bootstrap.conf
log() { logger -t openuf-bootstrap "$*"; echo "openuf-bootstrap: $*"; }

[ -f /opt/openuf/inform.lua ] && [ -x /etc/init.d/openuf ] && exit 0

# Wait for a default route and working DNS; the installer needs GitHub.
n=0
until ip -4 route show default | grep -q . && nslookup github.com >/dev/null 2>&1; do
	n=$((n + 1)); [ $((n % 30)) -eq 1 ] && log "waiting for the network"
	sleep 10
done

fetch() { uclient-fetch -q -T 30 -O "$2" "$1" 2>/dev/null || wget -q -T 30 -O "$2" "$1"; }
work=/tmp/openuf-bootstrap
rm -rf "$work"; mkdir -p "$work"; cd "$work" || exit 1

case "$OPENUF_REF" in
	*) [ -n "$OPENUF_URL" ] && OPENUF_REF="url:" ;;
esac
case "$OPENUF_REF" in
	url:)
		url="$OPENUF_URL" ;;
	branch:*)
		ref=${OPENUF_REF#branch:}
		url="https://codeload.github.com/$OPENUF_REPO/tar.gz/refs/heads/$ref" ;;
	latest)
		url="https://github.com/$OPENUF_REPO/releases/latest/download/openuf.tar.gz" ;;
	*)
		url="https://github.com/$OPENUF_REPO/releases/download/$OPENUF_REF/openuf.tar.gz" ;;
esac

try=0
until fetch "$url" openuf.tar.gz && [ -s openuf.tar.gz ]; do
	try=$((try + 1))
	log "download failed ($url), retry $try"
	[ $try -ge 30 ] && { log "giving up"; exit 1; }
	sleep 60
done

sum=$(sha256sum openuf.tar.gz | cut -d' ' -f1)
want="$OPENUF_SHA256"
if [ -z "$want" ] && [ "${OPENUF_REF#branch:}" = "$OPENUF_REF" ] && [ "$OPENUF_REF" != "url:" ]; then
	# A release publishes its checksum beside the tarball.
	fetch "$url.sha256" openuf.tar.gz.sha256 && want=$(cut -d' ' -f1 openuf.tar.gz.sha256)
fi
if [ -n "$want" ] && [ "$sum" != "$want" ]; then
	log "checksum mismatch ($sum != $want), not installing"
	exit 1
fi

tar xzf openuf.tar.gz || { log "bad tarball"; exit 1; }
src=$(dirname "$(find . -maxdepth 3 -name install.sh | head -1)")
[ -f "$src/install.sh" ] || { log "no install.sh in the tarball"; exit 1; }

fresh=1
[ -f /opt/openuf/conf.lua ] && fresh=0   # a kept conf.lua: this is a reinstall
(cd "$src" && sh install.sh install) || { log "install.sh failed"; exit 1; }

if [ "$fresh" = 1 ]; then
	conf=/opt/openuf/conf.lua
	sed -i "s|^dev = dofile(\"modelmap/.*\")|dev = dofile(\"modelmap/$MODELMAP.lua\")|" "$conf"
	[ "$L2_ANNOUNCE" = 1 ] || sed -i 's/^\([[:space:]]*\)l2_announce = true/\1l2_announce = false/' "$conf"
	sed -i "s/^\([[:space:]]*\)bridge_backend = \"[a-z_]*\"/\1bridge_backend = \"$BRIDGE_BACKEND\"/" "$conf"
	grep -q "bridge_backend = \"$BRIDGE_BACKEND\"" "$conf" \
		|| printf '\nconfig.bridge_backend = "%s"\n' "$BRIDGE_BACKEND" >> "$conf"
	[ -n "$INFORM_URL" ] && /usr/bin/syswrapper.sh set-inform "$INFORM_URL"
fi

# LLDP's chassis id must be the MAC openUF is adopted under, which is the
# management bridge's (see USAGE: LLDP topology).
if [ -f /etc/config/lldpd ]; then
	br=$(readlink "/sys/class/net/$(lua -e 'dofile("/opt/openuf/conf.lua") print(dev.conf.net.lan_cpueth)' 2>/dev/null)/master" 2>/dev/null)
	br=${br##*/}
	[ -n "$br" ] && uci -q set lldpd.config.cid_interface="$br" && uci commit lldpd \
		&& /etc/init.d/lldpd restart
fi

/etc/init.d/openuf enable
/etc/init.d/openuf restart
log "openUF installed from $url (sha256 $sum)"
rm -rf "$work"
WORKER
chmod 0755 /etc/openuf/bootstrap.sh

cat > /etc/init.d/openuf-bootstrap <<'SERVICE'
#!/bin/sh /etc/rc.common
# Reinstalls openUF on the first boot of every new image (see
# /etc/openuf/bootstrap.sh); a no-op once it is installed.
START=98
USE_PROCD=1
start_service() {
	procd_open_instance
	procd_set_param command /bin/sh /etc/openuf/bootstrap.sh
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
SERVICE
chmod 0755 /etc/init.d/openuf-bootstrap
/etc/init.d/openuf-bootstrap enable

# Keep the bootstrap, its settings and openUF's state across sysupgrades.
for keep in /etc/openuf/ /opt/openuf/conf.lua /etc/init.d/openuf-bootstrap \
		/etc/rc.d/S98openuf-bootstrap; do
	grep -qxF "$keep" /etc/sysupgrade.conf 2>/dev/null || echo "$keep" >> /etc/sysupgrade.conf
done

# Make future `owut upgrade` builds carry the same packages.
if [ "$REGISTER_OWUT" = 1 ] && uci -q get attendedsysupgrade.owut >/dev/null; then
	for p in lua lua-cjson luasocket lua-openssl luabitop libuci-lua iw ip-bridge \
			hostapd-utils usteer lldpd nftables kmod-nft-bridge tc-tiny \
			kmod-sched-act-police wpad-openssl; do
		uci -q del_list attendedsysupgrade.owut.add="$p"
		uci add_list attendedsysupgrade.owut.add="$p"
	done
	# Only a package that is actually installed can be removed from a build.
	if { apk info -e wpad-basic-mbedtls || opkg list-installed wpad-basic-mbedtls | grep -q .; } >/dev/null 2>&1; then
		uci -q del_list attendedsysupgrade.owut.remove="wpad-basic-mbedtls"
		uci add_list attendedsysupgrade.owut.remove="wpad-basic-mbedtls"
	fi
	uci commit attendedsysupgrade
fi

exit 0
