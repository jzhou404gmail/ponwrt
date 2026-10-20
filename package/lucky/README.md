# lucky（随仓库 vendored）

- 上游：<https://github.com/sirpdboy/luci-app-lucky> @ `31f068051de9798c0fb8f3e1d8e32310b4063e5d`
- 版本：幸运核心 `lucky` 2.27.2，界面 `luci-app-lucky` 3.0.3

## 相对上游的改动

1. **构建可复现**：上游用 `PKG_HASH:=skip` 加 `Build/Prepare` 里一句裸
   `wget`，每次构建都取 GitHub 当天给的二进制、且不校验，而这个二进制以
   root 跑在路由器上。这里改成框架管理的下载（`PKG_SOURCE_URL` +
   固定 `PKG_HASH`），并显式从 `DL_DIR` 解压——默认 `Build/Prepare` 在这个
   包上会被跳过（`PKG_SOURCE` 由 `LUCKY_ARCH` 拼出，`PKG_UNPACK` 判空），
   症状是 build_dir 里只有 stamp、随后 `install: cannot stat .../lucky`。

   固定哈希是 **arm64** 的实测值。本仓库只编 aarch64；若将来为别的架构构建，
   必须补上对应架构的哈希，否则会在下载校验处直接失败（比静默装上未校验的
   二进制好）。

2. **翻译包版本**：`PKG_PO_VERSION` 固定成应用版本。上游没有这个设置，
   而该包不在 luci feed 里，`findrev` 取不到 git 历史，`luci-i18n-lucky-zh-cn`
   会被打成版本 `0`，翻译更新永远无法作为升级安装。与
   `package/luci-app-airoha-npu` 的处理一致。

3. **可执行位**：`root/etc/uci-defaults/luci-app-lucky` 与
   `root/usr/share/rpcd/ucode/luci.lucky` 在上游检出里是 0664，这里改成 0755。

## 占用

`/usr/bin/lucky` 约 8.9 MB。本项目所有机型都是 256 MB NAND，放得下；
新增小 flash 机型时需重新评估。
