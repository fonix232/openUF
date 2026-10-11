#!/bin/sh
# Which packages a feed run builds, and which gh-pages commit it publishes onto.
#
#   feed-plan.sh <sha>     prints packages=, base=, tip= and source= lines
#
# gh-pages mirrors main commit by commit (publish.sh): each of its commits is
# the whole feed after one main commit, named in a "Source: main@<sha>" line.
# The base is the newest of them whose source is still an ancestor of <sha>
# -- the tip on an ordinary push, an older one after main was rewritten,
# none at all when the two histories share nothing (gh-pages then starts over).
# A package is built when its directory, or the build itself, changed since
# the base's source, or when the base does not carry it; the rest are
# published again as they are.
#
# BASE_SHA set (a pull request): compare with it instead, and publish nothing.
# REBUILD=true: build every package.
set -eu
SHA=$1
BRANCH=${FEED_BRANCH:-gh-pages}
REMOTE=${FEED_REMOTE:-origin}
. "$(dirname "$0")/packages.sh"
# A change here changes how every package is built (the list in packages.sh
# does not).
SHARED=".github/scripts/sdk-build.sh"

log() { printf 'plan: %s\n' "$*" >&2; }
short() { printf '%.7s' "$1"; }

base="" tip="" src=""
if [ -n "${BASE_SHA:-}" ]; then
	src=$BASE_SHA
	log "pull request: comparing with $(short "$src")"
elif git fetch --quiet "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" 2>/dev/null; then
	tip=$(git rev-parse "refs/remotes/$REMOTE/$BRANCH")
	for c in $(git rev-list "$tip"); do
		s=$(git log -1 --format=%B "$c" | sed -n 's/^Source: main@\([0-9a-f]\{40\}\)$/\1/p' | head -n 1)
		[ -n "$s" ] || continue                 # not a mirror commit
		[ "$s" = "$SHA" ] && continue           # published before: replace it
		if git cat-file -e "$s^{commit}" 2>/dev/null && git merge-base --is-ancestor "$s" "$SHA"; then
			base=$c src=$s
			break
		fi
	done
	if [ -z "$base" ]; then
		log "$BRANCH shares no history with main@$(short "$SHA"): starting it over"
	elif [ "$base" = "$tip" ]; then
		log "$BRANCH at $(short "$tip") is main@$(short "$src")"
	else
		log "main was rewritten: $BRANCH goes back to $(short "$base") (main@$(short "$src"))"
	fi
else
	log "no $BRANCH yet: starting it"
fi

build=""
for p in $PKGS; do
	why=""
	if [ "${REBUILD:-false}" = true ]; then
		why="rebuild requested"
	elif [ -z "$src" ]; then
		why="nothing published to compare with"
	elif [ -z "${BASE_SHA:-}" ] && ! git ls-tree --name-only "$base" apk/ | grep -q "^apk/$p-[0-9]"; then
		why="not in the feed"
	elif ! git diff --quiet "$src" "$SHA" -- "$p" $SHARED; then
		why="changed"
	fi
	if [ -n "$why" ]; then
		build="$build $p"
		log "$p: build ($why)"
	else
		log "$p: unchanged"
	fi
done

echo "packages=${build# }"
echo "base=$base"
echo "tip=$tip"
echo "source=$src"
