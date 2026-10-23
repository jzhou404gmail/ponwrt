# XG-040G-MD 发射功率 -40 dBm 排查记录（EN7572 BOB A0/A2 标定表）

现象：Nokia XG-040G-MD（PONWrt，`epon-10g-1g` 已注册、PPPoE 正常）的
LuCI「网络 → PON → 状态」里：

```
[frontend]
calibration: missing
rx_power_dbm: -20.09
temperature_celsius: 43.23
tx_bias_ma: 107.07          ← 偏置高得离谱
tx_power_dbm: -40.00        ← 发射功率卡在最小值
voltage_volts: 3.24
```

接收功率、温度、电压都正常，只有发射功率是 `-40.00`，偏置 `107 mA`。

排查方式：机器在线，直接 SSH（`192.168.32.254`）取活体证据 + 从原厂备份里读
`bosa` 标定 blob 对照。

---

## 一、-40 不是一个“读数”，是 DAC 的字面值 `[实测]`

`ponctl` 里 8472 的线性值换算成 dBm 是 `10*log10(x) - 40`（见
`airoha-ponctl/src/src/status.rs: convert_optics()`），所以：

| 原始字 | 含义 |
| --- | --- |
| `0x0000` / `0x0001` | 0.1 µW 及以下 ⇒ **-40.00 dBm**（下限，等价于“没测到”） |
| `0x5b9b` | 2.35 mW ⇒ +3.70 dBm |

实机直读（`i2ctransfer -f -y 0 w2@0x51 <reg_hi> <reg_lo> r2@0x51`，EN7572 在
`0x51`，16 位大端子地址）：

```
0x0060: 0x2d 0x3c   temp
0x0062: 0x7e 0xbb   vcc
0x0064: 0xd1 0x1d   bias   = 53533 × 2 µA = 107.07 mA
0x0066: 0x00 0x01   tx     = 1 ⇒ -40.00 dBm
0x0068: 0x00 0x60   rx     = 96 ⇒ -20.18 dBm
```

所以不是显示层四舍五入的问题，是 dmesg 里那句警告的真实后果：

```
airoha-en7572 0-0050: BOB A0 calibration area is empty; XE/XES will use erased/default register codes
airoha-en7572 0-0050: BOB A0 TX DDMI is erased; copied 4 bytes from A2
airoha-en7572 0-0050: BOB loaded from NVMEM: A0=empty A2=valid
```

## 二、根因：驱动挑了那块**没标定**的表 `[实测]`

`bosa` 卷（UBI 卷 `bosa`，或原厂 `bosa` 分区）格式是 `aa 55` + 512 字节 BOB：
前 256 字节 A0 页、后 256 字节 A2 页。本机（以及另外两台 XG-040G-MD 的原厂备份）
里 **A0 页是 0xff，只有 A2 页被标定**：

```
# dd if=/dev/ubi0_3 bs=1 count=640 | hexdump -C | sed -n '1,4p'
00000000  aa 55 ff ff ff ff ff ff  ff ff ff ff ff ff ff ff
00000010  ff ff ff ff ff ff 45 43  4f 4e 45 54 20 20 20 20   ← ECONET
00000020  20 20 20 20 20 20 ff ff  ff ff 45 4e 37 35 37 32   ← EN7572
00000030  20 20 20 20 20 20 20 20  20 20 ff ff ff ff ff ff
...
00000160  ff ff 22 81 7f 04 18 90  5b 9b 00 0a 4c fc ff ff
                ↑temp  ↑vcc  ↑bias  ↑tx   ↑rx      ← A2 页里的出厂 DDMI 快照
```

`en7572_bob_base()` 按模式选表：GPON/XG(S)-PON/1G-EPON → A2，**10G-EPON
（`epon-10g-1g` / `epon-10g-10g`）→ A0**。本机正好是 `epon-10g-1g`，于是
`prepare()` 从全 0xff 的 A0 页取校准码，各自截断到寄存器位宽就成了“全 1”：

```
# i2ctransfer -f -y 0 w2@0x51 0x02 0x10 r4@0x51
0x0210 → 0x0fff1fff   IMOD_CAL=0x0fff IAV_CAL=0x1fff，正是 0xff 截断后的样子
0x0124 → 0x0002ff00   APC_CAL = 0xff
0x0128 → 0x0fffff00   ERC_DAC / ERC_CDAC = 全 1
0x0130 → 0x001b3f01
0x013c → 0x0007027b
```

IAV_CAL 是偏置电流码，写满 0x1fff 就是把激光往死里推 —— 这就是 107 mA 的来源；
而 MD32 在“未标定”状态下算出来的 TX DDMI 词就是 `0x0001`（0.1 µW）。

### 佐证：同样的表里存着出厂时的 DDMI 快照

A2 页偏移 0x60–0x6d 是模块出厂测试时写进去的 DDMI 快照，三台同型号机器的值：

| 机器 | temp | vcc | bias | **tx** | rx |
| --- | --- | --- | --- | --- | --- |
| 本机（`/dev/ubi0_3`） | 34.5 °C | 3.25 V | 12.6 mA | **+3.70 dBm** | 光纤黑 |
| 原厂备份 `503D7F7C64F5` | 26.1 °C | 3.26 V | 10.4 mA | **+3.62 dBm** | 光纤黑 |
| 原厂备份 `80AE3CC0438D`（坏板） | 44.5 °C | 3.24 V | 13.8 mA | **+3.83 dBm** | -27.2 dBm |

也就是说这台模块在标定表生效时本来就该报 **+3.6 ~ +3.8 dBm**，绝不该是 -40。

## 三、验证：把已标定的那张表的参数直接写进芯片 `[实测]`

`docs/pon-txpwr-probe.sh` 把 `prepare()` 的写入序列原样重放，但参数取 A2 页
（`IMOD=0x0822 IAV=0x0578 APC=0xd6 ERC_DAC=0x0740 ERC_CDAC=0xd6 tia=0x23
PGA_GAIN=3 PGA_CAP=0`），BEN 只在写入期间关 <100 ms：

```
=== before         0x0210=0x0fff1fff  bias=0xd11d  tx=0x0001
BEN off : 0x20032049
0x0210  : 0x08220578
...
0x0208  : 0x02040521  (rg_loop_en 0->1)
BEN norm: 0x20032041
=== after 3s       0x0210=0x08220578  bias=0x311d  tx=0x5be2
=== after 10s      bias≈0x0bec(6 mA)  tx=0x5b7c~0x5bc6(+3.70~+3.72 dBm)
```

偏置从 107 mA 掉到 6–25 mA，发射功率稳定在 +3.7 dBm，EPON 注册与 PPPoE 不受影响。

## 四、修复：模式永远从**已标定**的那半边取参数

`feed-patches/pon_drivers/airoha-pon-frontends/0001-en7572-run-modes-from-the-calibrated-bob-profile.patch`：

* 新增 `en7572_calibrated_base()`：模式选中的那张表若为空、另一张有效，就用
  有效的那张（`prepare()` 与 `get_diagnostics()` 都改走它）；
* 删掉原来只补 4 字节 TSSI 的 `en7572_apply_tx_ddmi_fallback()` —— 整张表都被
  替换后它已是死代码，而“BOB A0 TX DDMI is erased; copied 4 bytes from A2”
  这条日志会让人误以为已经修好；
* 开机日志改成说人话：
  `BOB A0 profile is erased; every mode runs from the calibrated A2 profile`，
  且 `ponctl status` 的 `calibration` 由 `missing` 变成 `ready`。

验证（替换 `/lib/modules/6.18.52/airoha-en7572.ko` 后重启）：

```
[   19.110529] airoha-en7572 0-0050: BOB A0 profile is erased; every mode runs from the calibrated A2 profile
[   19.120213] airoha-en7572 0-0050: BOB loaded from NVMEM: A0=empty A2=valid

[frontend]
calibration: ready
rx_power_dbm: -20.13
temperature_celsius: 44.21
tx_bias_ma: 16.61
tx_gate_enabled: 1
tx_power_dbm: 3.70
```

偏置 16.6 mA（44 °C）与出厂快照 12.6 mA（34.5 °C）同一量级，温度高偏置高是对的。

### 关于“正常应该是 -4 ~ -6 dBm”

本次能确认的是**读数**：硬件在标定参数生效时报 +3.6 ~ +3.8 dBm，三台机器的
出厂快照互相印证。原厂固件上看到 -4 ~ -6，更像是它按 ISP 下发的功率档位把激光
压低了 8 ~ 9 dB（原厂 web/cgi 里确实有 `X_CT-COM_GponInterfaceConfig.TXPower`
这类参数）。本 fork 目前不实现功率档位，报的是模块真实输出值；若确实要压到
-4 ~ -6，需要再加一个可配置的上行功率目标（另开一项工作，别和 `-40` 这个 bug 混在
一起）。

## 五、自检清单

```
# 1) 校准表状态与真实 DDM
ponctl status | sed -n '/frontend/,/^$/p'
#   期望 calibration: ready、tx_power_dbm ≈ +3.6~+3.8、tx_bias_ma 个位数~20 mA

# 2) 原始寄存器（不经过用户态换算）
i2ctransfer -f -y 0 w2@0x51 0x00 0x66 r2@0x51     # 0x5b.. 才算对，0x00/0x01 就是老问题
i2ctransfer -f -y 0 w2@0x51 0x02 0x10 r4@0x51     # 0x08220578 = 已用 A2 标定码

# 3) 想临时复现/对比时
sh /tmp/pon-txpwr-probe.sh restore   # 写回擦除值（=老固件行为）
sh /tmp/pon-txpwr-probe.sh           # 再写回 A2 标定值
```

> 另一种 -40：UNG00A 的 A0 页模拟标定有效、只有 TSSI 被擦除，0001 把
> A0←A2 的 TSSI 回退当死代码删掉后回归。见
> [`docs/ung00a-tx-power-tssi.md`](ung00a-tx-power-tssi.md)。

## 六、编译环境备注（只影响在受限沙箱里出镜像）

本机沙箱里 `./build.sh` 会停在 `package/install`：

```
WARNING: ... failed to preserve <file>: owner
418 errors; 171.6 MiB in 418 packages
make[1]: *** [package/Makefile:164: package/install] Error 99
```

原因是工作目录所在文件系统不支持 `chown`（`chown root:root f` 直接 `EINVAL`），
apk v3 在“非 root + 不能改属主”下按错误处理，与本次改动无关。出完整镜像请在
常规的 root/容器环境里跑；单验证驱动可以只编 kmod 再手工替换：

（同一类环境限制还会让 per-device rootfs 的 `target-dir-<hash>` 也报
`failed to preserve ...: owner`，都属同一件 chown 的事。）

### 另一个坑：内核构建树被留成 initramfs 配置（和本次改动无关）

非“separate ramdisk”模式下，生成 recovery 镜像那一步会**就地**把
`build_dir/.../linux-<board>/linux-*/​.config` 改成
`CONFIG_INITRAMFS_SOURCE="<rootfs> ..."`，构建结束也不还原。下一次构建的
“普通内核”于是拿这份配置重链，`Image` 变成 194 MB 的 initramfs 内核 →
sysupgrade 镜像从 58 MB 涨到 117 MB，刷进去 U-Boot `inflate() returned -5`。
指纹：`Image` 里能 `strings` 出 `etc/openwrt_release`、sysupgrade 与 recovery
两侧内核 md5 相同。`verify-images.sh` 会拦下，`build.sh` 现在在**开编前**把它们
复位（`kernel_tree_heal()`：`.config ← .config.set`），手工恢复也可以：

```
rm -rf build_dir/target-*/linux-<board>_<subtarget>   # 最省事，重编内核
# 或只复位配置，让内核增量重链：
cp build_dir/target-*/linux-*/linux-6.18.52/.config.set \
   build_dir/target-*/linux-*/linux-6.18.52/.config
```

```
make package/feeds/pon_drivers/airoha-pon-frontends/compile
scp build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/airoha-pon-frontends/airoha-en7572.ko \
    root@<光猫>:/lib/modules/6.18.52/airoha-en7572.ko
```
