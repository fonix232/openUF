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
# openUF is not in the official package feeds, so an image cannot carry it.
# This lays down its settings (/etc/config/openuf), the openUF feed's key and
# repository line, and the bootstrap service the openuf package itself ships
# (a test keeps the copy below identical): once the network is up, that
# service installs openuf -- and luci-app-openuf when LuCI is there -- from
# the feed. From then on the package keeps itself across firmware upgrades.
#
# Edit the settings below before building. Nothing else needs changing.

# ─── Settings ────────────────────────────────────────────────────────────────
INFORM_URL=""                   # e.g. http://10.0.0.1:8080/inform (empty: http://unifi:8080/inform)
BRIDGE_BACKEND="auto"           # auto | vlan_filtering (controller owns the bridge) | bridges
L2_ANNOUNCE="0"                 # 1: broadcast L2 discovery (the controller adopts over SSH)
AP_MODE="1"                     # 1: a fresh board boots as an AP ready to adopt (below)
SSH_ADOPT="0"                   # 1: temporary ubnt/ubnt account for SSH adoption (L2 discovery)
FEED="https://fonix232.github.io/openUF"
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

# ─── openUF's settings ────────────────────────────────────────────────────────
# Only on a board that has none: a later image keeps the device's own.
if [ ! -f /etc/config/openuf ]; then
	cat > /etc/config/openuf <<EOF
config openuf 'main'
	option inform_url '${INFORM_URL:-http://unifi:8080/inform}'
	option bridge_backend '$BRIDGE_BACKEND'
	option l2_announce '$L2_ANNOUNCE'
	option ssh_adopt '$SSH_ADOPT'
EOF
fi

# ─── The openUF feed ─────────────────────────────────────────────────────────
mkdir -p /etc/apk/keys /etc/apk/repositories.d
cat > /etc/apk/keys/openuf.pem <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqpVcObiagPpzXuDYOM5z7+k9h/PV
NL+swuTAD9dqyu6Hc2LcnkLY21ZOoJgWEmd5Ra/s+CajGmPpLEc/uPTAcw==
-----END PUBLIC KEY-----
KEY
echo "$FEED/apk/packages.adb" > /etc/apk/repositories.d/openuf.list

# ─── The bootstrap service (the openuf package's /etc/init.d/openuf-bootstrap)
cat > /etc/init.d/openuf-bootstrap <<'SERVICE'
#!/bin/sh /etc/rc.common
# openUF upgrade bootstrap.
#
# A firmware upgrade that keeps settings (owut, LuCI's attended sysupgrade,
# sysupgrade -c) restores /etc -- openUF's state and settings, this script,
# and the openUF feed's key and repository line (/lib/upgrade/keep.d/openuf)
# -- but not the package: packages only survive when they are built into the
# image, and the ASU server only builds official ones. On the first boot of
# such an image this reinstalls openUF from the openUF feed, with its LuCI
# page when LuCI is there. A no-op whenever openUF is installed.

START=98
USE_PROCD=1
EXTRA_COMMANDS="reinstall"
EXTRA_HELP="	reinstall	Install openUF from the openUF feed now"

LOCK=/var/run/openuf-bootstrap.lock

# Detached rather than a procd instance: the package's own post-install runs
# `start` on this script, and procd would answer that by stopping the
# instance -- killing the very apk transaction that is installing openUF.
start_service() {
	[ -x /etc/init.d/openuf ] && return 0
	[ -e "$LOCK" ] && return 0
	touch "$LOCK"
	( /etc/init.d/openuf-bootstrap reinstall; rm -f "$LOCK" ) </dev/null >/dev/null 2>&1 &
}

log() { logger -t openuf-bootstrap "$*"; echo "openuf-bootstrap: $*"; }

reinstall() {
	local pkgs=openuf n=0
	# The feed is on the internet: wait for a default route and DNS.
	until ip -4 route show default | grep -q . && nslookup github.io >/dev/null 2>&1; do
		n=$((n + 1)); [ $((n % 30)) -eq 1 ] && log "waiting for the network"
		sleep 10
	done
	apk info -e luci-base >/dev/null 2>&1 && pkgs="$pkgs luci-app-openuf"
	n=0
	until apk update >/dev/null 2>&1 && apk add $pkgs; do
		n=$((n + 1)); [ $n -ge 30 ] && { log "giving up on: apk add $pkgs"; return 1; }
		log "apk add $pkgs failed, retry $n"; sleep 60
	done
	log "installed $pkgs from the openUF feed"
}
SERVICE
chmod 0755 /etc/init.d/openuf-bootstrap
/etc/init.d/openuf-bootstrap enable
exit 0
