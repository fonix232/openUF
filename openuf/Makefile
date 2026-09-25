#
# openUF: UniFi access point emulation for OpenWrt.
#
# Built by the OpenWrt SDK or buildroot from this feed (see the repository's
# README: the feed's CI builds it with the official SDK images).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=openuf
PKG_VERSION:=0.10.0
# Monotonic across builds of the branch the feed publishes from: its commit
# count. 1 outside a git checkout.
PKG_RELEASE:=$(shell git -C $(CURDIR) rev-list --count HEAD 2>/dev/null || echo 1)

PKG_MAINTAINER:=fonix232
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

# A host Lua strips the comments from what ships (tools/strip-tree.sh).
PKG_BUILD_DEPENDS:=lua/host

include $(INCLUDE_DIR)/package.mk

# "a b" -> "a (>=0), b (>=0)": EXTRA_DEPENDS entries must carry a version
# constraint, so each gets one that any version meets.
runtime_depends=$(subst |,$(space),$(subst $(space),$(comma)$(space),$(foreach d,$(1),$(d)|(>=0))))

# Runtime dependencies. OpenWrt makes every DEPENDS entry a build dependency
# too, so an SDK would compile openssl, hostapd, the kernel modules and the
# rest before packaging a few hundred KB of Lua. The feed's CI sets
# OPENUF_FEED_BUILD=1 and declares them as EXTRA_DEPENDS instead (package
# metadata only); a buildroot image build keeps DEPENDS, so selecting openuf
# selects them.
OPENUF_RUNTIME_DEPENDS:=lua lua-cjson luasocket lua-openssl luabitop libuci-lua \
	iw lldpd nftables kmod-nft-bridge hostapd-utils ip-bridge

define Package/openuf
  SECTION:=net
  CATEGORY:=Network
  TITLE:=UniFi access point emulation (adoptable by a UniFi Network controller)
  URL:=https://github.com/fonix232/openUF
  PKGARCH:=all
  DEPENDS:=$(if $(filter 1,$(OPENUF_FEED_BUILD)),,$(addprefix +,$(OPENUF_RUNTIME_DEPENDS)))
  EXTRA_DEPENDS:=$(if $(filter 1,$(OPENUF_FEED_BUILD)),$(call runtime_depends,$(OPENUF_RUNTIME_DEPENDS)))
endef

define Package/openuf/description
  Makes an OpenWrt access point adoptable by a UniFi Network controller: it
  speaks the controller's inform protocol, applies the WLANs, VLANs, radio
  and system settings the controller pushes, and reports clients, radios,
  ports and topology back. Settings: /etc/config/openuf.
  Optional extras: usteer (band steering), tc-tiny and kmod-sched-act-police
  (WiFi speed limits), luasec (an https:// inform URL), a full wpad build
  (BSS transition).
endef

define Package/openuf/conffiles
/etc/config/openuf
/etc/openuf/local.lua
endef

# The tree is staged in a subdirectory: the build directory also holds the
# build system's own stamps and package staging area.
OPENUF_TREE:=$(PKG_BUILD_DIR)/openuf

define Build/Prepare
	$(INSTALL_DIR) $(OPENUF_TREE)
	$(CP) ./src/. $(OPENUF_TREE)/
endef

define Build/Configure
endef

define Build/Compile
	sh ./tools/strip-tree.sh $(OPENUF_TREE) $(STAGING_DIR_HOSTPKG)/bin/lua
	echo "$(PKG_VERSION)-r$(PKG_RELEASE) $(shell git -C $(CURDIR) describe --tags --always --dirty 2>/dev/null)" \
		> $(OPENUF_TREE)/BUILD
endef

define Package/openuf/install
	$(INSTALL_DIR) $(1)/usr/share/openuf
	$(CP) $(OPENUF_TREE)/. $(1)/usr/share/openuf/
	chmod 0755 $(1)/usr/share/openuf/hook/*.sh
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/sbin
	$(LN) /usr/share/openuf/hook/syswrapper.sh $(1)/usr/bin/syswrapper.sh
	$(INSTALL_BIN) ./files/openuf-update $(1)/usr/sbin/openuf-update
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config $(1)/etc/uci-defaults $(1)/lib/upgrade/keep.d
	$(INSTALL_BIN) ./files/openuf.init $(1)/etc/init.d/openuf
	$(INSTALL_BIN) ./files/openuf-bootstrap.init $(1)/etc/init.d/openuf-bootstrap
	$(INSTALL_CONF) ./files/openuf.config $(1)/etc/config/openuf
	$(INSTALL_DATA) ./files/openuf.uci-defaults $(1)/etc/uci-defaults/80_openuf
	$(INSTALL_DATA) ./files/openuf.keep $(1)/lib/upgrade/keep.d/openuf
ifdef CONFIG_USE_APK
	$(INSTALL_DIR) $(1)/etc/apk/keys $(1)/etc/apk/repositories.d
	$(INSTALL_DATA) ./files/feed/openuf.pem $(1)/etc/apk/keys/openuf.pem
	$(INSTALL_DATA) ./files/feed/openuf.list $(1)/etc/apk/repositories.d/openuf.list
else
	$(INSTALL_DIR) $(1)/etc/opkg/keys
	$(INSTALL_DATA) ./files/feed/55e48a603d3eb56a $(1)/etc/opkg/keys/55e48a603d3eb56a
	$(INSTALL_DATA) ./files/feed/openuf.conf $(1)/etc/opkg/openuf.conf
endif
endef

# A tarball install (install.sh into /opt/openuf) predates the package: stop
# it, keep its conf.lua for the move into UCI (uci-defaults), and take its
# files away so the package's own go in cleanly.
define Package/openuf/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -d /opt/openuf ] || exit 0
/etc/init.d/openuf stop >/dev/null 2>&1
/etc/init.d/openuf disable >/dev/null 2>&1
/etc/init.d/openuf-bootstrap disable >/dev/null 2>&1
mkdir -p /etc/openuf
for f in /opt/openuf/conf.lua /etc/openuf/conf.lua.last; do
	[ -f "$$f" ] && { cp "$$f" /etc/openuf/conf.lua.legacy; break; }
done
rm -rf /opt/openuf /etc/openuf/dist
rm -f /etc/openuf/bootstrap.sh /etc/openuf/bootstrap.conf /etc/openuf/conf.lua.last \
	/etc/init.d/openuf /etc/init.d/openuf-bootstrap /usr/bin/openuf-update /usr/bin/syswrapper.sh \
	/usr/share/luci/menu.d/luci-app-openuf.json /usr/share/rpcd/acl.d/luci-app-openuf.json \
	/usr/share/rpcd/ucode/luci.openuf
rm -rf /www/luci-static/resources/view/openuf
[ -f /etc/sysupgrade.conf ] && sed -i -e '\#^/opt/openuf/conf.lua$$#d' \
	-e '\#^/etc/init.d/openuf-bootstrap$$#d' -e '\#^/etc/rc.d/S98openuf-bootstrap$$#d' /etc/sysupgrade.conf
exit 0
endef

# An upgrade replaces the Lua under a running daemon, and procd does not
# restart a service whose definition is unchanged (apk runs no stop before an
# upgrade): restart it onto the new code.
define Package/openuf/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE}" = 1 ] && /etc/init.d/openuf restart
exit 0
endef

# Removal (not upgrade): the SSH adoption account goes with the package.
define Package/openuf/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE}" = 1 ] && exit 0
if grep -q '^ubnt:[^:]*:[0-9]*:[0-9]*:openuf bootstrap adoption:' /etc/passwd 2>/dev/null; then
	sed -i '/^ubnt:/d' /etc/passwd /etc/shadow
	sed -i '/^openuf:/d' /etc/group
fi
exit 0
endef

# opkg leaves the package's directories behind, empty.
define Package/openuf/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rmdir /usr/share/openuf/* /usr/share/openuf 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,openuf))
