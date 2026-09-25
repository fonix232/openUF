#!/bin/sh
# openUF bootstrap worker: (re)installs openUF when it is missing -- the first
# boot of a freshly built image, or the first boot after ANY firmware upgrade
# that kept settings (owut, LuCI attended sysupgrade, sysupgrade), which
# restores /etc/openuf/ and conf.lua but not openUF's code or packages.
#
# Installed as /etc/openuf/bootstrap.sh by install.sh and by
# contrib/asu/openuf-firstboot.sh (which embeds a copy of this file; a test
# keeps the two identical). Run by /etc/init.d/openuf-bootstrap at boot.
#
# Source, in order: the build that was installed before the upgrade
# (/etc/openuf/dist/openuf.tar.gz, kept by sysupgrade -- no network or GitHub
# release needed), else a download per /etc/openuf/bootstrap.conf.
# openUF's packages are part of an owut/ASU image (they keep installed
# packages); after a plain sysupgrade, install.sh adds them from the feed.

[ -f /etc/openuf/bootstrap.conf ] && . /etc/openuf/bootstrap.conf
OPENUF_REPO=${OPENUF_REPO:-fonix232/openUF}
OPENUF_REF=${OPENUF_REF:-latest}
CACHE=/etc/openuf/dist/openuf.tar.gz
log() { logger -t openuf-bootstrap "$*"; echo "openuf-bootstrap: $*"; }

[ -f /opt/openuf/inform.lua ] && [ -x /etc/init.d/openuf ] && exit 0

# wait_net [dns]: a default route, and working DNS when asked.
wait_net() {
	n=0
	until ip -4 route show default | grep -q . \
		&& { [ "${1:-}" != dns ] || nslookup downloads.openwrt.org >/dev/null 2>&1; }; do
		n=$((n + 1)); [ $((n % 30)) -eq 1 ] && log "waiting for the network"
		sleep 10
	done
}
have_deps() {
	command -v lua >/dev/null 2>&1 \
		&& lua -e 'require("cjson"); require("socket"); require("openssl")' >/dev/null 2>&1
}
fetch() { uclient-fetch -q -T 30 -O "$2" "$1" 2>/dev/null || wget -q -T 30 -O "$2" "$1"; }

work=/tmp/openuf-bootstrap
rm -rf "$work"; mkdir -p "$work"; cd "$work" || exit 1

if [ -s "$CACHE" ]; then
	cp "$CACHE" openuf.tar.gz
	url="$CACHE"
	sum=$(sha256sum openuf.tar.gz | cut -d' ' -f1)
else
	wait_net dns
	[ -n "${OPENUF_URL:-}" ] && OPENUF_REF="url:"
	case "$OPENUF_REF" in
		url:)     url="$OPENUF_URL" ;;
		branch:*) url="https://codeload.github.com/$OPENUF_REPO/tar.gz/refs/heads/${OPENUF_REF#branch:}" ;;
		latest)   url="https://github.com/$OPENUF_REPO/releases/latest/download/openuf.tar.gz" ;;
		*)        url="https://github.com/$OPENUF_REPO/releases/download/$OPENUF_REF/openuf.tar.gz" ;;
	esac
	try=0
	until fetch "$url" openuf.tar.gz && [ -s openuf.tar.gz ]; do
		try=$((try + 1))
		log "download failed ($url), retry $try"
		[ $try -ge 30 ] && { log "giving up"; exit 1; }
		sleep 60
	done
	sum=$(sha256sum openuf.tar.gz | cut -d' ' -f1)
	want="${OPENUF_SHA256:-}"
	if [ -z "$want" ] && [ "${OPENUF_REF#branch:}" = "$OPENUF_REF" ] && [ "$OPENUF_REF" != "url:" ]; then
		# A release publishes its checksum beside the tarball.
		fetch "$url.sha256" openuf.tar.gz.sha256 && want=$(cut -d' ' -f1 openuf.tar.gz.sha256)
	fi
	if [ -n "$want" ] && [ "$sum" != "$want" ]; then
		log "checksum mismatch ($sum != $want), not installing"
		exit 1
	fi
fi

tar xzf openuf.tar.gz || { log "bad tarball ($url)"; exit 1; }
src=$(dirname "$(find . -maxdepth 3 -name install.sh | head -1)")
[ -f "$src/install.sh" ] || { log "no install.sh in $url"; exit 1; }

# install.sh adds missing packages from the feed, which needs the network.
have_deps || wait_net dns

fresh=1
[ -f /opt/openuf/conf.lua ] && fresh=0   # a kept conf.lua: this is a reinstall
flags=""
[ "$fresh" = 1 ] && [ "${SSH_ADOPT:-0}" = 1 ] && flags="--bootstrap-adopt"
(cd "$src" && sh install.sh install $flags) || { log "install.sh failed"; exit 1; }

if [ "$fresh" = 1 ]; then
	conf=/opt/openuf/conf.lua
	[ -n "${MODELMAP:-}" ] && sed -i "s|^dev = dofile(\"modelmap/.*\")|dev = dofile(\"modelmap/$MODELMAP.lua\")|" "$conf"
	[ "${L2_ANNOUNCE:-1}" = 1 ] || sed -i 's/^\([[:space:]]*\)l2_announce = true/\1l2_announce = false/' "$conf"
	if [ -n "${BRIDGE_BACKEND:-}" ]; then
		sed -i "s/^\([[:space:]]*\)bridge_backend = \"[a-z_]*\"/\1bridge_backend = \"$BRIDGE_BACKEND\"/" "$conf"
		grep -q "bridge_backend = \"$BRIDGE_BACKEND\"" "$conf" \
			|| printf '\nconfig.bridge_backend = "%s"\n' "$BRIDGE_BACKEND" >> "$conf"
	fi
	[ -n "${INFORM_URL:-}" ] && /usr/bin/syswrapper.sh set-inform "$INFORM_URL"
fi

# LLDP's chassis id must be the MAC openUF is adopted under, which is the
# management bridge's (see USAGE: LLDP topology).
if [ -f /etc/config/lldpd ]; then
	br=$(readlink "/sys/class/net/$(cd /opt/openuf && lua -e 'dofile("conf.lua") print(dev.conf.net.lan_cpueth)' 2>/dev/null)/master" 2>/dev/null)
	br=${br##*/}
	[ -n "$br" ] && uci -q set lldpd.config.cid_interface="$br" && uci commit lldpd \
		&& /etc/init.d/lldpd restart
fi

/etc/init.d/openuf enable
/etc/init.d/openuf restart
log "openUF installed from $url (sha256 $sum)"
cd / && rm -rf "$work"
