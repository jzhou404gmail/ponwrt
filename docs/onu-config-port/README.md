# 需求二：PON 用户态换成 OpenWrt_ONU_CONFIG

提交：`986d4b1bf7`（分支 `exp/onu-config`，基于 `exp/7581-luci-apps` 的 P1–P3）

## 一、改了什么

| # | 改动 | 文件 |
|---|---|---|
| 1 | PON feed 由 `pbs05/openwrt-pon-userspace` 换成 `naoki66/OpenWrt_ONU_CONFIG` | `feeds.conf.default` |
| 2 | 引入上游的 fw4 卸载补丁 | `package/network/config/firewall4/patches/010-fw4-zone-device-flowtable.patch` |
| 3 | 种子配置里打开新界面 | `configs/release.config` |

包层面的效果：`luci-app-pon` + `luci-app-iptv` 消失，换成 `luci-app-onu`（七页：
状态 / 硬件身份 / 认证 / 上网 / IPTV / 语音 / 诊断）；`airoha-ponctl`、
`airoha-pon-daemons`、`airoha-pon-debug` 三个包名不变、内容换成上游重构版。

## 二、为什么不是"加一个包"

上游 fork 的分叉点正是本仓库原先 pin 的 `cce9d75`，之后把两个界面包合并重写，
并把三个底层包也一起改了 —— 包名相同、内容不同，因此**两个 feed 不能共存**。
切换时必须先把旧 feed 的包链接挪开：

```sh
mv package/feeds/pon_userspace tmp/feeds-off/pon_userspace
```

## 三、关键收益：OMCI 认证模式

旧的 OMCI 代理只有 LOID 一条路：没有 LOID 的线路上也会上报 CTC LOID ME，
运营商侧判定身份不一致，表现为 password-only 线路 **O5 反复掉线**。新版把它
改成显式的 `auth_mode`（`loid` / `password`）：

- 配置里没有 `auth_mode` 的老配置不会失效 —— 代码按"身上带了哪个凭据"推断，
  LOID 就是 LOID 认证，只有 registration-ID 的就走密码认证；
- `/etc/config/pon` 的读写位置没变，所以**刷机后原有的 LOID/密码不会丢**。

## 四、刷机后要注意的

| 项 | 说明 |
|---|---|
| 认证 | 沿用 `/etc/config/pon`，无需重配 |
| 上网 | 新文件 `/etc/config/onu-internet`，默认 `enabled '0'`，**首次开机不会改写现有 WAN 配置**；要用新页面管理再打开 |
| IPTV | 新文件 `/etc/config/onu-iptv`，旧 `/etc/config/iptv` 成为孤儿，需要在 ONU → IPTV 页重新配一次 |
| 语音 | 新文件 `/etc/config/onu-voice`，同样默认关闭 |
| 旧菜单 | 网络 → PON / IPTV 消失，换到顶级 ONU 菜单 |

## 五、语音这次做到哪

- **做了**：界面（三种投递方式 route/bridge/trunk、线路与 Codec 参数）与
  `voice-apply`（只写 network + firewall 的 VLAN 投递）。
- **没做**：SIP/H.248 协议栈（`asterisk` + `asterisk-chan-en75xx` +
  `airoha-voice-ctl`）与 FXS 硬件（Si32192 ProSLIC）的 DTS 节点与 PCM/ISI-SPI
  驱动。这几块在 Gemtek 分支里是
  `package/kernel/airoha-voice/patches/010-add-en1581-xg2010g-support.patch` 与
  `package/network/services/asterisk-chan-en75xx`，等硬件/SDK 资料到位再接。

## 六、本地资产的处理

| 资产 | 处理 |
|---|---|
| `package/base-files/files/usr/libexec/iptv-stb-fix`、`iptv-stb-watchdog`、`hotplug.d/iface/99-iptv-mc-nolearn` | **原样保留**：新版脚本建的设备名与旧版一致（`br-iptv`、`ct-iptv-mc`、`ct-iptv-svc`），MAC 学习修复继续有效 |
| 顶层 `files/usr/libexec/iptv-apply`（本地覆盖层，**未入库**） | **不再需要**：新版脚本自己从页面读中继地址并写成 `proto=static`，不再依赖"保留用户手改的 ipaddr" |

> 顺便纠正一处：顶层的 `files/` 被 `.gitignore` 的 `/files` 忽略，所以它不是
> "已入库的覆盖层"。它只存在于原树目录与备份的 `02-build-inputs.tar.gz` 里，
> 一次 `git clean -xdf` 就会静默消失。

## 七、回退

```sh
# 1) feed 换回上游
git checkout master -- feeds.conf.default
sed -i 's|^src-git onu_config .*|src-git pon_userspace https://github.com/pbs05/openwrt-pon-userspace.git|' feeds.conf.default
./scripts/feeds update pon_userspace && ./scripts/feeds install -a -p pon_userspace
# 2) 移除新 feed 的包链接，恢复旧链接
rm -rf package/feeds/onu_config
mv tmp/feeds-off/pon_userspace package/feeds/pon_userspace
# 3) 配置回退
make defconfig     # luci-app-onu 的符号会随 feed 一起消失
git checkout master -- configs/release.config
```

## 八、本次验证（未上机）

在 `fiberhome_hg5585f-cu` 的 squashfs 镜像里逐项核对：

```
/www/luci-static/resources/view/onu/    7 页 + onu.css
/etc/config/                              onu-internet / onu-iptv / onu-voice
/etc/init.d/                              internet / iptv / voice
/usr/share/luci/menu.d/                   只有 luci-app-onu.json（旧 pon/iptv 已消失）
/usr/share/ucode/fw4.uc                   含 zone_offload_devices（补丁已生效）
/usr/sbin/airoha-pond                     含 auth_mode 相关字符串（新 daemons）
```

## 九、已知遗留

1. `bin/targets/airoha/an7581/` 里另外 10 个机型仍是 P3 的旧镜像（没有 ONU）。
   要出全量固件请把机型全部选回再编一次。
2. `configs/an7581.config` 仍只有 206 个包（真实 457），`--config=an7581`
   会编出瘦身固件，被 `build.sh` 的掉包保护拦下。
3. 独立构建树 `../ponwrt-onu` 已完成工具链与 120 个包，本轮改走原树后未再用它。

## 十、HG5585F-CU 实机升级记录（2026-10-20）

从 `r41558+49-a57faf93c6`（旧 PON 界面）原地升级到 `r0+41615-67dd607e38`
（本分支），保留配置，结果逐项核对如下。

### 结论：光路与 IPTV 均无回归

| 项 | 结果 |
|---|---|
| 板型 | `fiberhome,hg5585f-cu`（镜像 `supported_devices` 与之一致）|
| 光路 | `active_mode=epon-10g-1g`、`lifecycle=operational`、`pcs_sync=1`、`rx_active=1` |
| PON 序列号 | UCI 未设 → 走板级身份（新 `pon.init` 的 board identity 回退逻辑）|
| PPPoE | 重新拨号成功，拿到公网地址 |
| IPTV 桥 | `br-iptv` UP，`172.16.200.1/24`（与升级前一致）|
| VLAN | `ct-iptv-svc`(3964) 与 `ct-iptv-mc`(4000) 都在桥里 |
| nft 过滤 | `table bridge iptv` 已由 fw4 include 加载 |
| 组播代理 | omcproxy 运行，命令行 `omcproxy br-iptv,br-lan,scope=global` |
| 单播中继 | udpxy 监听 4022，`/status` 返回 200，source=172.16.200.1 |
| STB 修复 | `ct-iptv-mc` 的 `learning off` 生效，`iptv-stb` 服务 running |
| 界面 | 仅 `luci-app-onu.json`；`/www/.../view/onu/` 七页 + onu.css |

### 一个必须记住的细节：段名没有改

新脚本的 `br_iptv` / `br_iptv_mc` 是 **trunk 模式**用的接口名；**bridge 模式
沿用旧名字**：

```
network.luci_iptv_bridge      网桥设备 br-iptv，ports = lan2 + ct-iptv-svc + ct-iptv-mc
network.luci_iptv             接口（static，172.16.200.1/24）
network.luci_iptv_service_vlan   8021q pon0 vid 3964 name ct-iptv-svc
network.luci_iptv_multicast_vlan 8021q pon0 vid 4000 name ct-iptv-mc
firewall.luci_iptv            nftables include → /etc/iptv.nft
```

`remove_managed_network()` 会先把 `luci_iptv*` 删掉再用同样的名字重建，所以
升级前后网段名、接口名、omcproxy 的 uplink 都不用改。**omcproxy 的 uplink
必须保持 `luci_iptv`**；写成 `br_iptv` 会让 omcproxy 起不来（"active with no
instances"）—— 本次升级第一版就是踩了这个坑，已修正。

### 升级时做过的一次性迁移

只做两件事，写在 `/etc/uci-defaults/99-onu-migrate` 里（带界面存在性守卫，
旧固件上不会误执行），并登记到 `/etc/sysupgrade.conf` 以便跨升级保留：

1. 删掉旧防火墙段 `firewall.iptv` / `firewall.iptv2lan` / `firewall.luci_iptv`。
   旧区域引用的 `network.luci_iptv` 会被新脚本重建，但区域本身要删 —— 否则
   新脚本再建一个同样叫 `iptv` 的区域，两个同名 zone 会让 fw4 拒绝加载，
   连带丢掉 NAT。
2. 修正 omcproxy uplink（本次写错，正确值是 `luci_iptv`）。

sysupgrade 保留 `/etc/config`，所以升级后 `/etc/config/iptv` 成为孤儿文件，
可以删；新的 IPTV 配置来自 `/etc/config/onu-iptv`。
