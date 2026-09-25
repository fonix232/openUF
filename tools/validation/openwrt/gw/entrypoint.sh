#!/bin/sh
# The gateway's "trunk" is a point-to-point veth to the AP's `wan` socket,
# created by `bench.sh up` once both containers exist -- a real cable, unlike
# the Docker bridge, which reflects a client's broadcasts back into the AP and
# teaches its bridge the client's MAC on the uplink. eth0 is only the way to
# the controller.
set -e
TRUNK=${TRUNK:-trunk}
echo "gw: waiting for $TRUNK"
until [ -e "/sys/class/net/$TRUNK" ]; do sleep 1; done
ip link set "$TRUNK" up
ip addr add 192.168.1.1/24 dev "$TRUNK" 2>/dev/null || true
for vid in 2 3 12 50; do
	ip link add link "$TRUNK" name "$TRUNK.$vid" type vlan id "$vid" 2>/dev/null || true
	ip addr add "10.$vid.0.1/24" dev "$TRUNK.$vid" 2>/dev/null || true
	ip link set "$TRUNK.$vid" up
done
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
exec dnsmasq --no-daemon --log-dhcp --port=0 --bind-dynamic \
	--interface="$TRUNK"    --dhcp-range="$TRUNK,192.168.1.100,192.168.1.200,1h" \
	--interface="$TRUNK.2"  --dhcp-range="$TRUNK.2,10.2.0.100,10.2.0.200,1h" \
	--interface="$TRUNK.3"  --dhcp-range="$TRUNK.3,10.3.0.100,10.3.0.200,1h" \
	--interface="$TRUNK.12" --dhcp-range="$TRUNK.12,10.12.0.100,10.12.0.200,1h" \
	--interface="$TRUNK.50" --dhcp-range="$TRUNK.50,10.50.0.100,10.50.0.200,1h" \
	--dhcp-authoritative
