#!/bin/sh
# Install locally built openUF packages on one or more access points, for
# testing a build before it reaches the feed. Devices otherwise update from
# the feed with apk upgrade.
#
#   sh tools/deploy.sh <dir> <host>...
#
# <dir> holds the packages .github/scripts/sdk-build.sh produced (openuf and,
# if the AP has LuCI, luci-app-openuf; luci-theme-unifi too where the AP
# already has it, or everywhere with OPENUF_DEPLOY_THEME=1).
# Hosts are done one at a time and each must complete an inform before the
# next is touched, so a bad build stops at the first AP.
#
# OPENUF_SSH overrides the ssh command (default: ssh with BatchMode).

set -u
DIR=${1:-}
[ -d "$DIR" ] && [ $# -ge 2 ] || { echo "usage: $0 <package dir> <host>..." >&2; exit 2; }
shift
SSH=${OPENUF_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR}

newest() { ls "$DIR" | grep -E "^$1[-_][0-9].*\.$2\$" | sort -V | tail -1; }

for h in "$@"; do
	echo "== $h"
	luci=$($SSH "root@$h" '[ -d /usr/share/luci/menu.d ] && echo 1 || echo 0') || { echo "  unreachable"; exit 1; }
	theme=0
	if [ "$luci" = 1 ] && [ -n "$(newest luci-theme-unifi apk)" ]; then
		[ "${OPENUF_DEPLOY_THEME:-0}" = 1 ] && theme=1
		$SSH "root@$h" 'apk info -e luci-theme-unifi >/dev/null 2>&1' && theme=1
	fi
	files=$(newest openuf apk)
	[ "$luci" = 1 ] && files="$files $(newest luci-app-openuf apk)"
	[ "$theme" = 1 ] && files="$files $(newest luci-theme-unifi apk)"
	[ -n "$files" ] || { echo "  no .apk packages in $DIR"; exit 1; }
	$SSH "root@$h" 'rm -rf /tmp/openuf-deploy && mkdir -p /tmp/openuf-deploy' || exit 1
	for f in $files; do
		$SSH "root@$h" "cat > /tmp/openuf-deploy/$f" < "$DIR/$f" || exit 1
	done
	echo "  installing: $files"
	started=$(date +%s)
	# A package added from a file is pinned in /etc/apk/world by checksum, and
	# apk upgrade then never moves it; re-adding it by name keeps the installed
	# build but lets the feed replace it later.
	names="openuf"; [ "$luci" = 1 ] && names="$names luci-app-openuf"
	[ "$theme" = 1 ] && names="$names luci-theme-unifi"
	$SSH "root@$h" "cd /tmp/openuf-deploy && apk add --allow-untrusted ./*.apk && apk add $names" || exit 1
	n=0
	until $SSH "root@$h" "ok=\$(sed -n 's/^last_ok=//p' /tmp/openuf-status); [ \"\${ok:-0}\" -ge $started ]" 2>/dev/null; do
		n=$((n + 1)); [ $n -ge 18 ] && { echo "  no completed inform within 90 s -- stopping here"; exit 1; }
		sleep 5
	done
	echo "  ok: $($SSH "root@$h" 'cat /usr/share/openuf/BUILD'), the controller answered"
done
