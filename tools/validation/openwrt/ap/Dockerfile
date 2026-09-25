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
COPY openuf/ /opt/openuf/
COPY tools/validation/openwrt/ap/bench-modelmap.lua /opt/openuf/modelmap/bench.lua
COPY tools/validation/openwrt/ap/network.bifrost /etc/config/network.bench
COPY tools/validation/openwrt/ap/prepare.sh /usr/local/sbin/bench-prepare
RUN chmod +x /usr/local/sbin/bench-prepare /opt/openuf/hook/syswrapper.sh \
    && ln -sf /opt/openuf/hook/syswrapper.sh /usr/bin/syswrapper.sh \
    && mkdir -p /etc/openuf \
    && sed -i 's|^dev = dofile("modelmap/.*")|dev = dofile("modelmap/bench.lua")|' /opt/openuf/conf.lua
CMD ["/sbin/init"]
