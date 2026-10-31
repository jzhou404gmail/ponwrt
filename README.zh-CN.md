# PonWrt（jzhou404gmail fork）

[主页（中文）](README.md) | [English](README.en.md) | **详细改动记录（本文件）**

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试、并把调出来的修复固化回源码树。

上游 `README.md` 的英文原文已移到 [`README.en.md`](README.en.md)（`README.md` 现在是中文主页），
上游 `README_zh.md`（中文翻译）保持原样未改。本文件只记录**这个 fork 相对上游多出来的东西**：
每一处硬件修复的**现象、根因、证据和验证方法**，以及一套"不破坏增量编译"的编译入口。

> **本 fork 的基线**：上游 `c3b518baec`（`firewall4: include transparent bridge ports in flowtable`），
> 在此之上是本 fork 自己的改动清单（见 §1）。
>
> **2026-10-16 已同步上游 `c3b518baec..a57faf93c6`**（7 个提交 = 4 个实质提交 + 3 个 merge：
> 新增 H3C HM-2004-DU 机型、HG5585F 复位键与面板 LED 修复、EN8811H 复位时序、FIT/ITS 镜像等）。
> 合并文本上干净，
> 但有**两处语义取舍** git 不会替你决定，这次的取舍是"两处都跟着上游走"（细节见 §8.3）：
>
> | 项 | 决定 |
> |---|---|
> | HG5585F-CU 面板灯：上游 `gpio-leds` 还是本 fork 的 PHY LED0 mux | **采用上游方案**，本 fork 的 mux 已撤掉（§2.3） |
> | EN8811H 复位时序：上游 `10000/20000us` 还是本 fork 的 `1000000/100000us` | **采用上游值**（本 fork 原先"故意不合并这笔提交"的做法从 2026-10-16 起作废；§8.3 记了需要时改回去的命令） |
>
> 同步没有覆盖任何本 fork 已提交的改动：同步前后"相对上游的差异文件集合"完全一致（58 个文件）。

---

## 1. 相对上游的改动总览

| # | 提交 | 主题 | 类型 |
|---|---|---|---|
| 1 | `chore(gitignore)` | 忽略 `.config` 备份、原厂固件转储、本机运维脚本 | 仓库卫生 |
| 2 | `build` | `build.sh` + `build-watch.sh` + `build-live.sh` 编译入口与进度观察 | 工具 |
| 3 | `airoha/an7581`+`an7583` | **面板 LAN 灯触发器缺失**（ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A，以及 an7583 的 XG-040G-MF） | 硬件修复 |
| 4 | `airoha/an7581` | **UNG00A 面板口序反转** + 启用 PHY1 LED0 | 硬件修复 |
| 5 | `airoha/an7583` | XG-040G-MF 的 PHY LED 补 `function` / `function-enumerator` | 一致性 |
| 6 | `airoha/an7581` | HG5585F-CU 四个 LAN 灯：**设备树/`01_leds` 随上游 `91077e9a6b` 合并**，另加 uci-defaults 迁移修**保留配置升级后触发器绑不上**（§2.3.1）＋ 补 `kmod-usb-ledtrig-usbport` 让 USB 灯能亮（§2.3.2） | 已并入上游 + 迁移 |
| 7 | `airoha/an7581` | **HG5585F-CT 热重启后 lan1 NO-CARRIER**（GPY211C PHY ID 竞态） | 硬件修复 |
| 8 | `luci-app-airoha-npu` | NPU/Frame Engine 面板移植，**WAN = PON 口** | 新功能 |
| 9 | `base-files` | **IPTV 机顶盒报 2001** 的组播 VLAN MAC 学习修复 | 功能修复 |
| 10 | `docs` | NPU 移植说明、IPTV 组播指南、PON 掉线采样脚本、渲染回归测试 | 文档 |
| 11 | `feeds.conf.default` | 注释形式记录可选的 PassWall feed | 说明 |
| 12 | `airoha/an7581` | **无线默认值（带无线的三款机型统一）**：国家码 CN、5G 160MHz、2.4G/5G 各自 SSID（`ImmortalWrt` / `ImmortalWrt_5G`）、默认 WPA2-PSK 密钥 `12345678` | 默认值修复 |
| 13 | `feed-patches` | **上游 feed 补丁机制**：`feeds/` 不入库，改在上游驱动里的修复以补丁形式存 `feed-patches/`，`build.sh` 编译前幂等套用（§5.2.1） | 工具 |
| 14 | `pon_drivers`（feed 补丁） | **EPON 上 `pon0-online` 永远不亮**（EPON 侧 `service_ready` 无人置 1）→ 改用"LLID 注册完成"作为 service ready | 硬件修复 |
| 15 | `airoha`（DTS） | 「光信号」灯的语义：**保持传统语义**（正常灭、无光红闪）。曾试过"有光常亮"，实机觉得别扭后已退回（§2.7.2） | 决策记录 |
| 16 | `airoha/base-files` | **「上网」灯 = 真实上网状态**：`pon-internet-led` 周期探测 well-known 站点，通就常亮、连续失败即灭；`/etc/init.d` + iface hotplug 拉起（§2.7.3）；**HG5382A 补上漏掉的 `wan-online` 节点（GPIO5）**，否则这台机器上服务在跑但一个灯都匹配不到（§2.7.4） | 功能修复 |
| 17 | `docs` | `pon-led-diag.sh`：面板灯取证脚本（触发器/亮度/线路状态/service_ready/OAM 认证 + 逐个点亮对面板） | 文档 |
| 18 | `verify-images.sh` | **产物体检闸**（+ `build.sh` 自动调用与内核自愈）：抓"体积翻倍 / 普通内核被 initramfs 内核顶替 / 截断"这类**能编译但不能刷**的产物（§5.5，真实事故复盘） | 工具 |
| 19 | `airoha/an7583` | **内核态 AES 之前一个都没开**：开启 ARMv8 CE（AES 全模式 + GHASH/PMULL）、`CRYPTO_CBC`、`CRYPTO_AUTHENC`、AF_ALG，并编上 EIP-93（§2.8） | 硬件修复 |
| 20 | `configs/an7583` | EIP-93 驱动与三个用户态包（`kmod-crypto-hw-eip93` / `kmod-cryptodev` / `libopenssl-devcrypto`），包数 239 → 245 | 默认值修复 |
| 21 | `docs` | AN7583 硬件加密核查（含两个可复现探针 `an7583-aes-check.c` / `an7583-eip93-probe-test.c`）与 XG-040G-MF **2.5G 口排查记录** | 文档 |
| 22 | `airoha/patches-6.18` | **NPU 固件版本暴露到 sysfs**（`950-npu-expose-fw-version-sysfs.patch`，§3）：用户态不必再去 grep 启动日志拿版本号 | 功能补充 |
| 23 | `configs/release.config` | 把 `luci-app-airoha-npu` 加进发布配置（§5.4） | 默认值 |
| 24 | `build` | **裸 `make` 也套 feed 补丁**（`include/toplevel.mk` 的 `feed-patches-apply`，任何目标都先走它）；`apply.sh` 把"git 用不了"与"补丁真冲突"分开报并新增 `--reset`；`build.sh`/`make` 增加 git 与 `REVISION=unknown` 自检；修正 `build_dir` 清理路径（kmod 包在 `linux-<板>_<子目标>/<包>`，原来没清到，`an7583` 里躺着 10-05 的旧源码）（§5.1.1、§5.2.1） | 工具/根因修复 |

---

## 2. 硬件修复详解

> **依据栏说明**
> `[实测]` = 在本机真机上取证过（寄存器 dump、换线实测或一次性诊断固件）；
> `[同源]` = 与已验证机型同硬件同驱动，结论直接沿用；
> `[补全]` = 从命名/顺序的确定性出发做的补全，未单独上机验证。

### 2.1 2.5G 口"看着是死的"——其实灯从来没亮过 `[实测]`

**机型**：`znxt_zn504xg-d`、`znxt_zn515xg-d`、`nokia_xg-040g-md-ubi`、
`nokia_xg-040g-tf-ubi`、`unionman_ung00a`，以及 an7583 的 `nokia_xg-040g-mf`（`-ubi` 同）

**现象**：2.5G 口插网线后面板灯不亮，LuCI 里看着像死口。但内核日志里口其实好得很：

```
airoha_eth 1fb50000.ethernet lan1: Link is Up - 2.5Gbps/Full - flow control off
Airoha EN8811H mt7530-0:0f: MD32 firmware version: 25062302
```

**根因（两层，缺一不可）**：

1. EN8811H 驱动在 `air_leds_init()` 里把 LED 设成 `AIR_LED_MODE_USER_DEFINE`
   （外部软件控制）。DTS 里的 `default-state = "keep"` **不会**让 PHY 硬件自己驱动灯，
   必须有 LED 触发绑定才会亮。
2. 更隐蔽的是：`phy_led_probe()` 注册 DT 里的 LED class 设备时会调
   `led_brightness_set(0)`，而驱动的 `air_hw_led_on_set(false)` 里有
   `priv->led[index].rules = 0` —— **驱动辛苦写好的默认规则被 LED core 一把清零**。
   此后只有 `netdev` 触发会把规则重新推回硬件。

而 `01_leds` 里**根本没有 znxt 的 case**，nokia 的 case 也只写了 lan2/3/4、漏了 2.5G 的
lan1。没有 UCI ⇒ 没有触发 ⇒ 规则永远是 0 ⇒ 灯永远不亮。

寄存器证据链（临时插桩 `air_leds_init` / `air_hw_led_on_set` / `air_hw_led_control_set`，
结论确认后诊断补丁已全部撤销，最终固件不含任何诊断代码）：

```
[10.9]  config_init: led_mode=1 → air_leds_init(USER_DEFINE)
        LED0 rules=00000601  ON=c107 BLINK=0c3f   ← 驱动默认规则(link+rx+tx)已写入，正确
[33.75] brightness_set LED0 value=0 -> ON=c080 rules=00000000
                                                  ← ★ LED core 注册时清零
[33.88] hw_control_set LED0 rules=00000001 -> ON=c187   ← netdev 触发把规则推回
[33.91] hw_control_set LED0 rules=00000601 -> ON=c187 BLINK=0c3f   ← 灯亮 ✓
[75.67] hw_control_set LED0 rules=00000601 -> ON=c187 BLINK=0c3f   ← 链路事件后自动重推，可自愈
```

**修复**：`target/linux/airoha/an7581/base-files/etc/board.d/01_leds`
新增 `znxt,zn504xg-d|znxt,zn515xg-d` case，并给 nokia MD/TF 与 unionman 补上 lan1 行。

**不刷机的热修**（改的是 UCI，零网络影响，一条命令可撤销）：

```sh
uci set system.led_lan1=led
uci set system.led_lan1.name='lan1'
uci set system.led_lan1.sysfs='mt7530-0:0f:green:lan-1'
uci set system.led_lan1.trigger='netdev'
uci set system.led_lan1.dev='lan1'
uci set system.led_lan1.mode='link tx rx'
uci commit system && /etc/init.d/led restart
# 撤销：uci delete system.led_lan1 && uci commit system && /etc/init.d/led restart
```

**验证**：`cat /sys/class/leds/mt7530-0:0f:green:lan-1/trigger` 应显示 `[netdev]`，
且同目录下出现 `device_name` / `link` / `link_2500` / `tx` / `rx`。

> **an7583（XG-040G-MF）的类设备名和上面这些都不一样，单独说一句。**
> 那颗 EN8811H 挂在 **SoC 自己的 MDIO 控制器**上（`mdio-bus@c8`，`scuclk` syscon 的子节点），
> 不是 an7581 那种交换机内部的 `mt7530-0` 总线，于是 `led_compose_name()` 拼出来的名字带一长串前缀：
>
> ```
> 1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1     ← 2.5G 口（EN8811H, PHY 0x0f）
> mt7530-0:0a:green:lan-2                                       ← 面板 LAN2-4 仍在交换机总线上
> ```
>
> 这个名字是从**运行中的机器** `/sys/bus/mdio_bus/devices/` 读出来的，不是推导的。写错一个字，
> netdev 触发就会静默绑不上、灯照样不亮 —— 和上面那个"灯本来就是被 LED core 清零过"的坑叠在一起，
> 表现完全一样，很难看出是名字写错。an7581 那批的 `01_leds` 是在 `fc5dd1c86b` 里补的，
> **an7583 当时漏了**，后来单独补在 `target/linux/airoha/an7583/base-files/etc/board.d/01_leds`。
> 完整排查过程（三个症状、三个各自的根因）见 `docs/xg-040g-mf-an7583-2p5g-fix.md`。

> 附带提醒：`ethtool lan1` 报 `master-slave cfg: preferred slave` 是该 PHY 的硬件默认值。
> 若对端也偏好 slave 且两端都是单端口设备，1000/2.5GBASE-T 的主从仲裁可能谈不下来。
> 真遇到"插上不亮也不 link"，可试 `ethtool -s lan1 autoneg on speed 1000 duplex full`。

### 2.2 UnionMan UNG00A 的面板口序是反的 `[实测]`

工厂 DTB 把 `port2=lan2 .. port4=lan4` 写反了，**真正的 LAN4 口因此一直是死的**
（它启用的是没接线的 port4 / PHY 0x0c）。用"插一根线在标注的口之间来回换、看哪个
netdev 拿到 carrier"的方式实测到的真实映射：

```
面板 LAN1 (2.5G) → gdm4 / EN8811H   (PHY 0x0f)
面板 LAN2        → switch port 3    (PHY 0x0b)
面板 LAN3        → switch port 2    (PHY 0x0a)
面板 LAN4        → switch port 1    (PHY 0x09)
```

结论用一次性诊断固件复核过：把没接线的 port4 暴露成 `lan5` 后，线插进 LAN4 口
总是起在 `lan4` 上、从不落在 `lan5`，所以映射是最终的，port4 保持 disabled。

**修复**：`an7581-unionman-ung00a.dts` 修正映射与注释，并 mux + 启用 PHY1 LED0（GPIO43），
给对应的 LED 类设备标上 lan4。

> LED 类设备名格式是 `<mdio-bus-id>:<phy-addr>:<color>:<function>-<enumerator>`，
> 所以 `01_leds` 里每一行必须写**属于它自己那个口**的 PHY —— 按 PHY 地址升序顺次写会把
> 每个触发器都绑到错的口上，并让 LAN4 口找不到任何 LED 设备。

### 2.3 HG5585F-CU 四个 LAN 灯全灭 `[实测]`

**现象**：CU 面板上四个 LAN 灯全灭，但四个口 link 正常。

**根因**：面板灯挂在 **GPIO43-46**（低有效）上 —— 并行 NAND 占了 **pin 4-7**
（`spi_cs0/clk/mosi/miso`，没有 GPIO 编号）与 **pin 30-42**，按
`gpio-ranges = <&en7581_pinctrl 0 13 50>` 的偏移换算即 **GPIO17-29**（这里容易看错：
pin 号和 GPIO 号差 13，所以不是 "GPIO4-7 与 GPIO30-42"）。这块板剩下的可用脚就是
GPIO43-46。而早期这块板的设备树里**根本没有这四个 LED 节点**，没有任何东西去驱动它们，
所以灯一直是灭的。

**修复（上游 `91077e9a6b`，作者在真机 CU 上逐脚驱动 GPIO 验证过）**：在
`an7581-fiberhome-hg5585f-common.dtsi` 里把 GPIO43-46 描述成 4 个普通 `gpio-leds`
（`blue:lan-1` .. `blue:lan-4`），并在 `board.d/01_leds` 的 `fiberhome,hg5585f-cu`
case 里给它们绑 netdev 触发。

**四个灯的最终形态**（`hg5585f-cu` 与 `hg5585f-cu-usb-sfp` 的 compatible 相同，
所以两个 profile 吃的是同一套）：

| 面板 | sysfs 类设备 | GPIO | UCI 触发 |
|---|---|---|---|
| LAN1 | `blue:lan-1` | GPIO43 | `netdev` → `lan1`，`link tx rx` |
| LAN2 | `blue:lan-2` | GPIO44 | `netdev` → `lan2`，`link tx rx` |
| LAN3 | `blue:lan-3` | GPIO45 | `netdev` → `lan3`，`link tx rx` |
| LAN4 | `blue:lan-4` | GPIO46 | `netdev` → `lan4`，`link tx rx` |

> ✅ **硬件已确认：上游那套「gpio-leds + netdev 触发」是对的**，本 fork 原先的
> PHY LED0 路线不需要再恢复（2026-10-17 逐脚驱动 GPIO43-46 复验，四个灯全亮，见 §2.3.1）。
> ⚠️ 但"设备树和 01_leds 都对"**不等于**"手上的机器上灯会亮" —— 保留配置升级时
> UCI 那一侧的触发器绑不上，灯照样全灭。**踩过一次，见 §2.3.1，别只看这一段就收工。**

**上机自检**：

```sh
ls /sys/class/leds/ | grep 'blue:lan'       # 期望 4 个：blue:lan-1 .. blue:lan-4
cat /sys/class/leds/blue:lan-1/trigger      # 期望 [netdev] —— 若是 [none] 就是没绑上，见 §2.3.1
cat /sys/class/leds/blue:lan-1/device_name  # 期望 lan1
uci show system | grep led_                 # 期望 6 段：led_lan1..4 + led_usb1/2，sysfs 与类设备一一对应
# 逐口插线：对应口的灯亮，并随 link/tx/rx 变化（有流量时闪是正常的，见 §2.3.1）
```

> 📌 `dmesg | grep -i 'PHY LED pinctrl'` 在 **CU / CT 上有 4 条
> `mdio_bus mt7530-0: Failed to setup PHY LED pinctrl` 是正常的**，不是故障：
> 这条来自 `an7581_phy_probe()` 里 `devm_pinctrl_get_select(..., "gbe-led")`，
> 而 CU/CT 的设备树**故意不给** `gbe-led` 状态（面板灯走 gpio-leds，PHY LED0 输出
> 那条路已经撤掉了，§2.3 下面那段）。报错只说明没选中任何 pinctrl 状态，脚仍归 GPIO，
> 灯照亮。**别照着这条报错去"修"pinctrl** —— 早先的自检清单把它当异常，是个误导。

#### 2.3.1 保留配置升级后，四个灯又全灭 `[实测]`

> 📄 **完整排查记录（问题 / 分析 / 修复 / 处理 / 测试和结果）见
> [`docs/hg5585f-cu-panel-leds.md`](docs/hg5585f-cu-panel-leds.md)。** 本节是摘要。

**现象**（2026-10-17，同机 192.168.32.254，跑 10-16 12:30 的镜像）：CU 面板上四个 LAN 灯
全灭，但 `blue:lan-1..4` 四个类设备都在，LAN1/LAN3 插着线也不亮：

```
$ for i in 1 2 3 4; do echo "lan$i trig=$(cat /sys/class/leds/blue:lan-$i/trigger|grep -o '\[.*\]') br=$(cat /sys/class/leds/blue:lan-$i/brightness)"; done
lan1 trig=[none] br=0     ← 全是 none
lan2 trig=[none] br=0
lan3 trig=[none] br=0
lan4 trig=[none] br=0
```

**先排除硬件**（这一步决定了后面往哪个方向修）：把四个脚直接拉低，低有效即点亮：

```sh
for i in 1 2 3 4; do echo none > /sys/class/leds/blue:lan-$i/trigger
                     echo 1    > /sys/class/leds/blue:lan-$i/brightness; done
grep -E 'gpio-4[3-6]' /sys/kernel/debug/gpio   # 四个脚都变 out lo
```

面板上**四个灯全亮** → GPIO43-46 到面板灯这条线是通的，pinmux（
`/sys/kernel/debug/pinctrl/*/pinmux-pins` 显示 pin 56-59 即 GPIO43-46 是 `GPIO`）
也是通的。**硬件、设备树、pinctrl 都没问题，问题在没人去驱动它们。**

**真根因**：这台机器的 `/etc/config/system` 里那份 LED 配置是**旧镜像时代手写的**，
指向已经不存在了的类设备：

```
config led 'led_lan2'
	option sysfs 'mt7530-0:0a:green:lan-2'   ← 12:30 镜像里已经没有这个类设备
	option trigger 'netdev'
	option dev 'lan2'
```

`/etc/init.d/led` 对不存在的 sysfs 只打一条日志、不报错，于是四个触发器**一个都没绑上**，
灯就一直灭着 —— 面板表现和"灯坏 / 设备树没配"完全一样，所以很容易往错的方向修。

那两个名字来自**本 fork 已经撤掉的 PHY LED0 路线**（就是本节下面"曾走另一条路"那段）：
当时的类设备叫 `mt7530-0:09/0a/0b/0c:green:lan-1..4`，2026-10-07 有人手写 UCI 把 netdev
触发绑上去、灯才亮；10-16 同步换成上游的 `blue:lan-*` 之后，这些条目就成了死配置。

**为什么 board.d 没自己修好**（这是整件事的关键，容易误判成"代码写错了"）：

* `board.d/01_leds` 只写 `/etc/board.json`；
* `/bin/config_generate` 把 board.json 落成 UCI 的那一整段——包括 `generate_led`——都包在
  `if [ ! -s /etc/config/system ]; then ... fi` 里（`config_generate` 末尾附近），
  也就是说 **`/etc/config/system` 非空就整段跳过，led 段根本不会生成**；
* 而保留配置升级时 `/etc/config/system` 是旧的、非空，`/etc/board.json`
  却**每次升级都会重新生成**（它不在 keep 清单里，`do_config_generate` 的守卫是
  `[ -f /etc/board.json ] ||`，文件一没就重跑 `board.d/*`）。

结果就是：机器上 `/etc/board.json` 里**已经是正确的 `blue:lan-1..4`**，
只有 UCI 那一侧是陈旧的。`grep -A6 '"led"' /etc/board.json` 一看便知 ——
**board.json 对、UCI 错**，这个组合基本就锁定是本问题。

**影响面**（比这台机器大）：任何**保留配置**升级到本次镜像的 CU 都会中招。同步之前的
`01_leds` 根本没有 CU 的 case（`git show 31e830faff:target/linux/airoha/an7581/base-files/etc/board.d/01_leds | grep hg5585f-cu` 为空），
所以那些机器的 `/etc/config/system` 里连 `led_lan*` 段都没有，四个触发同样绑不上。
**只有"刷机时清配置"的全新安装才会自动带上这 4 段。**

**修复（代码侧）**：新增
`target/linux/airoha/an7581/base-files/etc/uci-defaults/99-hg5585f-cu-leds`。
uci-defaults 在每次刷机后的首次启动都会重跑，脚本分两半（对应上面两条到达路径）：

1. **改名**（陈旧 PHY LED0 段）：用上游自己的机制
   `migrate_leds()`（`/lib/functions/migrations.sh`，ath79 / ramips / ipq40xx 等
   **15 个 target** 都在 `04_led_migration` 里用它），把那 4 个老类设备名
   `sed` 成 `blue:lan-N`。**改名而不是删掉重建 —— 用户手改过的 `mode`、或加过的
   自定义 option 会原样留下**（实测：`mode 'link'` 和 `option custom` 都保留了）。
2. **补齐**：给"还没有任何段指认"的类设备补上触发。这一半 `migrate_leds` 帮不上忙
   （它只会给已存在的段改名），而同步之前的 CU 恰恰一个段都没有。

补的**不只是 4 个 LAN 灯，而是 `01_leds` 给这块板描述的 6 个**（LAN1-4 + 两个 USB），
规则就是"让 UCI 与全新安装一致"：

```
led_lan1 blue:lan-1 netdev  lan1
led_lan2 blue:lan-2 netdev  lan2
led_lan3 blue:lan-3 netdev  lan3
led_lan4 blue:lan-4 netdev  lan4
led_usb1 blue:usb-1 usbport usb3-port1 usb4-port1
led_usb2 blue:usb-2 usbport usb1-port1 usb2-port1
```

幂等、且刻意收窄：只改那 4 个老名字，只补"类设备存在且没有任何段指认"的；
段名被占用时退回 `led_lanN_cu`，绝不覆盖用户自己的段。

真机上跑过的路径（用 `UCI_CONFIG_DIR` + 沙箱 `uci` 包装，不碰实机配置）：

| 路径 | 期望 | 结果 |
|---|---|---|
| 陈旧配置（旧名 + 自改过的 mode/option） | 3 段改名且选项保留 + 补 3 段 | ✅ |
| 全新安装（6 段齐） | 一字不改 | ✅ |
| 同步前的旧安装（一个 led 段都没有） | 补 6 段 | ✅ |
| 再跑一次 | 一字不改 | ✅ |
| 段名被用户占用 | 退回 `_cu` 名，用户段不动 | ✅ |

**修复（本轮手工，等效于上面脚本的 1+2）**：这台机器上只有 `led_lan2/3/4` 三段陈旧配置
（没有 `led_lan1`），先删掉再补 4 段：

```sh
uci -q delete system.led_lan2; uci -q delete system.led_lan3; uci -q delete system.led_lan4
for i in 1 2 3 4; do
  uci set system.led_lan$i=led
  uci set system.led_lan$i.name="lan$i"
  uci set system.led_lan$i.sysfs="blue:lan-$i"
  uci set system.led_lan$i.trigger=netdev
  uci set system.led_lan$i.mode="link tx rx"
  uci set system.led_lan$i.dev="lan$i"
done
uci commit system && /etc/init.d/led restart
```

修完 `lan1 carrier=1 → br=1`、`lan3 carrier=1 → br=1`、`lan2/lan4` 无 carrier → `br=0`，
面板上 LAN1/LAN3 亮、LAN2/LAN4 灭，与内核报的 carrier 一一对应（当时 LAN2 插着线但
对端 IPTV 机顶盒没开机，所以 NO-CARRIER 是对的，不是故障）。

> 🔎 **LAN1 看起来在"闪"是正常的**：`mode "link tx rx"` 下 netdev 触发器在有流量时
> 会翻转亮度比特（`netdev_trig_work()` 里 `led_blink_set_oneshot(..., invert)`），
> 所以拿 `cat brightness` 采样会看到 0/1 交替。要判断"灯亮不亮"，看 `carrier` 与
> `link` 模式位，别拿单次 `brightness` 采样下结论。

> 🧭 **一句话教训**：面板灯不亮时，先 `cat /sys/class/leds/<类设备>/trigger` 看是不是
> `[none]`，再 `uci show system | grep led` 看 UCI 指的是不是**本镜像里真实存在**的类设备名。
> 设备树和 `01_leds` 都对，也照样可能因为**保留配置升级**而全灭。

#### 2.3.2 CU / CT 的两个 USB 灯从来没亮过（缺一个 kmod）`[实测]`

查 §2.3.1 时顺手发现的**另一个独立问题**，与保留配置升级无关 —— **全新安装也一样**：

* 设备树里有 `led-usb1` / `led-usb2`（GPIO6 / GPIO8，低有效，
  `an7581-fiberhome-hg5585f-common.dtsi`），`01_leds` 也给 CU 绑了 `usb1`+`usb2`、
  给 CT 绑了 `usb1`，`trigger` 都是 **`usbport`**；
* 但这两块板子的 `DEVICE_PACKAGES`（`Device/fiberhome_hg5585f-common`，
  `target/linux/airoha/image/an7581.mk`）里有 `kmod-leds-gpio` 却**没有
  `kmod-usb-ledtrig-usbport`**，所以 `usbport` 触发器根本不存在；
* 后果：这两个 LED 类设备在 `trigger` 列表里**找不到 `usbport`**，
  绑不上、永远不亮，日志里只有一条"触发器不存在"。

实测（CU，192.168.32.254）：

```sh
grep -c usbport /sys/class/leds/blue:usb-1/trigger    # 0 —— 列表里没有 usbport
ls /lib/modules/*/ | grep ledtrig                     # 空 —— 模块根本没进镜像
grep -n usb-ledtrig target/linux/airoha/image/an7581.mk
#   290/354/371 行：别的机型都带了，5585F 这一块漏了
```

**修复**：给 `Device/fiberhome_hg5585f-common` 的 `DEVICE_PACKAGES` 补上
`kmod-usb-ledtrig-usbport`（内核里 `CONFIG_USB_LEDS_TRIGGER_USBPORT=m` 已经编好，
`bin/targets/airoha/an7581/packages/` 里也有这个 kmod 包，纯粹是设备包清单漏了）。
补上之后 CU 的两个 USB 灯、CT 的一个才真正能被 `usbport` 触发点亮。

> 顺带说明为什么 §2.3.1 的迁移要把这 2 个 USB 段一起补：一旦 kmod 补上，
> 保留配置升级过来的机器同样缺这两段（它们和 LAN 段是同一份 `01_leds` 产生的），
> 只补 LAN 就等于把同一个坑再踩一遍。


> ⚠️ **CT 别和 CU 搞混**：CT 与 CU 共用 `an7581-fiberhome-hg5585f-common.dtsi`，
> 所以 **CT 的设备树里同样有这 4 个 `led-lanN` 节点**，但 `01_leds` 只给
> `fiberhome,hg5585f-cu` 绑了触发（上游的理由是 CT 面板上没有 GE 口灯）。
> 结果是 **CT 上这 4 个节点存在、灯不会亮** —— 这是上游的有意取舍，不是漏配。
> 若实测发现手上的 CT 面板其实有 4 个 GE 口灯，就在 `01_leds` 的
> `fiberhome,hg5585f-ct` case 里照 CU 那样补 4 行即可。

> 📌 **本 fork 曾走另一条路，现已撤掉**：用内核补丁
> `203-09-pinctrl-airoha-permit-GPIO43-46-for-PHY-LED0.patch` 把 GPIO43-46 mux 成
> `phy1_led0` .. `phy4_led0`，让 PHY 硬件直接驱动面板灯，并启用
> `gsw_phy1_led0` .. `gsw_phy4_led0` 类设备。
>
> 撤掉的原因有两条：① 一个 pad 只能归 GPIO 或 PHY LED 输出**其中之一**，两套写法同时
> 存在会互相抢脚（`gbe-led` pinctrl 会把 4 个脚从 gpio-leds 手里拿走）；② 当时这条路线
> 只有一半 —— `01_leds` 里没有 fiberhome 的 case、没有 netdev 触发绑定，灯很可能仍然不亮。
> 上游的方案与 `01_leds` 是配套的，所以合并后采用上游写法。
> `an7581-fiberhome-hg5585f-cu-common.dtsi` 里留了一段注释写明"不要再把 GPIO43-46
> mux 成 phyN_led0"，以免以后重复踩。
>
> 那条内核补丁**必须保留**：UNG00A（§2.2）的 `gswp1_led0_pins` 仍然要拿 gpio43
> 当 `phy1_led0` 用。

### 2.4 HG5585F-CT：热重启后 lan1 一直 NO-CARRIER `[实测]`

**现象**：`lan1` 有时要等到下一次冷启动才有 carrier。

**根因**：这颗 2.5G PHY 是 **MaxLinear GPY211C**（HSGMII，低有效 GPIO34 复位），
原来用字符串 compatible + `ethernet-phy-ieee802.3-c45` 描述。这个组合会让核心在**扫描
MDIO 总线时**去读 C45 ID，而这个时机**早于** `mdio_probe()` 释放复位 GPIO。热重启后
PHY 那一刻可能还被按在复位里，ID 扫描读到 `0xffffffff`，内核于是绑定了不会协商的
`Generic Clause 45 PHY`，lan1 就一直是 NO-CARRIER。

**修复**：把 PHY ID 写死成 `ethernet-phy-id67c9.de10`，让设备直接从设备树创建，
复位时序竞态就不存在了。（GPY211B 是 `67c9.de08`，GPY2xx 家族 ID 是 `67c9.dc00`。）

### 2.5 XG-040G-MF 的 PHY LED 类设备命名不确定 `[补全]`

`gsw_phy1_led0` 本来就有 `function = LED_FUNCTION_LAN` + `function-enumerator = <1>`，
但 `gsw_phy2_led0 .. gsw_phy4_led0` 只有 `color`。LED core 于是按注册顺序把它们命名成
`green:lan`、`green:lan-1` ……，**哪个类设备对应哪个口没有保证**。

**修复**：给 phy2/3/4 补上显式的 `lan` function 与枚举号 2/3/4，命名变成确定的，
netdev 触发器可以按名字精确落到对应的口。

### 2.6 5G 选 160MHz 后"无线消失"：世界监管域里没有 160MHz 段 `[实测]`

**机型**：`fiberhome_hg5585f-ct`、`fiberhome_hg5585f-cu`（MT7916D）

**现象**：5G 带宽选 160MHz、国家码留在默认（空 / 驱动默认）时，5G 无线整块消失、AP 起不来；
把国家码手动选成 CN 或 US 就一切正常。

**这不是代码 bug，是监管域（regulatory domain）问题**。生成的 `/etc/config/wireless` 里
`country=''`，而 wifi 脚本只在 `country_code` 非空时才 `iw reg set`（UCI 的 `country` 经
schema 别名转成 `country_code` 后判空），hostapd 同样拿不到国家码。于是内核停在
**世界域 `country 00`**：

```
country 00:
	(5170 - 5250 @ 80), (20), AUTO-BW        # 只有这一段允许起 AP，宽度就 80MHz
	(5250 - 5330 @ 80), (20), NO-IR, DFS     # DFS 段
	(5490 - 5730 @ 160), (20), NO-IR, DFS    # 唯一 160MHz 宽的一段，也是 DFS 段
	(5735 - 5835 @ 80), (20), NO-IR
```

160MHz 需要一整段连续可用的 160MHz（ch36–64 或 ch100–128）：36–64 在世界域里只有 80MHz 宽；
100–128 属 DFS 段，而没设国家码时 hostapd 配置里不会有 `ieee80211h`（`device_country_code()`
在 `country_code` 为空时提前返回），wiphy 的 DFS region 也是 `UNSET`，cfg80211 直接拒绝起 AP。
hostapd 启动失败 → netifd 重试 3 次后放弃 → LuCI 里连这个 radio 都看不到。
**80MHz 之所以没事**，正是因为 ch36–48 那一块本身允许起 AP。

CN / US 能行是 **ImmortalWrt 的 `wireless-regdb` 补丁**
（`600-custom-change-txpower-and-dfs.patch`，**不是本 fork 加的**）把这两个国家的 5GHz
改成了无 DFS / 无 NO-IR 的整段 160MHz：

```
country CN: DFS-FCC
	(5150 - 5350 @ 160), (30)      # ch36-64 一整块 160MHz，不带 DFS
	(5725 - 5850 @ 80), (33)
```

**修复（源码级默认值）**：新增
`target/linux/airoha/an7581/base-files/etc/board.d/03_wireless`。
> 📌 **本 fork 的规则：所有带无线的机型共用同一套无线默认值**，保持一致。
> 当前在册三款：`HG5585F-CT`、`HG5585F-CU`、`ZN515XG-D`。
> **以后新增带无线的机型，把它的 `board_name` 加进这个 `case` 即可（一行）**；
> 不带无线的机型（含本 target 里上游的 valyrian / evb 等开发板）一律不动。
>
> 规则内容：① 国家码 CN　② 5G 默认 160MHz　③ 不做双频合一　④ 默认 WPA2-PSK + 固定初始密钥

```sh
ucidef_set_country CN             # -> board.json: wlan.defaults.country = "CN"
ucidef_set_wireless_width 5g 160  # -> board.json: wlan.defaults.widths.5g = 160

# 不做双频合一：2.4G / 5G 各用各的 SSID；默认 WPA2-PSK + 初始密钥
ucidef_set_wireless 2g "ImmortalWrt"    psk2 12345678   # -> wlan.defaults.ssids.2g
ucidef_set_wireless 5g "ImmortalWrt_5G" psk2 12345678   # -> wlan.defaults.ssids.5g
```

- `ucidef_set_country` 是上游函数（`package/base-files/files/lib/functions/uci-defaults.sh`），
  `/lib/wifi/mac80211.uc` 生成配置时把它写进每个 radio 的 `country`，之后 `iw reg set CN`
  和 hostapd 的 `country_code=CN` 都会生效（2.4G 也一起拿到 CN，该国 2.4G 限值更宽）。
- `ucidef_set_wireless_width` 是本 fork 新加的 helper（同一文件），落到
  `wlan.defaults.widths.<band>`。`mac80211.uc` 原来把非 2.4G 的默认宽度**一律压到 80MHz**，
  现在改为"板级声明优先（再按 phy 的 `max_width` 截断），没声明仍是 80MHz" ——
  其它机型（含 6GHz 机型）的生成结果**逐字节不变**。
- `ucidef_set_wireless` 也是上游函数，落到 `wlan.defaults.ssids.<band>`，
  `mac80211.uc` 用它生成 `default_radio<N>` 的 `ssid` / `encryption` / `key`。
  第三个参数 `psk2` 就是 LuCI 里显示的 **"WPA2-PSK"**（WPA2 + CCMP），第四个是密钥
  （8–63 位，`12345678` 正好是下限，刷完请自己改）。
  **两频段 SSID 不同 = "不做双频合一"**：2.4G 客户端不会被隐式"融合"到 5G，
  两个 SSID 在客户端列表里各自独立存在。
- **为什么默认不做成"开放网络"**（`ucidef_set_wireless 2g "ImmortalWrt"` 只给 SSID）：
  ① 开放 AP 等于把 LAN 敞开，邻居连上就能访问你的内网与 LuCI；
  ② 更阴的是"以后想加密"这一步 —— 在 LuCI 里把加密改成 WPA2-PSK 却忘了填密钥时，
  hostapd 会以 **`INVALID_WPA_PSK`** 启动失败、AP 整块起不来。给个固定初始密钥就没有这个坑。
  > 确实想要开放：只传 SSID 不传 encryption/key 即可（生成 `encryption='none'` + `key=''`）。
  > ⚠️ 反过来，**绝对不要**只填 `psk2` 而把密钥留空 —— 那就是上面那个 `INVALID_WPA_PSK`。

**上机自检**：

```sh
jsonfilter -i /etc/board.json -e '@.wlan.defaults'
# {"country":"CN","widths":{"5g":"160"},"ssids":{"2g":{...psk2...},"5g":{...psk2...}}}
uci show wireless | grep -E "country|htmode"          # country='CN'  htmode='HE160'
uci show wireless | grep -E "ssid|encryption|key"
#   2.4G: ssid='ImmortalWrt'     encryption='psk2'  key='12345678'
#   5G  : ssid='ImmortalWrt_5G'  encryption='psk2'  key='12345678'
iw reg get | head -2                                  # country CN
iw dev phy1-ap0 info | grep -E "channel|width"        # width: 160 MHz
```

> `/etc/board.json` 只在**首次启动**（该文件不存在时）由 `/etc/board.d/*` 生成。
> 从旧固件保留配置升上来的机器不会自动套用新默认值：要么 `rm /etc/board.json` 后重启
> 重新生成，要么直接在 LuCI 里改（国家码 CN / 带宽 160MHz / SSID / 自己设密码）。
> 注意 **`/etc/config/wireless` 会被保留配置刷机原样留下**，所以 SSID 与加密的默认值
> 也只对"全新配置"生效；想立刻拿到新默认值：
>
> ```sh
> rm /etc/config/wireless && wifi config && uci commit wireless && wifi up
> ```
>
> 生成逻辑已用宿主 `ucode` 做过回归（三款在册机型 → `country='CN'` + 5G `HE160` +
> 2.4G `ImmortalWrt` / 5G `ImmortalWrt_5G` + `psk2` + `key='12345678'`；板级不声明 → 仍
> `HE80`/空国家码/单 SSID/`none`，`max_width=80` 时按 80 截断），
> 但**默认值改动本身还没上机**，按 §6.2 验一行即可。

### 2.7 面板「光信号」/「上网」两个灯的语义与实现 `[实测]`+`[待上机]`

**适用机型**：所有 airoha 机型 —— 面板前四个灯的丝印与用途各机型一致：
`电源` / `PON(注册)` / `光信号` / `上网`。本节的结论在 **EPON 线路**上取证（联通 10G EPON）。

#### 2.7.1 硬件事实（先把"这盏灯到底是什么"钉死）

| 面板灯 | 丝印 | 颜色 | 设备树 / sysfs | 原厂 LED 表（`userfs/7581ptled.conf`） |
|---|---|---|---|---|
| 1 | 电源 | 绿（CU）/ 蓝（CT） | GPIO13 `blue:power` | `LED_TR68_PWR_*` → gpio 13 |
| 2 | PON | 绿 | GPIO14 `blue:wan` | `LED_XPON_STATUS` → gpio 14 |
| 3 | 光信号 | **只有一个红脚** | GPIO16 `red:wan` | `LED_XPON_LOS_ON/STATUS` → **都是 gpio 16** |
| 4 | 上网 | 绿 | GPIO5 `blue:wan-online` | 该表写 gpio 1，与 §2.3 真机逐脚驱动验证的 GPIO5 不同（表里其余脚与真机一致） |

**关键结论**：第 3 个「光信号」灯是**单色红灯**，原厂 LED 表里 `LOS` 语义也只有一个脚，
不存在"信号正常亮绿灯"的灯珠 —— 所以"正常时绿色常亮"在这块硬件上做不到。
（先用 `docs/pon-led-diag.sh walk` 逐个点亮对一遍面板，颜色与位置一目了然。）

#### 2.7.2 「光信号」灯：保持传统语义（正常灭、无光红闪）`[实测]`

**结论**：第 3 个「光信号」灯继续用**出厂语义** —— 有光时**灭**，断纤/无光时**500 ms 红闪**，
即设备树里的 `linux,default-trigger = "pon0-los"`，与原厂固件一致。

**曾经试过、已退回**：一度在驱动里加过一个触发器 `pon0-signal`（有光 → 常亮；无光 → 闪烁），
并把 8 个机型的设备树改绑过去，理由是"正常时这盏灯全黑，看起来像坏的"。
**实机用了几天后当事人觉得"红灯常亮"更别扭**（红灯在光猫语境里天然读作告警），
于是整条改动回退：

* 驱动里的 `pon0-signal` 触发器已删除（`feed-patches/` 里只剩 EPON 那一笔补丁）；
* 8 个机型的设备树全部改回 `pon0-los`（`grep -rn pon0-los target/linux/airoha/dts/` → 9 处，
  含 an7583）；
* 想要"有光常亮"的话，`git revert` 回退本次回退提交即可（`pon0-signal` 的驱动实现与
  DTS 绑定都在那笔提交里）。

> 需求侧的硬事实仍然成立：这盏灯硬件上**只有红光**（GPIO16，原厂 LED 表里 `LOS` 也只有
> 这一个脚），所以"正常时亮绿色"做不到；"光路正常"的正指示在第 2 个 PON 灯上（绿色常亮）。
> 判据始终是"**有没有光**"而不是"注册没注册"：光的问题看这盏灯（红闪），注册的问题看
> 第 2 个灯（闪），两件事分开才好定位。

#### 2.7.3 「上网」灯：真实探测"能不能上网" `[待上机]`

**需求**：不看 PON，真正检测 INTERNET 连通性 —— 能打开 well-known 站点（例如百度）就绿灯常亮。

**为什么不能靠 PON**（两层，`[实测]` 代码定位）：

1. 出厂绑的触发器 `pon0-online` 判据是 `xpon->service_ready`，而这个变量在两类线路上来源不同：
   * **XG(S)-PON / GPON**：`airoha-xpon-ploam.c` 在延迟数据通道补挂成功后置 1
     （调用它的只有 `airoha-xpon-main.c` 的**非 EPON 分支**）→ 灯会亮；
   * **EPON**：内核侧**永远不写 1**（`airoha-xpon-epon.c` 只在重置时写 0），唯一写入方是
     用户态 `airoha-pond`，条件为 `ctc_snapshot.authentication == "accepted"`
     —— **只有 OLT 走完 CTC 认证**才会写。只跑 MPCP + PPPoE 的线路上恒为 0 ⇒ 灯必灭。
2. 就算会亮，"PON 注册成功"也不等于"能上网"：PPPoE 可能拨不上、路由/DNS 可能不通。

**实现**（`target/linux/airoha/base-files/`）：

```
usr/libexec/pon-internet-led                 # 全部逻辑：探测 + 点灯
etc/init.d/pon-internet-led                  # procd 常驻循环（START=96）
etc/hotplug.d/iface/30-pon-internet-led      # 会话起来/断开的即时同步
```

判据：

```
http://connect.rom.miui.com/generate_204          ┐ 先试 204 端点（响应体最小）
http://www.baidu.com/                             ├ 任一个通 = 能上网 → 绿灯常亮
http://connectivitycheck.platform.hicloud.com/generate_204 ┘
ping 223.5.5.5 / 119.29.29.29                     # HTTP 全失败再 ping 兜底（有些线路封 ICMP/HTTP）
```

* 通 → 立刻点亮；连续失败 `failures` 次（默认 2）才熄灭 —— 滞回，避免抖动闪灯。
* PPPoE 会话断开时 hotplug 立刻灭灯（不用等探测超时）；会话起来 3 秒后立刻补探一次。
* 灯的控制方式：把 `/sys/class/leds/*:wan-online` 的 `trigger` 置 `none`，直接写 `brightness`
  —— 内核触发器不再抢这盏灯（`stop` 时会把灯还给内核的 `pon0-online`）。

配置（可选，缺省即下面的值）：`/etc/config/pon-led`

```sh
cat >/etc/config/pon-led <<'EOF'
config internet 'internet'
	option enabled '1'
	option interval '30'      # 探测周期（秒）
	option failures '2'       # 连续失败几次才灭灯
	option timeout '5'        # 单个请求超时（秒）
	option urls 'http://connect.rom.miui.com/generate_204 http://www.baidu.com/ http://connectivitycheck.platform.hicloud.com/generate_204'
	option ping_hosts '223.5.5.5 119.29.29.29'
EOF
/etc/init.d/pon-internet-led restart
```

关掉它（把灯还给内核触发器，退回"PON 侧就绪"语义）：

```sh
/etc/init.d/pon-internet-led stop && /etc/init.d/pon-internet-led disable
```

**驱动侧那处 EPON 修复仍然保留**（`0001-*.patch`）：`pon0-online` 在 EPON 上不再是死灯，
没装/关掉上面这个用户态服务时，这盏灯仍然反映"PON 侧就绪"。

#### 2.7.4 HG5382A 的第 4 个灯：设备树整台漏了 `wan-online` 节点 `[实测]`

**现象**：`192.168.32.254` 的 HG5382A（`fiberhome,hg5382a`）升级到带 `pon-internet-led`
的镜像后，面板第 4 个「宽带」灯始终不亮；同一镜像在 Nokia XG-040G-MD、HG5585F-CT/CU
上正常。

**取证**：

```sh
# 只有 3 个面板灯类设备，没有 *:wan-online
ls /sys/class/leds/
blue:power  blue:wan  red:wan

# 服务本身在跑、配置也 enabled，但一个灯都匹配不到
/etc/init.d/pon-internet-led running       # 0
/usr/libexec/pon-internet-led status
#   enabled : 1
#   last state : on http://connect.rom.miui.com/generate_204
#   leds :
```

**根因**：`an7581-fiberhome-hg5382a.dts` 只描述了电源（GPIO13）、PON（GPIO14）、
光信号（GPIO16）三个灯，**没有第 4 个灯的节点**。`pon-internet-led` 的匹配 glob 是
`*:wan-online`，没有类设备就一个也点不亮 —— 脚本的探测逻辑本身没问题。
`board.d/01_leds` 也不负责这盏灯（它只绑 netdev/usbport），所以 UCI 里补不出这个类设备。

**为什么 5382A 能空出 GPIO5**：这块板用 8-bit TSOP48 并行 NAND，pinctrl 的 `pnand`
组是 **pin 4-7（spi_cs0/clk/mosi/miso，没有 GPIO 编号）+ pin 30-42（= GPIO17-29）**；
GPIO4-7（对应 pin 17-20）并不在 `pnand` 组里，GPIO5 一直是空的。旧注释写成
"GPIO4-7 和 GPIO30-42"，容易让人以为 GPIO5 被 NAND 占了，实际上不是（这次一并改了注释）。

**修复**：在 DTS 的 `leds` 节点补第 4 盏：

```dts
led-internet {
	color = <LED_COLOR_ID_BLUE>;
	function = LED_FUNCTION_WAN_ONLINE;
	gpios = <&en7581_pinctrl 5 GPIO_ACTIVE_LOW>;
	linux,default-trigger = "pon0-online";
};
```

`pon-internet-led` 的 `*:wan-online` 会自动接管（trigger 置 `none`，写 brightness）；
`stop` 时把灯还给内核的 `pon0-online`。**不需要改 UCI/board.d**。

**实机验证（2026-10-18）**：在现场 5382A 上从 sysfs export GPIO5 并拉低 15 秒，
第 4 个「宽带」灯点亮；1 秒亮/1 秒灭闪 30 秒同步闪烁 —— 确认 GPIO5 就是这盏灯。
改 DTS 后刷机，`/usr/libexec/pon-internet-led status` 的 `leds:` 应出现
`/sys/class/leds/blue:wan-online`，能上网时常亮。

#### 2.7.5 上机自检

```sh
sh docs/pon-led-diag.sh                # 取证：LED/触发器/亮度、线路状态、service_ready、OAM 认证、代理
sh docs/pon-led-diag.sh walk 4         # 逐个点亮，确认"哪个 sysfs 灯 = 面板哪个位置、什么颜色"

cat /sys/class/leds/red:wan/trigger           # 期望 [pon0-los]（传统语义）
cat /sys/class/leds/blue:wan/trigger          # 期望 [pon0-registration]
ls /sys/class/leds/*:wan-online               # 期望恰好 1 个（5382A 以前是 0 个，见 §2.7.4）
cat /sys/class/leds/blue:wan-online/trigger   # 期望 [none]（被用户态接管）

pon-internet-led status                # 配置 + 上次探测结果（/var/run/pon-internet-led.state）
pon-internet-led once                  # 立刻探一次：online/offline 一目了然
logread | grep pon-internet-led        # 每次 online/offline 切换都有日志

# 行为验证
拔光纤   → 第 3 个灯红闪（500 ms）；第 2 个灯灭；第 4 个灯 30 秒内灭
插光纤   → 第 3 个灯**灭**（有光就没告警）；注册后第 2 个灯绿灯常亮；能上网后第 4 个灯绿灯常亮
ifdown wan → 第 4 个灯立刻灭；ifup wan → 3 秒后补探，通则重新点亮
```

#### 2.7.6 证据

```sh
# 原厂固件里的 LED 表（本机 CU rootfs 里 dump 出来的）
#   userfs/7581ptled.conf —— 面板 LED 号 → GPIO
#   LED 64/65 LED_XPON_STATUS  → gpio 14（PON 注册灯）
#   LED 66/67 LED_XPON_LOS_*   → gpio 16（光信号，只有这一个脚）
#   LED 40/41 LED_TR68_PWR_*   → gpio 13（电源）
#   LED 42    LED_PHY_TX_POWER_DISABLE → gpio 38

# 驱动侧判据（feeds/pon_drivers/airoha-xpon/src/airoha-xpon-leds.c）
#   pon0-registration : EPON 看 mpcp_state==REGISTERED / XG(S)PON 看 O5
#   pon0-los          : 线路在跑但没光 → 500ms 慢闪；有光 → 灭（传统语义）
#   （曾有一个 pon0-signal：有光 → 常亮；实机觉得别扭，已回退，见 §2.7.2）
#   pon0-online       : 线路在跑 + 有光 + service_ready（EPON 上按注册判据）
```

### 2.8 AN7583 的硬件 AES 一个都没开：CE 与 EIP-93 `[实测]`

**机型**：`nokia_xg-040g-mf`、`nokia_xg-040g-mf-ubi`（AN7583）

**现象**：手上这台 `op` 的 `/proc/crypto` 里一共只有 **13 个算法，全是 `software/generic`**：
`ecb(aes)` 解析到 `ecb(aes-generic)`、`ghash` 到 `ghash-generic`，**连软件 `cbc(aes)` 都没有**
（IPsec 直接没法用），更没有任何 CE / EIP-93 driver。

**根因**：AN7583 这颗 Cortex-A53 **带** ARMv8 Crypto Extensions，但内核侧一个都没编：

```
# cat /proc/cpuinfo | head -4
model name  : ARMv8 Processor rev 4 (v8l)
Features    : fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid     ← aes / pmull / sha1 / sha2 都在
CPU part    : 0xd03  (Cortex-A53)

$ grep -E "^CONFIG_(CRYPTO|ARM64|KERNEL_MODE_NEON)" target/linux/airoha/an7583/config-6.18
（没有任何 CE 选项；这份 config 与 an7581 的那份逐行 diff 为空）
$ grep -rn "ARM64_CE\|AES_ARM64\|GHASH" target/linux/airoha/
（空）
```

> **和 AN7581 的关键差异**：AN7581 那颗 A53 **没有** CE（`OPENSSL_armcap=0x1`，只有 NEON，
> 所以 140G-MD 必须走 EIP-93）；AN7583 **有**，而且 CE 同时覆盖 AES 各模式 **+ GCM**。
> 反过来 EIP-93 只有 ECB/CBC/CTR/DES/authenc、**没有 GCM/CCM**，所以在 AN7583 上它只是补充项。

**一个真实踩过的坑**：an7583 的 `config-6.18` **曾经**有 `CONFIG_CRYPTO_DEV_EIP93=y`
（从 6.12 抄 6.18 时带过来的），随后被上游 `ada7ded2f4`（`airoha: an7583: refresh kernel config`，
跑的是 `make kernel_oldconfig`）**静默删掉**。原因在 `drivers/crypto/Kconfig`：

```
 12: if CRYPTO_HW
 …
875:    source "drivers/crypto/inside-secure/eip93/Kconfig"
878: endif # CRYPTO_HW
```

`CRYPTO_DEV_EIP93` 在 `if CRYPTO_HW` 里面 —— `CRYPTO_HW=n` 时这个符号**根本不可见**，写进片段
也会在下次 `make defconfig` / `kernel_oldconfig` 时被丢掉。所以 **`CONFIG_CRYPTO_HW=y`
不是可选项**。反观 `arch/arm64/crypto/Kconfig`（AES/GHASH 的 CE 选项）由 `crypto/Kconfig` 在
`if ARM64` 下直接 source，**不受 `CRYPTO_HW` 门控**，可以直接写进片段。

**修复**（只动 `an7583/config-6.18`，**an7581 一行没改** —— 那颗没 CE，编了也不注册）：

```kconfig
CONFIG_CRYPTO_AES_ARM64=y            # 标量汇编 AES（CE/NEON 的公共依赖）
CONFIG_CRYPTO_AES_ARM64_BS=y         # bit-sliced NEON，A53 上比纯 C 快
CONFIG_CRYPTO_AES_ARM64_CE=y         # ★ AES 走 ARMv8 AES 指令
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y     # ★ ECB/CBC/CTR/XTS 块模式
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_AES_ARM64_NEON_BLK=y   # AES-NEON 模式层
CONFIG_CRYPTO_CBC=y                  # 之前连软件 CBC 都没有，IPsec 必需
CONFIG_CRYPTO_GHASH_ARM64_CE=y       # ★ PMULL → gcm(aes) 全硬件
CONFIG_CRYPTO_AUTHENC=y              # authenc(hmac,cbc(aes)) → IPsec
CONFIG_CRYPTO_HW=y                   # EIP-93 的前提（见上面那个坑）
CONFIG_CRYPTO_DEV_EIP93=m
# ↓ 下面两个是 hack 补丁引入的新符号，必须显式给值，
#   否则 syncconfig 会因为 (NEW) 无值直接中断构建（第一次构建就踩了）
CONFIG_CRYPTO_DEV_EIP93_AES_128_SW_MAX_LEN=512
CONFIG_CRYPTO_DEV_EIP93_GENERIC_SW_MAX_LEN=256
CONFIG_CRYPTO_USER_API_AEAD=y        # AF_ALG：把内核算法暴露给用户态
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_CRYPTO_USER_API_SKCIPHER=y
```

**故意没开的**：`CRYPTO_SHA3_ARM64`、`SM3_ARM64_CE`、`SM4_ARM64_*`、`CRYPTO_SHA512_ARM64_CE`
需要 ARMv8.2 指令，A53 **不能开**。

`configs/an7583.config`（种子配置带 `TARGET_MULTI_PROFILE` + `TARGET_PER_DEVICE_ROOTFS`，
所以 `DEVICE_PACKAGES` 走 `select MODULE_DEFAULT_<pkg>`，写 `=y` 即可进各 profile 的 rootfs）：

```
CONFIG_PACKAGE_kmod-crypto-hw-eip93=y   # 自动带出 authenc / des / md5 / sha1 / sha256
CONFIG_PACKAGE_kmod-cryptodev=y         # /dev/crypto
CONFIG_PACKAGE_libopenssl-devcrypto=y   # 用内核 crypto API 的 openssl engine
```

`make defconfig` 后包数 **239 → 245**（只增不减）。

**证据链**（三块，都是活体机器实测）：

① **用户态其实早就在跑硬件 AES**，不需要任何改动 —— `CONFIG_OPENSSL_WITH_ASM=y` 让 libcrypto
编进了 ARMv8 汇编，运行时按 `AT_HWCAP` 自动选 `aes_v8_*` / `gcm_ghash_v8`：

```
$ /tmp/aes-check            # 静态链 libcrypto.a，能打印内部能力位
AT_HWCAP         : 0x8ff  asimd=1 aes=1 pmull=1 sha1=1 sha2=1
OPENSSL_armcap_P : 0x3d   neon=1 aes=1 sha1=1 sha256=1 pmull=1     ← AN7581 上是 0x1
aes-128-gcm : 569.7 MB/s      aes-128-cbc : 889.4 MB/s
aes-256-gcm : 506.4 MB/s      chacha20-poly1305 : 199.4 MB/s

$ /tmp/aes-check-dyn        # 动态链设备上装的 libcrypto.so.3
aes-128-gcm : 568.5 MB/s    ← 与静态版一致 ⇒ 固件里那份库确实走 CE
```

GCM 570 MB/s（AN7581 同机实测只有 29 MB/s），且**比纯 NEON 的 ChaCha20-Poly1305（199 MB/s）还快**
⇒ 确实是 AES 指令 + PMULL 在做。本机跑的 PassWall（sing-box / xray / shadowsocks-rust）与
WireGuard 同样是运行时探测 HWCAP 的 Go/Rust 实现，**自动吃到 CE，无需改动**。

② **内核 SHA-1/SHA-256 本来就已经是硬件**：6.18 把 arm64 SHA 的 CE 分支并进了 `lib/crypto`，
用 static key 运行时探测（`cpu_have_named_feature(SHA2)`）。`/proc/crypto` 里名字仍显示
`sha1-lib`，那只是 lib 实现内部按 static key 分流，**不代表软件**。
（旧符号 `CONFIG_CRYPTO_SHA1_ARM64_CE` / `SHA2_ARM64_CE` 在 6.18 已不存在，
OpenWrt `generic/config-6.18` 里那两行是陈旧条目。）

③ **EIP-93 的硬件存在性是只读寄存器探针实测的**（`docs/an7583-eip93-probe-test.c`：
只 `devm_platform_ioremap_resource` + `readl`，不注册算法、不依赖 authenc/des，
所以能插进还没有这些符号的旧固件）：

```
$ insmod /tmp/eip93-probe-test.ko
EIP93TEST: reg=[mem 0x1fb70000-0x1fb70fff] ctrl_stat=0x00000002 status=0x00040402
           option_1=0xf08fe007 revision=0x0341a25d eip_no=0x5d hw_rev=3.4 patch=1
EIP93TEST: ALGO_AES=1 ALGO_DES=1 ALGO_HASH=1 (option_1 bits)
```

`eip_no=0x5d` 就是 EIP-93（hw rev 3.4，"ies" 变体），DT 节点能正常绑定、寄存器可读、无总线异常。
这次顺带也证实了旧内核为什么插不进完整驱动 —— 正是缺本次新增的那些符号：
`crypto_authenc_extractkeys` / `des_expand_key` / `md5_zero_message_hash` / `sha224/256_zero_message_hash`。

> **内核里唯一用到 AES 的地方是 PON PLOAM 换密钥**（`feeds/pon_drivers/airoha-xpon/src/airoha-xpon-crypto.c`
> 的 `crypto_alloc_sync_skcipher("ecb(aes)")`）—— 每帧一个 block，可忽略。
> **数据面 XGEM 的 AES 由 PON MAC 硬件完成**（密钥经 `AIROHA_XGPON_AES_UC_IDX*_KEY*` 寄存器下发），
> 不占 CPU。所以"内核 AES 是软件"在这台 ONU 上对转发性能几乎没影响；想拉开差距的是
> IPsec / dm-crypt / 走内核的 GCM，而这台机器目前都没装。

**刷机后自检**：

```sh
# 1) 内核 CE 算法注册上了（最关键）
grep -A3 '^name         : ecb(aes)$' /proc/crypto   # 期望 driver: ecb(aes-ce)
grep -A3 '^name         : cbc(aes)$' /proc/crypto   # 期望 driver: cbc(aes-ce)
grep -A3 '^name         : ctr(aes)$' /proc/crypto   # 期望 driver: ctr(aes-ce)
grep -A3 '^name         : gcm(aes)$' /proc/crypto   # 期望 gcm_base(ctr-aes-ce,ghash-ce)
# 2) EIP-93 与 AF_ALG 起来了
grep -c eip93 /proc/crypto                          # 期望 > 0
lsmod | grep -E "eip93|cryptodev"
dmesg | grep -iE "eip93|safexcel"
# 3) 用户态（本来就硬件，刷完应保持不变）
/tmp/aes-check                                      # armcap=0x3d，aes-128-gcm ~570 MB/s
```

万一 EIP-93 在启动时 probe 失败：本机 `panic_on_oops=1`，但 probe 失败是**返回错误**、不会 panic，
现象只是 `dmesg` 里一条报错 + `/proc/crypto` 里没有 eip93。要临时禁用就删
`/etc/modules.d/09-crypto-hw-eip93`（或把 `CONFIG_CRYPTO_DEV_EIP93=m` 去掉并同时去掉 `CRYPTO_HW=y`）。

完整核查记录、探针源码与交叉编译命令见 `docs/an7583-armv8-crypto-check.md`
（含"仍未做的是出数据级别的测试"这一条，见 §8.1）。

---

## 3. LuCI NPU 面板（`luci-app-airoha-npu`）

移植自 [rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)
v1.1.4（本 fork 内版本 `1.2.0-r3`），把 **WAN = 2.5G 铜口**改成 **WAN = PON 口**。

上游假设 WAN 是 GDM4 上的 2.5G PHY（netdev `wan`）、GDM2 的 PON 数据面在 DTS 里是关的，
所以把 GDM2 卡片写死成"未启用"。PonWrt 上角色正好反过来：

| | 上游 | PonWrt |
|---|---|---|
| WAN | GDM4 / EN8811 2.5G / `wan` | **GDM2 / XPON GEM / `pon0`** |
| 2.5G 口 | WAN | **LAN（`lan1`）** |
| 交换机 master | `dsa-mgr`（DTS 写死） | `eth0`（DTS 没给 `netdev-name`） |

这些网口名在 PonWrt 支持的 **12 个机型上都不通用**，所以 GDM → netdev 的映射不再写死，
改为**从活体设备树解析**（`/sys/class/net/*/of_node` → `ethernet@N` / `ethernet-port@M`），
与 `/lib/preinit/04_set_netdev_label` 用的是同一份数据源；PON 口另外由
`airoha,pon-data-path` 标记。两个边界情况已处理：

- **GDM4 被禁用**（HG5585F-CU）：按名字兜底会误抓 DSA 的 `lan1`，故加
  `of_node_available()` 保护 —— 能读到 `of_node` 就**只**采信设备树结果，
  该机型 GDM4 卡片正确显示「Not present on this board」。
- **GDM4 不是 2.5G**（Gemtek XG2010G 是 10G RTL8261N）：速率标签改为从 DTB `phy-mode`
  动态取（`2500base-x`→2.5G、`10gbase-r/usxgmii`→10G、`internal`→switch）。

**WiFi 内容画在 CDM4 卡片里，且数据源是重写的，不是照搬上游**：上游读的 `token_info` debugfs
只由 mt7996 的 NPU 代码创建（MT7916 上不存在），匹配的 `phy0.<band>-` 也是 mt7996 单 phy
多频段的命名（MT7916D 是两个 PCIe HIF ⇒ `phy0-ap0` / `phy1-ap0`，上游正则一个都匹配不上）。
现在只用芯片真机上确实存在的数据源：`iw dev info` / `station dump` / `survey dump` /
hwmon 温度。信道占用按两次 survey 采样的**差值**算当前值（累加值直接相除得到的是开机
至今均值）；**取不到的数据一律不画那一行**，不甩假 0。频段只画 2.4G / 5G 两张。

**CDM 卡片行**：Frame Engine 区块新增 `CDM1 (P0)` / `CDM2 (P5)` 两张 CPU DMA 引擎卡片，
**所有机型都画**（与有没有无线无关），显示 `HW Offload = RXHWF_OK / (RXCPU_OK + RXHWF_OK)`
卸载率条与 `CPU / HWF / TX` 计数；无线机型在下面再画 `CDM4 (P7 WiFi DMA)` 卡片，
里面就是那两个频段的详细卡片。CDM 计数器直接读寄存器（`CDM_BASE(0x400/0x1400) + 0x180`
起的 `TX_OK` / `RXCPU_OK` / `RXHWF_OK` / 两个 drop）—— 这几个计数器内核驱动**从来不读**
（只碰 CDM 的配置寄存器），所以用户态读它们不像 GDM MIB 那样会偷走内核的计数。

**后端**：

- `getWifiInfo` 取代 `getTokenInfo`，但**保留 `getTokenInfo` 作为别名** ——
  LuCI 的 JS 带 `?v=` 版本号而那个版本号来自 luci-base 不是本包，浏览器可能仍缓存旧的
  `status.js`，别名能让旧前端不整页报错（硬刷新后自动切到新方法）。
- `/usr/bin/ppe-verify` 动态解析 WAN 口，并顺带修了两个上游 bug：
  `${var^^}` 是 bash 语法会让 busybox ash 直接退出；`grep -c ... || echo 0` 在空表时
  会输出 `0\n0`。
- PSE 端口的丢包统计由 P1/P9 扩到 **P1/P2/P9**，把 PON 口算进去。

**内核补丁** `target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch`
把 NPU 的 `fw_version` / `num_cores` 暴露到 sysfs。RPC 本来就"优先读 sysfs、读不到再退回
抓 dmesg"，所以版本号一从环形缓冲区刷掉就显示 Unknown，补这个属性后不再丢。

**入口**：LuCI `状态 → SoC Status`。

---

## 4. IPTV 机顶盒报 2001「检测到网络不可达」

把 IPTV **业务 VLAN(3300)** 和**组播 VLAN(4075)** 桥进同一个网桥域后，会踩一个很隐蔽的
**网桥 MAC 学习陷阱**：

- 运营商 IPTV 组播流的**源 MAC** 和 IPTV**网关/EPG 的 MAC 是同一台设备**；
- 该 MAC 只在组播 VLAN 上有流量，于是网桥把它学在 `ct-iptv-mc`(4075) 端口上；
- 结果机顶盒发往网关的**所有单播**（DHCP 续租、DNS、EPG、鉴权）都只被转发到 4075，
  业务 VLAN 3300 一个包都收不到 → 盒子 DNS/EPG 全部超时 → **错误 2001**。
- 广播/组播因泛洪照常能通，**所以盒子能正常拿到 IP**，非常具有迷惑性。

netifd **表达不了**这件事：在 device 段写 `option learning '0'` 是静默无效的，
`network reload` 之后端口还是 `learning on`。所以本 fork 用四个互为保险的触发点固化：

| # | 位置 | 覆盖场景 |
|---|---|---|
| 1 | `/etc/hotplug.d/iface/99-iptv-mc-nolearn` | `luci_iptv`/`lan` 接口 ifup |
| 2 | `/etc/init.d/iptv-stb`（S95, procd） | 开机立即应用 + 拉起守护 |
| 3 | `/usr/libexec/iptv-stb-watchdog`（默认 15s 轮询） | `network reload` —— 它**不发** hotplug 事件却会重建网桥端口 |
| 4 | `/usr/libexec/iptv-stb-fix` | 唯一实现，上面三个都调它 |

实现还会清掉 reload 瞬间学进组播口的残留单播表项，并在配置里的端口名在当前机器上不存在时
**自动重新探测**网桥与 VLAN 端口。

`lib/upgrade/keep.d/iptv-stb` 把这些文件加进 sysupgrade 备份清单 —— 否则"恢复备份到新机器"
只会恢复出**触发该故障的桥接拓扑**，却带不过修复脚本，新机器照样报 2001。

**判断是否踩坑的最快命令**：

```sh
bridge fdb show br br-iptv | grep -v '^33:33\|^01:00:5e'
# 网关 MAC 落在 ct-iptv-mc 上 = 踩坑；落在 ct-iptv-svc 上 = 正确
bridge -d link show dev ct-iptv-mc | tr ',' '\n' | grep learning   # 期望 learning off
```

完整配置（udpxy / omcproxy / 防火墙 zone / VLC 地址 / 排查表）见
[`docs/iptv-udpxy-omcproxy-guide.md`](docs/iptv-udpxy-omcproxy-guide.md)。
该文档里的 ONT 序列号、LOID、线路 IP 与设备 MAC **已替换为占位符**。

> ⚠️ 文档里提到的 `scripts/iptv/apply-iptv-fix.sh` 是**另一棵树**（openwrt_XGPON）里的
> 远程修补工具，**本仓库没有这份脚本** —— PonWrt 已经把这套修复直接编进固件，刷机即生效。

---

## 5. 编译

### 5.1 依赖

照上游 README 的依赖清单装即可（`sudo apt install ...`，或用 ImmortalWrt 一键脚本）：

```sh
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'
```

#### 5.1.1 前置条件：`git` 必须真的在 PATH 里 `[实测]`

这条单列出来，因为 2026-10-17 那天两条编译路子一起翻车，根因就是它，而且**不报错、
只静默走样**。

本机（deepin）2026-10-14 的一次自动 `apt dist-upgrade` 顺手把系统 `git` 包删了
（`/var/log/apt/history.log`：`Upgrade: git-man …` + `Remove: git:amd64`）。后来 git 是
手工解开放在 `~/.local/opt/git/` 下的，靠 `~/.local/bin/git` 这个包装脚本调用：

```sh
#!/bin/sh
GIT_EXEC_PATH="$HOME/.local/opt/git/usr/lib/git-core" \
GIT_TEMPLATE_DIR="$HOME/.local/opt/git/usr/share/git-core/templates" \
exec "$HOME/.local/opt/git/usr/bin/git" "$@"
```

`~/.local/bin` 只由 `~/.profile` 加进 PATH，**登录 shell 才有**。所以桌面终端、
`sudo -s`、cron、某些 CI 风格的非登录 shell 里可能就没有 `git`。缺 git 的后果是静默的：

| 现象 | 实际原因 |
|---|---|
| `./build.sh` 报 **"套不上"**，并列出 `airoha-xpon/src/airoha-xpon-leds.c` | `apply.sh` 的三个 `git apply --check` 全失败（因为 `git` 命令本身就没了），被当成"补丁套不上"。补丁其实是好的 —— 照提示去改补丁就白费功夫 |
| 编了 20 多分钟，某个**毫不相干**的包报 `failed to build`（那天是 `package/base-files`） | `scripts/getver.sh` 拿不到版本 → `REVISION=unknown` → 包版本整棵树换一套（base-files 由 `1943~a57faf93c6` 变成 `1943~unknown`），增量状态错乱 |

自查与修法（一次修好，PATH/HOME 怎么变都不会再踩）：

```sh
git --version                             # 找不到就是它
git -C "$PWD" rev-parse --git-dir
scripts/getver.sh                         # 输出 unknown 就是它
sudo apt-get install -y git               # ← 一劳永逸：恢复系统 git
```

现在 `build.sh` 与顶层 `make` 都会先自检：`git` 用不了 / 版本是 `unknown` 就**当场停下**
并打印上面这几条，而不是等 20 分钟后随机报错（见 `build.sh` 与
`include/toplevel.mk` 里的自检）。`feed-patches/apply.sh` 也会把"git 用不了"和"补丁真
冲突"分开报 —— 这两件事的修法完全不同。

**没装系统 git 也能编**：`build.sh`、`feed-patches/apply.sh` 与顶层 `make` 在 PATH 里
找不到 `git` 时会自己去找 `~/.local/bin/git` 并补进 PATH（`build.sh` 补的那份还会传给
`make`，所以 `getver.sh` 也能拿到正确版本）。也就是说两种编译方式在这台机器上现在都
能跑通；`sudo apt-get install -y git` 是为了彻底免疫 —— 别处再冒出个非登录 shell、
`sudo`、cron 时不会再踩。想根治"桌面终端没有 `~/.local/bin`"，也可以把
`export PATH="$HOME/.local/bin:$PATH"` 加进 `~/.bashrc`（`~/.profile` 只对登录 shell 生效）。

### 5.2 取源码与 feed

```sh
git clone https://github.com/jzhou404gmail/ponwrt.git
cd ponwrt
./scripts/feeds update -a
./scripts/feeds install -a
```

#### 5.2.1 上游 feed 的补丁（`feed-patches/`）

`pon_drivers` / `pon_userspace` 这些 feed 是上游仓库（`feeds.conf.default` 里的 `src-git`），
而 **`feeds/` 目录不入库**。所以"改在上游驱动里的修复"如果只改 `feeds/` 检出，一次
`./scripts/feeds update -a` 就没了，`git log` 里也看不到。本 fork 的做法：

```
feed-patches/
├── apply.sh                                  # 幂等套用脚本
└── pon_drivers/airoha-xpon/
    └── 0001-*.patch                          # EPON 上 pon0-online 不再死灯（§2.7.3）
```

* **`build.sh` 和顶层的 `make` 都会套**（`make` 那一步挂在 `include/toplevel.mk` 的
  `feed-patches-apply` 上，是所有目标的必经之路）。原来只有 `build.sh` 和 CI workflow
  各套一遍，**直接 `make -j$(nproc)` 的人就漏了** —— 编出来的固件静默缺少这些修复
  （`feeds install` 拿到的是未打补丁的上游源码），而构建日志一切正常。CI 里那一步保留着
  也无害：脚本是幂等的。
* 已套过的跳过，没套的套上，套不上会明确报错而不是默默继续。**报错分两种，修法相反**：
  * `!! git 用不了：…` —— 环境问题（§5.1.1），报错里直接给出 `sudo apt-get install -y git`；
  * `!! 套不上: …` —— 真冲突。报错里会打印涉及的源文件、**git 自己报的错**（原先被
    `2>/dev/null` 吞掉了，只看得到"套不上"），以及两条成因对应的修法：
    文件被手工改过（`./feed-patches/apply.sh --reset`，或先
    `git -C feeds/<feed> checkout -- <文件>` 再重跑脚本）/ 上游改过同一段（要照现状重做补丁）。
* 一个 feed 里叠着多个补丁时，后面的补丁会改动前面补丁的上下文行，所以"已套用"的判定
  用 `git apply --check --reverse`（必要时缩小上下文 `-C1`，或 `--ignore-whitespace`
  兜住行尾/空白被动过的文件），不是简单比字符串。
* 刚套上某个补丁时，脚本会同时删掉该包在 `build_dir/` 里的旧拷贝 —— OpenWrt 只在
  prepare 阶段把本地源码**拷贝**进去，源码改了不删旧拷贝，就会出现"改了源码但编译用的
  还是旧文件"。**kmod 包的拷贝不在 `build_dir/target-*/<包>`，而在
  `build_dir/target-*/linux-<板>_<子目标>/<包>`**：两个位置都要删。这条是 2026-10-17
  查出来的 —— `linux-airoha_an7583/airoha-xpon` 里一直躺着 10-05 的旧源码（补丁前），
  脚本每次都说"已清理"，编出来的模块却还是旧的。
* 手动查看/套用/复位：`./feed-patches/apply.sh --check` / `./feed-patches/apply.sh` /
  `./feed-patches/apply.sh --reset`。

**分支政策：只保留一条主线**。`master` 就是这条线 —— 上游 `pbs05/ponwrt` + 本 fork 的
全部改动，**编译一律用它**：

```sh
git clone -b master https://github.com/jzhou404gmail/ponwrt.git
git fetch origin && git merge origin/master     # 同步上游
```

- `pr/*` 三个分支（`pr/hg5585f-ct-gpy211c`、`pr/iptv-mac-learning`、`pr/ung00a-panel-order`）
  **不是第二条主线**，只是给上游提 PR 用的提交快照，对应上游还开着的 PR
  [#34](https://github.com/pbs05/ponwrt/pull/34) / [#35](https://github.com/pbs05/ponwrt/pull/35) /
  [#33](https://github.com/pbs05/ponwrt/pull/33)；PR 合并后就可以删。
- 本机 `.git/config` 里设了 `branch.master.pushRemote=fork`：站在 `master` 上敲 `git push`
  推的是**自己的 fork**，不会误推到上游（`branch.master.remote` 仍是 `origin`，
  所以 `git status` 里"领先上游多少个提交"照样能看）。

### 5.3 `build.sh`：功能与用法

#### 5.3.1 参数一览

| 命令 | 作用 |
|---|---|
| `./build.sh` | **默认：完全沿用现有 `.config`，绝不修改它** —— 配置已经调好、只想增量编译时用这个 |
| `./build.sh --config=an7581` | 用 `configs/an7581.config` + `configs/release.config` 重建 `.config`（**先做种子完整度自检**；带备份与掉包保护，见 §5.3.3 的 ① ②） |
| `./build.sh --check-seeds` | 只检查两个 `configs/*.config` 是否仍是完整发布种子（>=400 个包、关键包齐全、硬件包不串），不编译。见 [docs/config-seed-drift.md](docs/config-seed-drift.md) |
| `JOBS=2 ./build.sh` | 降低并行度（内存紧张时避免被 OOM 击杀） |
| `./build.sh --watch` | **只做进度监视，不编译**（等价于直接跑 `./build-watch.sh`） |
| `./build.sh --force` | 忽略并发锁（**危险**，确认没有别的构建在跑再用） |
| `./build.sh -h` / `--help` | 打印脚本头部的用法说明 |

#### 5.3.2 设计原则：只做加法，绝不改动构建输入

不传任何额外的 make 变量、不重写 `.config`（除非你显式给 `--config=`），
保证 OpenWrt 的增量判断完全按你原来那套走 —— **只有改动过的部分才重编**。

#### 5.3.3 它按顺序做了这些事

| # | 阶段 | 做什么 | 为什么 |
|---|---|---|---|
| ⓪ | 环境自检 | `git` 用不了、或 `scripts/getver.sh` 给出 `unknown` → **当场停下**并打印修法（§5.1.1） | 缺 git 不会报错，只会静默走样：补丁判定全失败（误报"套不上"）+ 包版本整棵树换一套（随机包 `failed to build`）。宁可 0 秒失败，也不要 20 分钟后炸在无关的包上 |
| ① | 套配置 | 只有给 `--config=<档>` 时才动 `.config`：**先跑 `scripts/check-config-seeds.sh`**（两个种子 >=400 个包、关键包齐全、7581/7583 硬件包不串；不过就中止且不碰 `.config`），再备份成 `.config.bak-ponwrt-<时间戳>`，`cat configs/<档>.config configs/release.config > .config` + `make defconfig` | 旧版只做后置比例保护，防不住"种子本身就缩水"：`configs/an7583.config` 曾经只剩 275 个包却照样通过 275×0.8，`--config=an7583` 编出缺一半应用的镜像。复盘见 [docs/config-seed-drift.md](docs/config-seed-drift.md) |
| ② | 掉包保护 | 对比 `CONFIG_PACKAGE_*=y` 的数量，若从 N 掉到 **< N×0.8**，或 **defconfig 后低于绝对下限 400**，就**中止并把备份还原** | 一次误操作就能把手调的配置覆盖掉；打印 `包选择数量: before -> after` 让你看见变化 |
| ③ | 套 feed 补丁 | 跑一遍 `feed-patches/apply.sh`（幂等，§5.2.1） | `feeds/` 不入库，改在上游驱动里的修复靠补丁落地；刚套上的会清掉 `build_dir` 旧拷贝，保证增量编译用的是改过的源码。**裸 `make` 也会做这一步**（`include/toplevel.mk` 的 `feed-patches-apply`），所以"直接 `make`"不会静默漏掉修复 |
| ④ | 并发锁 | `tmp/build.lock`：锁在 **6 小时内** → 中止并打印锁里的 pid/时间；**过期锁** → 忽略继续 | 同一棵树并发 `make` 会同时写 `build_dir/` 与 `staging_dir/`，症状是 libunistring/perl 这类毫不相干的包"随机"失败，极难排查 |
| ⑤ | 编译 | `make -j$JOBS`，**原始输出全部进 `tmp/build.log`** | 控制台留给进度块，细节随时可查 |
| ⑥ | 进度 | 后台起 `build-watch.sh` 读日志，控制台只打印阶段/里程碑/正在编译什么 | 见 §5.3.4 |
| ⑦ | 逐包日志 | `BUILD_LOG=1` → 每个包的完整输出落 `logs/<包>/compile.txt`（整棵树约 2.5 MB，已在 `.gitignore`） | `tmp/build.log` 里通常只有一行 `ERROR: <包> failed to build.`，**真正的报错只在这份日志里** |
| ⑧ | 失败自愈 | 见 §5.3.5 | |
| ⑨ | 产物体检 | 编译成功后自动跑 `verify-images.sh`；若它返回 **2**（内核树脏这一类）则 `rm -rf build_dir/target-*/linux-<board>_<subtarget>` 后**重编一遍**；其它非 0 直接判失败并提示"不要刷" | "能编译"不等于"能刷"，真实事故见 §5.5 |
| ⑩ | 收尾 | 打印**开始时间 / 结束时间 / 总共耗时**（成功、失败、Ctrl-C 三种都打，`SUMMARY_DONE` 去重），追加进 `tmp/build.log`；再列出**本次新产出的 `.itb`** 与烧录自检提示 | 事后对时间、确认这次到底产出了什么 |
| ⑪ | 信号处理 | `trap EXIT INT TERM` → 连 **`make` 和 `build-watch.sh` 一起收掉**并删锁 | 否则 Ctrl-C 后 `make` 变孤儿继续跑，而锁已经删了 ⇒ 下次启动就是并发编译 |

#### 5.3.4 三种"看进度"的方式

| 工具 | 原理 | 什么时候用 |
|---|---|---|
| `build.sh` 自带的进度块 | 读 `tmp/build.log` | 默认，什么都不用做 |
| `./build-watch.sh [--once] [--iv=10]` | 同样读日志，但可以**单独另开一个终端**跑；`--once` 只打印一次 | 想边编译边盯进度 |
| `./build-live.sh [--iv=10] [--fast]` | **不依赖日志**，直接看「进程 + 文件系统改动」 | 你是用裸 `make -j$(nproc)` 起的构建，没有日志可读时 |

> `build-watch.sh` 除了绝对状态还给出两个**活性指标**：系统负载（接近核数 = 正在满负荷编译）
> 与日志静默时长。**进度条"看起来不动"通常是正常的** —— make 只在开始编一个包时打一行，
> samba4 / nfs-utils 这类大包会静默几十分钟；要看负载，而不是看有没有新行。

#### 5.3.5 两个"自愈"行为（都不是静默重试）

> 🐛 **一、包的子构建被"静默打断"**：某个包的子 make 被信号打断，于是 `tmp/build.log`
> 里只有那一行 ERROR、而 `logs/<包>/compile.txt` 是**空文件**（连 `time.pl` 的
> `time: <包>/compile#...` 都没有）—— 这不是编译报错，重编一次就好。
> `build.sh` 按这个判据自动处理：① 单独 `make <包>/compile` 把该包编好；
> ② 重新跑整个构建（**最多 2 轮**）；③ 每一步都打印说明，绝不静默重试。
> 判据"`compile.txt` 为空"**不会误伤真报错** —— 真报错时该文件非空，脚本直接失败退出。
> 实测（桩 make 单测）：正常 1 次通过；静默失败 → 自动重编 + 第 2 次尝试通过；真报错 → 立即失败并打印日志末尾。

> 🧹 **二、内核构建树被留在 initramfs 配置上**（`verify-images.sh` 返回 2）：
> 上一次被中途打断的构建会把内核树留在 initramfs 配置上，这次 sysupgrade 镜像里就会塞进
> **initramfs 内核**（体积翻倍、U-Boot inflate 失败 → 无限重启）。这一类**可以自愈**：
> `build.sh` 清掉 `build_dir/target-*/linux-<board>_<subtarget>` 后重编一遍，只做一次，避免死循环。
> 复盘见 §5.5。
>
> ⚠️ 这条自愈原先**一次都没跑成**（2026-10-17 实测）：脚本开头是 `set -e`，裸跑
> `./verify-images.sh` 一旦返回非 0，整个脚本当场结束 —— 自愈代码一行都到不了，只留下
> `==> 编译结束（未走完正常收尾）` 和 `bin/` 里那份**不能刷**的镜像。现在改成
> `./verify-images.sh || VRC=$?` 把退出码接住。同一次修复还改了要删的目录名：真实目录是
> `build_dir/target-*/linux-<board>_<subtarget>`（`KERNEL_BUILD_DIR`，见
> `include/kernel.mk:46`），原来少了 `linux-` 前缀，`rm` 什么都没删掉，"自愈"是空转。

#### 5.3.6 构建失败时按这个顺序查

1. **`logs/<包>/compile.txt`** —— 真正的报错在这里；**为空 = 被静默打断**（会被自愈，见 §5.3.5）
2. `tmp/build.log` 末尾 —— 失败时 `build.sh` 会自动打印最后 25 行
3. `grep -nE 'ERROR:|build failed' tmp/build.log | tail`
4. `dmesg | grep -i oom` —— 内存击杀（需要 root）
5. **同一棵树里有没有第二个 `make` 在跑** —— `build.sh` 的锁挡不住手敲的 `make`
6. **`git` 还在不在、版本是不是 `unknown`** —— `git --version` / `scripts/getver.sh`；
   这种环境下报的任何"随机失败"都不算数，先按 §5.1.1 修 git 再重来

### 5.4 产物

```
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-squashfs-sysupgrade.itb
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-initramfs-recovery.itb   # 救砖/恢复
```

`bin/targets/airoha/an7581/ponwrt-airoha-an7581.manifest` 里应能看到
`luci-app-airoha-npu - 1.2.0-r3`。

**代码覆盖 12 个 AN7581 机型**（改代码时不能只盯着出固件的 6 个；SFP 变体也算在内）：

```
fiberhome_hg5382a          nokia_xg-040g-md-ubi          znxt_zn504xg-d
fiberhome_hg5585f-ct       nokia_xg-040g-md-ubi-usb-sfp  znxt_zn515xg-d
fiberhome_hg5585f-ct-usb-sfp  nokia_xg-040g-tf-ubi       unionman_ung00a
fiberhome_hg5585f-cu       gemtek_xg2010g
fiberhome_hg5585f-cu-usb-sfp
```

**出固件只出下面 6 个 AN7581 机型**（均不带 SFP）：

```
fiberhome_hg5382a      fiberhome_hg5585f-ct   fiberhome_hg5585f-cu
nokia_xg-040g-md-ubi   unionman_ung00a        znxt_zn504xg-d
```

> “代码全支持、出固件只出 6 个”是 2026-10-25 定的长期原则，全文见
> [docs/build-models-policy.md](docs/build-models-policy.md)。
> `scripts/check-config-seeds.sh` 里的 `BUILD_7581_DEVICES` 会做精确校验：
> 多选（SFP 或其它机型）或少选都会让 `build.sh` 在编译前直接失败。
> 上游新增的 **`h3c_hm2004-du`**（H3C HM-2004-DU）不在这 12 个正式机型里，也不出固件；
> 要出的话先改白名单和 seed。

AN7583 只出 `nokia_xg-040g-mf-ubi` 的 UBI 固件；非 UBI 的 `nokia_xg-040g-mf`
不选、不出镜像（`configs/an7583.config`）。

> **本机踩过的坑**：如果系统上 `git` 不可用，`base-files` 的版本会变成
> `260923.84021~unknown`，apk 会拒绝（`~` 后面必须是十六进制）。
> 绕过办法是写 `TOPDIR/version`：`printf 'r0-c3b518baec\n' > version`，
> 编完**记得删掉**，否则会一直盖住真实版本号。

### 5.5 产物体检 `verify-images.sh` —— 为什么必须有这道闸 `[实测]`

**事故（2026-10-16）**：一次构建出的 `.itb` 刷进去**起不来，无限重启**。串口（U-Boot）原话：

```
   Uncompressing Kernel Image to 8a000000
Error: inflate() returned -5
Image too large: increase CONFIG_SYS_BOOTM_LEN
Must RESET board to recover
Resetting the board...
```

同时那个 `.itb` 从正常的 **58 MiB 涨到 117 MiB**（"在 .config 没变的前提下体积翻倍"）。

**根因**：`build_dir/target-*/linux-airoha_an7581/Image`（sysupgrade 镜像打包用的"普通内核"）
**就是 initramfs 内核** —— 它内含整个 rootfs 的 180 MiB cpio（`CONFIG_INITRAMFS_COMPRESSION_NONE=y`），
所以内核 194 MiB、gzip 后 71 MiB、整个 FIT 117 MiB。证据（md5 / 魔数都能直接复现）：

```sh
# 1) 打包用的"普通内核"和 initramfs 内核是同一个文件
md5sum build_dir/target-*/linux-airoha_an7581/Image \
       build_dir/target-*/linux-airoha_an7581/Image-initramfs
#   正常：Image 13 MiB（3284b5cc…）/ Image-initramfs 194 MiB（a7584721…），两个不一样
#   出事：两个 md5 一模一样

# 2) 内核树还留在 initramfs 配置上（每次构建结束时都长这样，本身不算错，
#    但它 + 中途掐断 = 上面那个后果）
grep INITRAMFS_SOURCE build_dir/target-*/linux-airoha_an7581/linux-*/.config
```

**怎么变成这样的**：内核构建树被一次**被中断的构建**（那条命令被外部 10 分钟超时 SIGTERM 掉）
留在了 initramfs 配置状态；下一次**增量**构建里，"普通内核"那一步认为产物是最新的，
直接把已经是 initramfs 内核的 `arch/arm64/boot/Image` 拷成了 `$(KERNEL_BUILD_DIR)/Image`，
镜像打包阶段照单全收 ⇒ 产出一个"能编译出来、但根本不能刷"的固件。
（那次产物连 arm64 头部自报的 `image_size` 都比文件本身大 —— 也是被中途掐断的痕迹。）

**防线**：`verify-images.sh`（+ `scripts/verify-fit.py`）**每次构建后自动跑**，任何一条不过就让
整次构建判为失败 —— 不会再打印"构建完成"，更不会让你拿到一个能刷的假象。

```sh
./verify-images.sh                     # 手动体检 bin/targets 下所有 .itb
./verify-images.sh <文件或目录...>      # 只体检指定产物
```

它逐个 `.itb` 检查：

| 检查 | 抓的是哪一类问题 |
|---|---|
| `.itb` 总体积（sysupgrade ≤ 95 MiB / recovery ≤ 70 MiB） | 体积翻倍 |
| 解压内核后 **不许出现 rootfs 里的文件**（`etc/openwrt_release` / `lib/apk/packages` / `etc/config/network`） | **普通内核被 initramfs 内核顶替**（本次事故） |
| 内核里有 arm64 `ARM\x64` 魔数、头部 `image_size` 不离谱 | 打进去的根本不是内核 / 产物被截断 |
| 解压后内核大小在 8–80 MiB（正常 13.2 MiB，出事 185 MiB） | 内核里塞了不该塞的东西 |
| rootfs 是 squashfs（`hsqs`）且 ≥ 5 MiB | rootfs 缺了/坏了 |
| 同机型 **sysupgrade 内核 ≠ recovery 内核** | 上面那条最直接的指纹 |

**自愈**：如果体检失败的原因属于"内核那一类"（`verify-images.sh` 退出码 **2**），
`build.sh` 会自动清掉 `build_dir/target-*/linux-<board>_<subtarget>` 并重编一次 ——
你不用手动救，但要知道它为什么慢了一轮。

**手工修法**（体检让你自己修时）：

```sh
rm -rf build_dir/target-*/linux-airoha_an7581     # 或对应的 board 目录
./build.sh
```

**教训（写给以后）**：

1. **别掐断正在跑的构建**。`Ctrl-C` / `kill` 掉一次 `make`，可能把内核树留在
   initramfs 配置上，进而产出上面那种"能编译、不能刷"的固件。要停就停，
   但**恢复构建后必须过一次 `verify-images.sh` 再刷**。
2. **"能编出来" ≠ "能刷"**。体积、内核里的 cpio、sysupgrade/recovery 内核是否同一份，
   都是可以自动判定的 —— 所以把它们写成了自动闸，而不是靠人眼看串口。
3. 事后核对：`verify-images.sh` 全 `ok` + 体积与已知可用版本同量级（AN7581 sysupgrade ≈ 58 MiB）。
4. **判据要用不会误报的指纹**：一开始想用 cpio 魔数 `070701` 判"内核里塞了 rootfs"，
   结果好内核也在同一个偏移碰巧命中（十几 MB 二进制里 6 字节串撞车很正常，附近还有
   个孤立的 `TRAILER!!!`），改成"rootfs 里必然有、内核里必然没有的路径名"才判得准 ——
   体检脚本自己也要按这个标准写，否则会把人吓去乱改。
5. 那次坏产物留了一份当回归样本：`tmp/broken/*.itb`（117 MiB，gitignore 里的 tmp/，
   随时可删）。改完体检脚本拿它跑一遍，应当**失败且退出码为 2**。

### 5.6 GitHub Actions 发布（CI 编固件并出 release）

仓库里带了一份 `.github/workflows/release.yml`，**在 GitHub 上就能编出固件并发布**，
不需要自己的机器 —— 用法和 [pbs05/uboot-an758x](https://github.com/pbs05/uboot-an758x) 那套是一样的。

**怎么用**：仓库 **Actions → Release PonWrt → Run workflow**，填两个输入：

| 输入 | 说明 |
|---|---|
| `tag` | 要发布的标签，例如 `v1.0.0`（必填） |
| `prerelease` | 是否标为预发布（默认 `true`） |

跑完 Release 页会出现 `PonWrt <tag>`，附件是：

```
ponwrt-an7581.tar.zst      # bin/targets/airoha/an7581/ 整个目录打包
ponwrt-an7583.tar.zst      # 同理
sha256sums
```

**用的是项目默认配置，不是本机 `.config`** —— 这正是关键的一步：

```sh
./scripts/kconfig.pl + configs/${target}.config configs/release.config > .config
make defconfig
```

* `configs/an7581.config` / `configs/an7583.config` 是**入库的种子配置**
  （`TARGET_MULTI_PROFILE=y` + `TARGET_PER_DEVICE_ROOTFS=y`，一次编出 seed 里选中的机型；
  出固件白名单见 [docs/build-models-policy.md](docs/build-models-policy.md)）；
* `configs/release.config` 是**发布叠加**（nft offload / wireguard / tcp-bbr / cake /
  `luci-app-airoha-npu` 等 11 项）；
* 用 `kconfig.pl +` 做**递归合并**，比 `cat` 更稳 —— 同一个符号在两份里都给值时不会留下重复行；
* 本机的 `.config` **根本不在仓库里**（`.gitignore` 里的 `/.config`），所以 CI 不可能用到
  你个人的配置。

**本 fork 对这份 workflow 补了三处**（前两条缺了，发出去的固件就是错的）：

| 步骤 | 为什么必须有 |
|---|---|
| `feed-patches/apply.sh` | `feeds/` 不入库，**EPON 上 `pon0-online` 恒灭**的修复只以补丁形式存在 `feed-patches/`。上游原来的 workflow 没有这一步 —— 那样编出来的固件会**静默缺少**这个修复（`feeds install` 拿到的是未打补丁的源码）。补丁套不上时脚本以非 0 退出，整个 job 失败，不会发布错固件 |
| `verify-images.sh` | "编译成功"不等于"能刷"（§5.5 那次事故）。不过这道闸就不产出 release |
| `fetch-depth: 0` | `scripts/getver.sh` 是靠 `git rev-list <固定提交>..HEAD` 数提交来算 `DISTRIB_REVISION` 的，`depth=1` 的浅克隆里那个提交不存在，算出来是错的 —— 刷完机 `cat /etc/openwrt_release` 就对不上 |

**可选**：`PONWRT_APK_PRIVATE_KEY` secret 用来签发 apk 包（不设也能编，只是包不签名）。

> ⚠️ **三个已知限制**：
> ① CI 里跑的是**裸 `make`，不是 `build.sh`** —— 所以本地的并发锁、逐包日志、失败自愈
> 在 CI 里都没有。CI 是一次性干净环境，这些本来也不必要，但"自愈"同样帮不上忙，
> 失败就是整轮重跑；
> ② 上游这份是**手动触发**（`workflow_dispatch` + tag 输入），不是 uboot-an758x 那种
> "推 tag 就发"。想改成推 tag 自动发，在 `on:` 下加 `push: tags: ['v*']`，
> 并把 release job 里用 `inputs.tag` 的地方换成 `github.ref_name` 即可；
> ③ `ccache` 在依赖列表里装了，但 `configs/*.config` 里 `CONFIG_CCACHE` 是**关的**
> （`# CONFIG_CCACHE is not set`，`CONFIG_CCACHE_DIR=""`）⇒ 缓存实际没生效，每次
> 发布都是全量编译。想加速重复发布，可以在 `make defconfig` 前给 `.config` 加一行
> `CONFIG_CCACHE=y`，再缓存 `<topdir>/.ccache`（`rules.mk` 里目录为空时回落到它）。
> **本仓库没有 CI 实测耗时记录**，二次发布前建议先跑一次看是否落在 360 分钟的 job 上限内。

---

## 6. 刷机与刷后自检

刷机本身沿用上游流程（[AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) 备份/装 UBI，
[AN758x U-Boot](https://github.com/pbs05/uboot-an758x) 提供引导与 Web 恢复）。
刷完 PonWrt 后通过 U-Boot Web 或 LuCI **网络 → PON → 配置 → PON 板卡数据** 恢复原厂
校准与身份数据。

### 6.1 通用自检

```sh
cat /etc/openwrt_release                      # 看 DISTRIB_REVISION
apk list -I | grep airoha-npu                 # 应见 luci-app-airoha-npu-1.2.0-r3

for d in /sys/class/net/*; do
  echo "$(basename $d) -> $(basename $(readlink -f $d/of_node))"
done                                          # 期望 eth0->ethernet@1  pon0->ethernet@2  lan1->ethernet@4
cat /sys/class/net/pon0/of_node/airoha,pon-data-path   # 存在即 PON 数据面
cat /sys/class/net/pon0/carrier                        # 1 = PON 已注册
dmesg | grep "OF: reserved mem:"                       # 期望 4 个区：atf/npu-binary/qdma0/qdma1
dmesg | grep -i "NPU fw version"
```

### 6.2 本次修复的专项自检

| 改动 | 机型 | 怎么验 |
|---|---|---|
| 2.5G 口 LED | ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A | `cat /sys/class/leds/mt7530-0:0f:green:lan-1/trigger` → `[netdev]`；插 2.5G 网线看灯 |
| 2.5G 口 LED（an7583） | XG-040G-MF | 这台的名字长得多，要带前缀：`cat '/sys/class/leds/1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1/trigger'` → `[netdev]`；插 2.5G 网线看 LED2.5（前缀由来见 §2.1） |
| 面板口序 | UNG00A | 四根线分别插 LAN1..4，`ip -br link` 看 carrier 是否落在 lan1..4（**不是**按 port 顺序） |
| 六个面板 LED 绑定 | HG5585F-CU | ① `ls /sys/class/leds/` 应出现 4 个 `blue:lan-*`（**不是** `mt7530-0:*:green:lan-*`，那是已撤掉的 PHY LED0 方案）＋ `blue:usb-1/2`；② **`cat /sys/class/leds/blue:lan-1/trigger` 必须是 `[netdev]`** —— 若是 `[none]`，说明 UCI 没绑上（保留配置升级的常见坑，见 §2.3.1），查 `uci show system \| grep led_` 的 sysfs 是不是本镜像里真实存在的类设备名；③ `device_name` → `lan1`；④ **逐口插线看灯**；⑤ `grep -c usbport /sys/class/leds/blue:usb-1/trigger` 应 ≥1（=0 说明 `kmod-usb-ledtrig-usbport` 没进镜像，见 §2.3.2）；⑥ `dmesg \| grep -i 'leds-gpio'` 不应报无法申请 GPIO43-46；⑦ `dmesg` 里的 4 条 `Failed to setup PHY LED pinctrl` 是**正常的**，见 §2.3 |
| lan1 冷启动一致性 | HG5585F-CT | `reboot`（热重启）后立刻 `cat /sys/class/net/lan1/carrier`，应看到 `1`；`dmesg \| grep -i "GPY211\|Clause 45"` 不应出现 Generic Clause 45 PHY |
| 内核硬件加密（AN7583） | XG-040G-MF | ① `grep -A3 '^name         : ecb(aes)$' /proc/crypto` → 期望 `driver: ecb(aes-ce)`（同类还有 `cbc(aes-ce)` / `ctr(aes-ce)`）；② `grep -A3 '^name         : gcm(aes)$' /proc/crypto` → 期望 `gcm_base(ctr-aes-ce,ghash-ce)`；③ `grep -c eip93 /proc/crypto` > 0、`lsmod \| grep -E "eip93\|cryptodev"` 有两条；④ 用户态本来就硬件，刷完 `/tmp/aes-check` 应仍是 `armcap=0x3d`、`aes-128-gcm ~570 MB/s`。完整清单见 §2.8 末尾 |
| 无线默认值（CN / 160MHz / SSID / WPA2-PSK） | HG5585F-CT / HG5585F-CU / ZN515XG-D | `jsonfilter -i /etc/board.json -e '@.wlan.defaults'` 应见 `country:"CN"`、`widths.5g:"160"`、`ssids.2g/5g`；`uci show wireless \| grep -E "country\|htmode"` 应见 `country='CN'` 与 `htmode='HE160'`；`uci show wireless \| grep -E "ssid\|encryption\|key"` 应见 2.4G=`ImmortalWrt` / 5G=`ImmortalWrt_5G`、两侧 `encryption='psk2'` 且 `key='12345678'`；`iw dev phy1-ap0 info \| grep width` 应见 `width: 160 MHz`；手机能搜到**两个** SSID，用 `12345678` 能连上（随后自己去 LuCI 改密码） |
| IPTV 组播 | 任意 | §4 的两条命令 |
| 「上网」灯（第 4 个，真实上网探测） | 所有 airoha 机型 | ① `pon-internet-led status`（配置 + 上次结果）；② `pon-internet-led once` 应为 `online (via …)`；③ `cat /sys/class/leds/*:wan-online/trigger` 期望 `[none]`（用户态接管）；④ 拔网线/`ifdown wan` → 灯立刻灭，`ifup wan` → 3 秒后补探并重新点亮；⑤ `logread \| grep pon-internet-led` 有 online/offline 切换日志 |
| 「光信号」灯（第 3 个） | 所有 airoha 机型 | ① `cat /sys/class/leds/*:wan/trigger` → `[pon0-los]`（红的那盏）；② 插着光纤 → **灭**（有光不告警）；拔光纤 → **红灯 500ms 闪**；③ `sh docs/pon-led-diag.sh walk 4` 确认该位置就是 GPIO16 那盏红灯。曾试过"有光常亮"，实机觉得别扭已退回（§2.7.2） |
| 「PON」灯（第 2 个，注册） | 所有 airoha 机型 | 注册成功应绿灯常亮：`cat /sys/class/leds/*:wan/trigger` → `[pon0-registration]` |

> LuCI 的 JS 带 `?v=` 版本号，而那个版本号来自 luci-base 不是本包，**刷完请硬刷新浏览器
> （Ctrl+Shift+R）**，否则可能仍在用缓存的旧 `status.js`。

---

## 7. 回退

**回退 NPU 面板移植**（配置 + 包目录 + 编译产物精确还原，不动已生成的 `.itb`）：

```sh
./docs/luci-app-airoha-npu-port/rollback.sh --dry-run   # 先看要做什么
./docs/luci-app-airoha-npu-port/rollback.sh
./build.sh                                              # 重新编译即回到移植前
```

**回退 LED / DTS 修复**：`git revert <提交>`，或直接取 `.before` 快照：

```sh
cp docs/luci-app-airoha-npu-port/01_leds.before \
   target/linux/airoha/an7581/base-files/etc/board.d/01_leds
```

**只想让某台机器保持原样**：从 `01_leds` 里删掉该机型那几行即可（一句话的事），
代价是 2.5G 口的灯会回到"插线上灯不亮"。

---

## 8. 已知限制与上游差异

### 8.1 未验证 / 需要上机确认的部分

| # | 项目 | 状态 |
|---|---|---|
| 1 | §2.5 的 XG-040G-MF LED 命名补全 | 标 `[补全]`，未单独上机验证（只影响类设备命名，风险低） |
| 2 | §2.3 的 HG5585F-CU 四个 LAN 灯 | 已改用上游 `91077e9a6b` 的方案（GPIO43-46 gpio-leds + `01_leds` netdev 触发），本 fork 原先的 PHY LED0 mux 路线已撤销。硬件已复验（逐脚驱动 GPIO43-46，四个灯全亮）。**但 2026-10-16 的"已上机确认正常"结论不成立**：那次是在 sysfs 里临时绑触发看到的，没落到 `/etc/config/system`，重启即失效；保留配置升级的机器上触发器绑不上、灯全灭。已补 uci-defaults 迁移 `99-hg5585f-cu-leds`（用上游 `migrate_leds()` 改名 + 补齐 6 段），五条路径真机验证（§2.3.1）。另发现 USB 灯因缺 `kmod-usb-ledtrig-usbport` 从来没亮过，已补（§2.3.2，与升级无关，全新安装也一样） |
| 3 | §2.4 的 HG5585F-CT GPY211C | 结论基于复位时序竞态分析，需在真机上做一次热重启核对 |
| 4 | 机型覆盖 | 修复的根因取证与刷机回归以 **ZN504XG-D** 为主力机型（UNG00A 的口序结论有换线实测记录）。代码覆盖 12 个 AN7581 机型，但只对白名单里的 6 个出固件（见 [docs/build-models-policy.md](docs/build-models-policy.md)）；这 6 个里除主力机外的机型未逐个做完整回归，按 §6.2 自检即可 |
| 5 | §2.7.3 的「上网」灯（主动探测） | 逻辑写好并编译进镜像，**等实机确认**：能上网 → 常亮，断网/拔纤 → 30 秒内灭；`pon-internet-led once` 可手动验证一次探测。若你常用的站点被列在探测表之外，改 `/etc/config/pon-led` 的 `urls` 即可 |
| 6 | §2.7.2 的「光信号」灯 | **已按实机反馈退回传统语义**（正常灭、无光红闪），与原厂一致；不需要再验。硬件上这盏灯只有红光，"正常亮绿灯"不存在 |
| 7 | §2.7 的 feed 驱动补丁（两个） | 改动在 `feed-patches/pon_drivers/airoha-xpon/`，套用/回退见 §5.2.1；`build.sh` 会自动套。`./feed-patches/apply.sh --check` 可随时看状态 |
| 8 | §2.1 的 an7583（XG-040G-MF）2.5G 灯触发 | 类设备名（`1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1`）是**从运行中的机器读出来的**，不是推导的；但补上触发后**还没重新上机看灯亮**。按 §6.2 对应行确认即可 |
| 9 | §2.8 的 AN7583 硬件加密 | 配置已编译进固件（产物里能数出 `aes-ce`/`ghash-ce`/`authenc`/`algif_skcipher` 特征串，EIP-93 是模块、按预期不在内核镜像里）；**EIP-93 的硬件存在性已用只读寄存器探针实测确认**，但**"出数据"级别的测试还没做**（真正跑一次加解密）。刷完后按 §2.8 末尾的三条自检，重点是 `/proc/crypto` 里出现 `ecb(aes-ce)` 与 `gcm_base(ctr-aes-ce,ghash-ce)` |

**明确不支持**：**MT7916 不能用 NPU 加速 WiFi 流量**。NPU 的 WiFi 卸载代码只在
**mt7996** 驱动里，mt7915 目录 0 处 airoha/npu 引用；NPU 固件包也只有 MT7992 / MT7996 两种。
HG5585F 这类机型上 WiFi 的实际通路是
**MT7916D → PCIe → GDM3(PSE P3) → PPE**，路由/NAT 仍被 PPE 硬件卸载，
只是没有 NPU 那一层。面板上会明确写"无 NPU 卸载路径"。

### 8.2 严格来说不属于本 fork 的东西

`luci-app-airoha-npu` 的界面代码来自 rchen14b 的上游项目（Apache-2.0，见
`package/luci-app-airoha-npu/LICENSE`），本 fork 做的是"WAN = PON"的角色反转与
MT7916 数据源重写。`docs/luci-app-airoha-npu-port/upstream/` 里保留了上游原始文件，
方便对比。

同理，**5G 能跑 160MHz 这件事本身来自 ImmortalWrt 的 `wireless-regdb` 补丁**
（CN / US 的 5GHz 被改成整段 160MHz 且不带 DFS），本 fork 只负责把"默认用哪个国家码、
默认多宽"落到板级默认值里（见 §2.6）。

### 8.3 与上游后续提交的关系

**2026-10-16 已把上游 `c3b518baec..a57faf93c6`（6 个提交）合并进来**，`git merge` 文本上
干净（无冲突），但有三处是**语义层面**的取舍 —— git 只按行合并，不会替你判断：

| 上游提交 | 内容 | 同步后的状态 |
|---|---|---|
| `91077e9a6b` | HG5585F 复位键改 GPIO35 + 新增 WPS/RFKILL 键 + 面板 LED（GPIO43-46 当普通 `gpio-leds`） | **采用上游方案**：本 fork 原先把同样这 4 个脚 mux 成 PHY LED0，两套写法会互相抢脚，已撤掉本 fork 那份，只留一段防回归注释（§2.3） |
| `69cd3e269f` | 把 EN8811H 复位时序改回 `10000/20000us` | ✅ **决定跟随上游**（`10000/20000us`）。本 fork 以前的做法是"故意不合并这笔提交"、保留刷机验证过的 `1000000/100000us`，**从 2026-10-16 起作废**，改为跟上上游。受影响的是 4 个 DTS 里的 EN8811H 复位时序：`an7581-nokia_xg-040g-md-common.dtsi`、`an7581-unionman-ung00a.dts`、`an7581-znxt-zn50xg-d-common.dtsi`、`an7583-nokia_xg-040g-mf-common.dtsi`。**若日后 2.5G 口出现探测不稳**，用下面这条命令改回长时序（只动这 4 个文件的这两个属性）：<br>`sed -i 's/reset-assert-us = <10000>;/reset-assert-us = <1000000>;/; s/reset-deassert-us = <20000>;/reset-deassert-us = <100000>;/'` + 上列 4 个文件 |
| `77ad7d0643` | 新增 H3C HM-2004-DU 机型（+ 新的 `board.d/03_pon_data`） | 已并入；`configs/an7581.config` 未选该机型（§5.4）。`03_pon_data` 把 PON 板卡数据的布局写进 `board.json`，本 fork 的 NPU 面板不读它（直接读 sysfs/debugfs），两者不冲突 |
| `ad21123a0f` | 去掉 an758x 无意义的 `DEVICE_DTS_CONFIG` | 已并入；本 fork 的 `configs/*.config` 与 `build.sh` 都没引用这个符号，无需处理 |

**下次再同步上游时的检查清单**（这次踩过的坑）：

```sh
git fetch origin
git merge origin/master
git diff HEAD~1 -- target/linux/airoha/dts/       # ① 上游动了哪些 DTS（复位时序、LED、pinctrl 都在这里）
git diff HEAD~1 -- '*reset-*'                     # ② 专门看 EN8811H 复位时序有没有再变
grep -n 'gpio4[3-6]' target/linux/airoha/dts/an7581-fiberhome-hg5585f-*.dtsi   # ③ GPIO43-46 归谁
```

**教训**：本 fork 有些"个性化"并不体现在提交里，而是"**故意不合并上游的某一笔提交**"
（EN8811H 复位时序在 2026-10-16 之前就是这种）。这类差异 `git merge` 一定会静默接受上游版本、
也一定不报冲突，所以**每次同步后都要把 DTS 手工 diff 一遍**，别只看 git 有没有冲突 ——
这次的决定是两处都跟随上游，但**必须是你看着 diff 主动决定的**，不能被 git 悄悄带走。

---

## 9. 目录导览（本 fork 新增部分）

```
README.md                                     中文主页（本 fork；英文原文已移到 README.en.md）
README.en.md                                  英文页（上游 README.md 的英文原文 + 本 fork 概览）
README.zh-CN.md                               本文件：相对上游的全部改动与取证记录
build.sh                                      编译入口：不改构建输入、并发锁、逐包日志、失败自愈、
                                              编完自动产物体检（功能与用法见 §5.3）
build-watch.sh                                读 tmp/build.log 显示进度（阶段/里程碑/活性指标）
build-live.sh                                 不依赖日志：直接看进程 + 文件系统改动
verify-images.sh                              刷机前产物体检（FIT 内部结构/内核 cpio/体积）
scripts/verify-fit.py                            verify-images.sh 的 FIT 解析内核部分
scripts/systemd/                              Ubuntu 24.04 systemd-oomd 防杀配置/安装脚本
package/luci-app-airoha-npu/                  NPU/Frame Engine 面板（1.2.0-r3）
target/linux/airoha/patches-6.18/
    950-npu-expose-fw-version-sysfs.patch     NPU 版本/核数 sysfs
package/base-files/files/                     IPTV 组播 MAC 学习修复（4 个触发点）
package/base-files/files/lib/functions/
    uci-defaults.sh                           + ucidef_set_wireless_width()（板级默认带宽）
                                              + ucidef_set_wireless()（默认 SSID/加密/密钥）
package/network/config/wifi-scripts/files/lib/wifi/
    mac80211.uc                               默认带宽支持板级 widths 声明
target/linux/airoha/an7581/base-files/etc/board.d/
    03_wireless                               带无线机型统一默认值：国家码 CN、5G 160MHz、
                                              双 SSID（ImmortalWrt / ImmortalWrt_5G）、
                                              默认 WPA2-PSK（密钥 12345678）
target/linux/airoha/an7583/config-6.18         AN7583 硬件加密：ARMv8 CE（AES/GHASH）+ CBC/
                                              AUTHENC/AF_ALG + CRYPTO_HW + EIP-93（§2.8）
configs/an7583.config                          同上对应的用户态包：kmod-crypto-hw-eip93 /
                                              kmod-cryptodev / libopenssl-devcrypto
docs/an7583-armv8-crypto-check.md              AN7583 硬件加密核查（硬件事实、开了什么/没开什么、
                                              踩过的 CRYPTO_HW 坑、刷机后自检）
docs/an7583-aes-check.c                        用户态探针：打印 OPENSSL_armcap_P 与真实吞吐
docs/an7583-eip93-probe-test.c                 EIP-93 只读寄存器探针模块（证明硬件存在）
docs/naiveproxy-an7581-sigill.md               PassWall 的 Naiveproxy 节点不通：naive 在 AN7581 上
                                              SIGILL（clang 的 -mcpu 顺手打开了可选 crypto）+
                                              节点地址填 IP、与服务端 SNI/证书对不上
docs/naive-sigill-probe.c                      无 gdb 时定位 SIGILL 的 LD_PRELOAD 探针（打印 pc/偏移）
docs/xg-040g-mf-an7583-2p5g-fix.md             XG-040G-MF 2.5G 口三个症状的完整排查记录
docs/xg-040g-tx-power-ddmi.md                  XG-040G-MD 发射功率 -40 dBm：EN7572 BOB
                                              A0/A2 标定表与「模式挑了没标定的那张」
docs/ung00a-tx-power-tssi.md                   UNG00A 发射功率 -40 dBm：A0 只标定模拟段、
                                              TSSI 在 A2（0001 删回退造成的回归）
feed-patches/apply.sh                         上游 feed 补丁（幂等）套用脚本：--check 只看状态、
                                              --reset 复位后重套；区分「git 用不了」与
                                              「补丁真冲突」两种报错。build.sh 与顶层 make 都调
include/toplevel.mk                           挂 feed-patches-apply（任何 make 目标都先套补丁）
                                              + git/REVISION 自检（§5.1.1）
feed-patches/pon_drivers/airoha-xpon/
    0001-*.patch                               EPON 上 pon0-online 触发器不再死灯
feed-patches/pon_drivers/airoha-pon-frontends/
    0001-*.patch                               模式改从已标定的 BOB 表取模拟参数（-40 dBm）
    0002-*.patch                               恢复 A0←A2 的 TSSI 回退（UNG00A 的 -40 回归）
feed-patches/packages/net/naiveproxy/
    0001-*.patch                               aarch64 加 `+nocrypto`：否则 naive 在 AN7581 上
                                              启动即 SIGILL，PassWall 节点静默不通
target/linux/airoha/base-files/usr/libexec/
    pon-internet-led                           「上网」灯 = 主动探测互联网（通=常亮、连续失败=灭）
target/linux/airoha/base-files/etc/init.d/
    pon-internet-led                           procd 常驻探测循环（START=96）
target/linux/airoha/base-files/etc/hotplug.d/iface/
    30-pon-internet-led                        PPPoE 起来/断开时立刻补探或灭灯
docs/luci-app-airoha-npu-port/README.md       移植全过程、根因取证、逐机型核对
docs/iptv-udpxy-omcproxy-guide.md             udpxy + omcproxy 完整指南（已脱敏）
docs/pon-link-watch.sh                        PON 光功率/温度/注册计数器定时光采样
docs/pon-led-diag.sh                          面板灯取证：触发器/亮度/线路状态 + 逐个点亮对面板
docs/pon-txpwr-probe.sh                       直接读写 EN7572 模拟寄存器，施加/回退 A2 标定值
docs/luci-app-airoha-npu-port/tests/          渲染回归测试 + 真机 fixture（MAC 已占位）
```

其他有用的调试脚本：[`docs/pon-link-watch.sh`](docs/pon-link-watch.sh) 周期采样
注册计数器（`deregisters` / `reregisters` / `register_nacks` / `registered_lifetime_ms`）
与光前端温度 —— 这些**只存在于运行内存**里，设备一重启就全没了，掉线那一刻不记录事后只能猜。

面板灯取证用 [`docs/pon-led-diag.sh`](docs/pon-led-diag.sh)：`sh /tmp/pon-led-diag.sh`
先打印 LED 类设备/触发器/亮度、PON 线路状态、`service_ready`、用户态 OAM 代理与 CTC 认证
状态；`sh /tmp/pon-led-diag.sh walk 4` 会**逐个点亮**每个 LED（每个 4 秒，结束后自动把
触发器恢复原样），用来确认"哪个 sysfs 灯 = 面板哪个位置、什么颜色"。§2.7 的结论就靠它取证。

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
