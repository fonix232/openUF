#!/bin/sh
# openUF bootstrap adoption shell.
#
# Forced login shell for the temporary --bootstrap-adopt account (see
# install.sh). Permits exactly one command shape and nothing else, whether
# invoked interactively or non-interactively over SSH:
#
#   [/usr/bin/]syswrapper.sh set-adopt <url> <key32hex> [<mac>]
#
# 10.6 sends the absolute path, and on some builds appends the device's MAC
# (devmgr VtWV); a MAC that is not this AP's is refused. TCP forwarding is off
# while this account is usable (hook/ssh-forwarding.sh), since a forced shell
# does not stop `ssh -N -L`.
#
# Any other input -- including a plain interactive login attempt -- is
# refused. This is the actual security boundary for the bootstrap account:
# it holds no elevated privilege of its own (see install.sh's
# --bootstrap-adopt, which makes it a non-root user only able to write
# /etc/openuf), but this restriction means it can never be used for
# anything beyond the one adoption call regardless of that.

deny() {
	echo "adopt-shell: $1" >&2
	exit 1
}

# dropbear/OpenSSH invoke a non-interactive `ssh user@host cmd` session as
# `<shell> -c "<cmd>"`. Anything else (no -c, i.e. an interactive login) is
# refused outright -- this account never gets an interactive prompt.
[ "$1" = "-c" ] || deny "interactive login not permitted"

cmd=$2

case "$cmd" in
	"syswrapper.sh set-adopt "*|"/usr/bin/syswrapper.sh set-adopt "*) ;;
	*) deny "command not permitted" ;;
esac

# Split into args and validate strictly before ever exec'ing anything --
# syswrapper.lua re-validates url/key shape itself, but fail closed here
# too. Disable globbing first so URL/key metacharacters can't expand
# against files in the current directory.
set -f
set -- $cmd
[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || deny "malformed command"

bin=$1; sub=$2; url=$3; key=$4; mac=${5:-}
[ "$bin" = "syswrapper.sh" ] || [ "$bin" = "/usr/bin/syswrapper.sh" ] || deny "malformed command"
[ "$sub" = "set-adopt" ]     || deny "malformed command"

case "$url" in
	http://*|https://*) ;;
	*) deny "invalid url" ;;
esac

case "$key" in
	*[!0-9a-fA-F]*) deny "invalid key" ;;
esac
[ "${#key}" -eq 32 ] || deny "invalid key length"

if [ -n "$mac" ]; then
	case "$mac" in
		*[!0-9a-fA-F:]*) deny "invalid mac" ;;
	esac
	own=$(sed -n 's/.*"mac":"\([0-9a-fA-F:]*\)".*/\1/p' "${OPENUF_STATE:-/etc/openuf/state.json}" 2>/dev/null)
	if [ -n "$own" ] && [ "$(echo "$mac" | tr 'A-F' 'a-f')" != "$(echo "$own" | tr 'A-F' 'a-f')" ]; then
		deny "not this device"
	fi
fi

exec "${OPENUF_SYSWRAPPER:-/usr/bin/syswrapper.sh}" set-adopt "$url" "$key"
