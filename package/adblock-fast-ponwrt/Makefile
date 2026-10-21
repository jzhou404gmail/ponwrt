# SPDX-License-Identifier: GPL-2.0-only
#
# Distro defaults for adblock-fast.  Kept in a local package rather than in
# the (git-ignored) files/ overlay so the 12-model release builds are
# reproducible.

include $(TOPDIR)/rules.mk

PKG_NAME:=adblock-fast-ponwrt
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/adblock-fast-ponwrt
  SECTION:=net
  CATEGORY:=Network
  TITLE:=PonWrt adblock-fast defaults
  DEPENDS:=+adblock-fast
  PKGARCH:=all
endef

define Package/adblock-fast-ponwrt/description
  PonWrt defaults for adblock-fast: anti-AD + OISD Small, Xiaomi TV ad
  domains, force_dns=0 so PassWall keeps ownership of the client DNS path.
endef

define Build/Compile
endef

define Package/adblock-fast-ponwrt/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/95-adblock-fast-ponwrt $(1)/etc/uci-defaults/95-adblock-fast-ponwrt
endef

$(eval $(call BuildPackage,adblock-fast-ponwrt))
