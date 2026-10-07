# PonWrt（jzhou404gmail fork）

[English](README.md) | **简体中文**

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试、并把调出来的修复固化回源码树。

上游 README 与 `README_zh.md` 保持原样未改，本文件只记录**这个 fork 相对上游多出来的东西**：
每一处硬件修复的**现象、根因、证据和验证方法**，以及一套"不破坏增量编译"的编译入口。

> **本 fork 的基线**：上游 `c3b518baec`（`firewall4: include transparent bridge ports in flowtable`）。
> 在此之上有 **11 个提交**（见 §1）。上游随后又前进了 5 个提交
> （`04986da1e6`，新增 H3C HM-2004-DU 机型、HG5585F 复位键与面板 LED 修复、
> EN8811H 复位时序改回 `10000/20000us`），**本 fork 有意暂未合并** ——
> 那会把已经刷机验证过的 EN8811H 复位时序改掉。合并方式见 §8.3。

---

## 1. 相对上游的改动总览

| # | 提交 | 主题 | 类型 |
|---|---|---|---|
| 1 | `chore(gitignore)` | 忽略 `.config` 备份、原厂固件转储、本机运维脚本 | 仓库卫生 |
| 2 | `build` | `build.sh` + `build-watch.sh` + `build-live.sh` 编译入口与进度观察 | 工具 |
| 3 | `airoha/an7581` | **面板 LAN 灯触发器缺失**（ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A） | 硬件修复 |
| 4 | `airoha/an7581` | **UNG00A 面板口序反转** + 启用 PHY1 LED0 | 硬件修复 |
| 5 | `airoha/an7583` | XG-040G-MF 的 PHY LED 补 `function` / `function-enumerator` | 一致性 |
| 6 | `airoha/an7581` | **HG5585F-CU 四个 LAN 灯全灭**（PHY LED0 pinctrl 未选中） | 硬件修复 |
| 7 | `airoha/an7581` | **HG5585F-CT 热重启后 lan1 NO-CARRIER**（GPY211C PHY ID 竞态） | 硬件修复 |
| 8 | `luci-app-airoha-npu` | NPU/Frame Engine 面板移植，**WAN = PON 口** | 新功能 |
| 9 | `base-files` | **IPTV 机顶盒报 2001** 的组播 VLAN MAC 学习修复 | 功能修复 |
| 10 | `docs` | NPU 移植说明、IPTV 组播指南、PON 掉线采样脚本、渲染回归测试 | 文档 |
| 11 | `feeds.conf.default` | 注释形式记录可选的 PassWall feed | 说明 |

---

## 2. 硬件修复详解

> **依据栏说明**
> `[实测]` = 在本机真机上取证过（寄存器 dump、换线实测或一次性诊断固件）；
> `[同源]` = 与已验证机型同硬件同驱动，结论直接沿用；
> `[补全]` = 从命名/顺序的确定性出发做的补全，未单独上机验证。

### 2.1 2.5G 口"看着是死的"——其实灯从来没亮过 `[实测]`

**机型**：`znxt_zn504xg-d`、`znxt_zn515xg-d`、`nokia_xg-040g-md-ubi`、
`nokia_xg-040g-tf-ubi`、`unionman_ung00a`

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

每个面板 LAN 灯挂在**它自己那个口的 PHY LED0 输出**上，而 AN7581 pinctrl
只有在 `an7581_phy_probe()` 里选中 `"gbe-led"` pinctrl 状态时才真正驱出这个输出。
本机型没选，所以 LED 输出一直被 mux 掉，PHY 做什么都到不了面板。

并行 NAND 占了 GPIO4-7 与 GPIO30-42，这块板还能给 PHY LED0 用的只剩 **GPIO43-46**。

GPIO43-46 能当 PHY LED0 用，靠的是本仓库已带的内核补丁
`203-09-pinctrl-airoha-permit-GPIO43-46-for-PHY-LED0.patch`
（上游维护者 Christian Marangi，理由就是"某些板子上 GPIO43-46 也被用于 PHY LED0"）——
它把这 4 个脚加进了 `phy1_led0` .. `phy4_led0` 的函数分组。**没有这个补丁，
`function = "phy1_led0"; pins = "gpio43"` 会被 `airoha_pinmux_set_mux()` 按名字匹配失败而
返回 `-EINVAL`，pinctrl 状态选择直接失败、mux 根本不会写下去。**

**修复**：`an7581-fiberhome-hg5585f-cu-common.dtsi` 描述这 4 个 pinctrl 组，
从 `gsw_phy1..4` 选中它们，并给对应 LED 类设备标上 `green` / `lan` + 对应枚举号。

> ⚠️ **这一处还有一半没做**：`01_leds` 里**没有 fiberhome 的 case**，所以这四个
> LED 类设备目前没有 netdev 触发绑定。按 §2.1 的同一套机制（LED core 注册时清规则），
> 只把 PHY LED0 mux 出来、不绑触发，**灯仍可能不亮**。上机时请一并确认 §6.2 的对应行；
> 若确认不亮，照 §2.1 的热修命令给 `lan1..lan4` 各补一条 UCI 即可（`sysfs` 填实际类设备名）。

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

---

## 3. LuCI NPU 面板（`luci-app-airoha-npu`）

移植自 [rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)
v1.1.4（本 fork 内版本 `1.2.0-r2`），把 **WAN = 2.5G 铜口**改成 **WAN = PON 口**。

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

**WiFi 区块是重写的，不是照搬上游**：上游读的 `token_info` debugfs 只由 mt7996 的 NPU
代码创建（MT7916 上不存在），匹配的 `phy0.<band>-` 也是 mt7996 单 phy 多频段的命名
（MT7916D 是两个 PCIe HIF ⇒ `phy0-ap0` / `phy1-ap0`，上游正则一个都匹配不上）。
现在只用芯片真机上确实存在的数据源：`iw dev info` / `station dump` / `survey dump` /
hwmon 温度。信道占用按两次 survey 采样的**差值**算当前值（累加值直接相除得到的是开机
至今均值）；**取不到的数据一律不画那一行**，不甩假 0。

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

### 5.2 取源码与 feed

```sh
git clone https://github.com/jzhou404gmail/ponwrt.git
cd ponwrt
./scripts/feeds update -a
./scripts/feeds install -a
```

### 5.3 三种编译方式

```sh
./build.sh                 # 默认：沿用现有 .config，绝不改动它（增量编译）
./build.sh --config=an7581 # 从 configs/an7581.config + configs/release.config 重建 .config
JOBS=2 ./build.sh          # 内存紧张时降并行
./build.sh --watch         # 另开一个终端只看进度
```

`build.sh` 的设计原则是**只做加法、绝不改动构建输入**：不传任何额外 make 变量、
不重写 `.config`，保证 OpenWrt 的增量判断完全按你原来那套走。raw make 输出全部进
`tmp/build.log`，控制台只打印进度块（阶段 / 里程碑 / 正在编译什么）。

`--config=<档>` 会先自动备份现有 `.config`，并且**带掉包保护**：
如果新配置的包数量比原来少 20% 以上就中止并自动还原。

**并发保护**：同一棵树里并行跑两个 `make` 会同时写 `build_dir/` 与 `staging_dir/`，
症状是 libunistring/perl 之类完全无关的包"随机"编译失败，极难排查。`build.sh` 用
`tmp/build.lock` 挡住这种情况，确认真没别的构建在跑时才加 `--force`。

### 5.4 产物

```
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-squashfs-sysupgrade.itb
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-initramfs-recovery.itb   # 救砖/恢复
```

`bin/targets/airoha/an7581/ponwrt-airoha-an7581.manifest` 里应能看到
`luci-app-airoha-npu - 1.2.0-r2`。

支持并已一起编译的 12 个 AN7581 机型：

```
fiberhome_hg5382a          nokia_xg-040g-md-ubi          znxt_zn504xg-d
fiberhome_hg5585f-ct       nokia_xg-040g-md-ubi-usb-sfp  znxt_zn515xg-d
fiberhome_hg5585f-ct-usb-sfp  nokia_xg-040g-tf-ubi       unionman_ung00a
fiberhome_hg5585f-cu       gemtek_xg2010g
fiberhome_hg5585f-cu-usb-sfp
```

AN7583 目标（`nokia_xg-040g-mf`、`nokia_xg-040g-mf-ubi`）用 `configs/an7583.config`。

> **本机踩过的坑**：如果系统上 `git` 不可用，`base-files` 的版本会变成
> `260923.84021~unknown`，apk 会拒绝（`~` 后面必须是十六进制）。
> 绕过办法是写 `TOPDIR/version`：`printf 'r0-c3b518baec\n' > version`，
> 编完**记得删掉**，否则会一直盖住真实版本号。

---

## 6. 刷机与刷后自检

刷机本身沿用上游流程（[AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) 备份/装 UBI，
[AN758x U-Boot](https://github.com/pbs05/uboot-an758x) 提供引导与 Web 恢复）。
刷完 PonWrt 后通过 U-Boot Web 或 LuCI **网络 → PON → 配置 → PON 板卡数据** 恢复原厂
校准与身份数据。

### 6.1 通用自检

```sh
cat /etc/openwrt_release                      # 看 DISTRIB_REVISION
apk list -I | grep airoha-npu                 # 应见 luci-app-airoha-npu-1.2.0-r2

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
| 面板口序 | UNG00A | 四根线分别插 LAN1..4，`ip -br link` 看 carrier 是否落在 lan1..4（**不是**按 port 顺序） |
| 四个 LAN 灯 | HG5585F-CU | ① `dmesg \| grep -iE 'pinctrl\|gbe-led\|phy?_led'` 不应有 `-EINVAL` / "not supported" 之类报错；② `ls /sys/class/leds/` 应出现 4 个 `mt7530-0:*:green:lan-*`；③ **逐口插线看灯** —— 若类设备在但灯不亮，就是缺 netdev 触发绑定（见 §2.3 的警告），按 §2.1 热修命令补 UCI |
| lan1 冷启动一致性 | HG5585F-CT | `reboot`（热重启）后立刻 `cat /sys/class/net/lan1/carrier`，应看到 `1`；`dmesg \| grep -i "GPY211\|Clause 45"` 不应出现 Generic Clause 45 PHY |
| IPTV 组播 | 任意 | §4 的两条命令 |

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
| 2 | §2.3 的 HG5585F-CU 四个 LAN 灯 | **只做了一半**：PHY LED0 输出被 mux 出来，但 `01_leds` 里还没有 fiberhome 的 case，即没有 netdev 触发绑定。按 §2.1 的机制这很可能导致灯仍不亮 —— 必须上机按 §6.2 确认 |
| 3 | §2.4 的 HG5585F-CT GPY211C | 结论基于复位时序竞态分析，需在真机上做一次热重启核对 |
| 4 | 机型覆盖 | 修复的根因取证与刷机回归以 **ZN504XG-D** 为主力机型（UNG00A 的口序结论有换线实测记录）。其余 11 个机型已一起编译出固件，但未逐个上机验证，按 §6.2 自检即可 |

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

### 8.3 与上游后续提交的关系

上游 `c3b518baec..04986da1e6` 的 5 个提交里有三处和本 fork 的改动**同区域**：

| 上游提交 | 内容 | 与本 fork 的关系 |
|---|---|---|
| `91077e9a6b` | HG5585F 复位键 GPIO 修正 + 补全面板 LED | ⚠️ **同一组引脚的两种方案**：上游把 **GPIO43-46 当普通 GPIO 灯**用（`gpio-leds`，CT 蓝 / CU 绿），并在 `01_leds` 里绑 `blue:lan-1..4`；本 fork 则把**同样这 4 个脚 mux 成 PHY LED0 输出**。两者互斥，合并后会同时存在，必须上机确认哪一种才对 |
| `69cd3e269f` | 把 EN8811H 复位时序改回 `10000/20000us` | **冲突面**：本 fork 保留 `1000000/100000us`（已刷机验证过） |
| `77ad7d0643` | 新增 H3C HM-2004-DU 机型 | **独立**，无重叠 |

实测 `git merge-tree` 合并**无冲突**（文本上），两边的 `01_leds` 改动能并存。
但上面第一行的**语义冲突不会被 git 发现**，所以要合的话：

```sh
git remote add upstream https://github.com/pbs05/ponwrt.git
git fetch upstream master
git merge upstream/master          # 文本上干净
git diff HEAD~1 -- '*reset-*'      # ① 确认 EN8811H 复位时序是否被改成 10000/20000
grep -n 'gpio4[3-6]' \
  target/linux/airoha/dts/an7581-fiberhome-hg5585f-common.dtsi \
  target/linux/airoha/dts/an7581-fiberhome-hg5585f-cu-common.dtsi   # ② 看 GPIO43-46 被谁占
```

**结论：合并上游之前，先用 HG5585F-CU 上机把 GPIO43-46 的归属确认下来**
（PHY LED0 输出 vs 普通 GPIO 灯），否则会出现"pinctrl 说是 PHY 灯、gpio-leds 说是 GPIO 灯"
的互相打架，表现为其中一个静默失效。

---

## 9. 目录导览（本 fork 新增部分）

```
build.sh / build-watch.sh / build-live.sh     编译入口与两种进度观察
package/luci-app-airoha-npu/                  NPU/Frame Engine 面板（1.2.0-r2）
target/linux/airoha/patches-6.18/
    950-npu-expose-fw-version-sysfs.patch     NPU 版本/核数 sysfs
package/base-files/files/                     IPTV 组播 MAC 学习修复（4 个触发点）
docs/luci-app-airoha-npu-port/README.md       移植全过程、根因取证、逐机型核对
docs/iptv-udpxy-omcproxy-guide.md             udpxy + omcproxy 完整指南（已脱敏）
docs/pon-link-watch.sh                        PON 光功率/温度/注册计数器定时光采样
docs/luci-app-airoha-npu-port/tests/          渲染回归测试 + 真机 fixture（MAC 已占位）
```

其他有用的调试脚本：[`docs/pon-link-watch.sh`](docs/pon-link-watch.sh) 周期采样
注册计数器（`deregisters` / `reregisters` / `register_nacks` / `registered_lifetime_ms`）
与光前端温度 —— 这些**只存在于运行内存**里，设备一重启就全没了，掉线那一刻不记录事后只能猜。

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
