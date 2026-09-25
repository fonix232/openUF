#!/bin/sh
# Strip comments from an installed openUF tree, in place.
#
# OpenWrt devices are flash-constrained and roughly half of src/'s bytes are
# comments, so the repo keeps its protocol-archaeology commentary and the
# device does not. The package Makefile runs this on its build copy.
#
# Usage:
#   sh tools/strip-tree.sh <dir> [lua]   strip <dir> in place (lua: interpreter)
#   sh tools/strip-tree.sh --verify      prove a stripped copy of src/ is
#                                        bytecode-identical and passes the suite
#                                        (from the package directory; CI)

set -e
TOOLS=$(cd "$(dirname "$0")" && pwd)

strip_tree() {
	dir=$1 lua=${2:-lua}
	# Model maps are the files a user may still read on the device to see
	# what a board's ports and radios are; their comments are the
	# explanation, so they ship intact.
	find "$dir" -name '*.lua' ! -path "$dir/modelmap/*" | while read -r f; do
		"$lua" "$TOOLS/strip.lua" "$f" > "$f.stripped" && mv "$f.stripped" "$f"
	done
	# Shell hooks: full-line comments only, and never line 1 -- the shebang is
	# functional, and a mid-line "#" may be a parameter expansion (${#key}).
	find "$dir" -name '*.sh' | while read -r f; do
		awk 'NR==1 || $0 !~ /^[[:space:]]*#/' "$f" > "$f.stripped" \
			&& cat "$f.stripped" > "$f" && rm -f "$f.stripped"
	done
}

if [ "$1" != "--verify" ]; then
	[ -d "${1:-}" ] || { echo "usage: $0 <dir> [lua] | --verify" >&2; exit 2; }
	strip_tree "$1" "$2"
	exit 0
fi

# A copy of the package (and the LuCI app beside it, which the packaging
# tests read) with src/ stripped.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/openuf"
cp -r . "$work/openuf/"
[ -d ../luci-app-openuf ] && cp -r ../luci-app-openuf "$work/"
strip_tree "$work/openuf/src"

echo "verify: bytecode equivalence"
LUAC=$(command -v luac5.1 || command -v luac || true)
if [ -z "$LUAC" ]; then
	echo "  SKIP (no luac available)"
else
	# Normalise away what legitimately differs: the source filename, heap
	# addresses and line numbers (comments are gone, so lines shift). What
	# remains is the opcode stream -- identical output proves the strip
	# changed nothing but comments.
	norm() {
		"$LUAC" -l -l -p "$1" 2>/dev/null \
			| grep -v 'instructions at' \
			| sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+\[[0-9]+\][[:space:]]+/ /' \
			| sed -E 's/0x[0-9a-f]+/ADDR/g; s/<[^>]*:[0-9]+,[0-9]+>/<F>/g'
	}
	for f in $(cd src && find . -name '*.lua' | sort); do
		norm "src/$f" > "$work/.a"
		norm "$work/openuf/src/$f" > "$work/.b"
		if ! cmp -s "$work/.a" "$work/.b"; then
			echo "  FAIL src/$f -- opcodes differ after strip"
			diff "$work/.a" "$work/.b" | head -20
			exit 1
		fi
	done
	echo "  OK   all stripped files are bytecode-identical"
fi

echo "verify: test suite against the stripped tree"
# The suite dofile()s "src/..." relative to cwd, so running it from a
# directory whose src/ is the stripped one tests exactly what ships.
( cd "$work/openuf" && lua tests/run_tests.lua ) || {
	echo "  FAIL tests do not pass against the stripped tree"
	exit 1
}
before=$(find src -type f -exec cat {} + | wc -c | tr -d ' ')
after=$(find "$work/openuf/src" -type f -exec cat {} + | wc -c | tr -d ' ')
echo "installed tree: $before -> $after bytes"
