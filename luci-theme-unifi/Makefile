#
# luci-theme-unifi: a LuCI theme with the look and feel of the UniFi Network
# Application 10.x: an app bar across the top, an icon rail down the left,
# a secondary navigation column, and white cards on a pale canvas.
#
# Plain package rules rather than luci.mk, like luci-app-openuf, so this feed
# builds without the LuCI feed checked out beside it. The theme is files
# only: templates, stylesheets, a few scripts, a menu entry, an rpcd ACL and
# a uci-defaults hook.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-theme-unifi
PKG_VERSION:=1.0.0
# The UTC date (YYYYMMDDHHMM) of the last commit that touched the theme, as
# openuf's Makefile does for the whole tree but limited to this directory:
# the theme is independent of the daemon, so a daemon-only change should not
# offer every device a theme "upgrade" that changes nothing. 1 outside git.
PKG_RELEASE:=$(or $(shell TZ=UTC git -C $(CURDIR) log -1 --format=%cd --date=format-local:%Y%m%d%H%M -- . 2>/dev/null),1)

PKG_MAINTAINER:=fonix232
# Apache-2.0 like LuCI and luci-theme-bootstrap, whose template structure and
# selector coverage it follows; the rest of openUF is MIT.
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

# "a b" -> "a (>=0), b (>=0)": EXTRA_DEPENDS entries must carry a version
# constraint, so each gets one that any version meets.
runtime_depends=$(subst |,$(space),$(subst $(space),$(comma)$(space),$(foreach d,$(1),$(d)|(>=0))))

# See openuf/Makefile: runtime-only dependencies in the feed's own builds.
LUCI_THEME_UNIFI_DEPENDS:=luci-base

define Package/luci-theme-unifi
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=4. Themes
  TITLE:=UniFi Theme
  URL:=https://github.com/fonix232/openUF
  PKGARCH:=all
  DEPENDS:=@USE_APK $(if $(filter 1,$(OPENUF_FEED_BUILD)),,$(addprefix +,$(LUCI_THEME_UNIFI_DEPENDS)))
  EXTRA_DEPENDS:=$(if $(filter 1,$(OPENUF_FEED_BUILD)),$(call runtime_depends,$(LUCI_THEME_UNIFI_DEPENDS)))
endef

define Package/luci-theme-unifi/description
  A LuCI theme modelled on the UniFi Network Application, with light, dark
  and follow-the-system colour schemes, and styling for luci-mod-dashboard.
  Network > Interfaces and Network > Wireless each come in three designs
  (device list, settings list, device cards), and Interfaces opens with a
  UniFi Port Manager of the router's ports; both are chosen on its own
  settings page, System > UniFi Theme.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

# The stylesheet ships as written: LuCI's csstidy rewrites selectors and
# properties it does not know, and collapsed the Status overview's grid.
# cp -R keeps the unifi-dark and unifi-light symlinks as links.
define Package/luci-theme-unifi/install
	$(INSTALL_DIR) $(1)/www $(1)/usr/share/ucode/luci
	$(CP) ./htdocs/. $(1)/www/
	$(CP) ./ucode/. $(1)/usr/share/ucode/luci/
	$(CP) ./root/. $(1)/
endef

# default_postinst runs the uci-defaults hook, which registers the three
# theme entries and selects UniFi on a first install.
define Package/luci-theme-unifi/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null
exit 0
endef

define Package/luci-theme-unifi/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
case "$$(uci -q get luci.main.mediaurlbase)" in
	/luci-static/unifi*) uci set luci.main.mediaurlbase=/luci-static/bootstrap ;;
esac
uci -q delete luci.themes.UniFi
uci -q delete luci.themes.UniFiDark
uci -q delete luci.themes.UniFiLight
uci -q delete luci.unifi
uci commit luci
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
exit 0
endef

$(eval $(call BuildPackage,luci-theme-unifi))
