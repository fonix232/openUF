#!/bin/sh
# openUF: dropbear TCP forwarding while the bootstrap adoption account is usable.
#
#   ssh-forwarding.sh lock      forwarding off (the board's settings are stamped)
#   ssh-forwarding.sh restore   the board's settings back
#
# The --bootstrap-adopt account logs in with the well-known ubnt/ubnt password,
# and its forced shell (adopt-shell.sh) only limits COMMANDS: dropbear still
# lets any password-authenticated account forward TCP, which would turn the
# unadopted AP into a tunnel into every network it sits on. dropbear has no
# per-user switch, so forwarding is off for everyone for as long as the account
# is unlocked (until adoption), and exactly what the board had comes back after.
# inform.lua runs this alongside passwd -u / passwd -l.

set -u
changed=0
sections=$(uci -X -q show dropbear | sed -n 's/^dropbear\.\([^.=]*\)=dropbear$/\1/p')

case "${1:-}" in
	lock)
		for s in $sections; do
			for o in LocalPortForward RemotePortForward; do
				cur=$(uci -q get "dropbear.$s.$o")
				[ "$cur" = 0 ] && continue
				uci -q get "dropbear.$s.openuf_$o" >/dev/null \
					|| uci set "dropbear.$s.openuf_$o=${cur:-unset}"
				uci set "dropbear.$s.$o=0"
				changed=1
			done
		done
		;;
	restore)
		for s in $sections; do
			for o in LocalPortForward RemotePortForward; do
				orig=$(uci -q get "dropbear.$s.openuf_$o") || continue
				if [ "$orig" = unset ]; then
					uci -q delete "dropbear.$s.$o"
				else
					uci set "dropbear.$s.$o=$orig"
				fi
				uci -q delete "dropbear.$s.openuf_$o"
				changed=1
			done
		done
		;;
	*)
		echo "usage: $0 lock|restore" >&2
		exit 2
		;;
esac

if [ "$changed" = 1 ]; then
	uci commit dropbear
	/etc/init.d/dropbear reload >/dev/null 2>&1
fi
exit 0
