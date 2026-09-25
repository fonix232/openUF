#!/bin/sh
# Build openUF's packages with an official OpenWrt SDK image (docker
# openwrt/sdk:<target>-<version>, SDK in /builder). Both packages are
# architecture-independent, so one SDK per package format is enough: 25.12 or
# later for apk, 24.10 for opkg.
#
#   sdk-build.sh <repo> <out>     (inside the SDK container)
#
# <repo> becomes a src-link feed; <out> receives the built packages.
set -e
REPO=$1 OUT=$2
[ -d "$REPO/openuf" ] && [ -n "$OUT" ] || { echo "usage: $0 <repo> <out>" >&2; exit 2; }
# The Makefiles number releases by commit count; the checkout may belong to
# another uid inside the container.
git config --global --add safe.directory '*'

# Runtime dependencies become package metadata only (see openuf/Makefile), so
# the only other thing to build is lua/host, which strips the shipped Lua.
export OPENUF_FEED_BUILD=1

cd /builder
# The moving tags (x86-64-openwrt-25.12) ship only setup.sh, which downloads
# and verifies that branch's current SDK; the versioned tags include it.
[ -f rules.mk ] || ./setup.sh >/dev/null
grep -E '^src-git[^ ]*( --root=[^ ]+)? base ' feeds.conf.default > feeds.conf
echo "src-link openuf $REPO" >> feeds.conf
./scripts/feeds update -a >/dev/null
./scripts/feeds install -a -p openuf >/dev/null
./scripts/feeds install lua >/dev/null
make defconfig >/dev/null
make -j"$(nproc)" package/openuf/compile package/luci-app-openuf/compile \
	|| make package/openuf/compile package/luci-app-openuf/compile V=s
mkdir -p "$OUT"
find bin/packages -name 'openuf[-_]*' -o -name 'luci-app-openuf[-_]*' | while read -r f; do
	cp "$f" "$OUT/"
done
ls -l "$OUT"
