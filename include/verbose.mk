# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2006-2020 OpenWrt.org

ifndef OPENWRT_VERBOSE
  OPENWRT_VERBOSE:=
endif
ifeq ("$(origin V)", "command line")
  OPENWRT_VERBOSE:=$(V)
endif

ifeq ($(OPENWRT_VERBOSE),1)
  OPENWRT_VERBOSE:=w
endif
ifeq ($(OPENWRT_VERBOSE),99)
  OPENWRT_VERBOSE:=s
endif

ifeq ($(NO_TRACE_MAKE),)
NO_TRACE_MAKE := $(MAKE) V=s$(OPENWRT_VERBOSE)
export NO_TRACE_MAKE
endif

ifeq ($(IS_TTY),1)
  ifneq ($(strip $(NO_COLOR)),1)
    _Y:=\\033[33m
    _R:=\\033[31m
    _N:=\\033[m
  endif
endif

define ERROR_MESSAGE
  { \
	printf "$(_R)%s$(_N)\n" "$(1)" >&9 || \
	printf "$(_R)%s$(_N)\n" "$(1)"; \
  } >&2 2>/dev/null
endef

ifeq ($(findstring s,$(OPENWRT_VERBOSE)),)
  define MESSAGE
	{ \
		printf "$(_Y)%s$(_N)\n" "$(1)" >&8 || \
		printf "$(_Y)%s$(_N)\n" "$(1)"; \
	} 2>/dev/null
  endef

  ifeq ($(QUIET),1)
    ifneq ($(CURDIR),$(TOPDIR))
      _DIR:=$(patsubst $(TOPDIR)/%,%,${CURDIR})
    else
      _DIR:=
    endif
    _MESSAGE:=$(if $(MAKECMDGOALS),$(shell \
		$(call MESSAGE, make[$(MAKELEVEL)]$(if $(_DIR), -C $(_DIR)) $(MAKECMDGOALS)); \
    ))
    ifneq ($(strip $(_MESSAGE)),)
      $(info $(_MESSAGE))
    endif
    SUBMAKE=$(MAKE)
  else
    # stdout 照旧静音（控制台的进度块由 build-watch.sh 解析 tmp/build.log 生成），
    # 但 stderr 不再跟着丢进 /dev/null：顶层子 make（package/install、
    # target/install、package/index …）的真实报错全在 stderr，一起吞掉的后果是
    # tmp/build.log 里只剩一行 "make -r world: build failed"。2026-10-21 的
    # kernel.version 事故就是这样隐身了：69 秒"失败"，日志里一个字都没有。
    # 包内输出不受影响 —— include/subdir.mk 会单独 tee 到 logs/<包>/<步骤>.txt。
    SILENT:=>/dev/null
    export QUIET:=1
    SUBMAKE=cmd() { $(SILENT) $(MAKE) -s "$$@" < /dev/null || { echo "make $$*: build failed. Please re-run make with -j1 V=s or V=sc for a higher verbosity level to see what's going on"; false; } } 8>&1 9>&2; cmd
  endif

  .SILENT: $(MAKECMDGOALS)
else
  SUBMAKE=$(MAKE) -w
  define MESSAGE
    printf "%s\n" "$(1)"
  endef
endif
