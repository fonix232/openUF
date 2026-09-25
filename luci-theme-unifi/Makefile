#
# luci-theme-unifi: a LuCI theme with the look and feel of the UniFi
# Network Application (10.x): an app bar across the top, an icon rail down
# the left, a secondary navigation column, and white cards on a pale canvas.
#
# Build it as part of a feed. openUF is a valid feed as it stands, because
# the OpenWrt feed scripts find every package Makefile in the tree:
#
#   echo 'src-git openuf https://github.com/fonix232/openUF.git' >> feeds.conf
#   ./scripts/feeds update openuf luci
#   ./scripts/feeds install luci-theme-unifi
#   make package/luci-theme-unifi/compile
#
# No buildroot at hand? See README.md: the theme is plain files, so
# install.sh can copy it straight onto a running device.
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=UniFi Theme
LUCI_DESCRIPTION:=A LuCI theme modelled on the UniFi Network Application, \
	with light, dark and follow-the-system colour schemes.
LUCI_DEPENDS:=+luci-base
LUCI_URL:=https://github.com/fonix232/openUF
LUCI_MAINTAINER:=openUF contributors

PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

define Package/luci-theme-unifi/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	case "$$(uci -q get luci.main.mediaurlbase)" in
		/luci-static/unifi*) uci set luci.main.mediaurlbase=/luci-static/bootstrap ;;
	esac
	uci -q delete luci.themes.UniFi
	uci -q delete luci.themes.UniFiDark
	uci -q delete luci.themes.UniFiLight
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
