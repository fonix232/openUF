#!/bin/sh
# Put this checkout's daemon (src/) onto an AP's installed openUF and restart
# it, without building a package. For trying a change on a test AP between
# releases; tools/deploy.sh installs real packages and is the normal path.
#
#   sh tools/hotpatch.sh <host>
#
# Run from anywhere; needs a local `lua` for the strip. OPENUF_SSH overrides
# the ssh command (default: ssh with BatchMode, i.e. a key).
#
# What it does:
#   1. stages src/ and strips it exactly as the package build does
#      (tools/strip-tree.sh), with a BUILD stamp naming this checkout;
#   2. copies the staged tree to the AP and checks EVERY .lua file there with
#      the AP's own Lua (loadfile) -- one that does not load means nothing is
#      replaced;
#   3. replaces only the files that differ under /usr/share/openuf, keeping
#      the installed copy of each in /usr/share/openuf.pre-hotpatch (the first
#      time only: the backup is always the packaged file, never a previous
#      hotpatch);
#   4. /etc/init.d/openuf restart, and waits for a completed inform.
#
# Only src/ is copied: the init scripts, /etc/config/openuf and everything
# else the package installs are left alone. The way back is `apk fix openuf`
# (or reinstalling the package), which also makes the backup moot.
#
# Ported from yesrab/openUF's tools/hotpatch.sh (2026-10-03), adapted to the
# package layout here.

set -u
cd "$(dirname "$0")/.." || exit 2
[ -f src/inform.lua ] || { echo "hotpatch: run from an openUF checkout" >&2; exit 2; }
HOST=${1:-}
[ -n "$HOST" ] || { echo "usage: sh tools/hotpatch.sh <host>" >&2; exit 2; }
SSH=${OPENUF_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR}
command -v lua >/dev/null 2>&1 || { echo "hotpatch: a local lua is needed for the strip" >&2; exit 2; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/openuf-hotpatch.XXXXXX") || exit 1
trap 'rm -rf "$STAGE"' EXIT
cp -R src/. "$STAGE/" || exit 1
# macOS leaves AppleDouble `._*` files and .DS_Store beside edited files.
find "$STAGE" \( -name '._*' -o -name .DS_Store \) -exec rm -f {} + 2>/dev/null
sh tools/strip-tree.sh "$STAGE" lua || { echo "hotpatch: strip failed" >&2; exit 1; }
STAMP="hotpatch $(git describe --always --dirty 2>/dev/null || echo unknown) $(date -u +%Y-%m-%dT%H:%MZ)"
echo "$STAMP" > "$STAGE/BUILD"
echo "$HOST: patching /usr/share/openuf with: $STAMP"

COPYFILE_DISABLE=1 tar -C "$STAGE" -cf - . | $SSH "root@$HOST" '
set -u
D=/usr/share/openuf
B=/usr/share/openuf.pre-hotpatch
[ -f "$D/inform.lua" ] || { echo "  openUF is not installed here (no $D/inform.lua)"; exit 1; }
T=$(mktemp -d /tmp/openuf-hotpatch.XXXXXX) || exit 1
trap "rm -rf \"$T\"" EXIT
tar -C "$T" -xf - || exit 1
bad=0
for f in $(cd "$T" && find . -name "*.lua" | sed "s|^\./||"); do
	# Compiled, never run: loadfile() only parses. (A file argument after
	# -e would be RUN as a script, hence the path inside the chunk.)
	lua -e "local f, e = loadfile([[$T/$f]]) if not f then io.stderr:write(e, string.char(10)) os.exit(1) end" \
		|| { echo "  does not load: $f"; bad=1; }
done
[ "$bad" = 0 ] || { echo "  nothing replaced"; exit 1; }
changed=0
for f in $(cd "$T" && find . -type f | sed "s|^\./||"); do
	if [ -f "$D/$f" ] && cmp -s "$T/$f" "$D/$f"; then continue; fi
	if [ -f "$D/$f" ] && [ ! -f "$B/$f" ]; then
		mkdir -p "$B/$(dirname "$f")" && cp -p "$D/$f" "$B/$f"
	fi
	mkdir -p "$D/$(dirname "$f")" && cp "$T/$f" "$D/$f" || exit 1
	changed=$((changed + 1))
	echo "  updated $f"
done
chmod 0755 "$D"/hook/*.sh 2>/dev/null
echo "  $changed file(s) changed; originals in $B"
started=$(date +%s)
/etc/init.d/openuf restart
n=0
while [ $n -lt 18 ]; do
	sleep 5
	ok=$(sed -n "s/^last_ok=//p" /tmp/openuf-status 2>/dev/null)
	[ "${ok:-0}" -ge "$started" ] && { echo "  the controller answered"; exit 0; }
	n=$((n + 1))
done
echo "  no completed inform within 90 s -- logread -e openuf"
exit 1
' || { echo "$HOST: hotpatch failed" >&2; exit 1; }
echo "$HOST: done"
