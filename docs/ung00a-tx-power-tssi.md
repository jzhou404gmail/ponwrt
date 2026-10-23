# UNG00A 发射功率 -40 dBm：A0 只标定了模拟段，TSSI 在 A2

现象（`192.168.32.254`，PONWrt，`epon-10g-1g` 已注册、PPPoE 正常）：

```
[frontend]
calibration: ready
error: 0
rx_power_dbm: -20.60
temperature_celsius: 66.52
tx_bias_ma: 16.51
tx_gate_enabled: 1
tx_power_dbm: -40.00       ← 只有发射功率是下限
voltage_volts: 3.31
```

开机日志里两张表都是 `valid`，和 XG-040G-MD 那种“A0 整页擦除”不是同一种情况：

```
airoha-en7572 0-0050: BOB loaded from NVMEM: A0=valid A2=valid
airoha-en7572 0-0050: MD32 initialized, ... burst TX disabled, board TX_DISABLE asserted
```

## 一、根因：A0 的模拟标定在，TSSI 标定不在 `[实测]`

UNG00A 的 `factory` 卷里，标定 blob 在 `0x1c0400`，512 字节 = A0 页 256 字节 +
A2 页 256 字节。实机读出：

```
A0 @0x1c0400+0x80: ff ff ff ff 1d 01 1e 07 a8 04 c3 ff 00 c3 50 08 03 04 04 00
                   ↑0x86 IMOD=0x071e  ↑0x88 IAV=0x04a8  ↑0x8a APC=0xc3 ...
A0 @0x1c0400+0xb4: ff ff ff ff        ← TSSI_CAL_1 整段擦除
A2 @0x1c0400+0x1b4: 01 94 de 69       ← TSSI 标定只写在这一页
```

驱动 `prepare()` 会把所选页的 `0xb4..0xb7` 原样写到运行时寄存器 `0x00b4`。
`epon-10g-1g` 按 `en7572_bob_base()` 选 A0，于是写进去的是 `0xffffffff`，
MD32 在“没有 TX 功率计标定”时给出的字面值就是 `0x0001`：

| 原始字 | 换算 |
| --- | --- |
| `0x0001` | 0.1 µW ⇒ **-40.00 dBm**（下限，等价于“测不到”） |
| `0x6adb` | 2.7355 mW ⇒ **+4.37 dBm** |

所以偏置、接收、温度、电压全都正常，只有 TX 功率计这一项缺标定。这也解释了
为什么 `calibration: ready` 仍然可能是 -40：`en7572_bob_table_valid()` 只看
`0x80..0xd7` 的模拟标定段，A0 这段是有效的。

### 直接验证是 TSSI 缺字节 `[实测]`

不重启、不碰激光，只把 A2 的四个字节写进运行时 `0x00b4`：

```
# 写前
0x00b4 = ff ff ff ff     0x0066 = 0x0001   → -40.00 dBm
# i2ctransfer -f -y 0 w6@0x51 0x00 0xb4 0x01 0x94 0xde 0x69
0x00b4 = 01 94 de 69     0x0066 = 0x6adb   → +4.37 dBm
```

偏置始终是 16.5 mA，说明激光功率没有变，变的只是 MD32 对 TX 功率的换算。
（这个写入是易失的，重启后回到 -40。）

## 二、为什么以前是 3.42 dBm：0001 删掉了一个“看起来是死代码”的回退

旧驱动在 BOB 加载后有一个 `en7572_apply_tx_ddmi_fallback()`：A0 的 4 字节
TSSI 为 `0xffffffff` 时，从 A2 复制同样 4 字节过来。它在 XG-040G-MD 上确实
不再触发（那张板子的 A0 是整页擦除，0001 会直接改用 A2），所以 0001 把它当成
死代码删了。

但 UNG00A 的 A0 **不是整页擦除**：模拟段有效，只有 TSSI 被擦除。
`en7572_calibrated_base()` 看到 `bob_a0_valid == true` 就继续用 A0，
而被删掉的 TSSI 回退正是这里唯一能补上 `0xb4` 的路径。于是：

* 0001 之前：A0 模拟参数 + A2 TSSI ⇒ TX 功率正常（用户看到的 3.42 dBm）；
* 0001 之后：A0 模拟参数 + A0 的 `0xffffffff` ⇒ TX 功率 -40 dBm。

这不是 `airoha-xpon`（XPON MAC/PLOAM）的问题；XPON 只是消费前端驱动报上来的
DDMI。问题在 `airoha-pon-frontends` 的 EN7572 BOB 处理。

## 三、修复：恢复 TSSI 回退（0002）

`feed-patches/pon_drivers/airoha-pon-frontends/0002-en7572-restore-tx-ddmi-fallback.patch`
把回退加回来，并在 BOB 载入 DM 之前调用（`prepare()` 随后也会写 `0x00b4`）：

```c
if (a0_tssi != U32_MAX)
        return;
if (a2_tssi == U32_MAX) {
        dev_warn(dev, "BOB TX DDMI calibration is erased in both profiles\n");
        return;
}
memcpy(a0 + EN7572_BOB_TSSI_CAL_1, a2 + EN7572_BOB_TSSI_CAL_1,
       sizeof(a0_tssi));
dev_warn(dev, "BOB A0 TX DDMI is erased; using the A2 TSSI calibration\n");
```

TSSI 是“这个模块的 TX 功率计”的标定，不随波长/模式变；借 A2 的四个字节不会
改动激光的 IMOD/IAV/APC/ERC/TIA/PGA（这些仍来自 A0）。

### 真机回归（替换 `.ko` 后重启）`[实测]`

```
[   18.396379] airoha-en7572 0-0050: BOB A0 TX DDMI is erased; using the A2 TSSI calibration
[   18.404577] airoha-en7572 0-0050: BOB loaded from NVMEM: A0=valid A2=valid

[frontend]
calibration: ready
rx_power_dbm: -20.60
temperature_celsius: 66.52
tx_bias_ma: 16.51
tx_gate_enabled: 1
tx_power_dbm: 4.34
voltage_volts: 3.31

[registration]
llid: 17
mpcp_state: registered
upstream_tx_armed: 1
```

`pppoe-wan` 拿到 `114.248.20.37`，`ping 223.5.5.5` 正常；重启后 `0x00b4` 直接
就是 `01 94 de 69`，不需要人工写寄存器。

## 四、自检

```
ponctl status | sed -n '/frontend/,/^$/p'
#   期望 calibration: ready、tx_power_dbm ≈ +4.3~+4.4（66 °C）、tx_bias_ma ≈ 16.5

dmesg | grep -E 'BOB|en7572'
#   期望出现 "BOB A0 TX DDMI is erased; using the A2 TSSI calibration"

i2ctransfer -f -y 0 w2@0x51 0x00 0xb4 r4@0x51   # 01 94 de 69，不是 ff ff ff ff
i2ctransfer -f -y 0 w2@0x51 0x00 0x66 r2@0x51   # 0x6b.. 量级，0x00 0x01 就是又丢了
```

## 五、两条旁证

* 本机 `factory` 卷里的机器标识是 `F02178003638` / `UMTC60000F60`，而工作区
  `原厂备份/UNG00A/F02178071B40` 里是 `F02178071B40` / `UMTC60019A39`，不是
  同一台。两份数据的 A0 TSSI **都**是 `ff ff ff ff`，所以 -40 与“用哪份备份
  恢复”无关；恢复原厂参数不会造成这个现象。
* +4.3~4.4 dBm 是模块在 66 °C 下的真实读数；用户之前看到的 3.42 dBm 是更低
  温度下的同一路读数。原厂固件的 -4~-6 dBm 是 ISP 功率档位把激光压低了，
  和这个 -40 的“测不到”不是一回事（见 `docs/xg-040g-tx-power-ddmi.md` §四）。
