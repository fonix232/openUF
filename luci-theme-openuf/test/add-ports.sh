#!/bin/sh
#
# Give the test container switch ports to show, the way a DSA router has
# them: lan1..lan4 in a VLAN-filtering br-lan and a wan port.
#
#   sh test/add-ports.sh CONTAINER
#
# The container has no NET_ADMIN (and must not: eth0 carries the address
# LuCI is reached on), so the ports are veth pairs made from the host in
# the container's network namespace. A port has carrier while its peer
# (lanNp) is up, so some peers stay down; lan4 itself stays down, which
# LuCI reports as a disabled port. Every veth reports 10 Gbit/s.
#
# board.json then lists them, as board.d would on real hardware, and UCI
# puts them in networks and VLANs:
#
#   VLAN 1   untagged on lan1-lan3        network lan, zone lan
#   VLAN 30  tagged on lan3, native lan4  network iot, zone iot
#   wan                                   network wan (DHCP), zone wan
#
# netifd cannot bring anything up without NET_ADMIN either, so the bridge
# is made here too. eth0 is left alone.

set -eu

name=$1

for tool in nsenter ip; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "warning: no $tool on this host; the test container gets no switch ports" >&2
		exit 0
	fi
done

pid=$(docker inspect -f '{{.State.Pid}}' "$name")

ns() {
	nsenter -t "$pid" -n "$@"
}

if ! ns ip link show lo >/dev/null 2>&1; then
	echo "warning: cannot enter the network namespace of $name (not root?); no switch ports" >&2
	exit 0
fi

for port in lan1 lan2 lan3 lan4 wan; do
	ns ip link add "$port" type veth peer name "${port}p"
done

# The VLANs themselves live in UCI only (LuCI reads them from there), so a
# kernel without bridge VLAN filtering gets a plain bridge.
ns ip link add br-lan type bridge vlan_filtering 1 2>/dev/null ||
	ns ip link add br-lan type bridge

for port in lan1 lan2 lan3 lan4; do
	ns ip link set "$port" master br-lan
done

# Up with carrier: lan1, lan3, wan. Up without: lan2. Down: lan4.
for dev in lan1 lan1p lan2 lan3 lan3p wan wanp br-lan; do
	ns ip link set "$dev" up
done

docker exec -i "$name" sh -s <<'EOF'
set -e

# Keep what board.d detected (the model, eth0's own entry is replaced).
ucode -l fs -e '
	let board = json(fs.readfile("/etc/board.json") || "{}");
	board.network = {
		lan: { ports: [ "lan1", "lan2", "lan3", "lan4" ], protocol: "static" },
		wan: { device: "wan", protocol: "dhcp" }
	};
	fs.writefile("/etc/board.json", sprintf("%.J\n", board));
'

for s in $(uci -q show network | sed -n "s/^network\.\([^.=]*\)=device$/\1/p"); do
	[ "$(uci -q get "network.$s.name")" = br-lan ] && uci delete "network.$s"
done

uci -q batch <<UCI
set network.br_lan=device
set network.br_lan.name='br-lan'
set network.br_lan.type='bridge'
add_list network.br_lan.ports='lan1'
add_list network.br_lan.ports='lan2'
add_list network.br_lan.ports='lan3'
add_list network.br_lan.ports='lan4'
set network.br_lan_vlan1=bridge-vlan
set network.br_lan_vlan1.device='br-lan'
set network.br_lan_vlan1.vlan='1'
add_list network.br_lan_vlan1.ports='lan1:u*'
add_list network.br_lan_vlan1.ports='lan2:u*'
add_list network.br_lan_vlan1.ports='lan3:u*'
set network.br_lan_vlan30=bridge-vlan
set network.br_lan_vlan30.device='br-lan'
set network.br_lan_vlan30.vlan='30'
add_list network.br_lan_vlan30.ports='lan3:t'
add_list network.br_lan_vlan30.ports='lan4:u*'
set network.lan.device='br-lan.1'
set network.iot=interface
set network.iot.device='br-lan.30'
set network.iot.proto='static'
set network.iot.ipaddr='192.168.30.1/24'
set network.wan=interface
set network.wan.device='wan'
set network.wan.proto='dhcp'
commit network
UCI

zone=$(uci add firewall zone)
uci -q batch <<UCI
set firewall.$zone.name='iot'
add_list firewall.$zone.network='iot'
set firewall.$zone.input='REJECT'
set firewall.$zone.output='ACCEPT'
set firewall.$zone.forward='REJECT'
commit firewall
UCI

/etc/init.d/network reload
EOF

echo "added ports lan1-lan4 and wan"
