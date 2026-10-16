# PonWrt（jzhou404gmail fork）

[English](README.md) | **简体中文**

本仓库是 [pbs05/ponwrt](https://github.com/pbs05/ponwrt) 的个人 fork，用于在
**Airoha AN7581 / AN7583 系列 PON 光猫**上实机调试、并把调出来的修复固化回源码树。

上游 README 与 `README_zh.md` 保持原样未改，本文件只记录**这个 fork 相对上游多出来的东西**：
每一处硬件修复的**现象、根因、证据和验证方法**，以及一套"不破坏增量编译"的编译入口。

> **本 fork 的基线**：上游 `c3b518baec`（`firewall4: include transparent bridge ports in flowtable`），
> 在此之上是本 fork 自己的改动清单（见 §1）。
>
> **2026-10-16 已同步上游 `c3b518baec..a57faf93c6`**（6 个提交：新增 H3C HM-2004-DU 机型、
> HG5585F 复位键与面板 LED 修复、EN8811H 复位时序、FIT/ITS 镜像等）。合并文本上干净，
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
| 3 | `airoha/an7581` | **面板 LAN 灯触发器缺失**（ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A） | 硬件修复 |
| 4 | `airoha/an7581` | **UNG00A 面板口序反转** + 启用 PHY1 LED0 | 硬件修复 |
| 5 | `airoha/an7583` | XG-040G-MF 的 PHY LED 补 `function` / `function-enumerator` | 一致性 |
| 6 | `airoha/an7581` | HG5585F-CU 四个 LAN 灯全灭 —— **已改为随上游 `91077e9a6b` 合并**，本 fork 只留一段防回归注释 | 已并入上游 |
| 7 | `airoha/an7581` | **HG5585F-CT 热重启后 lan1 NO-CARRIER**（GPY211C PHY ID 竞态） | 硬件修复 |
| 8 | `luci-app-airoha-npu` | NPU/Frame Engine 面板移植，**WAN = PON 口** | 新功能 |
| 9 | `base-files` | **IPTV 机顶盒报 2001** 的组播 VLAN MAC 学习修复 | 功能修复 |
| 10 | `docs` | NPU 移植说明、IPTV 组播指南、PON 掉线采样脚本、渲染回归测试 | 文档 |
| 11 | `feeds.conf.default` | 注释形式记录可选的 PassWall feed | 说明 |
| 12 | `airoha/an7581` | **无线默认值（带无线的三款机型统一）**：国家码 CN、5G 160MHz、2.4G/5G 各自 SSID（`ImmortalWrt` / `ImmortalWrt_5G`）、默认 WPA2-PSK 密钥 `12345678` | 默认值修复 |
| 13 | `feed-patches` | **上游 feed 补丁机制**：`feeds/` 不入库，改在上游驱动里的修复以补丁形式存 `feed-patches/`，`build.sh` 编译前幂等套用（§5.2.1） | 工具 |
| 14 | `pon_drivers`（feed 补丁） | **EPON 上 `pon0-online` 永远不亮**（EPON 侧 `service_ready` 无人置 1）→ 改用"LLID 注册完成"作为 service ready | 硬件修复 |
| 15 | `pon_drivers`（feed 补丁） | **新增 `pon0-signal` 触发器**：有光常亮、断纤闪烁，并把 8 个机型的光信号灯改绑到它（§2.7.2） | 功能修复 |
| 16 | `airoha/base-files` | **「上网」灯 = 真实上网状态**：`pon-internet-led` 周期探测 well-known 站点，通就常亮、连续失败即灭；`/etc/init.d` + iface hotplug 拉起（§2.7.3） | 功能修复 |
| 17 | `docs` | `pon-led-diag.sh`：面板灯取证脚本（触发器/亮度/线路状态/service_ready/OAM 认证 + 逐个点亮对面板） | 文档 |
| 18 | `verify-images.sh` | **产物体检闸**（+ `build.sh` 自动调用与内核自愈）：抓"体积翻倍 / 普通内核被 initramfs 内核顶替 / 截断"这类**能编译但不能刷**的产物（§5.5，真实事故复盘） | 工具 |

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

**现象**：CU 面板上四个 LAN 灯全灭，但四个口 link 正常。

**根因**：面板灯挂在 **GPIO43-46**（低有效）上 —— 并行 NAND 占了 GPIO4-7 与 GPIO30-42，
这块板剩下的可用脚就是 GPIO43-46。而早期这块板的设备树里**根本没有这四个 LED 节点**，
没有任何东西去驱动它们，所以灯一直是灭的。

**修复（上游 `91077e9a6b`，作者在真机 CU 上逐脚驱动 GPIO 验证过）**：在
`an7581-fiberhome-hg5585f-common.dtsi` 里把 GPIO43-46 描述成 4 个普通 `gpio-leds`
（`blue:lan-1` .. `blue:lan-4`），并在 `board.d/01_leds` 的 `fiberhome,hg5585f-cu`
case 里给它们绑 netdev 触发。

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

#### 2.7.2 「光信号」灯：有光常亮、断纤闪烁 `[待上机]`

**需求**：光纤插好、光路正常 → 红灯**常亮**；断纤/无光 → 红灯**闪烁**。

**实现**：驱动新增一个触发器 **`pon0-signal`**（`feed-patches/pon_drivers/airoha-xpon/0002-*.patch`）：

| 线路状态 | `pon0-signal`（本 fork 采用） | `pon0-los`（传统语义，仍保留） |
|---|---|---|
| 有光 | **常亮** | 灭 |
| 无光、线路在跑 | **500ms 闪烁** | 500ms 闪烁 |
| 线路没跑（PON 口没起来） | 灭 | 灭 |

并把 8 个机型的设备树从 `pon0-los` 改绑到 `pon0-signal`（HG5585F / HG5382A / ZN504XG-D /
ZN515XG-D / UNG00A / XG-040G-MF / XG-040G-MD / HM-2004-DU / XG2010G），这样各机型行为一致。

> ⚠️ **这是本 fork 故意偏离行业惯例的一处**：常规光猫"光信号"灯是**灭 = 正常**、红闪 = 断纤。
> 这里改成"常亮 = 有光"，好处是面板上"光路好的"这件事有正指示（否则正常时这盏灯全黑，
> 看起来像坏了一样）。
> **想回传统语义**：把设备树里那行改回 `linux,default-trigger = "pon0-los";` 即可
> （8 处，`grep -rn pon0-signal target/linux/airoha/dts/`）。
> 注意判据是"**有没有光**"而不是"注册没注册"：光有问题（灯闪）和注册有问题（第 2 个灯
> 在闪）是两件事，分开看才好定位。

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

#### 2.7.4 上机自检

```sh
sh docs/pon-led-diag.sh                # 取证：LED/触发器/亮度、线路状态、service_ready、OAM 认证、代理
sh docs/pon-led-diag.sh walk 4         # 逐个点亮，确认"哪个 sysfs 灯 = 面板哪个位置、什么颜色"

cat /sys/class/leds/red:wan/trigger           # 期望 [pon0-signal]
cat /sys/class/leds/blue:wan/trigger          # 期望 [pon0-registration]
cat /sys/class/leds/blue:wan-online/trigger   # 期望 [none]（被用户态接管）

pon-internet-led status                # 配置 + 上次探测结果（/var/run/pon-internet-led.state）
pon-internet-led once                  # 立刻探一次：online/offline 一目了然
logread | grep pon-internet-led        # 每次 online/offline 切换都有日志

# 行为验证
拔光纤   → 第 3 个灯红闪；第 2 个灯灭；第 4 个灯 30 秒内灭
插光纤   → 第 3 个灯常亮；注册后第 2 个灯绿灯常亮；能上网后第 4 个灯绿灯常亮
ifdown wan → 第 4 个灯立刻灭；ifup wan → 3 秒后补探，通则重新点亮
```

#### 2.7.5 证据

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
#   pon0-signal       : 有光 → 常亮；线路在跑但没光 → 500ms 慢闪（本 fork 采用）
#   pon0-online       : 线路在跑 + 有光 + service_ready（EPON 上按注册判据）
```

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
    ├── 0001-*.patch                          # EPON 上 pon0-online 不再死灯（§2.7.3）
    └── 0002-*.patch                          # 新增 pon0-signal 触发器（§2.7.2）
```

* `build.sh` 在 **make 之前**自动调用 `feed-patches/apply.sh`：已套过的跳过，没套的套上，
  套不上（上游改过同一段）会明确报错而不是默默继续。
* 一个 feed 里叠着多个补丁时，后面的补丁会改动前面补丁的上下文行，所以"已套用"的判定
  用 `git apply --check --reverse`（必要时缩小上下文 `-C1`），不是简单比字符串。
* 刚套上某个补丁时，脚本会同时删掉该包在 `build_dir/` 里的旧拷贝 —— OpenWrt 只在
  prepare 阶段把本地源码**拷贝**进去，源码改了不删旧拷贝，就会出现"改了源码但编译用的
  还是旧文件"。
* 手动查看/套用：`./feed-patches/apply.sh --check` / `./feed-patches/apply.sh`。

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
编译前会先跑一遍 `feed-patches/apply.sh`（§5.2.1），这一步是幂等的，没补丁要套时
什么都不做。

`--config=<档>` 会先自动备份现有 `.config`，并且**带掉包保护**：
如果新配置的包数量比原来少 20% 以上就中止并自动还原。

**并发保护**：同一棵树里并行跑两个 `make` 会同时写 `build_dir/` 与 `staging_dir/`，
症状是 libunistring/perl 之类完全无关的包"随机"编译失败，极难排查。`build.sh` 用
`tmp/build.lock` 挡住这种情况，确认真没别的构建在跑时才加 `--force`。

**收尾汇总**：编译结束时会打印**开始时间 / 结束时间 / 总共耗时**（成功、失败、
Ctrl-C 中断三种情况都会打；`SUMMARY_DONE` 去重，中断时不会既报"被中断"又报"失败"），
同一段也追加进 `tmp/build.log` 末尾，方便事后对时间。

**每个包的日志 + 失败自愈**：`build.sh` 默认开 `BUILD_LOG=1`，每个包的完整输出落在
`logs/<包>/compile.txt`（整棵树约 2.5 MB，已在 `.gitignore` 里）。这样任何失败都有明细可查 ——
`tmp/build.log` 里通常只有一行 `ERROR: <包> failed to build.`，**真正的报错只在这份日志里**。

> 🐛 **已知的时序性失败（"静默被打断"）**：某个包的子 make 被信号打断，于是
> `tmp/build.log` 里只有那一行 ERROR、而 `logs/<包>/compile.txt` 是**空文件**（连
> `time.pl` 的 `time: <包>/compile#...` 都没有）—— 这不是编译报错，重编一次就好。
> `build.sh` 会按这个判据自动处理：① 单独 `make <包>/compile` 把该包编好；
> ② 重新跑整个构建（最多 2 轮）；③ 打印说明，绝不静默重试。
> 判据"`logs/<包>/compile.txt` 为空"**不会误伤真报错** —— 真报错时该文件非空，脚本直接失败退出。
> 实测（桩 make 单测）：正常 1 次通过；静默失败 → 自动重编 + 第 2 次尝试通过；真报错 → 立即失败并打印日志末尾。
>
> 排查这类问题时，先看三处：`logs/<包>/compile.txt`（为空 = 被打断）、
> `dmesg | grep -i oom`（内存击杀，需要 root）、以及**同一棵树里有没有第二个 `make` 在跑**
> （`build.sh` 的锁挡不住手敲的 `make`）。

### 5.4 产物

```
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-squashfs-sysupgrade.itb
bin/targets/airoha/an7581/ponwrt-airoha-an7581-<机型>-initramfs-recovery.itb   # 救砖/恢复
```

`bin/targets/airoha/an7581/ponwrt-airoha-an7581.manifest` 里应能看到
`luci-app-airoha-npu - 1.2.0-r3`。

支持并已一起编译的 12 个 AN7581 机型：

```
fiberhome_hg5382a          nokia_xg-040g-md-ubi          znxt_zn504xg-d
fiberhome_hg5585f-ct       nokia_xg-040g-md-ubi-usb-sfp  znxt_zn515xg-d
fiberhome_hg5585f-ct-usb-sfp  nokia_xg-040g-tf-ubi       unionman_ung00a
fiberhome_hg5585f-cu       gemtek_xg2010g
fiberhome_hg5585f-cu-usb-sfp
```

> 上游 2026-10-16 之后又多了一个 AN7581 机型 **`h3c_hm2004-du`**（H3C HM-2004-DU），
> `configs/an7581.config` 里**没有选**它 —— 想一起编就在配置里加
> `CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_h3c_hm2004-du=y`。

AN7583 目标（`nokia_xg-040g-mf`、`nokia_xg-040g-mf-ubi`）用 `configs/an7583.config`。

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

**防线**：`verify-images.sh`（+ `docs/verify-fit.py`）**每次构建后自动跑**，任何一条不过就让
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
`build.sh` 会自动清掉 `build_dir/target-*/<board>_<subtarget>` 并重编一次 ——
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
| 面板口序 | UNG00A | 四根线分别插 LAN1..4，`ip -br link` 看 carrier 是否落在 lan1..4（**不是**按 port 顺序） |
| 四个 LAN 灯 | HG5585F-CU | ① `ls /sys/class/leds/` 应出现 4 个 `blue:lan-*`（**不是** `mt7530-0:*:green:lan-*`，那是已撤掉的 PHY LED0 方案）；② `dmesg \| grep -iE 'pinctrl\|gbe-led'` 不应有 `-EINVAL` / "not supported" 报错；③ **逐口插线看灯**；④ `dmesg \| grep -i 'leds-gpio'` 不应报无法申请 GPIO43-46 |
| lan1 冷启动一致性 | HG5585F-CT | `reboot`（热重启）后立刻 `cat /sys/class/net/lan1/carrier`，应看到 `1`；`dmesg \| grep -i "GPY211\|Clause 45"` 不应出现 Generic Clause 45 PHY |
| 无线默认值（CN / 160MHz / SSID / WPA2-PSK） | HG5585F-CT / HG5585F-CU / ZN515XG-D | `jsonfilter -i /etc/board.json -e '@.wlan.defaults'` 应见 `country:"CN"`、`widths.5g:"160"`、`ssids.2g/5g`；`uci show wireless \| grep -E "country\|htmode"` 应见 `country='CN'` 与 `htmode='HE160'`；`uci show wireless \| grep -E "ssid\|encryption\|key"` 应见 2.4G=`ImmortalWrt` / 5G=`ImmortalWrt_5G`、两侧 `encryption='psk2'` 且 `key='12345678'`；`iw dev phy1-ap0 info \| grep width` 应见 `width: 160 MHz`；手机能搜到**两个** SSID，用 `12345678` 能连上（随后自己去 LuCI 改密码） |
| IPTV 组播 | 任意 | §4 的两条命令 |
| 「上网」灯（第 4 个，真实上网探测） | 所有 airoha 机型 | ① `pon-internet-led status`（配置 + 上次结果）；② `pon-internet-led once` 应为 `online (via …)`；③ `cat /sys/class/leds/*:wan-online/trigger` 期望 `[none]`（用户态接管）；④ 拔网线/`ifdown wan` → 灯立刻灭，`ifup wan` → 3 秒后补探并重新点亮；⑤ `logread \| grep pon-internet-led` 有 online/offline 切换日志 |
| 「光信号」灯（第 3 个） | 所有 airoha 机型 | ① `cat /sys/class/leds/*:wan/trigger` → `[pon0-signal]`（红的那盏）；② 插着光纤 → **红灯常亮**；拔光纤 → **红灯 500ms 闪**；③ `sh docs/pon-led-diag.sh walk 4` 确认该位置就是 GPIO16 那盏红灯。想回到"灭=正常"的老语义：把设备树那行改回 `pon0-los` |
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
| 2 | §2.3 的 HG5585F-CU 四个 LAN 灯 | 已改用上游 `91077e9a6b` 的方案（GPIO43-46 gpio-leds + `01_leds` netdev 触发），该方案由上游作者在真机 CU 上验证。本 fork 原先的 PHY LED0 mux 路线已撤销；仍需按 §6.2 上机确认灯确实亮 |
| 3 | §2.4 的 HG5585F-CT GPY211C | 结论基于复位时序竞态分析，需在真机上做一次热重启核对 |
| 4 | 机型覆盖 | 修复的根因取证与刷机回归以 **ZN504XG-D** 为主力机型（UNG00A 的口序结论有换线实测记录）。其余 11 个机型已一起编译出固件，但未逐个上机验证，按 §6.2 自检即可 |
| 5 | §2.7.3 的「上网」灯（主动探测） | 逻辑写好并编译进镜像，**等实机确认**：能上网 → 常亮，断网/拔纤 → 30 秒内灭；`pon-internet-led once` 可手动验证一次探测。若你常用的站点被列在探测表之外，改 `/etc/config/pon-led` 的 `urls` 即可 |
| 6 | §2.7.2 的「光信号」灯（有光常亮） | 驱动新增 `pon0-signal` 触发器 + 8 个机型改绑，**等实机确认**：插纤常亮、拔纤闪。这是**故意偏离行业惯例**的一处（常规是"灭=正常"），想回去见 §2.7.2 的改法。另外这盏灯硬件上只有红光，不存在"正常亮绿灯" |
| 7 | §2.7 的 feed 驱动补丁（两个） | 改动在 `feed-patches/pon_drivers/airoha-xpon/`，套用/回退见 §5.2.1；`build.sh` 会自动套。`./feed-patches/apply.sh --check` 可随时看状态 |

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
build.sh / build-watch.sh / build-live.sh     编译入口与两种进度观察
verify-images.sh                              刷机前产物体检（FIT 内部结构/内核 cpio/体积）
docs/verify-fit.py                            verify-images.sh 的 FIT 解析内核部分
package/luci-app-airoha-npu/                  NPU/Frame Engine 面板（1.2.0-r3）
target/linux/airoha/patches-6.18/
    950-npu-expose-fw-version-sysfs.patch     NPU 版本/核数 sysfs
package/base-files/files/                     IPTV 组播 MAC 学习修复（4 个触发点）
package/base-files/files/lib/functions/
    uci-defaults.sh                           + ucidef_set_wireless_width()
package/network/config/wifi-scripts/files/lib/wifi/
    mac80211.uc                               默认带宽支持板级 widths 声明
target/linux/airoha/an7581/base-files/etc/board.d/
    03_wireless                               带无线机型统一默认值：国家码 CN、5G 160MHz、
                                              双 SSID（ImmortalWrt / ImmortalWrt_5G）、
                                              默认 WPA2-PSK（密钥 12345678）
feed-patches/apply.sh                         上游 feed 补丁（幂等）套用脚本，build.sh 自动调
feed-patches/pon_drivers/airoha-xpon/
    0001-*.patch                               EPON 上 pon0-online 触发器不再死灯
    0002-*.patch                               新增 pon0-signal 触发器（有光常亮/断纤闪）
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
