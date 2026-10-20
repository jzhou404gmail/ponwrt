# luci-app-airoha-npu（上游 2.0.0，随仓库 vendored）

- 上游：<https://github.com/naoki66/luci-app-airoha> @ `323539cf229bce52754fbb318135c9c56c514d2f`
- 版本：2.0.0-r9

Airoha AN7581 / AN7583 的 SoC/NPU 状态页：CPU（频率/调频/温度）、Frame Engine
（GDM/CDM/PSE 计数器）、PPE 硬件卸载（flow 表、命中率、绑定数）、以太网拓扑、
以及按机型显示的 WiFi 状态。

## 为什么整包换成上游 2.0.0

本仓库原先放的是 1.1.4 的 PonWrt 移植版（`package/luci-app-airoha-npu` 1.2.0），
当时为了适配"WAN 走 PON 而非 EN8811 2.5G"改了不少地方：从活体设备树解析
GDM→netdev、加 CDM1/CDM2 卡片等。

上游 2.0.0 已经把这些做进去了，而且做得更彻底：

- WAN 从 `ubus call network.interface.wan status` 取，不认网卡名 —— PON 上
  `wan` 接口就是 `pon0`，天然适配；
- GDM 寄存器块按设备树的 `ethernet@N` 索引解析，不硬编码；
- 有 **CDM Engines** 卡片（1.2.0 里是手工加的 CDM1/CDM2）。

所以继续保持本地分支的代价大于收益：界面越走越远，还得自己维护。换成上游后
界面与上游 100% 一致。

## 相对上游的改动（只有两处）

1. `menu.d` 的标题由 `Airoha Soc` 改成 `Airoha SoC`（大小写；菜单路径沿用上游的
   `admin/status/airoha`）。
2. 加 `PKG_PO_VERSION`：本包不在 luci feed 里，`findrev` 取不到 git 历史，
   `luci-i18n-airoha-npu-zh-cn` 会被打成版本 0，翻译更新永远无法作为升级安装。
   与 `package/lucky`、`package/luci-app-mesh-conf` 同样处理。

## 运行时前提（镜像里已满足）

Frame Engine 那一段直接读物理内存窗口，需要 kernel 与 busybox 两半都开：

```
CONFIG_KERNEL_DEVMEM=y
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_DEVMEM=y
```

缺任一半，该块在运行时退化成 "devmem applet ... unavailable"。

## 设备树补丁

`target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch` 给 NPU
暴露 `fw_version` / `num_cores`，让版本号不必从 dmesg 抓（dmesg 刷掉后显示
Unknown）。上游 RPC 本来就是"先读 sysfs、读不到再退回 dmesg"，所以 app 侧零改动。
