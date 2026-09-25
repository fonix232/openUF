# LuCI status page for openUF (Services -> openUF).
#
# Built by the LuCI feed: copy this directory to feeds/luci/applications/.
# install.sh installs the same files directly when LuCI is present.

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for openUF
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

PKG_LICENSE:=MIT

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
