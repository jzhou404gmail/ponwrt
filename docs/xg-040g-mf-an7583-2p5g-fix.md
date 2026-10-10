# XG-040G-MF（AN7583）2.5G 口排查记录

现象（同一台机器上同时出现）：

1. LAN1（2.5G）插线上不了，`LED2.5` 不亮；
2. LuCI「SOC 状态」页里**完全没有 2.5G 口那张卡**（GDM4 卡片消失）。

排查方式：机器在线，直接 SSH 取活体证据（`192.168.32.254`，走 LAN4 进）。

---

## 一、2.5G 口不工作：PHY 驱动根本没进固件 `[实测]`

```
# ls /lib/modules/6.18.52/ | grep -i "en8811\|libphy"     ← 空
# dmesg | grep lan1
[ 8.606984] airoha_eth 1fb50000.ethernet lan1: validation of 2500base-x with
            support 0000000,00000000,00000000,000062e8 and
            advertisement 0000000,00000000,00000000,000062c0 failed: -EINVAL
[ 9.668696] airoha_eth 1fb50000.ethernet lan1: could not attach PHY: -22
[25.680142] br-lan: port 1(lan1) entered blocking state
[25.685401] br-lan: port 1(lan1) entered disabled state

# ethtool lan1 | head -12
	Supported link modes:   2500baseX/Full
	PHYAD: 0
	Link detected: no
```

`lan1` 背后是 GDM3 上的 EN8811H（PHY 地址 `0x0f`，MDIO0 控制器 `mdio-bus@c8`）。
`air_en8811h.ko` 不在 `/lib/modules` 里，phylib 只能退回 generic PHY，
而 generic PHY 不会做 `2500base-x` 协商 ⇒ `phy_attach` 直接 `-EINVAL`，口永远起不来。

### 根因：`.config` 里 EN8811H 被钉成 `=m`，而这次构建**不是** per-device rootfs 模式

```
$ grep -n "PER_DEVICE\|MULTI_PROFILE\|en8811h=" .config
(无 TARGET_MULTI_PROFILE / TARGET_PER_DEVICE_ROOTFS)
CONFIG_PACKAGE_kmod-phy-airoha-en8811h=m
CONFIG_PACKAGE_airoha-en8811h-firmware=m

$ grep -n "MULTI_PROFILE\|PER_DEVICE" configs/an7583.config
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y
```

* `TARGET_PER_DEVICE_ROOTFS=y`（种子配置的用法）时，`DEVICE_PACKAGES` 走
  `select MODULE_DEFAULT_<pkg>`，kmod 以 `=m` 打进「每个机型自己的 rootfs」——
  这是**正确**的，`=m` 没问题。
* 本机 `.config` 里这两个符号**都不见了**（关掉了 per-device rootfs，只选了 1 个机型），
  于是 `DEVICE_PACKAGES` 改走 `select DEFAULT_<pkg>`，Kconfig 默认给 `y`；
  但那份 `.config` 是从 per-device 时代抄过来的，`CONFIG_PACKAGE_*=m` 是**显式值**，
  会压过 Kconfig 默认值 ⇒ 包被编译出来（`.apk` 在 `bin/targets/.../packages/`），
  **却不会装进镜像**。

受害的不止 2.5G，同一份 `.config` 里被静默丢掉的还有：

| 包 | 丢失后果 |
|---|---|
| `kmod-phy-airoha-en8811h` + `airoha-en8811h-firmware` + `kmod-libphy` | **2.5G 口完全不可用、LED 不亮** |
| `kmod-usb3` / `kmod-usb-xhci-hcd` / `kmod-usb-core` | USB 口无主机控制器 |
| `kmod-usb-storage` / `-uas` / `kmod-fs-ext4/vfat/exfat` / `block-mount` | USB 存储挂不上 |
| `kmod-regulator-userspace-consumer` / `kmod-usb-ledtrig-usbport` | USB 供电与 LED 触发器缺失 |

### 修复

```sh
# .config：11 个被钉死的包改回 =y（改完 make defconfig 会自动补出依赖）
for p in block-mount airoha-en8811h-firmware kmod-fs-exfat kmod-fs-ext4 kmod-fs-vfat \
         kmod-phy-airoha-en8811h kmod-regulator-userspace-consumer kmod-usb-ledtrig-usbport \
         kmod-usb-storage kmod-usb-storage-uas kmod-usb3; do
	sed -i "s/^CONFIG_PACKAGE_${p}=m$/CONFIG_PACKAGE_${p}=y/" .config
done
make defconfig
```

`make defconfig` 后包数 215 → 237（只增不减），并自动带出 `kmod-libphy`、
`kmod-usb-core`、`kmod-scsi-core`、`kmod-nls-*` 等依赖。

> 另一条同样可行的路：把 `.config` 改回种子配置的模式
> （`CONFIG_TARGET_MULTI_PROFILE=y` + `CONFIG_TARGET_PER_DEVICE_ROOTFS=y`），
> 此时 `=m` 是对的。**两条路不要混用**，混用就是这次踩的坑。

---

## 二、LED2.5 不亮：`01_leds` 没给 LAN1 绑触发器 `[实测]`

```
# ls /sys/class/leds/
green:power  green:usb-1  green:usb-2  green:wan  green:wan-online  red:wan
mt7530-0:0a:green:lan-2  mt7530-0:0b:green:lan-3  mt7530-0:0c:green:lan-4
                                                     ↑ 2.5G 的 lan-1 根本没有
```

两层原因，缺一不可：

1. EN8811H 驱动在 `air_leds_init()` 里把 LED 设成 `AIR_LED_MODE_USER_DEFINE`，
   DTS 的 `default-state = "keep"` **不会**让 PHY 自己驱动灯；
2. `phy_led_probe()` 注册 DT LED class 设备时调 `brightness_set(0)`，
   驱动里的 `air_hw_led_on_set(false)` 会把 `priv->led[i].rules` 清零——
   只有 `netdev` 触发器会把规则重新推回硬件。

an7583 的 `01_leds`（`nokia,xg-040g-mf` case）只写了 lan2/3/4，
2.5G 的 lan1 一行都没有 ⇒ 触发器永远 none ⇒ 灯永远不亮。
an7581 那几个机型在 `fc5dd1c86b` 里已经补过，这次是 an7583 漏了。

### LED 类设备名怎么来的

`led_compose_name()` 的规则是 `<设备名>:<color>:<function>-<枚举号>`，
PHY LED 的「设备名」取 `dev_name(&phydev->mdio.dev)`：

| 机型 | 2.5G PHY 挂在哪 | MDIO 设备名 | LED 类设备名 |
|---|---|---|---|
| AN7581（MD/TF/ZNXT/UNG00A） | 交换机内部 mdio（`&mdio`） | `mt7530-0:0f` | `mt7530-0:0f:green:lan-1` |
| **AN7583（XG-040G-MF）** | SoC MDIO0 控制器（`&mdio_0`，scuclk syscon 的子节点） | `1fb00000.system-controller:mdio-bus@c8-mii:0f` | **`1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1`** |

设备名是从活体机器上核对的：

```
# ls /sys/bus/mdio_bus/devices/
1fb00000.system-controller:mdio-bus@c8-mii:0f   mt7530-0:0a  mt7530-0:0b  mt7530-0:0c
# ls /proc/device-tree/soc/system-controller@1fb00000/mdio-bus@c8/ethernet-phy@f/leds/led-0
color  default-state  function  function-enumerator  name  reg
```

### 修复

`target/linux/airoha/an7583/base-files/etc/board.d/01_leds` 的
`nokia,xg-040g-mf|nokia,xg-040g-mf-ubi` case 增加：

```sh
ucidef_set_led_netdev "lan1" "lan1" \
	"1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1" "lan1" "link tx rx"
```

**不刷机的热修**（`/etc/board.d/*` 只在 `/etc/board.json` 不存在时执行，
所以保留配置升级后必须手工补，一条命令可撤销）：

```sh
uci set system.led_lan1=led
uci set system.led_lan1.name='lan1'
uci set system.led_lan1.sysfs='1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1'
uci set system.led_lan1.trigger='netdev'
uci set system.led_lan1.dev='lan1'
uci set system.led_lan1.mode='link tx rx'
uci commit system && /etc/init.d/led restart
# 撤销：uci delete system.led_lan1 && uci commit system && /etc/init.d/led restart
```

---

## 三、SOC 状态页没有 2.5G 口卡片：`luci-app-airoha-npu` 把铜口写死成 GDM4 `[实测]`

```
# ubus call luci.airoha_npu getFrameEngine | tr "," "\n" | grep -E "gdm|netdev"
"gdm1":{"netdev":"eth0" ...
"gdm2":{"netdev":"pon0" ...
"gdm4":{"netdev":"" ...        ← 空，前端因此不渲染这张卡
```

设备树实测：`lan1 -> .../ethernet@1fb50000/ethernet@3`，即 **2.5G 在 GDM3**：

* AN7581：`gdm4: ethernet@4`（PSE 端口 **P9**）—— 上游/本 fork 一直按这个写；
* AN7583：**没有 `ethernet@4` 节点**，2.5G 在 `gdm3: ethernet@3`（PSE 端口 **P3**）；
  内核 `airoha_an7583_get_sport()` 也印证：GDM3 = ETH SerDes，GDM4 = PCIe/USB SerDes。

所以 RPC 里 `gdm_netdev 4` 在 AN7583 上必然取空，前端 `gdmCards()` 又把空卡片过滤掉
⇒ 页面看起来「没有 2.5G 口」，实际是查询的 GDM 号错了。

### 修复

* `root/usr/libexec/rpcd/luci.airoha_npu`：
  * 新增 `gdm_copper_index()`：按 DTS `phy-mode` 反推铜口在哪个 GDM
    （扫 GDM4 → GDM3，`2500base-x`/`10gbase-r`/`usxgmii` 这类对外 SerDes 模式即铜口；
    GDM1 是 `internal`、GDM2 没有 `phy-mode`，自然被跳过）；
  * 新增 `"gdm_copper":{"index":N,...}` 字段（保留旧 `"gdm4"` 键给老前端）；
  * 新增 `gdm_pse_port()`：GDM 序号 ≠ PSE 端口号，GDM3 才是 P3，**GDM4 是 P9**
    （P4..P8 归 PPE 引擎和 CDM）。丢弃计数按这张表取，不再写死 P9。
* `htdocs/.../airoha_npu/status.js`：卡片名用 `GDM<index>`，PSE 标签
  `P3` 在 AN7583 上显示为 `Copper PHY`（AN7581 有 WiFi 时仍是 `PCIe (WiFi)`），
  `P9` 在 AN7583 上显示为 `PCIe/USB SerDes`；GDM→PSE 的换算与 `gdm_pse_port()` 同规则。

> **这个「序号 ≠ 端口号」是在 AN7581 上实测才发现的**：第一版直接把 PSE 端口号和
> GDM 序号比较（`[ "$port" = "$gdm_copper_idx" ]`），在 AN7583 上恰好 `3 = 3` 蒙对，
> 在 AN7581 上却是 `4 ≠ 9`，于是 **P9 的 RX Drop 静默变成 0**。对照活体机器的
> `lan1 rx_dropped` 才看出来，所以现在两边都用显式映射表。

在活的机器上跑改后的 RPC（拷到 `/tmp` 直接执行，不动固件）。

AN7583（XG-040G-MF）上索引解析为 3：

```
"gdm_copper":{"index":3,"netdev":"lan1","present":true,"link":false,"speed":"2.5G",...}
```

AN7581（ZN504XG-D）上回归：索引仍是 4，其余字段与固件里旧 RPC 的输出逐字节相同
（只有时间和流量计数在走）：

```
$ ssh op 'ubus call luci.airoha_npu getFrameEngine' > /tmp/fe_old.json   # 固件里的旧 RPC
$ cat luci.airoha_npu | ssh op 'cat > /tmp/npufix/rpc' && ssh op 'sh /tmp/npufix/rpc call getFrameEngine' > /tmp/fe_new.json
新增字段: ['gdm_copper']   删除字段: []
"gdm_copper":{"index":4,"netdev":"lan1","present":true,"link":true,"speed":"2.5G","tx_drop":5,"rx_drop":15}
PSE drops 旧: {..., 9: 15, ...}   新: {..., 9: 15, ...}      # P9 的丢弃计数没有丢
```

---

## 四、刷机后自检

```sh
# 1. 驱动与固件都在
ls /lib/modules/$(uname -r)/air_en8811h.ko
ls /lib/firmware/airoha/EthMD32.*.bin
dmesg | grep -i en8811
#    期望：Airoha EN8811H ...:0f: MD32 firmware version: 25062302
#          lan1: PHY [...:0f] driver [Airoha EN8811H]

# 2. 口起来了
ip -br link show lan1
ethtool lan1 | grep -E "Speed|Link detected"
dmesg | grep "lan1: Link is Up"          # 期望 2.5Gbps/Full

# 3. 灯绑上了（保留配置升级后先跑第二节的 uci 热修）
cat /sys/class/leds/1fb00000.system-controller:mdio-bus@c8-mii:0f:green:lan-1/trigger
#    期望 [netdev]，同目录有 device_name / link / link_2500 / tx / rx

# 4. SOC 状态页
ubus call luci.airoha_npu getFrameEngine | tr "," "\n" | grep -A2 gdm_copper
#    期望 index=3，netdev=lan1，speed=2.5G，link 跟随插拔
```

## 五、编译环境备注（只影响在沙箱/受限环境里编译）

`package/install` 是 `$(FAKEROOT) apk add ...` 装 rootfs。fakeroot 2.1.3 的
chown 包装器**只容忍 EPERM**（`if (r && errno == EPERM) r = 0;`），
在 chown 会返回 `EINVAL` 的环境里，每个包都会报
`failed to preserve ...: owner` 并以 `N errors; ...` + 退出码 99 中止：

```
# 现象
(1/207) Installing libgcc1 ...
WARNING: libgcc1-...: failed to preserve lib/libgcc_s.so.1: owner
207 errors; 24.3 MiB in 207 packages
make[1]: *** [package/Makefile:164: package/install] Error 99
```

绕过（fakeroot 官方开关，跳过「真去 chown」那一步，只记假所有权）：

```sh
FAKEROOTDONTTRYCHOWN=1 ./build.sh
```

普通非 root shell 里 chown 返回 EPERM，会被 fakeroot 吞掉，所以平时编译不需要这个变量。
