#!/bin/sh
#
# Install a LuCI package into the test container straight from its source
# directory in a LuCI checkout, the way luci.mk would lay it out:
#
#   sh test/add-luci-package.sh CONTAINER path/to/luci/modules/luci-mod-dashboard
#
# Only for pure JavaScript/ucode packages (most of LuCI): nothing is compiled.

set -eu

name=$1
src=$2
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$stage/www" "$stage/usr/share/ucode/luci"
[ ! -d "$src/htdocs" ] || cp -R "$src/htdocs/." "$stage/www/"
[ ! -d "$src/ucode" ] || cp -R "$src/ucode/." "$stage/usr/share/ucode/luci/"
[ ! -d "$src/root" ] || cp -R "$src/root/." "$stage/"

# Name the top-level entries rather than ".": the staging directory is mode
# 0700, and extracting "./" would give the container's / that mode too.
# shellcheck disable=SC2046 # word splitting of the plain directory names
tar -C "$stage" -cf - $(ls "$stage") | docker exec -i "$name" sh -c '
	tar -o -C / -xf -
	for f in /etc/uci-defaults/*; do
		[ -f "$f" ] && ( . "$f" ) && rm -f "$f"
	done
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd restart
'

echo "added $(basename "$src")"
