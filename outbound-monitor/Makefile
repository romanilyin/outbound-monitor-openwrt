# SPDX-License-Identifier: MIT
include $(TOPDIR)/rules.mk

PKG_NAME:=outbound-monitor
PKG_VERSION:=2026.9.23
PKG_RELEASE:=2
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/outbound-monitor
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight sing-box outbound availability history
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-digest +curl +ca-bundle +flock
  PKGARCH:=all
endef

define Package/outbound-monitor/conffiles
/etc/config/outbound-monitor
endef

define Build/Compile
endef

define Package/outbound-monitor/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/outbound-monitor $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/bin/outbound-monitor $(1)/usr/bin/outbound-monitor
	$(INSTALL_BIN) ./files/usr/bin/outbound-monitor-update $(1)/usr/bin/outbound-monitor-update
	$(INSTALL_DATA) ./files/usr/share/outbound-monitor/*.uc $(1)/usr/share/outbound-monitor/
	$(INSTALL_DATA) ../VERSION $(1)/usr/share/outbound-monitor/version
	$(INSTALL_BIN) ../install.sh $(1)/usr/share/outbound-monitor/install.sh
	$(INSTALL_CONF) ./files/etc/config/outbound-monitor $(1)/etc/config/outbound-monitor
	$(INSTALL_BIN) ./files/etc/init.d/outbound-monitor $(1)/etc/init.d/outbound-monitor
endef

$(eval $(call BuildPackage,outbound-monitor))
