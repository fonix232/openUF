#
# LuCI pages for openUF: Services -> openUF (Status, Settings, Unhandled
# messages). Plain package rules rather than luci.mk, so this feed builds
# without the LuCI feed checked out beside it.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openuf
PKG_VERSION:=0.10.0
# The commit's UTC date (YYYYMMDDHHMM): it only goes up however a change
# reaches main -- merge, squash or rebase -- where a commit count would drop
# after a squash. 1 outside a git checkout.
PKG_RELEASE:=$(or $(shell TZ=UTC git -C $(CURDIR) log -1 --format=%cd --date=format-local:%Y%m%d%H%M 2>/dev/null),1)

PKG_MAINTAINER:=fonix232
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# "a b" -> "a (>=0), b (>=0)": EXTRA_DEPENDS entries must carry a version
# constraint, so each gets one that any version meets.
runtime_depends=$(subst |,$(space),$(subst $(space),$(comma)$(space),$(foreach d,$(1),$(d)|(>=0))))

# See openuf/Makefile: runtime-only dependencies in the feed's own builds.
LUCI_OPENUF_DEPENDS:=openuf luci-base rpcd-mod-ucode

define Package/luci-app-openuf
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI pages for openUF
  URL:=https://github.com/fonix232/openUF
  PKGARCH:=all
  DEPENDS:=$(if $(filter 1,$(OPENUF_FEED_BUILD)),,$(addprefix +,$(LUCI_OPENUF_DEPENDS)))
  EXTRA_DEPENDS:=$(if $(filter 1,$(OPENUF_FEED_BUILD)),$(call runtime_depends,$(LUCI_OPENUF_DEPENDS)))
endef

define Package/luci-app-openuf/description
  Services -> openUF: the daemon's status, its settings (/etc/config/openuf)
  and the controller messages it did not act on.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-openuf/install
	$(INSTALL_DIR) $(1)/www $(1)/usr/share
	$(CP) ./htdocs/. $(1)/www/
	$(CP) ./root/usr/share/. $(1)/usr/share/
endef

define Package/luci-app-openuf/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,luci-app-openuf))
