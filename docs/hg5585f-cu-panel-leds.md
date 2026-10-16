# HG5585F-CU（AN7581）面板 LED 全灭排查记录

> 机器：FiberHome HG5585F CU，`fiberhome,hg5585f-cu`，在线运行（`192.168.32.254`，也正是编译机的默认网关）
> 镜像：PonWrt `r41558+37-a57faf93c6`，内核 `6.18.52`（SMP Fri Oct 16 04:07:13 2026；squashfs 产物时间 10-16 12:30）
> 排查方式：活体取证（SSH 直连）＋ 设备树 / `board.d` / 内核源码静态核对 ＋ 沙箱复盘（沙箱跑迁移脚本，**不碰实机配置**）
> 关联提交：`ce0b1b7acb`、`430f689c6b`、`e191bd94e6`

---

## 0. 结论速览

| # | 问题 | 根因层次 | 修复 | 状态 |
|---|---|---|---|---|
| 1 | 四个 LAN 灯全灭（口 link 正常） | **持久化配置过期** —— `/etc/config/system` 里的 `config led` 指向本镜像已不存在的类设备，触发器一个都没绑上 | 迁移脚本 `99-hg5585f-cu-leds`（改名 + 补齐） | ✅ 实机确认 |
| 2 | 两个 USB 灯从来没亮过（**全新安装也一样**） | `DEVICE_PACKAGES` 漏了 `kmod-usb-ledtrig-usbport`，`usbport` 触发器不存在 | `image/an7581.mk` 补一行 | ✅ 已修（待刷机生效） |
| 3 | `dmesg` 每次开机 4 条 `Failed to setup PHY LED pinctrl` | 上游 `mtk-ge-soc.c` 对可选功能用 `dev_err`；CU/CT 故意不定义 `gbe-led` 状态 | **未改**（正常现象，已写进自检清单避免误判） | ℹ️ 仅记录 |

**一句话结论**：设备树、`01_leds`、pinctrl、GPIO 硬件**全都是对的**；坏的是这台机器
`/etc/config/system` 里那份**保留配置升级带过来的旧 LED 配置**，而 `board.d` 在
"保留配置"的升级路径上永远不会重跑 —— 所以灯灭了，且没有任何一条报错。

---

## 一、问题

### 1.1 原始报告

> 现在在线的 5855F CU 的 LED 和 CT 版不一样，带物理 LAN1-LAN4 的，之前修理好了，
> 显示都是正常的，现在 IP 192.168.32.254，LAN1-LAN3 都插了网线，均没有显示。

三个关键信息：① 这是**带 4 个物理 GE 口灯**的 CU 变体；② **之前是好的**（修过）；
③ 现在 LAN1–LAN3 插了线，四个灯**一个都不亮**。

### 1.2 实机现象 `[实测]`

```
# ls /sys/class/leds/
blue:lan-1  blue:lan-2  blue:lan-3  blue:lan-4        ← 四个类设备都在
blue:phone  blue:power  blue:usb-1  blue:usb-2
blue:wan  blue:wan-online  blue:wlan  red:wan
mt76-phy0  mt76-phy1

# for i in 1 2 3 4; do echo "lan$i trig=$(cat /sys/class/leds/blue:lan-$i/trigger|grep -o '\[.*\]') br=$(cat /sys/class/leds/blue:lan-$i/brightness)"; done
lan1 trig=[none] br=0
lan2 trig=[none] br=0
lan3 trig=[none] br=0
lan4 trig=[none] br=0                                 ← 全是 none

# ip -br link | grep -E 'lan[1-4]'
lan1@eth0  UP             68:de:ce:71:fb:60 <BROADCAST,MULTICAST,UP,LOWER_UP>   ← carrier=1
lan2@eth0  LOWERLAYERDOWN ... <NO-CARRIER,BROADCAST,MULTICAST,UP>               ← carrier=0
lan3@eth0  UP             ... <BROADCAST,MULTICAST,UP,LOWER_UP>                 ← carrier=1
lan4@eth0  LOWERLAYERDOWN ... <NO-CARRIER,BROADCAST,MULTICAST,UP>               ← carrier=0
```

**类设备齐全、口也 link 正常，但四个触发器全是 `[none]`** —— 这就是"灯不亮"的直接原因：
`leds-gpio` 把灯注册好了，但**没有任何东西去驱动它们**，默认 `brightness=0`（低有效 = 灭）。

### 1.3 期望

`01_leds` 给 `fiberhome,hg5585f-cu` 描述的是四个 `netdev` 触发器，绑到各自的 netdev 上：

| 面板 | 类设备 | GPIO | 期望的 UCI 触发 |
|---|---|---|---|
| LAN1 | `blue:lan-1` | GPIO43 | `netdev` → `lan1`，`link tx rx` |
| LAN2 | `blue:lan-2` | GPIO44 | `netdev` → `lan2`，`link tx rx` |
| LAN3 | `blue:lan-3` | GPIO45 | `netdev` → `lan3`，`link tx rx` |
| LAN4 | `blue:lan-4` | GPIO46 | `netdev` → `lan4`，`link tx rx` |

---

## 二、分析

### 2.1 先排除硬件 —— 这一步决定了后面往哪个方向修 `[实测]`

灯不亮的可能原因有一堆（灯珠坏 / 设备树没配 / pinctrl 被 mux 走 / GPIO 被别的驱动占了 /
触发器没绑），**先用一次可控实验把它们一次分开**：把四个脚直接拉低（低有效即点亮）。

```
# for i in 1 2 3 4; do echo none > /sys/class/leds/blue:lan-$i/trigger
#                      echo 1    > /sys/class/leds/blue:lan-$i/brightness; done

# grep -E 'gpio-4[3-6]' /sys/kernel/debug/gpio
 gpio-43  (                    |blue:lan-1          ) out lo ACTIVE LOW
 gpio-44  (                    |blue:lan-2          ) out lo ACTIVE LOW
 gpio-45  (                    |blue:lan-3          ) out lo ACTIVE LOW
 gpio-46  (                    |blue:lan-4          ) out lo ACTIVE LOW
```

**结果：面板上四个灯全亮**（已由现场确认）。同时旁证两条：

```
# cat /sys/kernel/debug/pinctrl/*/pinmux-pins | grep -E 'pin 5[6-9]'
pin 56 (gpio43): GPIO 1fbf0200.system-controller:pinctrl:555
pin 57 (gpio44): GPIO 1fbf0200.system-controller:pinctrl:556
pin 58 (gpio45): GPIO 1fbf0200.system-controller:pinctrl:557
pin 59 (gpio46): GPIO 1fbf0200.system-controller:pinctrl:558
```

pin 56–59（按 `gpio-ranges = <&en7581_pinctrl 0 13 50>` 的偏移即 GPIO43–46）当前功能是
**`GPIO`**，而且已经被 `blue:lan-*` 这几个 `leds-gpio` 类设备 request 走了。

**结论**：面板灯确实挂在 GPIO43–46（低有效）上，pinmux 通、GPIO 通、`leds-gpio` 也通。
**硬件、设备树、pinctrl 全部无罪，问题在"没人去驱动它们"。**

> 这一步的价值在于**排除法一次到位**：如果不是先做这个测试，很容易顺着
> `dmesg` 里那 4 条 `Failed to setup PHY LED pinctrl` 去"修 pinctrl"，
> 或者怀疑是已经撤掉的 PHY LED0 那条路 —— 两条都是错的方向（见 §2.5、§6.1）。

### 2.2 真根因：UCI 指向了本镜像里**已经不存在**的类设备 `[实测]`

```
# uci show system | grep -A5 led_lan
system.led_lan2=led
system.led_lan2.name='lan2'
system.led_lan2.sysfs='mt7530-0:0a:green:lan-2'      ← 这台机器上根本没有这个类设备
system.led_lan2.trigger='netdev'
system.led_lan2.mode='link tx rx'
system.led_lan2.dev='lan2'
（led_lan3 → mt7530-0:0b:green:lan-3，led_lan4 → mt7530-0:0c:green:lan-4，同样不存在）
```

三处致命细节：

1. **名字来自本 fork 已经撤掉的 PHY LED0 路线**。上一版 CU 设备树（`60667288e6` 之前）
   把 GPIO43–46 mux 成 `phy1_led0..phy4_led0` 并启用 `gsw_phyN_led0` 类设备，它们当时叫
   `mt7530-0:09/0a/0b/0c:green:lan-1..4`。10-16 同步换成上游的 gpio-leds 方案后，
   **这些类设备不再存在**。
2. **`/etc/init.d/led` 对不存在的 sysfs 只打一条日志、不报错**，于是**静默失败** ——
   面板表现和"灯坏 / 设备树没配"完全一样，是最难查的一类。
3. 配置里**只有 lan2/3/4，没有 lan1**，也**没有任何 `led_usb*`** —— 说明它是
   手工写上去的三段（而不是 `board.d` 生成的），这一条在 §2.3 会用上。

### 2.3 为什么 `board.d` 没有自己修好（本次最关键的一条）

`board.d/01_leds` 里 `fiberhome,hg5585f-cu` 的 case **一直是对的**，机器上
`/etc/board.json`（每次升级都会重新生成）里**也已经是正确的 `blue:lan-*`**：

```
# awk '/"led"/,0' /etc/board.json
	"led": {
		"lan1": {
			"name": "lan1",
			"sysfs": "blue:lan-1",        ← 与 UCI 里那份（§2.2）不一致
			"type": "netdev",
			"device": "lan1",
			"mode": "link tx rx"
		},
		…（lan2/lan3/lan4 同构）
		"usb1": { "name": "USB 1", "sysfs": "blue:usb-1", "type": "usbport",
		          "ports": [ "usb3-port1", "usb4-port1" ] },
		"usb2": { "name": "USB 2", "sysfs": "blue:usb-2", "type": "usbport",
		          "ports": [ "usb1-port1", "usb2-port1" ] }
```

**`board.json` 对、UCI 错** —— 这个组合就是本问题的指纹。链路是这样断的：

| 环节 | 行为 | 依据 |
|---|---|---|
| `board.d/01_leds` | 只写 `/etc/board.json`，**不写** `/etc/config/*` | `ucidef_set_led_netdev` → `board_config_flush` |
| `/bin/config_generate` | 把 board.json 落成 UCI 的**整段**（含 `generate_led`）包在 `if [ ! -s /etc/config/system ]; then … fi` 里 ⇒ **system 配置非空就整段跳过** | `package/base-files/files/bin/config_generate` 末尾 |
| `do_config_generate` | 守卫是 `[ -f /etc/board.json ] \|\|` ⇒ board.json 一没就重跑 | `lib/preinit/82_config_generate` |
| keep 清单 | `/lib/upgrade/keep.d/base-files` 只列 `/etc/config/`、`/etc/config/network`、`/etc/config/system`、`/etc/profile.d` ⇒ **`/etc/config/system` 保留，`/etc/board.json` 不保留** | 实机 `cat /lib/upgrade/keep.d/base-files` |

于是"保留配置"升级 = **board.json 每次重建（内容正确），system 配置原封不动（内容陈旧）**，
两边永远对不上。实机时间戳也对得上：

```
# ls -l /overlay/upper/etc/config/system      ← 保留配置带过来的
-rw------- 1 root root 934 Oct  7 17:13 /overlay/upper/etc/config/system
# ls -l /etc/board.json                        ← 本次刷机（10-16 12:07）后重建的
-rw-r--r-- 1 root root 2383 Oct 16 12:10 /etc/board.json
```

> 10-07 17:13 这个时间点、以及"只有 lan2/3/4 没有 lan1"这个形状，**推断**是当时
> 为了适配 10-07 那版 PHY LED0 路线，照 `01_leds` 里 Nokia case（恰好也是 lan2/3/4 →
> 0a/0b/0c）手写上去的。这一条是推断，不是实测 —— 但不影响结论：**配置过期**是事实。

### 2.4 影响面：不止这一台机器

同步之前的 `01_leds` **根本没有 CU 的 case**：

```
$ git show 31e830faff:target/linux/airoha/an7581/base-files/etc/board.d/01_leds | grep hg5585f-cu
（空）
```

所以**任何"保留配置"升级到本次镜像的 CU**，`/etc/config/system` 里连 `led_lan*` 段都
没有 —— 和这台机器一样，四个触发器绑不上、四个灯全灭。**只有"刷机时清配置"的全新安装**
才会自动带上这 4 段（外加 2 段 USB）。

> 这也解释了 §1.1 里"之前修理好了，显示都是正常的"：10-07 那版走的是 **PHY LED0 路线**，
> 当时的类设备就叫 `mt7530-0:09/0a/0b/0c:green:lan-1..4`，而当时那份配置**正好指着这些
> 名字**（§2.2）—— 两边是**匹配**的，所以触发器绑得上、灯能亮。同步把类设备换成
> `blue:lan-*` 之后，那几条配置就变成了**指空**，触发器一个都绑不上、四个灯全灭。
>
> （严格说：当时 `led_lan1` 也是缺的，所以 lan1 到底靠触发器还是靠 PHY 的硬件 LED 默认规则
> 点亮，**没有留下记录**。这一点不影响结论 —— 无论哪种，同步之后都需要触发器绑定，
> 而绑定是断的。）

### 2.5 顺带发现：两个 USB 灯从来没亮过，**全新安装也一样** `[实测]`

```
# for l in blue:usb-1 blue:usb-2; do echo "$l: trig=$(cat /sys/class/leds/$l/trigger|grep -o '\[.*\]')"; done
blue:usb-1: trig=[none]
blue:usb-2: trig=[none]

# cat /sys/class/leds/blue:usb-1/trigger
[none] timer heartbeat default-on netdev pon0-registration pon0-los pon0-online
       phy0rx phy0tx phy0assoc phy0radio phy0tpt phy1rx phy1tx phy1assoc phy1radio phy1tpt
                                                       ↑ 列表里根本没有 usbport
# ls /lib/modules/*/ | grep -i ledtrig      → 空（模块文件不存在）
# grep -rn usbport /etc/modules.d/          → 空（也没有 autoload 条目）
```

设备树里有 `led-usb1`/`led-usb2`（GPIO6 / GPIO8，低有效，**没有 `default-trigger`**），
`01_leds` 给 CU 绑 `usb1`+`usb2`、给 CT 绑 `usb1`，触发器都写 **`usbport`** —— 但
`Device/fiberhome_hg5585f-common`（`target/linux/airoha/image/an7581.mk`）里有
`kmod-leds-gpio` 却**没有 `kmod-usb-ledtrig-usbport`**。

这是个**与升级路径无关的独立缺陷**：触发器不存在 ⇒ 这两个 LED 永远绑不上，
**全新安装也照灭**。

---

## 三、修复

### 3.1 迁移脚本：`99-hg5585f-cu-leds`（对应问题 1）

新增 `target/linux/airoha/an7581/base-files/etc/uci-defaults/99-hg5585f-cu-leds`。
选 uci-defaults 是因为**它每次刷机后的首次启动都会重跑**（而 `board.d` 只在
`/etc/board.json` 不存在时跑），正是补这条断链的位置。

脚本分两半，对应 §2.4 的两种到达路径：

1. **改名**（陈旧 PHY LED0 段）：直接用**上游自己的机制** `migrate_leds()`
   （`/lib/functions/migrations.sh`）—— 上游在 ath79 / ramips / ipq40xx / apm821xx /
   lantiq / tegra 这些 target 下共有 **15 处** `*_led_migration` 脚本，用的就是它。
   它把那 4 个老名字 `sed` 成 `blue:lan-N`。

   > **为什么是改名而不是"删掉重建"**：`migrate_led_sysfs()` 只改 `sysfs` 一个选项，
   > 用户手改过的 `trigger` / `mode`、或加过的自定义 `option` **原样保留**。
   > 第一版脚本是删了重建，会把这些一起丢掉 —— 这是本次重构的主要原因之一。

2. **补齐**：给"还没有任何段指认"的类设备补上触发。这一半 `migrate_leds` 帮不上忙
   （它只会给**已存在**的段改名），而同步前的 CU 恰恰一个段都没有。

补的是 `01_leds` 给这块板描述的**全部 6 个**（LAN1–4 + USB1–2），规则就是
"让 UCI 与全新安装一致"：

```
led_lan1 blue:lan-1 netdev  lan1
led_lan2 blue:lan-2 netdev  lan2
led_lan3 blue:lan-3 netdev  lan3
led_lan4 blue:lan-4 netdev  lan4
led_usb1 blue:usb-1 usbport usb3-port1 usb4-port1
led_usb2 blue:usb-2 usbport usb1-port1 usb2-port1
```

收窄与幂等（刻意加的约束，避免迁移脚本变成"配置文件粉碎机"）：

* **只改那 4 个已知的作废旧名字**，其它段即使类设备不存在也一律不动（那可能是用户自己配的）；
* **只补"类设备存在且没有任何段指认"的**，已有段一律不改；
* 段名被占用时退回 `led_lanN_cu`，**绝不覆盖**用户自己的同名段；
* 全新安装时 6 段都在 ⇒ 脚本是纯空操作。

### 3.2 补 `kmod-usb-ledtrig-usbport`（对应问题 2）

`target/linux/airoha/image/an7581.mk` 的 `Device/fiberhome_hg5585f-common` 增加：

```make
  # kmod-usb-ledtrig-usbport is not optional: the CU binds its two panel USB
  # LEDs and the CT its one (board.d/01_leds, trigger "usbport"), and without
  # the module that trigger never appears, so those jacks stay dark.
  DEVICE_PACKAGES := kmod-gpio-button-hotplug kmod-leds-gpio kmod-usb3 \
    kmod-usb-ledtrig-usbport \
    kmod-airoha-paged-bosa …
```

这不是"加功能"，而是**补漏**：内核侧 `CONFIG_USB_LEDS_TRIGGER_USBPORT=m` 早就编好了，
`bin/targets/airoha/an7581/packages/kmod-usb-ledtrig-usbport-6.18.52-r1.apk` 也早就躺在
产物目录里，只有设备包清单没列它（同一个 target 里别的机型都列了）。

> 副作用：`usbport` 触发器消失时，`/etc/init.d/led` 会为这两段打一条"触发器不存在"的
> 日志 —— 这也是为什么 §3.1 的迁移要**在补了 kmod 之后**才有意义；只补 LAN 段、
> 不管 USB 段，等于把同一个坑再踩一遍。

### 3.3 文档侧

* `README.zh-CN.md` 新增 **§2.3.1**（保留配置升级后灯又灭：现象/排除/根因/影响面/修复/自检）
  与 **§2.3.2**（USB 灯与缺失的 kmod）；
* **纠正两处会误导后来人的表述**：
  * 10-16 那条"已上机确认：CU 四个 LAN 灯全部正常 / 无需再处理"—— 结论不成立（见 §6.1）；
  * 自检清单把 4 条 `Failed to setup PHY LED pinctrl` 当异常 —— 在 CU/CT 上是**正常**的（见 §6.1）；
* §6.2 自检行扩到 **6 个绑定**，并加上"`usbport` 是否在 `trigger` 列表里"这一条。

---

## 四、处理

### 4.1 现场处置（这台机器，已执行并验证）

按 §2.2 的两步走：先删掉 3 段指向作废类设备的配置，再按 `01_leds` 补 4 段。

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

**为什么这次手工修是"永久"的**：修的是 `/etc/config/system`，它在 `/etc/config/` 下、
属于 sysupgrade 的 keep 清单，`uci commit` 后已落盘；`/etc/rc.d/S96led` 每次启动都会按它
重新绑定。**所以这台机器不刷机、仅重启也不会再灭。**

> 现场**没有**动 USB 段：`usbport` 触发器此刻还不存在（§2.5），现在加只会多一条报错。
> 下一次刷入带 §3.2 的镜像时，§3.1 的迁移会把缺失的两段一并补上。

### 4.2 上线步骤（给其他/以后的机器）

```sh
./build.sh                     # 用 master 编译（本 fork 只有一条主线）
# 刷机时保留配置即可（sysupgrade 默认保留）
```

刷完首次启动时 uci-defaults 自动跑一次迁移，然后自删。**刷机要"保留配置"**才需要它；
反过来，如果哪天从**旧配置备份**恢复，迁移会在下次启动再修一遍 —— 这正是它的用途。

### 4.3 撤销方式

* 迁移脚本：`rm /etc/uci-defaults/99-hg5585f-cu-leds`（刷机前删它即可不执行）；
* 现场手工修：`uci -q delete system.led_lan1..4 && uci commit system && /etc/init.d/led restart`
  （删掉 4 段就回到"灯不亮"的原状，可逆、无副作用）；
* kmod：把 `image/an7581.mk` 里那一行去掉即可（只是两个 USB 灯回到不亮）。

---

## 五、测试和结果

### 5.1 硬件判定测试（§2.1）

| 测试 | 期望 | 结果 |
|---|---|---|
| 四个 GPIO 强制拉低 | 四个灯全亮 | ✅ 现场确认全亮 |
| `/sys/kernel/debug/pinctrl/*/pinmux-pins` | pin 56–59 = `GPIO` | ✅ |
| `/sys/kernel/debug/gpio` | gpio-43–46 = `out lo ACTIVE LOW` | ✅ |
| 判定 | 硬件/DT/pinctrl 无罪 | ✅ 故障锁定在配置层 |

### 5.2 迁移脚本五条路径（沙箱复盘，**不碰实机配置**）

用 `UCI_CONFIG_DIR=<沙箱目录>` 重定向 `config_load` 的读取（`/lib/config/uci.sh` 里
`uci_load()` 用的就是这个变量），再用一个 `uci -c <沙箱目录>` 的包装脚本接管写入，
于是可以拿**真实的 `/etc/config/system` 内容**在真机上跑真脚本，而不动线上配置。

| 路径 | 构造 | 期望 | 结果 |
|---|---|---|---|
| 陈旧配置（旧名 + 用户改过的 `mode`/自定义 option） | `led_lan2/3/4` → `mt7530-0:*`，其中 lan2 带 `mode 'link'` 和 `option custom` | 3 段改名且**选项原样保留** + 补 3 段（lan1/usb1/usb2） | ✅ `blue:lan-2` + `mode 'link'` + `custom` 都在 |
| 全新安装（6 段俱全） | 按 `board.d` 会生成的完整 6 段 | 一字不改 | ✅ md5 不变 |
| 同步前的旧安装（一个 led 段都没有） | 只有 `config system` | 补 6 段 | ✅ 6 段，与 `board.d` 逐字段一致 |
| 再跑一次 | —— | 一字不改 | ✅ md5 不变 |
| 段名被用户占用 | `led_lan1` 已被指向别的类设备 | 退回 `led_lan1_cu`，用户段不动 | ✅ 用户段保留 |

### 5.3 实机结果 `[实测]`

```
# for i in 1 2 3 4; do echo "lan$i: trig=$(cat /sys/class/leds/blue:lan-$i/trigger|grep -o '\[.*\]') dev=$(cat /sys/class/leds/blue:lan-$i/device_name) carrier=$(cat /sys/class/net/lan$i/carrier)"; done
lan1: trig=[netdev] dev=lan1 carrier=1
lan2: trig=[netdev] dev=lan2 carrier=0
lan3: trig=[netdev] dev=lan3 carrier=1
lan4: trig=[netdev] dev=lan4 carrier=0

# uci changes     → 空（配置已落盘）
```

**面板结果（现场确认）：LAN1 亮、LAN3 亮、LAN2 灭、LAN4 灭** ——

* 与内核报的 carrier **一一对应**；
* **LAN2 插着线却是 NO-CARRIER 是对的**：对端 IPTV 机顶盒当时**没开机**（现场确认），
  物理层没连上，灯不该亮。**这不是故障。**

### 5.4 一个容易误判的"灯在闪" `[实测]`

排查中一度看到 `lan1` 的 `brightness=0` 而 `carrier=1`，疑似"绑上了却不亮"。
采样 40 次后真相清楚了：

```
# for i in $(seq 40); do printf "%s%s " "$(cat .../blue:lan-1/brightness)" "$(cat .../blue:lan-3/brightness)"; sleep 0.1; done
01 01 11 11 11 11 11 11 01 01 ...
（每对 = lan1 lan3）

# cat /sys/class/net/lan{1,3}/statistics/rx_packets
lan1 rx=279963 tx=554833      ← 跑着编译机自己的 SSH 流量
lan3 rx=861    tx=2901        ← 空闲
```

`mode "link tx rx"` 下，netdev 触发器在有流量时会翻转亮度
（`netdev_trig_work()` 里 `led_blink_set_oneshot(..., invert)`），所以 **`brightness`
单次采样看到的 0 是"流量闪烁"，不是"没绑上"**。判断"灯亮不亮"要看 `carrier` /
`link` 模式位，别拿单次 `brightness` 下结论（已写进 README §2.3.1）。

### 5.5 刷机后自检

```sh
# 1. 六个绑定都在，trigger 不是 none
for l in lan-1 lan-2 lan-3 lan-4; do
  echo "$l $(cat /sys/class/leds/blue:$l/trigger | grep -o '\[.*\]') \
$(cat /sys/class/leds/blue:$l/device_name)"; done
#    期望：4 行都是 [netdev] 且 device_name 为 lan1..lan4
uci show system | grep '^system.led_'          # 期望 6 段：led_lan1..4 + led_usb1/2

# 2. usbport 触发器这次在不在（本次补的 kmod 是否生效）
grep -c usbport /sys/class/leds/blue:usb-1/trigger     # 期望 ≥1（原来恒为 0）

# 3. 逐口插线看灯；有流量时闪属正常

# 4. 这 4 条是正常的，别去"修 pinctrl"（见 §6.1）
dmesg | grep -c 'Failed to setup PHY LED pinctrl'      # 期望 4
```

---

## 六、遗留与备注

### 6.1 `dmesg` 里那 4 条 ERROR：正常现象，但很会带偏人 `[实测]`

```
[    3.872847] mdio_bus mt7530-0: Failed to setup PHY LED pinctrl
（共 4 条，对应 gsw_phy1..4）
```

来源是上游 `drivers/net/phy/mediatek/mtk-ge-soc.c` 的 `an7581_phy_probe()`：

```c
	/* Toggle pinctrl to enable PHY LED */
	pinctrl = devm_pinctrl_get_select(&phydev->mdio.dev, "gbe-led");
	if (IS_ERR(pinctrl))
		dev_err(&phydev->mdio.bus.dev, "Failed to setup PHY LED pinctrl\n");
```

**对可选功能用了 `dev_err`**：CU/CT 的设备树**故意不定义** `gbe-led` 状态（面板灯走
gpio-leds，PHY LED0 那条路已经撤掉了），所以查不到状态、报错、脚仍归 GPIO、灯照亮 ——
**功能上完全正常**。

> ⚠️ **这条曾经真的把人带偏**：上一版的 README 自检清单写着"`dmesg | grep -iE
> 'pinctrl|gbe-led'` 不应有报错"，于是这几条**正常**的日志被当成异常，排查方向被引向
> pinctrl —— 而真正的原因（触发器没绑）在另一个地方。本轮的 README 已改为明确说明
> "这 4 条是正常的"。
>
> 这段代码是 **mainline**，本 target 只有一个补丁碰 `mtk-ge-soc.c`
> （`131-v7.0-net-phy-mediatek-enable-interrupts-on-AN7581.patch`），而它只在驱动结构体
> 处加 2 行、不碰这个函数。上游为**同一个症状**动过手（openwrt `65aed6aa12c6`
> "airoha: an7581: correct the pinctrl-name of phy leds"，把 evb 的 `pinctrl-names`
> 从 `"led"` 改成 `"gbe-led"`，理由就是贴这几行报错），但没覆盖"根本没有该状态"的机型。
> 合理的上游修法：只在节点确实声明了 `pinctrl-names` 时才 `dev_warn`，否则 `dev_dbg`。

### 6.2 为什么没有回到 PHY LED0 那条路

* 硬件已证明 gpio-leds 这条路**通**（§2.1），上游的方案是对的；
* 一个 pad 只能归 GPIO 或 PHY LED 输出**其中之一**：两套描述同时在设备树里，
  `gbe-led` pinctrl 状态会把 4 个脚从 gpio-leds 手里拿走，`01_leds` 的绑定就全废了
  （这正是 `60667288e6` 撤掉它的原因）。
* PHY LED0 路线看起来"灯交给 PHY 硬件、不需要用户态"，但**它在别的机型上同样被证明
  仍然需要 netdev 触发器**：`docs/xg-040g-mf-an7583-2p5g-fix.md` 第二节在 EN8811H 上
  实测到 —— 驱动在 `air_leds_init()` 里把 LED 设成 `AIR_LED_MODE_USER_DEFINE`，
  而 LED 类设备走一次 `air_hw_led_on_set(false)` 就会把 `priv->led[i].rules` 清零，
  **只有 netdev 触发器推得回来**。所以这条路并没有省掉"触发器必须绑上"这个前提。
  **结论：留上游方案，把断掉的绑定补上。**

### 6.3 本次没做的事

* **没有重启验证**：这台机器是编译机的默认路由，重启会掐断排查通道。间接证据充分
  （配置已 `uci commit` 落盘、`S96led` 已启用、触发器激活时会读当前 carrier ——
  单独做过"解绑再绑定"测试，`lan1` 立刻回到 `br=1`），但严格说**缺一次重启复核**。
* **USB 段未在实机补**：理由见 §4.1，下一次刷机由迁移脚本补上。
* **迁移脚本只认这 4 个老名字**：如果将来 `blue:lan-*` 再改名，它救不了。那时按
  README §2.3.1 的两条命令自查（`trigger` 是否 `[none]`、UCI 里的 `sysfs` 是否
  真实存在的类设备名）。
* **没有泛化到别的机型**：同样的"保留配置升级 ⇒ 拿不到新板级 LED 默认值"对
  所有 an7581 机型都成立（同步前的 `01_leds` 只给其中一部分绑了触发）。
  理论上可以做一个"按 `/etc/board.json` 纯增量补齐"的通用迁移，
  但那需要把 `generate_led` 的 netdev/usbport/gpio/… 逻辑复刻一遍，且会"撤销"用户
  主动删掉的段，权衡后先按机型做（本次只做 CU，证据最足的那个）。

---

## 附：相关提交

| 提交 | 内容 |
|---|---|
| `ce0b1b7acb` | 迁移脚本首版 + README §2.3.1 + 自检清单更正 |
| `430f689c6b` | `image/an7581.mk` 补 `kmod-usb-ledtrig-usbport` |
| `e191bd94e6` | 迁移脚本改用上游 `migrate_leds()` 并覆盖全部 6 个绑定 + README §2.3.2 |

**关键文件**

```
target/linux/airoha/an7581/base-files/etc/uci-defaults/99-hg5585f-cu-leds   ← 新增（迁移）
target/linux/airoha/image/an7581.mk                                        ← DEVICE_PACKAGES 补 kmod
target/linux/airoha/an7581/base-files/etc/board.d/01_leds                  ← 未改（本来就是对的）
target/linux/airoha/dts/an7581-fiberhome-hg5585f-common.dtsi               ← 未改（本来就是对的）
README.zh-CN.md                                                            ← §2.3.1 / §2.3.2 / §6.2 自检
```
