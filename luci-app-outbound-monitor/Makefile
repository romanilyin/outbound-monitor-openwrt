# SPDX-License-Identifier: MIT
include $(TOPDIR)/rules.mk

PKG_VERSION:=2026.9.23
PKG_RELEASE:=3
PKG_LICENSE:=MIT
LUCI_TITLE:=LuCI outbound availability and delay charts
LUCI_DEPENDS:=+outbound-monitor +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - package scanner signature (implementation is in luci.mk)
