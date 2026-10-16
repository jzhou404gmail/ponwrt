# PonWrt

[English](README.en.md) | **简体中文** | [本 fork 的详细改动记录](README.zh-CN.md) | [上游中文说明](README_zh.md)

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试，并把调出来的修复固化回源码树。

> 📌 每一处修复的**现象、根因、寄存器级证据与上机验证方法**都记在
> **[README.zh-CN.md](README.zh-CN.md)**。英文说明见 **[README.en.md](README.en.md)**。

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
英文全文见 [README.en.md](README.en.md)。摘要：

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

## 免责声明

同上游：PonWrt 是用于研究与开发的开源固件项目。刷写固件或修改 PON 相关设置存在风险，
可能导致无法启动、配置或设备专有数据丢失，或无法在 PON 网络注册。**请在操作前备份原厂
固件与设备数据。**

使用者需自行确保使用方式符合当地法律法规与网络运营商要求。**请勿**将本项目用于未授权
的网络接入、伪造或克隆他人设备身份，或干扰运营商网络。

作者与贡献者不对刷机、配置或使用本项目造成的设备损坏、网络服务中断或其他后果负责。

## 致谢

上游 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 与
[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)；
NPU 面板界面来自 [rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)。
