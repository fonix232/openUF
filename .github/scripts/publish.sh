#!/bin/sh
# Publish the feed as of main@<sha> onto gh-pages (after fonix232/CV's
# scripts/publish.sh).
#
#   publish.sh <main-sha> [<dir of newly built .apk files>]
#
# gh-pages is a parallel history of main: one commit per published main
# commit, the whole feed as of that commit, its body naming the source
# ("Source: main@<sha>"). BASE is the gh-pages commit to publish onto and TIP
# the branch head, both as feed-plan.sh found them: BASE is behind TIP when
# main was rewritten (the commits after it are dropped), and empty to start
# the branch over. The push is refused if gh-pages moved since the plan.
#
# Packages not rebuilt are carried over from BASE as they were published;
# the last KEEP builds of each stay in the feed, so an earlier one can be
# reinstalled with `apk add openuf=<version>`. The index is signed with
# APK_SIGN_KEY (an ECDSA private key, PEM) in the OpenWrt SDK image.
set -eu
SHA=$1 NEW=${2:-}
BRANCH=${FEED_BRANCH:-gh-pages}
REMOTE=${FEED_REMOTE:-origin}
KEEP=${KEEP:-5}
BASE=${BASE:-} TIP=${TIP:-}
SDK_IMAGE=${SDK_IMAGE:-openwrt/sdk:x86-64-openwrt-25.12}
. "$(dirname "$0")/packages.sh"

log() { printf 'publish: %s\n' "$*" >&2; }
short() { printf '%.7s' "$1"; }

git cat-file -e "$SHA^{commit}" || { log "unknown commit $SHA"; exit 2; }
wt=$(mktemp -d) keys=$(mktemp -d)
trap 'rm -rf "$keys"; git worktree remove --force "$wt" 2>/dev/null || true
	git branch -q -D "$BRANCH-publish" 2>/dev/null || true' EXIT

if [ -n "$BASE" ]; then
	git worktree add --quiet --detach "$wt" "$BASE"
	log "onto $(short "$BASE")"
else
	git worktree add --quiet --detach "$wt" "$SHA"
	git -C "$wt" checkout --quiet --orphan "$BRANCH-publish"
	git -C "$wt" rm -rqf --cached .
	find "$wt" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
	log "starting $BRANCH over"
fi
mkdir -p "$wt/apk"

reindex=""
[ -f "$wt/apk/packages.adb" ] || reindex=1
if [ -n "$NEW" ] && ls "$NEW"/*.apk >/dev/null 2>&1; then
	cp "$NEW"/*.apk "$wt/apk/"
	reindex=1
	for p in $PKGS; do
		ls "$wt/apk" | grep -E "^$p-[0-9].*\.apk$" | sort -V \
			| awk -v keep="$KEEP" '{ f[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print f[i] }' \
			| while read -r f; do rm -f "$wt/apk/$f"; log "retired $f"; done
	done
fi

# Re-signed only when the set of packages changed: an unchanged feed keeps
# its index byte for byte.
if [ -n "$reindex" ]; then
	(umask 077; printf '%s\n' "$APK_SIGN_KEY" > "$keys/apk-private.pem")
	chmod -R a+rX "$keys" && chmod -R a+rwX "$wt/apk"
	docker run --rm -v "$wt/apk:/apk" -v "$keys:/keys:ro" "$SDK_IMAGE" sh -c '
		cd /builder && { [ -f rules.mk ] || ./setup.sh >/dev/null; } &&
		cd /apk && rm -f packages.adb &&
		/builder/staging_dir/host/bin/apk mkndx --allow-untrusted \
			--sign /keys/apk-private.pem --output packages.adb *.apk'
	log "indexed: $(cd "$wt/apk" && ls -- *.apk | tr '\n' ' ')"
fi
cp openuf/files/feed/openuf.pem "$wt/"
cp .github/pages/index.html "$wt/index.html"
touch "$wt/.nojekyll"

subject=$(git log -1 --format=%s "$SHA")
git -C "$wt" add -A
git -C "$wt" commit --quiet --allow-empty \
	-m "Publish main@$(short "$SHA"): $subject" \
	-m "Source: main@$SHA"
# An empty TIP means the branch must not exist yet.
git -C "$wt" push --quiet --force-with-lease="refs/heads/$BRANCH:$TIP" "$REMOTE" "HEAD:refs/heads/$BRANCH"
log "pushed $(short "$(git -C "$wt" rev-parse HEAD)") to $BRANCH (main@$(short "$SHA"))"
