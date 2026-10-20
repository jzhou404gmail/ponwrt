# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2021-2025  sirpdboy  <herboy2008@gmail.com>
# 
# This is free software, licensed under the Apache License, Version 2.0 .
#
#

include $(TOPDIR)/rules.mk

PKG_NAME:=lucky
PKG_VERSION:=2.27.2
PKG_RELEASE:=1
PKGARCH:=all 

ifeq ($(ARCH),mipsel)
	LUCKY_ARCH:=mipsle_softfloat
endif
ifeq ($(ARCH),mips)
	LUCKY_ARCH:=mips_softfloat
endif
ifeq ($(ARCH),i386)
	LUCKY_ARCH:=i386
endif
ifeq ($(ARCH),x86_64)
	LUCKY_ARCH:=x86_64
endif
ifeq ($(ARCH),arm)
	ifeq ($(BOARD),bcm53xx)
		LUCKY_ARCH:=armv6
	else
	LUCKY_ARCH:=armv7
endif
endif
ifeq ($(BOARD),bcm53xx)
	LUCKY_ARCH:=armv6
ifeq ($(word 2,$(subst +,$(space),$(call qstrip,$(CONFIG_CPU_TYPE)))),)
	LUCKY_ARCH:=armv5
endif
endif
ifeq ($(BOARD),kirkwood)
	LUCKY_ARCH:=armv5
endif
ifeq ($(ARCH),aarch64)
	LUCKY_ARCH:=arm64
endif

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=GDY666 <gdy666@foxmail.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# 上游用 PKG_HASH:=skip 加 Build/Prepare 里一句裸 wget：每次构建都下载
# GitHub 当天给的二进制，且没有任何校验 —— 而这个二进制会以 root 身份
# 跑在路由器上（/usr/bin/lucky）。这里改成框架管理的下载：
# 固定 URL + 固定哈希，哈希对不上时 prepare 阶段就失败，不会把未校验的
# 二进制打进固件。
#
# 下面的哈希是 arm64 包的实测值，本 fork 只编 aarch64（an7581/an7583 都是）。
# 将来若要为别的架构构建，必须补上对应架构的哈希 —— 留着这一条会让它
# 在下载校验处直接失败，这比静默装上未校验的二进制好。
PKG_SOURCE:=$(PKG_NAME)_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz
PKG_SOURCE_URL:=https://github.com/gdy666/lucky/releases/download/v$(PKG_VERSION)
PKG_HASH:=eb3a095238595193dab1fb486eed2a19d46190f37d4efd6630cc53e97d853466

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Lucky gdy
	DEPENDS:=@(i386||x86_64||arm||aarch64||mipsel||mips)
	URL:=https://github.com/gdy666/lucky
endef

define Package/$(PKG_NAME)/description
  Main functions of Lucky: ipv4/ipv6 portforward,ddns,IOT wake on lan ,reverse proxy and more...
endef

# 显式解压：框架的默认 Build/Prepare 只在 PKG_UNPACK 非空时才生成，而这个
# 包的 PKG_SOURCE 是由 LUCKY_ARCH 拼出来的，走默认路径时解压步骤被跳过 ——
# build_dir 里只剩下 stamp，随后 install 报 "cannot stat .../lucky"。
# 下载和哈希校验仍然由框架完成（dl/ 里那份已经验过），这里只负责解开它，
# 不再自己 wget。
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/lucky
/etc/lucky/*
endef
define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lucky $(1)/usr/bin/lucky
	$(INSTALL_BIN) $(CURDIR)/files/luckyarch.bin $(1)/usr/bin/luckyarch
	$(INSTALL_BIN) ./files/lucky.init $(1)/etc/init.d/lucky
	$(INSTALL_CONF) $(CURDIR)/files/lucky.config $(1)/etc/config/lucky
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
