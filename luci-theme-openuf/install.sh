#!/bin/sh
#
# Install luci-theme-openuf onto an OpenWrt device without a buildroot.
#
#   sh install.sh                       on the device itself
#   sh install.sh root@192.168.1.1      from a workstation, over SSH
#   sh install.sh --uninstall [TARGET]  remove it again
#
# The theme is only files (templates, stylesheets, scripts, a menu entry, an
# rpcd ACL, a uci-defaults hook), so this does what the package's install
# and postinst would: unpack the files, register the theme, and drop LuCI's
# caches.
#
# UF_REMOTE_SHELL replaces ssh as the transport. It is run as
# "$UF_REMOTE_SHELL TARGET sh -c SCRIPT", SCRIPT one argument and the payload
# on stdin, so "docker exec -i" works too (test/run.sh uses exactly that).

set -eu

here=$(cd "$(dirname "$0")" && pwd)
action=install
target=

for arg in "$@"; do
	case "$arg" in
		--uninstall) action=uninstall ;;
		-h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown option: $arg" >&2; exit 2 ;;
		*) target=$arg ;;
	esac
done

# Runs on the device, with a tar of the payload on stdin.
install_script='
set -e
tar -o -C / -xf -
sh /etc/uci-defaults/30_luci-theme-openuf && rm -f /etc/uci-defaults/30_luci-theme-openuf
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null || true
echo "luci-theme-openuf installed; theme: $(uci -q get luci.main.mediaurlbase)"
'

uninstall_script='
set -e
case "$(uci -q get luci.main.mediaurlbase)" in
	/luci-static/openuf*) uci set luci.main.mediaurlbase=/luci-static/bootstrap ;;
esac
uci -q delete luci.themes.openUF || true
uci -q delete luci.themes.openUFDark || true
uci -q delete luci.themes.openUFLight || true
uci -q delete luci.openuf_theme || true
uci commit luci
rm -rf /www/luci-static/openuf /www/luci-static/openuf-dark /www/luci-static/openuf-light \
	/www/luci-static/resources/menu-openuf.js \
	/www/luci-static/resources/view/openuf-theme \
	/www/luci-static/resources/view/dashboard/include/25_ports.js \
	/usr/share/rpcd/acl.d/luci-theme-openuf.json \
	/usr/share/luci/menu.d/luci-theme-openuf.json \
	/usr/share/ucode/luci/template/themes/openuf \
	/usr/share/ucode/luci/template/themes/openuf-dark \
	/usr/share/ucode/luci/template/themes/openuf-light
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null || true
echo "luci-theme-openuf removed; theme: $(uci -q get luci.main.mediaurlbase)"
'

# Lay the files out as they land on the device, the way luci.mk would.
payload() {
	stage=$(mktemp -d)
	trap 'rm -rf "$stage"' EXIT

	mkdir -p "$stage/www" "$stage/usr/share/ucode/luci"
	cp -R "$here/htdocs/." "$stage/www/"
	cp -R "$here/ucode/." "$stage/usr/share/ucode/luci/"
	cp -R "$here/root/." "$stage/"

	# COPYFILE_DISABLE keeps macOS tar from adding ._* metadata files.
	COPYFILE_DISABLE=1 tar -C "$stage" -cf - www usr etc
}

run() {
	if [ -z "$target" ]; then
		sh -c "$1"
	elif [ -n "${UF_REMOTE_SHELL:-}" ]; then
		# shellcheck disable=SC2086 # UF_REMOTE_SHELL may carry arguments.
		$UF_REMOTE_SHELL "$target" sh -c "$1"
	else
		# ssh hands the remote shell one string, so quote the script for it.
		ssh "$target" "sh -c '$(printf %s "$1" | sed "s/'/'\\\\''/g")'"
	fi
}

if [ "$action" = install ]; then
	[ -n "$target" ] || [ -d /usr/share/ucode/luci ] || {
		echo "no LuCI here; pass the device to install onto, e.g. root@192.168.1.1" >&2
		exit 1
	}
	payload | run "$install_script"
else
	run "$uninstall_script" </dev/null
fi
