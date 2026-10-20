# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2021-2026  sirpdboy  <herboy2008@gmail.com> https://github.com/sirpdboy/luci-app-lucky
# 
# This is free software, licensed under the Apache License, Version 2.0 .
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-lucky
PKG_VERSION:=3.0.3
PKG_RELEASE:=15

# luci.mk 用 findrev 走包目录所在的 git 历史来定 luci-i18n-* 的版本。这个包不在
# luci feed 里（是随仓库 vendored 进来的），findrev 拿不到东西，翻译包会被打成
# 版本 0（manifest 里就是 "luci-i18n-lucky-zh-cn - 0"），后果是翻译更新永远无法
# 作为一次升级被安装。固定成应用版本。与 package/luci-app-airoha-npu 同样处理。
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

LUCI_TITLE:=LuCI Support for Dynamic lucky Client
LUCI_DEPENDS:=+lucky
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
