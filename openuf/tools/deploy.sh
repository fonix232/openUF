#!/bin/sh
# Install locally built openUF packages on one or more access points, for
# testing a build before it reaches the feed. Devices otherwise update from
# the feed with openuf-update.
#
#   sh tools/deploy.sh <dir> <host>...
#
# <dir> holds the packages .github/scripts/sdk-build.sh produced (openuf and,
# if the AP has LuCI, luci-app-openuf; .apk or .ipk, whichever the AP uses).
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
	fmt=$($SSH "root@$h" 'command -v apk >/dev/null && echo apk || echo ipk') || { echo "  unreachable"; exit 1; }
	luci=$($SSH "root@$h" '[ -d /usr/share/luci/menu.d ] && echo 1')
	files=$(newest openuf "$fmt")
	[ "$luci" = 1 ] && files="$files $(newest luci-app-openuf "$fmt")"
	[ -n "$files" ] || { echo "  no .$fmt packages in $DIR"; exit 1; }
	$SSH "root@$h" 'rm -rf /tmp/openuf-deploy && mkdir -p /tmp/openuf-deploy' || exit 1
	for f in $files; do
		$SSH "root@$h" "cat > /tmp/openuf-deploy/$f" < "$DIR/$f" || exit 1
	done
	echo "  installing: $files"
	started=$(date +%s)
	if [ "$fmt" = apk ]; then
		$SSH "root@$h" 'cd /tmp/openuf-deploy && apk add --allow-untrusted ./*.apk' || exit 1
	else
		$SSH "root@$h" 'cd /tmp/openuf-deploy && opkg install --force-reinstall ./*.ipk' || exit 1
	fi
	n=0
	until $SSH "root@$h" "ok=\$(sed -n 's/^last_ok=//p' /tmp/openuf-status); [ \"\${ok:-0}\" -ge $started ]" 2>/dev/null; do
		n=$((n + 1)); [ $n -ge 18 ] && { echo "  no completed inform within 90 s -- stopping here"; exit 1; }
		sleep 5
	done
	echo "  ok: $($SSH "root@$h" 'cat /usr/share/openuf/BUILD'), the controller answered"
done
