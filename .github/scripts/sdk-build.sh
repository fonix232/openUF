#!/bin/sh
# Build openUF's packages with an official OpenWrt SDK image (docker
# openwrt/sdk:<target>-<version>, SDK in /builder; 25.12 or later). They
# are all architecture-independent, so one SDK builds them for every device.
#
#   sdk-build.sh <repo> <out> [package...]     (inside the SDK container)
#
# <repo> becomes a src-link feed; <out> receives the built packages. Without
# a package list, every package in packages.sh is built.
set -e
REPO=$1 OUT=$2
[ -d "$REPO/openuf" ] && [ -n "$OUT" ] || { echo "usage: $0 <repo> <out> [package...]" >&2; exit 2; }
shift 2
. "$REPO/.github/scripts/packages.sh"
[ $# -eq 0 ] || PKGS="$*"
# The Makefiles number releases by commit date; the checkout may belong to
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
targets=$(for p in $PKGS; do printf 'package/%s/compile ' "$p"; done)
# shellcheck disable=SC2086 # a list of make targets, by design
make -j"$(nproc)" $targets || make $targets V=s
mkdir -p "$OUT"
for p in $PKGS; do
	find bin/packages -name "${p}[-_]*" -exec cp {} "$OUT/" \;
done
ls "$OUT" | grep -q '\.apk$' || { echo "sdk-build: no packages were built" >&2; exit 1; }
ls -l "$OUT"
