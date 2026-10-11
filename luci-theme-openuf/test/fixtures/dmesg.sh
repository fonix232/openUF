#!/bin/sh
# Stand-in for busybox dmesg in the theme's lab (test/add-logs.sh), where
# the container may not read the kernel's log: the boot log from
# /etc/fake-dmesg, then each line written to /dev/kmsg (a plain file in
# a container) since, stamped with the uptime when first read. -r prints
# them as dmesg -r does, "<level>[seconds] message", a level written from
# userspace in the user facility, as the kernel files it; without -r the
# "<level>" goes.

log=/tmp/fake-dmesg

lock /var/lock/fake-dmesg
[ -f "$log" ] || cp /etc/fake-dmesg "$log"

if [ -s /dev/kmsg ]; then
	awk -v t="$(cut -d' ' -f1 /proc/uptime)" '
		match($0, /^<[0-9]+>/) {
			n = substr($0, 2, RLENGTH - 2) + 0
			printf "<%d>[%12.6f] %s\n", (n < 8) ? n + 8 : n, t, substr($0, RLENGTH + 1)
		}' /dev/kmsg >> "$log"
	: > /dev/kmsg
fi
lock -u /var/lock/fake-dmesg

case " $* " in
*" -r "*) cat "$log" ;;
*) sed 's/^<[0-9]*>//' "$log" ;;
esac
