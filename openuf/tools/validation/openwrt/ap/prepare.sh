#!/bin/sh
# Run once after /sbin/init is up: bring up the two downstream "sockets" lan1
# and lan2 (veth pairs whose far ends live in the clients container), install
# the bifrost-style network, and let netifd bring it up.
# (bench.sh up has already moved c1eth/c2eth into the clients container.)
for n in 1 2; do
	ip link show "lan$n" >/dev/null 2>&1 || ip link add "lan$n" type veth peer name "c${n}eth"
	ip link set "lan$n" up
done
# Docker's eth0 plays no part: the uplink is `wan`, a veth to the gateway.
ip addr flush dev eth0
ip link set eth0 down
until [ -e /sys/class/net/wan ]; do sleep 1; done
ip link set wan up
# Docker Desktop's kernel has br_netfilter loaded for every namespace, which
# sends bridged frames through fw4's forward chain; an OpenWrt AP does not
# load br_netfilter at all.
for f in iptables ip6tables arptables; do
	echo 0 > "/proc/sys/net/bridge/bridge-nf-call-$f" 2>/dev/null || true
done
cp /etc/config/network.bench /etc/config/network
# The rootfs ships dnsmasq/odhcpd for a router; an AP bench runs neither.
/etc/init.d/dnsmasq stop 2>/dev/null; /etc/init.d/dnsmasq disable 2>/dev/null
/etc/init.d/odhcpd stop 2>/dev/null; /etc/init.d/odhcpd disable 2>/dev/null
/etc/init.d/network reload
