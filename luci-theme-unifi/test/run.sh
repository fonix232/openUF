#!/bin/sh
#
# Boot a stock OpenWrt container, install the theme into it (the built package
# when UF_APK names one, as the feed's CI does, else this checkout via install.sh),
# and drive LuCI in headless Chromium (test/smoke.cjs): every page in the menu
# has to render with no script error, no failed asset and no sideways scroll,
# in light, dark and phone layouts. Screenshots land in test/out/.
#
#   sh test/run.sh            set up, test, tear down
#   sh test/run.sh --setup    set up and leave it running, to work against
#
# The official openwrt/rootfs images ship LuCI, uhttpd and rpcd, so nothing is
# fetched from the OpenWrt package feeds. Extra LuCI packages that are not in
# the image (luci-mod-dashboard) are installed from LuCI's own sources, and a
# two-radio wireless config gives the Wireless pages something to show.
#
# Environment knobs:
#   OPENWRT_IMAGE  image to test against      (openwrt/rootfs:x86-64-25.12.5)
#   LUCI_BRANCH    LuCI branch for extras     (openwrt-25.12)
#   LUCI_PACKAGES  extras, paths in LuCI      (modules/luci-mod-dashboard
#                                              applications/luci-app-usteer
#                                              applications/luci-app-uhttpd)
#   UF_NAME        container name             (luci-theme-unifi-test)
#   UF_PORT        host port for LuCI         (8080)
#   UF_OUT         screenshot directory       (test/out)
#   UF_APK         a built luci-theme-unifi .apk to install instead of this
#                  checkout's files (what the feed publishes)
#   UF_COMPAT      0 skips the fallback pass  (1, test/compat.cjs)
#   UF_FAKE_USTEER 0 leaves luci-app-usteer   (1)
#                  without its fake daemon
#   UF_SWCONFIG    1: add a swconfig switch   (off; see test/add-swconfig.sh)

set -eu

here=$(cd "$(dirname "$0")" && pwd)
image=${OPENWRT_IMAGE:-openwrt/rootfs:x86-64-25.12.5}
branch=${LUCI_BRANCH:-openwrt-25.12}
packages=${LUCI_PACKAGES:-modules/luci-mod-dashboard applications/luci-app-usteer applications/luci-app-uhttpd}
name=${UF_NAME:-luci-theme-unifi-test}
port=${UF_PORT:-8080}
out=${UF_OUT:-$here/out}
password=unifi-test
setup_only=

[ "${1:-}" != --setup ] || setup_only=1

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "127.0.0.1:$port:80" "$image" /sbin/init >/dev/null

if [ -z "$setup_only" ]; then
	trap 'docker rm -f "$name" >/dev/null 2>&1' EXIT
fi

tries=0
until curl -fsS -o /dev/null "http://127.0.0.1:$port/"; do
	tries=$((tries + 1))
	if [ $tries -ge 60 ]; then
		echo "uhttpd did not come up" >&2
		docker logs "$name" >&2
		exit 1
	fi
	sleep 1
done

docker exec "$name" sh -c "printf '%s\n%s\n' '$password' '$password' | passwd root >/dev/null"
docker exec "$name" sh -c 'cat /etc/openwrt_release' | sed -n "s/^DISTRIB_DESCRIPTION=/testing on /p"
docker exec -i "$name" sh -c 'cat > /etc/config/wireless' < "$here/fixtures/wireless"

# Answer Attended Sysupgrade's one-time "check online for upgrades?" prompt,
# which otherwise opens over the Status overview on every visit.
docker exec "$name" sh -c 'uci -q set attendedsysupgrade.client.login_check_for_upgrades=0 && uci commit attendedsysupgrade' || true

# LuCI packages the image lacks, from a sparse checkout cached in test/.cache.
if [ -n "$packages" ]; then
	luci="$here/.cache/luci-$branch"

	if [ ! -d "$luci/.git" ]; then
		mkdir -p "$here/.cache"
		git clone -q --depth 1 --filter=blob:none --sparse --branch "$branch" \
			https://github.com/openwrt/luci "$luci" || echo "could not fetch LuCI; skipping $packages" >&2
	fi

	if [ -d "$luci/.git" ]; then
		# shellcheck disable=SC2086 # a space-separated list, by design
		git -C "$luci" sparse-checkout set $packages

		for pkg in $packages; do
			sh "$here/add-luci-package.sh" "$name" "$luci/$pkg"
		done
	fi
fi

# usteerd is not in the image: a fake "usteer" ubus object gives its page data.
case " $packages " in
*" applications/luci-app-usteer "*)
	[ "${UF_FAKE_USTEER:-1}" = 0 ] || sh "$here/fake-usteer.sh" "$name" ;;
esac

# A switch chip for Network > Switch. Off by default, as it switches LuCI's
# "swconfig" feature on for every page (the Status overview's port card goes).
[ "${UF_SWCONFIG:-}" != 1 ] || sh "$here/add-swconfig.sh" "$name"

if [ -n "${UF_APK:-}" ]; then
	# The lab is offline: resolve luci-base from the installed packages.
	docker cp "$UF_APK" "$name:/tmp/luci-theme-unifi.apk"
	docker exec "$name" apk add --no-network --allow-untrusted /tmp/luci-theme-unifi.apk 2>&1 | { grep -v '^WARNING: opening from cache' || true; }
	docker exec "$name" sh -c 'uci -q get luci.main.mediaurlbase' | grep -qx /luci-static/unifi \
		|| { echo "the package did not select the theme" >&2; exit 1; }
else
	UF_REMOTE_SHELL="docker exec -i" sh "$here/../install.sh" "$name"
fi

if [ -n "$setup_only" ]; then
	echo "ready: http://127.0.0.1:$port/ (root / $password), container $name"
	exit 0
fi

mkdir -p "$out"
NODE_PATH=${NODE_PATH:-$(npm root -g)} node "$here/smoke.cjs" "http://127.0.0.1:$port" "$password" "$out"

# Again as Firefox and Safari see it, without the CSS only Chromium has.
if [ "${UF_COMPAT:-1}" != 0 ]; then
	NODE_PATH=${NODE_PATH:-$(npm root -g)} node "$here/compat.cjs" "http://127.0.0.1:$port" "$password" "$out/compat"
fi
