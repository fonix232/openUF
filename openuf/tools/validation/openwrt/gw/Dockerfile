# Disposable VLAN-aware gateway for the bridge-ownership bench -- NOT part of
# openUF. Untagged + VLAN 2/3/12/50 DHCP on one trunk, NAT towards the
# controller, the way a UniFi gateway port feeds an AP.
FROM alpine:3.20
RUN apk add --no-cache dnsmasq iproute2 iptables tcpdump
COPY tools/validation/openwrt/gw/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
