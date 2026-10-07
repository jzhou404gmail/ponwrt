# This is free software, licensed under the Apache License, Version 2.0 .
#
# PonWrt port of https://github.com/rchen14b/luci-app-airoha-npu
#
# Upstream assumes the WAN is the EN8811 2.5G PHY on GDM4. On PonWrt the
# upstream link is the XPON GEM data path on GDM2 (netdev pon0) and the 2.5G
# PHY became a LAN port, so the GDM port roles are resolved from the running
# device tree instead of being hardcoded.

include $(TOPDIR)/rules.mk

PKG_VERSION:=1.2.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

# luci.mk derives the luci-i18n-* package version from findrev, which walks the
# git history of the directory the package lives in. This package is not part
# of the luci feed, so that lookup yields nothing and the translation package
# would be versioned "0" (meaning a translation-only update could never be
# installed as an upgrade). Pin it to the application version instead.
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

LUCI_TITLE:=LuCI Airoha SoC Status (NPU, CPU, Frame Engine)
LUCI_DESCRIPTION:=Real-time monitoring of the Airoha AN7581 SoC: NPU offload, \
	CPU frequency, Frame Engine (PSE/GDM) counters and the PPE flow table. \
	Adapted for PonWrt, where the WAN is the PON port (GDM2 / pon0).
LUCI_DEPENDS:=+luci-base +jsonfilter @TARGET_airoha

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
