<a id="top"></a>

# PonWrt（中文优先）

**简体中文（默认）** · [English ↓](#english) · [本 fork 的改动记录](README.zh-CN.md) · [上游中文说明](README_zh.md)

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试，并把调出来的修复固化回源码树。

> 📌 **详细记录在 [README.zh-CN.md](README.zh-CN.md)** —— 每一处修复的**现象、根因、寄存器级证据
> 与上机验证方法**都写在那里。下方 [English](#english) 一节是上游 `README.md` 的英文原文（辅）。

## 本 fork 改了什么

| 方面 | 改动 |
|---|---|
| 面板 LAN 灯 | **netdev 触发器整批缺失**（ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A，以及 an7583 的 XG-040G-MF）：EN8811H 驱动把 PHY 的 LED 输出设成用户自定义模式，而 LED core 注册类设备时又会把驱动写好的规则清零 —— 没有 `netdev` 触发，口 link 上了灯也是灭的 |
| 面板口序 | UNG00A 的原厂 DTB 把口序写反了，**真正的 LAN4 口一直是死的** |
| HG5585F-CT | 把 GPY211C 的 PHY ID 写进设备树，热重启后不会再绑上不协商的 Generic Clause 45 PHY，`lan1` 不再一直 NO-CARRIER |
| AN7583 硬件加密 | 内核 AES 之前**全是软件**。现在开了 ARMv8 CE（AES 全模式 + GHASH/PMULL）、`CRYPTO_CBC`、`CRYPTO_AUTHENC`、AF_ALG 与 EIP-93 引擎，并带上对应的用户态包（`kmod-crypto-hw-eip93` / `kmod-cryptodev` / `libopenssl-devcrypto`） |
| 无线默认值 | 带无线的三款机型统一默认值：国家码 `CN`、5G 160MHz、2.4G/5G 各自 SSID、WPA2-PSK。**世界监管域里没有能起 AP 的 160MHz 段**，不设国家码时 5G 选 160MHz 会让整个 radio 消失 |
| PON 面板灯 | 「光信号」灯保持传统语义（正常灭、无光红闪）；「上网」灯改成**真实探测能不能上网**，不再跟着 PON 注册状态 |
| `luci-app-airoha-npu` | NPU 面板移植，**WAN = PON 口**（上游是 2.5G 铜口），WiFi 数据源重写，并新增 CDM1/CDM2 两张 CPU DMA 卡片 |
| IPTV | 机顶盒报「2001 网络不可达」：组播 VLAN 口上保持 MAC 学习关闭 |
| 构建工具 | `build.sh` / `build-watch.sh` / `build-live.sh`；上游 feed 补丁机制（`feed-patches/`，幂等）；`verify-images.sh` 挡掉**能编译但不能刷**的产物 |

本 fork 只保留**一条主线**：`master` = 上游 + 本 fork 的全部改动，构建就从这一条分支走。

## 支持机型 / 编译 / 刷入

这三节与上游一致，**中文全文见 [README_zh.md](README_zh.md)**（上游中文说明，本仓库原样保留），
英文全文见下方 [English](#english)。摘要：

- **支持机型**：AN7581 十款 —— FiberHome HG5382A、HG5585F CT / CU、Gemtek XG2010G、
  Nokia XG-040G-MD / -TF UBI、UnionMan UNG00A、ZNXT ZN504XG-D / ZN515XG-D、H3C HM2004-DU；
  以及 AN7583 的 Nokia XG-040G-MF（`nokia_xg-040g-mf`、`nokia_xg-040g-mf-ubi` 两个 profile）。
- **编译**：`cp configs/an7581.config .config`（AN7583 换成 `configs/an7583.config`）→
  `make defconfig` → `make -j$(nproc)`，产物在 `bin/targets/airoha/{an7581,an7583}/`。
  本 fork 另提供 `./build.sh`（对增量编译友好，并自动套用 feed 补丁、做完产物体检），
  见 [README.zh-CN.md](README.zh-CN.md) 第 5 节。
- **刷入**：先用 [AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) 备份原厂 flash 并写入
  UBI 布局，启动镜像与 Web 恢复由 [AN758x U-Boot](https://github.com/pbs05/uboot-an758x) 提供；
  刷完后经 U-Boot Web 或 LuCI 的 **网络 → PON → 配置 → PON 板卡数据** 回填原厂校准与身份数据
  （FiberHome 的 `factory` 备份需先用 [FiberHome Factory](https://github.com/pbs05/fiberhome-factory) 转换）。

---

<a id="english"></a>

> **English（英文版，辅）** —— 以下是上游 `README.md` 的英文原文，**逐字保留未改**。
>
> [↑ 返回中文（默认）](#top) · [本 fork 的详细改动记录（中文）](README.zh-CN.md) · [上游中文说明](README_zh.md)

# PonWrt

English | [简体中文](README_zh.md)

PonWrt is based on [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) and adds support for Airoha AN7581 and AN7583 PON devices.

> 📌 **This repository is a fork of [pbs05/ponwrt](https://github.com/pbs05/ponwrt).** It carries a
> batch of hardware fixes found by debugging real AN7581 / AN7583 ONUs on the bench. The full
> write-up — symptom, root cause, register-level evidence and how to verify each fix — is in
> **[README.zh-CN.md](README.zh-CN.md)** (Chinese). The Chinese version of this page is at the
> [top](#top); from here down the text is upstream's own, kept verbatim.

## What this fork adds

| Area | Change |
| --- | --- |
| Panel LAN LEDs | The netdev triggers were missing entirely (ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A, and the AN7583 XG-040G-MF): the EN8811H driver puts its LED outputs into user-defined mode and the LED core clears the driver's own rules at registration, so without a `netdev` trigger the jack stays dark even with the port linked. |
| Panel port order | The UNG00A factory DTB reverses the panel order, which left the real LAN4 jack dead. |
| HG5585F-CT | The GPY211C PHY ID is pinned in the device tree, so a warm reboot can no longer bind the non-negotiating Generic Clause 45 PHY and leave `lan1` at NO-CARRIER. |
| AN7583 crypto | Kernel AES was entirely software. The ARMv8 Crypto Extensions (AES + GHASH/PMULL), `CRYPTO_CBC`, `CRYPTO_AUTHENC`, AF_ALG and the EIP-93 engine are now enabled, together with the matching userspace packages (`kmod-crypto-hw-eip93`, `kmod-cryptodev`, `libopenssl-devcrypto`). |
| Wireless defaults | One set of defaults for the three wireless boards: country `CN`, 160 MHz on 5 GHz, separate 2.4/5 GHz SSIDs, WPA2-PSK. Needed because the world regulatory domain has no AP-capable 160 MHz block, so the 5 GHz radio silently disappears at 160 MHz. |
| PON panel LEDs | The "optical signal" LED keeps the conventional meaning (off when the link is healthy, slow blink when there is no light), and the "internet" LED follows a real reachability probe rather than the PON registration state. |
| `luci-app-airoha-npu` | The NPU dashboard ported with **WAN = the PON port** instead of the 2.5G copper port, with rewritten WiFi data sources and CDM1/CDM2 CPU DMA cards. |
| IPTV | Set-top boxes reporting "2001 network unreachable": MAC learning is kept off on the multicast VLAN port. |
| Build tooling | `build.sh` / `build-watch.sh` / `build-live.sh`, an idempotent mechanism for patching upstream feeds (`feed-patches/`), and `verify-images.sh`, which rejects images that compile but cannot boot. |

This fork keeps **a single main line**: `master` carries upstream plus every fork change, so that is
the only branch to build from.

## ⚠️ Disclaimer

PonWrt is an open-source firmware project intended for research and development.

Flashing firmware or modifying PON-related settings involves risks and may result in boot failure, loss of configuration or device-specific data, or failure to register with the PON network. Please back up the original firmware and device data before making any changes.

Users are responsible for ensuring that their use complies with applicable laws, regulations, and network operator requirements. Do not use this project for unauthorized network access, impersonating or cloning another device's identity, or interfering with operator networks.

The authors and contributors are not responsible for device damage, network service disruption, or other consequences resulting from flashing, configuring, or using this project.

## Supported devices

| SoC | Device | Profile | Stock calibration / identity data |
| --- | --- | --- | --- |
| AN7581 | FiberHome HG5382A | `fiberhome_hg5382a` | `factory` |
| AN7581 | FiberHome HG5585F CT | `fiberhome_hg5585f-ct` | `factory` |
| AN7581 | FiberHome HG5585F CU | `fiberhome_hg5585f-cu` | `factory` |
| AN7581 | Gemtek XG2010G | `gemtek_xg2010g` | `dsd` |
| AN7581 | Nokia XG-040G-MD UBI | `nokia_xg-040g-md-ubi` | `bosa`, `ri` |
| AN7581 | Nokia XG-040G-TF UBI | `nokia_xg-040g-tf-ubi` | `bosa`, `ri` |
| AN7581 | UnionMan UNG00A | `unionman_ung00a` | `reservearea` |
| AN7581 | ZNXT ZN504XG-D | `znxt_zn504xg-d` | `reservearea` |
| AN7581 | ZNXT ZN515XG-D | `znxt_zn515xg-d` | `reservearea` |
| AN7581 | H3C HM2004-DU | `h3c_hm2004-du` | `factory` |
| AN7583 | Nokia XG-040G-MF | `nokia_xg-040g-mf`, `nokia_xg-040g-mf-ubi` | `bosa`, `ri` |

## Build

```sh
#  Install the required toolchain and libraries for building
sudo apt update -y
sudo apt full-upgrade -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
  bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
  g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
  libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
  libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
  ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
  python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs \
  upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd

#  Or use the ImmortalWrt one-click script to install dependencies
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'


#  Clone the source code
git clone https://github.com/pbs05/ponwrt.git
cd ponwrt


#  Update and install feeds (package sources)
./scripts/feeds update -a
./scripts/feeds install -a


#  Select a configuration, using 7581 as an example
cp configs/an7581.config .config
#  If the target is AN7583, use the following line instead:
cp configs/an7583.config .config



#  Start building
# -j$(nproc) means compiling in parallel with all CPU cores to speed things up
make defconfig
make -j$(nproc)
```

Images are written to `bin/targets/airoha/an7581/` or `bin/targets/airoha/an7583/`.

## Install

Use [AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) to back up the stock flash and install the UBI layout. Boot images and Web recovery are provided by [AN758x U-Boot](https://github.com/pbs05/uboot-an758x).

After installing PonWrt, restore the stock calibration and identity data through U-Boot Web or **Network → PON → Configuration → PON board data** in LuCI. Convert FiberHome `factory` backups with [FiberHome Factory](https://github.com/pbs05/fiberhome-factory) first. Restore converted FiberHome data, `reservearea`, or `dsd` backups to the PonWrt `factory` volume. Nokia `bosa` and `ri` backups use volumes with the same names.
