# Disposable OpenWrt AP for the bridge-ownership bench -- NOT part of openUF.
# Real procd/ubusd/netifd/uci from an OpenWrt rootfs, so /etc/config/network
# changes are applied by genuine netifd, bridge-vlan and all. No radios: the
# WLAN side is exercised at the UCI level only.
ARG OPENWRT_TAG=armsr-armv8-SNAPSHOT
FROM openwrt/rootfs:${OPENWRT_TAG}
RUN mkdir -p /var/lock /var/run \
    && apk update \
    && apk add lua lua-cjson luasocket lua-openssl luabitop libuci-lua ip-full ip-bridge nftables \
    && rm -rf /var/cache/apk/*
# The package's files where the package puts them (no SDK needed for a bench).
COPY src/ /usr/share/openuf/
COPY files/openuf.init /etc/init.d/openuf
COPY files/openuf.config /etc/config/openuf
# Bench board (local.json over the derived description): `wan` is a veth
# cable to the bench gateway, lan1/lan2 are veths. U6IW numbering: 1-4
# downstream, 5 = the uplink ("PoE In + Data"). No status LED.
COPY tools/validation/openwrt/ap/bench-local.json /etc/openuf/local.json
COPY tools/validation/openwrt/ap/network.bifrost /etc/config/network.bench
COPY tools/validation/openwrt/ap/prepare.sh /usr/local/sbin/bench-prepare
RUN chmod +x /usr/local/sbin/bench-prepare /etc/init.d/openuf /usr/share/openuf/hook/*.sh \
    && ln -sf /usr/share/openuf/hook/syswrapper.sh /usr/bin/syswrapper.sh \
    && mkdir -p /etc/openuf
CMD ["/sbin/init"]
