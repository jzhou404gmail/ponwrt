# luci-app-mesh-conf（随仓库 vendored）

- 上游：<https://github.com/naoki66/luci-app-airoha> @ `323539cf229bce52754fbb318135c9c56c514d2f`
- 版本：0.3.0-r1

界面：原生 802.11s 无线 mesh，或走 LAN 的有线同步（L2 邻居发现 + 在共享密钥
后 push/pull `/etc/config/wireless`），配一键 802.11k/v/r 漫游、DAWN 客户端
引导，以及「本机 + 对端」统一的 AP/客户端视图。

## 相对上游的改动

1. **wpad 变体**：上游依赖 `+wpad-mesh-mbedtls`，本仓库整棵树用 openssl
   （`wpad-openssl`），所以改成 `+wpad-mesh-openssl`，避免同一镜像里出现两套
   TLS 栈。mesh 变体在 hostapd 里按 `CONFIG_VARIANT=full` 编译
   （`package/network/services/hostapd/Makefile` 的 `LOCAL_VARIANT=mesh`），
   802.11ax/ac 与 k/v/r 都不丢，换过去只是多出 802.11s。

2. **翻译包版本**：`PKG_PO_VERSION` 固定成应用版本，理由同
   `package/lucky/README.md`（`findrev` 在 feed 外的包里取不到 git 历史，
   否则 `luci-i18n-mesh-conf-zh-cn` 的版本会是 `0`）。

3. **安装范围**：只随带无线的机型走（`an7581.mk` 的
   `fiberhome_hg5585f-common` 与 `znxt_zn515xg-d` 的 `DEVICE_PACKAGES`），
   无无线的 PON 机型不装。同时把这两处的 `wpad-openssl` 换成
   `wpad-mesh-openssl`。

## 运行时

服务 `meshconf` 只在 `meshconf.sync.enabled=1` 时启动两个 procd 实例：
`meshconf-beacon`（L2 发现）和一个专用 `uhttpd`（同步端口，默认 7761）。
同步端口只在 LAN 侧，且 `/etc/config/wireless` 的推拉要共享密钥。

上游的告警值得记住：这个包历史上两次因为 rpcd 插件带 CR 或缺少可执行位而
整个不可用（`-32000 Object not found`），所以它的 `Makefile` 会自校验安装
后的可执行位，`init.d` 启动时还会自愈一次。
