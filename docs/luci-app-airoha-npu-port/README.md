# luci-app-airoha-npu 移植说明（PonWrt）

参考 `~/work/openwrt_XG-140G-MD` 里的 `package/luci-app-airoha-npu`（v1.1.4，来自
<https://github.com/rchen14b/luci-app-airoha-npu>），移植到 PonWrt，
并把「WAN = 2.5G 铜口」改成「WAN = PON 口」。

---

## 一、改动范围（回退只需处理这些）

| # | 类型 | 内容 |
|---|---|---|
| 1 | **新增目录** | `package/luci-app-airoha-npu/`（11 个文件） |
| 2 | **改 .config** | +3 行：`CONFIG_PACKAGE_luci-app-airoha-npu=y`、`luci-i18n-airoha-npu-zh-cn=y`、`# CONFIG_PACKAGE_luci-i18n-airoha-npu-es is not set` |
| 3 | **改 configs/release.config** | +1 行：`CONFIG_PACKAGE_luci-app-airoha-npu=y` |
| 4 | **改 01_leds** | `target/linux/airoha/an7581/base-files/etc/board.d/01_leds`：新增 `znxt` case，并给 `nokia`/`unionman` 补上 2.5G PHY 的 `lan1` LED（详见第八节） |
| 5 | **新增内核补丁** | `target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch`：给 NPU 加 `fw_version` / `num_cores` sysfs 属性（原本只能从 dmesg 抓版本，日志被刷掉就显示 Unknown）。RPC 里本来就有「优先读 sysfs、读不到再退回 dmesg」的分支，**app 侧零改动** |

没有改 DTS、没有动 `feeds/`、没有动 `bin/targets/` 里已有的固件。

```
$ diff .config.bak-airoha-npu-port .config      # 只有 5 行 diff
$ diff docs/luci-app-airoha-npu-port/release.config.before configs/release.config
$ diff docs/luci-app-airoha-npu-port/01_leds.before target/linux/airoha/an7581/base-files/etc/board.d/01_leds
$ cat target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch   # 新增文件
```

## 二、回退

```sh
./docs/luci-app-airoha-npu-port/rollback.sh --dry-run   # 先看要做什么
./docs/luci-app-airoha-npu-port/rollback.sh             # 真正回退
./build.sh                                              # 重新编译即回到移植前
```

脚本按备份精确还原配置、删除包目录与编译产物；**不会**删除 `bin/targets` 下已生成的
`.itb` 固件。手工回退等价于：

```sh
rm -rf package/luci-app-airoha-npu
cp docs/luci-app-airoha-npu-port/config.before .config
cp docs/luci-app-airoha-npu-port/release.config.before configs/release.config
cp docs/luci-app-airoha-npu-port/01_leds.before target/linux/airoha/an7581/base-files/etc/board.d/01_leds
```

## 三、为什么必须改（角色反转）

| | 参考树 openwrt_XG-140G-MD | PonWrt |
|---|---|---|
| WAN | GDM4 / EN8811 2.5G / netdev `wan` | **GDM2 / XPON GEM / netdev `pon0`** |
| 2.5G 口 | WAN | **LAN（`lan1`）** |
| 交换机 master | `dsa-mgr`（DTS 里写死） | `eth0`（DTS 没给 `netdev-name`） |

原代码 `find_gdm_dev dsa-mgr eth0` / `find_gdm_dev wan eth1` 在 PonWrt 上必然失效
（`wan` 不存在，`eth1` 已被改名为 `lan1`）。因此改为**从活体设备树解析**：
扫 `/sys/class/net/*/of_node`，用 `ethernet@N`（或多口 GDM 的 `ethernet-port@M` 父节点）
反推 GDM 序号 —— 与内核 `device_add()` 建的 of_node 链接、以及
`/lib/preinit/04_set_netdev_label` 用的是同一份数据源。

## 四、全机型核对结果（从各机型已编译的 DTB 提取）

```
profile                             GDM 拓扑（app 会解析到的 netdev）
n7581-fiberhome-hg5382a             GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
n7581-fiberhome-hg5585f-ct          GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
n7581-fiberhome-hg5585f-ct-usb-sfp  GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1/lan5
n7581-fiberhome-hg5585f-cu          GDM1->eth0  GDM2->pon0[WAN]  GDM4->禁用
n7581-fiberhome-hg5585f-cu-usb-sfp  GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan5/lan6
n7581-gemtek-xg2010g                GDM1->eth0  GDM2->pon0[WAN]  GDM3->lan2  GDM4->lan1/lan3
n7581-nokia_xg-040g-md-ubi          GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
n7581-nokia_xg-040g-md-ubi-usb-sfp  GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1/lan5
n7581-nokia_xg-040g-tf-ubi          GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
n7581-unionman-ung00a               GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
n7581-znxt-zn504xg-d                GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1        ← 主力机型
n7581-znxt-zn515xg-d                GDM1->eth0  GDM2->pon0[WAN]  GDM4->lan1
```

- **12 个机型全部** GDM2 带 `airoha,pon-data-path` → `pon0` = WAN，无例外。
- 两个边界情况已处理：
  - **GDM4 被禁用**（HG5585F-CU）：按名字兜底会误抓 DSA 的 `lan1`，故加了
    `of_node_available()` 保护 —— 只要能读到 `of_node` 就**只**采信设备树结果，
    该机型 GDM4 卡片正确显示「Not present on this board」。
  - **GDM4 不是 2.5G**（Gemtek XG2010G 是 RTL8261N 10G）：速率标签改成从 DTB
    `phy-mode` 动态取（`2500base-x`→2.5G、`10gbase-r/usxgmii`→10G、`internal`→switch），
    卡片显示成 `Copper PHY (LAN) · lan1 · 2.5G` 这种形式。
- 多口 GDM（usb-sfp 机型）只取按字母序的第一个网口做计数与丢包映射，其余端口不重复计入。

## 五、界面/行为改动

- **GDM2 卡片** = 活跃的 PON/WAN 卡：TX/RX、丢包、链路状态（`carrier`，由
  `airoha-xpon` 随 ONU 注册/US-GEM 状态驱动）、解析到的网口名。
- **GDM4 卡片** = Copper PHY（LAN），带动态速率标签。
- **PSE 端口网格**：`P2`→GDM2(PON/WAN)、`P9`→Copper PHY；丢包统计由 P1/P9 扩到 **P1/P2/P9**。
- **`/usr/bin/ppe-verify`**：WAN 口动态解析；顺带修了两个上游 bug
  （`${var^^}` 是 bash 语法、会让 busybox ash 直接退出；`grep -c ... || echo 0`
  在空表时会输出 `0\n0`）。
- **WiFi 区块**（仅无线机型渲染）：MT7916 真实数据（信道占用/噪声/客户端/流量/芯片温度），
  详见第九节。
- 新增简体中文翻译（`po/zh_Hans`），西语翻译同步刷新。

## 六、编译前必读：git 的坑

这台机器上 `git` 被卸载了（`dpkg -l git` → `rc`），会导致：

```
ERROR: info field 'version' has invalid value: package version is invalid
  （base-files 版本变成 260923.84021~unknown，apk 要求 ~ 后面必须是十六进制）
```

原因：系统是 Deepin（提供 `libcurl3-gnutls`/`libcurl4`），而 APT 里优先级更高的
Ubuntu noble PPA 版本 git 依赖 Ubuntu 的 t64 改名包 `libcurl3t64-gnutls`，
Deepin 源里没有。**装 Deepin 自己那个版本即可**（已用 `apt-get -s` 模拟验证通过）：

```sh
sudo apt install --allow-downgrades git=1:2.51.0-1 git-man=1:2.51.0-1
```

### 如果不装 git：用 getver.sh 的官方 `version` 覆盖文件

`scripts/getver.sh` 会优先读 `TOPDIR/version`（SDK 就是这么用的）。注意 `~` 后面
必须十六进制，所以要写成 `r<数字>-<十六进制>`：

```sh
cd <你的工作目录>/ponwrt
printf 'r0-c3b518baec\n' > version      # c3b518baec = 上一次真实构建的 revision
./build.sh
rm -f version                            # 装回 git 后务必删掉，否则会盖住真实版本号
```

副作用：固件里的 `DISTRIB_REVISION` 会显示成 `r0-c3b518baec`（仅版本字符串，不影响功能）。

## 七、刷机后核对（以 ZN504XG-D 为准）

产物：`bin/targets/airoha/an7581/ponwrt-airoha-an7581-znxt_zn504xg-d-squashfs-sysupgrade.itb`

```sh
for d in /sys/class/net/*; do echo "$(basename $d) -> $(basename $(readlink -f $d/of_node))"; done
# 期望：eth0 -> ethernet@1   pon0 -> ethernet@2   lan1 -> ethernet@4   lan2/3/4 -> port@2/3/4

cat /sys/class/net/pon0/of_node/airoha,pon-data-path   # 存在即为 PON 数据面
cat /sys/class/net/pon0/carrier                        # 1 = PON 已注册
dmesg | grep -i "NPU fw version"
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
head -3 /sys/kernel/debug/ppe/entries
dmesg | grep "OF: reserved mem:"                       # 期望 4 个区（atf/npu-binary/qdma0/qdma1）
```

页面（`状态 → SoC Status`）重点看：
CPU 频率柱与调速器、NPU ACTIVE + 版本、Frame Engine 三张卡
（GDM2 应显示 `PON (WAN uplink) · pon0`，链路随光路注册变化）、
PSE 网格 P2 有 OQ 值、PPE 表 5 秒自刷。

## 八、2.5G 口"看起来是死的"其实是 LED 没配（已修）

现象：页面 GDM4 卡显示 `Link down`，2.5G 口插网线 LED 不亮，像是死口。

上机取证结论：**口是好的，是灯从来没亮过。**

```
# 2.5G 口以 2.5Gbps 起来过多次（插/拔线的痕迹）
[  35.9] airoha_eth 1fb50000.ethernet lan1: Link is Up - 2.5Gbps/Full - flow control off
[ 121.2] airoha_eth 1fb50000.ethernet lan1: Link is Up - 2.5Gbps/Full - flow control off
[ 142.0] airoha_eth 1fb50000.ethernet lan1: Link is Up - 2.5Gbps/Full - flow control off
# PHY 完全正常
Airoha EN8811H mt7530-0:0f: MD32 firmware version: 25062302
airoha_eth 1fb50000.ethernet lan1: PHY [mt7530-0:0f] driver [Airoha EN8811H]
```

**根因**：EN8811H 驱动在 `air_leds_init()` 里把 LED 设成 `AIR_LED_MODE_USER_DEFINE`
（外部软件控制），DTS 里的 `default-state = "keep"` **并不会**让 PHY 硬件自己驱动灯。
所以必须有 LED 触发绑定才会亮。而：

- 交换机 3 个口（`mt7530-0:0a/0b/0c`）通过 UCI 绑了 `netdev` → 一直正常；
- 2.5G PHY 的 `mt7530-0:0f:green:lan-1` **谁都没绑**（`trigger=none`、无 `device_name`）→ 永远不亮；
- 原因：`01_leds` 里**没有 `znxt,zn504xg-d` / `znxt,zn515xg-d` 的 case**，nokia / unionman 的 case 也只写了 lan2/3/4、漏了 2.5G 的 lan1。

**修复**（已提交到树里）：

```sh
znxt,zn504xg-d|\
znxt,zn515xg-d)
	ucidef_set_led_netdev "lan1" "lan1" "mt7530-0:0f:green:lan-1" "lan1" "link tx rx"
	ucidef_set_led_netdev "lan2" "lan2" "mt7530-0:0a:green:lan-2" "lan2" "link tx rx"
	ucidef_set_led_netdev "lan3" "lan3" "mt7530-0:0b:green:lan-3" "lan3" "link tx rx"
	ucidef_set_led_netdev "lan4" "lan4" "mt7530-0:0c:green:lan-4" "lan4" "link tx rx"
	;;
```

nokia / unionman 两个 case 也补了对应的 `lan1` 行（同样是 EN8811H @ MDIO 0x0f）。
Gemtek XG2010G 的 EN8811H 没有 `leds` 子节点，不适用。

**无需刷机即可热修**（改的是 UCI，网络零影响，可一条命令撤销）：

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

验证：`cat /sys/class/leds/mt7530-0:0f:green:lan-1/trigger` 应显示 `[netdev]`，
且该目录下出现 `device_name` / `link` / `link_2500` / `tx` / `rx`。

一个次要提醒：`ethtool lan1` 报 `master-slave cfg: preferred slave`（PHY 硬件默认值）。
如果对端设备也偏好 slave 且两端都是单端口设备，1000/2.5GBASE-T 的主从仲裁可能谈不下来。
真遇到"插上不亮也不 link"时，可试 `ethtool -s lan1 autoneg on speed 1000 duplex full` 复核。

### 8.1 根因（用寄存器 dump 定死，2026-10-07 上机实测）

在 EN8811H 驱动里临时插了诊断打印（`air_leds_init`、`air_hw_led_on_set`、
`air_hw_led_control_set` 写入后读回，外加 buckpbus `EN8811H_GPIO_OUTPUT`），
从 dmesg 拿到完整证据链：

> 该诊断补丁（`999-en8811h-led-diag.patch`）与配套的 DTS `led-1`/`led-2`
> **在结论确认后已全部撤销**，最终固件里不含任何诊断代码。


```
[ 10.9] config_init: led_mode=1 → air_leds_init(USER_DEFINE)
        LED0 rules=00000601  ON=c107 BLINK=0c3f     ← 驱动默认规则（link+rx+tx）已写入，正确
        LED1 rules=00000018  ON=c101 BLINK=0000
        LED2 rules=00000014  ON=c102 BLINK=0000
[33.75] brightness_set LED0 value=0 -> ON=c080 rules=00000000
                                                    ← ★ LED class 设备注册时，
                                                      LED core 调 brightness_set(0)，
                                                      把 priv->led[0].rules 和硬件 ON
                                                      寄存器一起清零，只剩 ENABLE|POLARITY
[33.88] hw_control_set LED0 rules=00000001 -> ON=c187   ← netdev 触发把规则推回去
[33.90] hw_control_set LED0 rules=00000201 -> ON=c187
[33.91] hw_control_set LED0 rules=00000601 -> ON=c187 BLINK=0c3f   ← 灯亮 ✓
[75.67] hw_control_set LED0 rules=00000601 -> ON=c187 BLINK=0c3f   ← 链路事件后自动重推，可自愈
```

**机制**：`phy_led_probe()` 注册 DT 里声明的 LED class 设备时会调用
`led_brightness_set(0)`，而驱动的 `air_hw_led_on_set(false)` 里有
`priv->led[index].rules = 0` —— 驱动辛苦写的默认规则被 LED core 一把清零。
此后**只有 `netdev` 触发把规则重新推回去，灯才会亮**。PonWrt 的 `01_leds` 里没有
znxt case ⇒ 没有 UCI ⇒ 没有触发 ⇒ 规则永远是 0 ⇒ **灯永远不亮**（而口本身完全正常）。

这也解释了为什么厂商固件灯是亮的：厂商 `/userfs/led.conf` 里
`LED_LANPORT1..4` 全是 `0 = LED_MODE_NOT_USED`，厂商**根本不从 SoC 驱动 LAN 灯**，
而是让 PHY 保持自身的硬件 LED 行为（对应驱动里的 `AIR_LED_MODE_DISABLE`），
不需要任何软件参与。

### 8.2 验证过的鲁棒性

- `for i in 1 2 3; do /etc/init.d/led restart; done` → 每次都稳定回到
  `trigger=netdev / dev=lan1`，寄存器 `ON=c187` 保持（脚本会打出 3 个
  `write error: Invalid argument`，那是无关的 mode 属性写入，**无害**）。
- 链路 up/down 事件后触发会自动重推规则（[75.67] 那条），不会像上游 commit
  描述的那样"重协商后变黑"。
- `brightness_set value=1 -> ON=c0c0`（含 FORCE_ON=0x40）确认强制点亮路径也通。

### 8.3 排查过程中排除掉的假设

| 假设 | 结论 |
|---|---|
| PHY 没起来 / 固件没加载 | 否：`MD32 firmware version: 25062302`，2.5G 链路正常 |
| LED GPIO 方向因 MCU 重启变回输入 | 否：`928f5c5ab8` 修复已在核里，`EN8811H_GPIO_OUTPUT` 每次 config_init 都重写 |
| 面板的灯接在 LED1/LED2 而不是 LED0 | 否：LED1/LED2 一直带着默认规则（无触发、无人清），若面板灯在其上早就亮了；实测面板 2.5G 灯对应 **LED0** |
| 移植的 luci-app 造成的 | 否：刷回无该包的旧固件，现象完全一样（A/B 实测） |
| LED 硬件/接线坏 | 否：原厂固件下该灯是亮的 |


## 九、WiFi 部分（FiberHome HG5585F-CT/CU + MT7916D）

### 9.1 结论：MT7916 **不能**用 NPU 加速 WiFi 流量

| # | 证据 | 位置 |
|---|---|---|
| 1 | NPU 的 WiFi TX/RX 卸载代码只在 **mt7996** 驱动里 | `mt76/mt7996/npu.c` → `mt7992_npu_txrx_offload_init()` |
| 2 | 只有 mt7996 与 Airoha NPU 交互；**mt7915 目录 0 处** airoha/npu 引用 | `mt7996/mmio.c` → `airoha_npu_wlan_enable_irq()` |
| 3 | mt76 的 NPU 层只在选 `kmod-mt7996e` 时才编译进去 | `package/kernel/mt76/Makefile:508-511` |
| 4 | NPU 固件包只有 MT7992 / MT7996 两种，**没有 MT7916** | `package/firmware/linux-firmware/airoha.mk` |
| 5 | 5855F 的 DTS **没有** include `an7581-npu-wlan.dtsi`，NPU 的 WiFi 专用保留内存没保留 | `an7581-fiberhome-hg5585f-common.dtsi` |

5855F 上的实际通路：**MT7916D → PCIe（`14c3:7906` 主 HIF 在 PCIe1，PCIe0 提供 HIF2）→ GDM3 (PSE P3) → PPE**。
路由/NAT 流量**仍然被 PPE 硬件卸载**，只是没有 NPU 那一层。NPU 在该机型上只加速以太网/PON 侧。

### 9.2 上游的 WiFi 界面为什么不能照搬

上游 `status.js` 把 3 个频段 chip 塞进 `CDM4 / WDMA`（「P7 WiFi DMA」）卡片，徽标取自 `token_info` 的 `npu`/`dma`。三个问题：

1. `token_info` 这个 debugfs **只由 mt7996 的 NPU 代码创建** —— MT7916 上根本不存在（真机实测 `No such file or directory`）；
2. `CDM4/WDMA` 不是 MT7916 的通路（WiFi 走 PCIe/GDM3），参考的 v1.1.4 正是因此删掉了这张卡；
3. 上游用 `/Interface phy0\.<band>-/` 匹配接口名 —— 那是 **mt7996 单 phy 多频段**（`phy0.0-apN`）的命名；**MT7916D 是两个 PCIe HIF → 两个 phy**，真机命名为 `phy0-ap0`(2.4G) / `phy1-ap0`(5G)，且每个 wiphy 的 band 编号从 1/2 起 ⇒ 上游正则**一个都匹配不上**，所有频段都会显示 0 客户端。

### 9.3 采集：只用 MT7916 真机上真实存在的数据源

先做数据源普查（真机逐项确认），结果是 MT7916D 在本内核下能提供这些：

| 数据 | 来源 | 5855F 实测 |
|---|---|---|
| 频段 / 信道 / 带宽 / SSID | `iw dev <if> info` | phy0-ap0 ch1@20 · phy1-ap0 ch36@80 |
| 客户端数、单客户端收发字节/包数/重传/失败/信号 | `iw dev <if> station dump` | 字段名已对内核 `iw-6.17/station.c` 逐个核对 |
| 信道占用（忙时占比）、噪声底 | `iw dev <if> survey dump` | 2.4G busy 41% / noise −91 dBm；5G busy 10% / noise −92 dBm |
| 芯片结温与上限 | `/sys/class/ieee80211/phy*/hwmon*/temp1_{input,crit}` | 52.0 °C，上限 110 °C |
| 驱动名 | `/sys/class/ieee80211/phy0/device/driver` | `mt7915e` |

反过来，下面这些在这台机器上**根本不存在**，而上游界面正是建立在其上，所以不能照搬：
`/sys/kernel/debug/ieee80211/phy0/mt76/token_info`（只有 mt7996 的 NPU 代码创建）、
`fw_util_*`（只有一行 `Program counter: 0x0`，没有占用率）、`muru_stats`、
每队列 `xmit-queues`（恒为 0）。

评估后**没有采纳**的数据：`mt76/tx_stats` 的 MCS 直方图（太细）、`aql_pending`、
`xmit-queues` 队列深度（常年为 0，且与卡片上已有数字重复）。

### 9.4 显示：与 GDM 卡片同风格，且「没数据 / 重复」的一律不画

- **标题栏**：`WiFi` + 芯片温度徽标。两个 phy 的温度来自同一颗 MT7916 die（实测都是 52 °C），
  所以温度**只在标题出现一次**，不在每张频段卡上重复；副标题为
  `mt7915e · 无 NPU 卸载路径 · WiFi → PCIe → GDM3 (P3) → PPE`。
- **每个频段一张卡**（沿用 GDM 卡的视觉语言：左侧色条、彩色标题、右侧接口名徽标、键值网格）：
  - 始终显示：`SSID`、`信道 x @ y MHz`、`客户端数`
  - 有客户端才显示：`信号（最弱客户端）`（≥−60 绿 / ≥−70 橙 / 否则红）、
    `流量`（↓ 下行发给客户端 / ↑ 上行收自客户端，鼠标悬停有说明）、
    `重传率`（重传/发包，>10% 橙、>25% 红）、`发送失败`（非 0 才显示）
  - 读到 survey 才显示：`信道占用`（<30% 绿 / <60% 橙 / 否则红）、`噪声`
  - 频段被关闭 ⇒ 既无信道也无客户端 ⇒ **整张卡不渲染**；机型没有无线 ⇒ **整个区块不渲染**
  - 同一频段上有第二个 AP（多 SSID）⇒ 折叠进同一张卡（否则同一个射频会出现两张一样的卡）
- **PSE 网格 P3**：有 WiFi 时标签变成 `PCIe (WiFi)`，无 WiFi 时仍是 `GDM3`。

为什么客户端数为 0 时看不到流量行：流量取自 **station 表**，不是网卡的 `statistics`。
网卡 `tx_bytes` 含 beacon，空口闲着也会一直涨（实测 33 KB 全是 beacon）；station 表只统计
真正的客户端数据帧，于是「没有客户端 ⇒ 没有流量行」，不会甩出一堆看着像测量值的 0。

### 9.5 信道占用是「当前值」，不是「开机至今均值」

mac80211 的 survey 计数器是累加值（`channel active/busy time` 从接口 up 起一直加），
直接相除得到的是开机至今的平均值。后端把上一次采样存到 `/tmp/.airoha_npu_survey`，
用两次的差值算当前占用率；两次间隔不足 1 秒（或接口重启导致计数器回绕）就退回累加均值，
避免报出 0% / 100% 这种假值。页面轮询周期 5 秒，所以看到的基本都是当前值。

**验证方法**（已实测）：手工把状态文件里的历史样本改成「30 秒前且全忙」，
2.4G 的读数从 41% 变成 86%（= 走差值），证明差值分支确实生效。

### 9.6 接口与兼容性

- RPC 方法为 `getWifiInfo`（原 `getTokenInfo`）。**`getTokenInfo` 作为别名保留**：
  LuCI 的 JS 带 `?v=` 版本号，而那个版本号来自 luci-base 不是本包，浏览器可能缓存旧
  `status.js`；旧前端调 `getTokenInfo` 仍能拿到数据，页面不会整页加载失败，硬刷新后
  自动切到新的 `getWifiInfo`。
- 单次 `getWifiInfo` 实测约 200 ms（5855F）；页面四个 RPC 合计约 1.2 s，轮询 5 s，压力可接受。
- 旧返回里的 `station_counts` / `token_count` / `npu_active` / `tx_queues` 已删除（无数据或重复）。
- i18n 用官方扫描器重建（`feeds/luci/build/i18n-scan.pl . > po/templates/luci-app-airoha-npu.pot`），
  简中/西语各 55 条，`po2lmo` 编译通过。

### 9.7 真机验证（HG5585F-CT，192.168.1.1）

```json
{"wifi_present":true,"npu_offload":false,"chip":"mt7915e","temp_c":52.0,"temp_crit_c":110,
 "bands":[{"band":1,"freq_mhz":5180,"channel":36,"width_mhz":80,"up":true,"netdev":"phy1-ap0",
           "ssid":"ImmortalWrt","count":0,"signal_dbm":null,"busy_pct":10,"noise_dbm":-92},
          {"band":0,"freq_mhz":2412,"channel":1,"width_mhz":20,"up":true,"netdev":"phy0-ap0",
           "ssid":"ImmortalWrt","count":0,"signal_dbm":null,"busy_pct":41,"noise_dbm":-91}]}
```

渲染回归测试共 7 个场景（真机无客户端 / 3 个客户端 / 5G 关闭 / 无无线的机型 /
survey 与温度都读不到 / 同频段多 SSID / **一次真机抓包**：手机连到 5G，
`rx 82702 / tx 22616 / tx packets 229 / retries 2 / failed 2 / signal -33`，
已核对解析与 RPC 输出逐项一致），脚本在 `tests/smoke_wifi.js`：

```sh
cd package/luci-app-airoha-npu
node ../../docs/luci-app-airoha-npu-port/tests/smoke_wifi.js
```

ZN504XG-D 上 `/sys/class/ieee80211` 为空（该机型无无线模块），实测 WiFi 区块整体不渲染。

## 十、编译刷机固件 + 各机型影响核对（本稿：1.2.0-r2）

### 10.1 编译命令

```sh
cd <你的工作目录>/ponwrt
./build.sh                 # 默认：沿用现有 .config，绝不改动它
                           #   —— 现有 .config 已含 12 个机型 + 本插件 + 中文语言包
# 需要从配置档重建 .config 时（= configs/an7581.config + configs/release.config）：
./build.sh --config=an7581
JOBS=2 ./build.sh          # 内存紧张时降并行
./build.sh --watch         # 另开终端只看进度
```

- 插件级已在本机验证：`make package/luci-app-airoha-npu/compile` → `rc=0`，
  产物 `bin/packages/aarch64_cortex-a53/base/luci-app-airoha-npu-1.2.0-r2.apk`。
  用 `staging_dir/host/bin/apk extract` 解包核对过：包内 `status.js` = `754cfe82…`、
  `luci.airoha_npu` = `58cfc072…`，与源码构建产物 md5 一致。
- **整包 image 需要你自己跑 `./build.sh`**：本会话里 fakeroot 的 `chown` 在
  用户命名空间 `uid_map = 1000 0 1` 下返回 EINVAL，420 个包全部报
  "failed to preserve owner"（第六节已记录）。

### 10.2 产物与机型对应（12 个机型一起出）

`bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-squashfs-sysupgrade.itb`
（另有 `<机型>-initramfs-recovery.itb` 用于救砖/恢复）

| 机型 | 无线 | GDM4（2.5G/10G 口） |
|---|---|---|
| `znxt_zn504xg-d` ← 主力 | 无 | `lan1`，2500base-x，EN8811H（PHY 0x0f） |
| `nokia_xg-040g-md-ubi` / `-usb-sfp` / `tf-ubi` | 无 | `lan1`(/`lan5`)，EN8811H（PHY 0x0f） |
| `unionman_ung00a` | 无 | `lan1`，EN8811H（PHY 0x0f） |
| `gemtek_xg2010g` | 无 | `lan1`/`lan3`，10G RTL8261N |
| `fiberhome_hg5382a` | 无 | `lan1`，MaxLinear GPY211 |
| `fiberhome_hg5585f-ct` / `-ct-usb-sfp` | **MT7916D** | `lan1`，2500base-x |
| `fiberhome_hg5585f-cu` / `-cu-usb-sfp` | **MT7916D** | **disabled（该机型没有这颗 PHY）** |
| `znxt_zn515xg-d` | **MT7916D**（带 zn515 专用 eeprom 包） | `lan1`，EN8811H |

刷机后自检：`cat /etc/openwrt_release` 看 `DISTRIB_REVISION`；
`apk list -I | grep airoha-npu` 应显示 `luci-app-airoha-npu-1.2.0-r2`。
**刷完记得硬刷新浏览器（Ctrl+Shift+R）**：LuCI 的 JS 带 `?v=` 版本号，
而那个版本号来自 luci-base 而不是本包，浏览器可能仍用旧的 `status.js`
（第 9.6 节的 `getTokenInfo` 别名就是为这种情况留的）。

### 10.3 CU 与 CT 的核对结果（从两台已编译的 DTB 读出）

```
                         HG5585F-CT              HG5585F-CU
PCIe 上的 wifi@0,0 节点   2（pcie0 + pcie1）      2（完全相同）
wifi eeprom（factory）    2 处引用                2 处引用
ethernet@4 (GDM4)        okay / 2500base-x       disabled
2.5G PHY                 MaxLinear GPY211(0x07)  —
```

- 两款无线路由**完全同源**：都继承 `an7581-fiberhome-hg5585f-common.dtsi`，
  `&pcie0`/`&pcie1` 各挂一个 `wifi@0,0`，各自变体的 DTS 里 0 处无线差异；
  驱动包也相同（`kmod-mt7915e kmod-mt7916-firmware wpad-openssl`）⇒ 真机实测的
  `phy0-ap0`(2.4G) / `phy1-ap0`(5G) 布局对 CT 与 CU 都成立。
- 唯一差异是 **GDM4**：CT 上它是 2.5G 口（`lan1`），CU 上 `disabled` ⇒
  CU 上 GDM4 卡片不出现（RPC 返回 `present:false`），属预期。
- **CT/CU 不需要 504 那个 EN8811H LED 修复**：CT 的 2.5G PHY 是 MaxLinear
  GPY211（PHY ID `67c9:de10`，`kmod-phy-maxlinear`），不是 EN8811H；
  并且 `01_leds` 里本来就没有 fiberhome 的 case（两款都是按 DTS/PHY 默认驱动 LED）。
- 另外注意：`znxt_zn515xg-d` 的 profile **也带 MT7916**（第 10.2 节表格），
  如果那台机器上没插无线模块，WiFi 区块同样不会渲染，无副作用。

### 10.4 没有无线的机型：确认不受影响

WiFi 相关的改动全部在插件内部（`getWifiInfo` 的采集 + 视图里的 WiFi 区块），
而且都是**运行时判定**，没有一行是按机型写死的：

| 检查项 | 结论 / 证据 |
|---|---|
| 包依赖 | `LUCI_DEPENDS:=+luci-base +jsonfilter @TARGET_airoha` —— 不引入任何无线包 |
| 界面 | `wifi_present=false` ⇒ 整个 WiFi 区块不渲染（用 **504 真机数据**跑整页渲染测试验证：无 WiFi 区块，GDM1/2/4 三张卡 + PSE 10 格完整，轮询刷新后仍在） |
| RPC | 没有无线时 `command -v iw` 通过但 `iw dev` 返回空 ⇒ 立刻返回 `wifi_present:false`；**不写任何 `/tmp` 状态文件**（真机 504 实测无残留） |
| 频段判定 | 只认运行时中心频率（<3000→2.4G，<5925→5G，其余 6G），与机型/芯片无关 |
| 机型相关文件 | 除 LED 一处（见下），**没有**改任何 DTS/Kconfig/profile |

**唯一会碰到非无线机型的是 `01_leds` 里的 LED 触发器**（第八节的修复）：
新增 `znxt,zn504xg-d|znxt,zn515xg-d` 一个 case，并给 `nokia,xg-040g-md-ubi|
nokia,xg-040g-tf-ubi` 与 `unionman,ung00a` 各补了一行 `lan1`。
依据是从 DTB 读出的同一套硬件：这三家的 GDM4 都是 **EN8811H（PHY 0x0f，
`ethernet-phy-id03a2.a411`，带 `function = "lan"` 的 LED 子节点）**，
而 EN8811H 驱动在 `air_leds_init()` 里把 LED 切到 user-defined 模式，
不绑 netdev 触发器就永远是灭的 —— 504 上已实测证实。若你希望 MD 保持原样，
删掉那两行即可（一句话的事），但 2.5G 口的灯会回到"插线上灯不亮"的状态。

