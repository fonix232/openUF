#!/bin/sh
#
# Log lines of every severity in the test container, for Status > System Log
# and Kernel Log, which the theme draws a row per line, coloured by severity:
#
#   sh test/add-logs.sh CONTAINER
#
# The System Log gets them from logger, the Kernel Log from /dev/kmsg, as on
# a device. A container may not read the kernel's log, though (klogctl needs
# CAP_SYSLOG, and /dev/kmsg is a plain file there): then fixtures/dmesg.sh
# stands in for dmesg, with a boot log (fixtures/dmesg) and whatever is
# written to /dev/kmsg after it.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
name=$1

if ! docker exec "$name" dmesg -r >/dev/null 2>&1; then
	docker exec -i "$name" sh -c 'cat > /etc/fake-dmesg' < "$here/fixtures/dmesg"
	docker exec -i "$name" sh -c 'rm -f /bin/dmesg && cat > /bin/dmesg && chmod 755 /bin/dmesg' < "$here/fixtures/dmesg.sh"
	echo "faked dmesg"
fi

docker exec -i "$name" sh -s <<'EOF'
logger -p daemon.info -t 'dnsmasq[1204]' 'started, version 2.90 cachesize 1000'
logger -p daemon.notice -t netifd "Interface 'lan' is now up"
logger -p daemon.warning -t 'odhcpd[1311]' 'No default route present, overriding ra_lifetime to 0!'
logger -p daemon.err -t 'uhttpd[1074]' 'socket(): Address family not supported by protocol'
logger -p daemon.debug -t hostapd 'phy0-ap0: STA 00:00:5e:00:53:01 WPA: EAPOL-Key timeout'
logger -p user.crit -t kernel '[   42.108271] EXT4-fs error (device sdb1): ext4_find_entry:1683: inode #2: comm ls: reading directory lblock 0'
logger -p user.emerg -t watchdog 'hardware watchdog did not respond, rebooting'
logger -p auth.alert -t 'dropbear[2211]' "Exit before auth from <198.51.100.7:52110>: Max auth tries reached - user 'root'"
logger -p authpriv.info -t 'dropbear[2214]' "Password auth succeeded for 'root' from 192.0.2.10:52114"
logger -p cron.info -t 'crond[1190]' 'USER root pid 3021 cmd /usr/sbin/ntpd -q -p 0.openwrt.pool.ntp.org'
logger -p daemon.notice -t 'ntpd[1402]' 'reply from 192.0.2.1: offset:+0.001233 delay:0.001034 status:0x24 strat:2 refid:0x0100007f rootdelay:0.000992'
logger -p local0.warning -t openuf 'controller unreachable, retrying in 30s'
logger -p daemon.debug -t 'odhcpd[1311]' 'Got a DHCPv6-request on br-lan'
logger -p daemon.info -t 'hostapd' 'phy0-ap0: STA 00:00:5e:00:53:02 IEEE 802.11: associated (aid 1)'

echo '<6>br-lan: port 2(lan2) entered forwarding state' >> /dev/kmsg
echo '<4>mt7915e 0000:02:00.0: Message 00020007 (seq 3) timeout' >> /dev/kmsg
echo '<3>mtd: partition "rootfs_data" extends beyond the end of device "spi0.0" -- size truncated' >> /dev/kmsg
echo '<5>audit: type=1403 audit(1790468795.517:2): auid=4294967295 ses=4294967295 lsm=selinux res=1' >> /dev/kmsg
echo '<7>wlan0: authenticate with 00:00:5e:00:53:03 (local address=00:00:5e:00:53:04)' >> /dev/kmsg
dmesg -r >/dev/null
EOF

echo "added log lines"
