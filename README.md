# PonWrt

[English](README.en.md) | **简体中文** | [本 fork 的详细改动记录](README.zh-CN.md) | [上游中文说明](README_zh.md)

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试，并把调出来的修复固化回源码树。

> 📌 每一处修复的**现象、根因、寄存器级证据与上机验证方法**都记在
> **[README.zh-CN.md](README.zh-CN.md)**。英文说明见 **[README.en.md](README.en.md)**。

## 本 fork 改了什么

| 方面 | 改动 |
|---|---|
| **UNG00A 的 LAN4 口是死的** | 原厂 DTB 把面板口序写反了：面板 LAN2 / LAN3 / LAN4 实际接的是交换口 3 / 2 / 1（PHY `0x0b` / `0x0a` / `0x09`），而 port4（PHY `0x0c`）**根本没接线**却占着 `lan4` 这个名字 ⇒ **真正的 LAN4 口一直是死的**。用"一根线在标注的口之间来回换、看哪个 netdev 拿到 carrier"实测出真实映射后改正口序，并顺手启用 PHY1 的 LED0 |
| **HG5585F-CT 的 2.5G 口（lan1）热重启后起不来** | 这颗 2.5G PHY 是 MaxLinear **GPY211C**，原来用字符串 compatible + `ethernet-phy-ieee802.3-c45` 描述。这个组合会让核心**在 `mdio_probe()` 释放复位 GPIO 之前**就去扫 MDIO 读 C45 ID；热重启时 PHY 那一刻还在复位里，ID 读到 `0xffffffff`，内核于是绑上不会协商的 `Generic Clause 45 PHY` ⇒ **lan1 一直 NO-CARRIER，要等到下次冷启动**。把 PHY ID 写死成 `ethernet-phy-id67c9.de10`，让设备直接由设备树创建，竞态就不存在了 |
| **面板 LAN 灯不亮（整批机型）** | ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A / an7583 的 XG-040G-MF：**netdev 触发器整批缺失**。EN8811H 驱动把 PHY 的 LED 输出设成用户自定义模式，而 LED core 注册类设备时又会把驱动写好的规则清零 —— 没有 `netdev` 触发，口 link 上了灯也是灭的 |
| **XG-040G-MF 的 LAN 灯类设备名不确定** | `gsw_phy2/3/4_led0` 只有颜色、没有 function 与 enumerator，LED core 就按注册顺序给名字（`green:lan`、`green:lan-1`…）⇒ **哪个类设备对应哪个口没有保证**，触发会绑错口。补上 `lan` function 与枚举 2/3/4 |
| **AN7583 硬件加密** | 内核 AES 之前**全是软件**（`/proc/crypto` 只有 13 个 software/generic 算法，连软件 `cbc(aes)` 都没有）。现在开了 ARMv8 CE（AES 全模式 + GHASH/PMULL）、`CRYPTO_CBC`、`CRYPTO_AUTHENC`、AF_ALG 与 EIP-93 引擎，并带上对应的用户态包（`kmod-crypto-hw-eip93` / `kmod-cryptodev` / `libopenssl-devcrypto`） |
| **无线默认值** | 带无线的三款机型统一默认值：国家码 `CN`、5G 160MHz、2.4G/5G 各自 SSID、WPA2-PSK。**世界监管域里没有能起 AP 的 160MHz 段**，不设国家码时 5G 选 160MHz 会让整个 radio 消失 |
| **PON 面板灯（含 EPON 上「上网」灯永远不亮）** | ① 「光信号」灯保持传统语义（正常灭、无光红闪），曾试过"有光常亮"，实机觉得别扭已退回；② **EPON 没有 OMCI**，`service_ready` 只由用户态 OAM 代理在 CTC 认证之后才写，而普通 MPCP 注册 + PPPoE 的线路永远到不了那个状态 ⇒ `pon0-online` 恒灭，补丁改为以"LLID 注册完成"作判据；③ 「上网」灯另外改成**真实探测能不能上网**，不再跟着 PON 注册状态 |
| **`luci-app-airoha-npu`** | NPU 面板移植，**WAN = PON 口**（上游是 2.5G 铜口）；WiFi 数据源按 MT7916D 重写（上游那套只认 mt7996，一个频段都匹配不上）；Frame Engine 区新增 CDM1 / CDM2 两张 CPU DMA 卡片；铜口卡改成运行时解析 GDM 而不是写死 gdm4；另加一个内核补丁把 **NPU 固件版本暴露到 sysfs**，用户态不必去 grep 启动日志 |
| **IPTV 机顶盒报「2001 网络不可达」** | 组播 VLAN 口上保持 MAC 学习关闭 |
| **构建工具** | `build.sh`：**不改动构建输入**（增量友好）、`--config=` 带备份与掉包保护、并发锁、逐包日志、**两处自愈**（包子构建被静默打断 / 内核树被留在 initramfs 配置上）、收尾汇总耗时并列出本次新产物；另有 `build-watch.sh`（读日志看进度）与 `build-live.sh`（不依赖日志，直接看进程与文件改动）；上游 feed 补丁机制（`feed-patches/`，幂等套用）；`verify-images.sh` 挡掉**能编译但不能刷**的产物。用法详见 [README.zh-CN.md](README.zh-CN.md) 第 5.3 节 |
| **其他** | `feeds.conf.default` 以注释形式记录可选的 PassWall feed；`.gitignore` 忽略本机 `.config` 备份、原厂固件转储与本机运维脚本 |

本 fork 只保留**一条主线**：`master` = 上游 + 本 fork 的全部改动，构建就从这一条分支走。

## 支持机型 / 编译 / 刷入

这三节与上游一致，**中文全文见 [README_zh.md](README_zh.md)**（上游中文说明，本仓库原样保留），
英文全文见 [README.en.md](README.en.md)。摘要：

- **支持机型**：AN7581 十款 —— FiberHome HG5382A、HG5585F CT / CU、Gemtek XG2010G、
  Nokia XG-040G-MD / -TF UBI、UnionMan UNG00A、ZNXT ZN504XG-D / ZN515XG-D、H3C HM2004-DU；
  以及 AN7583 的 Nokia XG-040G-MF（`nokia_xg-040g-mf`、`nokia_xg-040g-mf-ubi` 两个 profile）。
- **编译**：`cp configs/an7581.config .config`（AN7583 换成 `configs/an7583.config`）→
  `make defconfig` → `make -j$(nproc)`，产物在 `bin/targets/airoha/{an7581,an7583}/`。
  本 fork 另提供 **`./build.sh`** —— 默认沿用现有 `.config` 不动它（增量编译）、自动套 feed 补丁、
  逐包日志、失败自愈、编完自动做产物体检；**参数与用法见
  [README.zh-CN.md](README.zh-CN.md) 第 5.3 节**。
- **刷入**：先用 [AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) 备份原厂 flash 并写入
  UBI 布局，启动镜像与 Web 恢复由 [AN758x U-Boot](https://github.com/pbs05/uboot-an758x) 提供；
  刷完后经 U-Boot Web 或 LuCI 的 **网络 → PON → 配置 → PON 板卡数据** 回填原厂校准与身份数据
  （FiberHome 的 `factory` 备份需先用 [FiberHome Factory](https://github.com/pbs05/fiberhome-factory) 转换）。
- **发布（不用自己的机器）**：仓库自带 GitHub Actions。Actions 里手动跑 **`Release PonWrt`**
  并填一个 tag，就会编出 `ponwrt-an7581.tar.zst` / `ponwrt-an7583.tar.zst` + `sha256sums`
  并自动建 Release。**用的是 `configs/` 里的项目默认配置**
  （`kconfig.pl + configs/<target>.config configs/release.config`），**不是任何人的本机 `.config`**
  —— 后者根本没入库。细节与已知限制见 [README.zh-CN.md](README.zh-CN.md) 第 5.6 节。

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
