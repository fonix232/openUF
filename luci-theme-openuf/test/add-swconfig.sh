#!/bin/sh
#
# Give the test container a swconfig switch, so the pages that exist only on
# a board with a switch chip (Network > Switch) have one to show: the
# TP-Link Archer C5 v1's AR8327. openUF itself no longer runs on swconfig
# boards, but LuCI still serves this page on them, and so does the theme.
#
#   sh test/add-swconfig.sh CONTAINER
#
# - /sbin/swconfig is test/fixtures/swconfig, a stub that answers from files:
#   "show" is a verbatim capture from that board, kept from openUF's test
#   fixtures from before it dropped swconfig boards
#   (fixtures/swconfig_show_ar8327.txt: ports 0 and 6 are the CPU, 1 is WAN
#   at 100baseT, 2 and 4 are LAN at gigabit, 3 and 5 have no link), and
#   "help" is fixtures/swconfig_help_ar8327.txt, in the real tool's format
#   with the ar8327 driver's attributes.
# - /etc/board.json gains the board's switch layout, written by the line
#   ath79's 02_network has for it, so LuCI labels the ports.
# - UCI network gets what config_generate writes from that layout (VLAN 1:
#   the LAN sockets and CPU port 0; VLAN 2: WAN and CPU port 6, both CPU
#   ports untagged, as on the board), plus the tagged VLAN 10 trunk openUF
#   had there for a tagged SSID when the capture was taken (CPU port 0 and
#   the four LAN sockets). Interfaces and devices are left alone: eth0
#   carries the lab's address.
#
# L.hasSystemFeature('swconfig') is then true on every page, and the Status
# overview drops its port card for it: run.sh does this only when asked
# (UF_SWCONFIG=1).

set -eu

here=$(cd "$(dirname "$0")" && pwd)
name=$1
show=$here/fixtures/swconfig_show_ar8327.txt

if [ ! -f "$show" ]; then
	echo "add-swconfig: no capture at $show" >&2
	exit 1
fi

docker exec "$name" mkdir -p /usr/share/swconfig-fake
docker exec -i "$name" sh -c 'cat > /sbin/swconfig && chmod 755 /sbin/swconfig' < "$here/fixtures/swconfig"
docker exec -i "$name" sh -c 'cat > /usr/share/swconfig-fake/switch0.help' < "$here/fixtures/swconfig_help_ar8327.txt"
docker exec -i "$name" sh -c 'cat > /usr/share/swconfig-fake/switch0.show' < "$show"

# Not under set -e: OpenWrt's JSON helpers are not written for it. The last
# command checks the result instead.
docker exec -i "$name" sh <<'EOF'
# The layout, from OpenWrt's own helper into a scratch file; only its
# "switch" key is merged into board.json, whose "network" key (the ports
# the Status overview lists) stays the container's.
. /lib/functions/uci-defaults.sh
CFG=/tmp/board-switch.json
rm -f "$CFG"
board_config_update
ucidef_add_switch "switch0" \
	"0u@eth1" "2:lan" "3:lan" "4:lan" "5:lan" "6u@eth0" "1:wan"
board_config_flush

ucode -l fs -e '
	const board = json(fs.readfile("/etc/board.json"));
	board.switch = json(fs.readfile("/tmp/board-switch.json")).switch;
	fs.writefile("/etc/board.json", sprintf("%.J\n", board));
'
rm -f "$CFG"

while uci -q delete network.@switch_vlan[0]; do :; done
while uci -q delete network.@switch[0]; do :; done

uci batch >/dev/null <<-UCI
	add network switch
	set network.@switch[-1].name='switch0'
	set network.@switch[-1].reset='1'
	set network.@switch[-1].enable_vlan='1'
	add network switch_vlan
	set network.@switch_vlan[-1].device='switch0'
	set network.@switch_vlan[-1].vlan='1'
	set network.@switch_vlan[-1].ports='2 3 4 5 0'
	add network switch_vlan
	set network.@switch_vlan[-1].device='switch0'
	set network.@switch_vlan[-1].vlan='2'
	set network.@switch_vlan[-1].ports='1 6'
	set network.openuf_swvlan10=switch_vlan
	set network.openuf_swvlan10.device='switch0'
	set network.openuf_swvlan10.vlan='10'
	set network.openuf_swvlan10.ports='0t 2t 3t 4t 5t'
	commit network
UCI

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/

jsonfilter -i /etc/board.json -e '@.switch.switch0.ports' >/dev/null &&
	[ "$(uci -q get network.openuf_swvlan10.ports)" = "0t 2t 3t 4t 5t" ]
EOF

echo "added swconfig switch0 (Archer C5 v1, AR8327)"
