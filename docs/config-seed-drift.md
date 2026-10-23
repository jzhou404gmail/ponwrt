# 配置种子漂移：an7583 只剩 275 个包的复盘与防复发

> 2026-10-23。`./build.sh --config=an7583` 编出来的镜像只有 245 个包，
> 而同一棵树里 7581 的 `.config` 是 454 个包 —— 少掉的是 passwall、samba4、
> NFS、diskman、ddns、ttyd、netdata、collectd 这一整批通用应用。
> 这不是某个包坏了，而是 `configs/an7583.config` 这个**种子**本身退化了。

## 一、两套配置，两个入口

这个树里有两个不同的配置输入：

| 入口 | 读的是哪个文件 | 用途 |
|---|---|---|
| `./build.sh` | 当前 `.config` | 日常增量编译；配置是手调出来的完整集合 |
| `./build.sh --config=<target>` | `configs/<target>.config` + `configs/release.config` | 从种子可复现地重建 `.config` |

两者本来就应该描述**同一套发布包**，只是后者要能脱离本机 `.config` 重建。
一旦只维护 `.config`、不刷新种子，两个入口就会开始分叉，而且分叉是静默的：

* 平时都用 `./build.sh`，完整的 `.config` 一直正常；
* 某天用 `--config=an7583`，种子还停在几个月前的最小基线，
  编出来的镜像就少一大半应用，但**编译过程 0 报错**。

## 二、根因

1. **种子没有随功能增长而刷新。**
   `configs/an7583.config` 长期停留在早期的最小包集（226 个 `=y`，
   defconfig 后 275 个）。`51cc83c4bd` 刷新过 an7581 的种子，但提交信息里
   明确写了 an7583 "otherwise untouched"；后面的回滚/ONU 切换又让它继续
   停在旧基线。7581 的 454 个包只存在于本机 `.config`，从未回流到种子。

2. **旧的掉包保护只做相对比较，防不住"种子一开始就是小的"。**
   `build.sh` 原来只检查 `after < seed_before × 0.8`。
   275 个包的种子 defconfig 后还是 275，275 > 275×0.8，永远通过。
   它保护的是"这次套种子时被 defconfig 缩水"，不是"种子是否完整"。

3. **没有跨 target 的对比。**
   7581 和 7583 的通用应用集应该一致，只允许硬件相关包不同；
   但没有任何检查去比较两个种子。一个种子掉 100 个通用包，另一个不会报错。

4. **手调 `.config` 没有回流种子的固定流程。**
   装一个插件、试一个功能，改的都是 `.config`；种子是否同步，全靠人记得。
   这次不是第一次，根因就是这条流程缺失。

## 三、修复

### 3.1 两个种子都恢复为完整配置

| 种子 | 修复前 | 修复后 |
|---|---|---|
| `configs/an7581.config` | 223 `=y`（defconfig 后 268） | **454 `=y` / 14 `=m`** |
| `configs/an7583.config` | 226 `=y`（defconfig 后 275） | **443 `=y` / 7 `=m`** |

7583 的种子以 7581 的完整 `.config` 为基准，去掉 20 个 7581 专用/WiFi 包，
补上 9 个 7583 专用包（EIP-93/cryptodev/OpenSSL engine、an7583 NPU 固件、
an7583 BL2/BL31/U-Boot）。两边共有 434 个包，硬件差异只在白名单里：

* **仅 7581**：MT7916/WiFi 用户态、`kmod-airoha-paged-bosa`、an7581 NPU 固件、
  an7581 BL2/BL31/U-Boot，以及 7583 已内建的 `kmod-thermal`/`kmod-usb-xhci-mtk`。
* **仅 7583**：`airoha-an7583-npu-firmware`、`kmod-crypto-hw-eip93`、
  `kmod-cryptodev`、`kmod-crypto-des/md5`、`libopenssl-devcrypto`、
  an7583 BL2/BL31/U-Boot。

### 3.2 新增 `scripts/check-config-seeds.sh`

它检查的是**种子本身**，而不是 `.config`（用户可能有意做一个精简 `.config`，
但发布种子不能）：

* 两个种子都必须有 **>= 400 个 `CONFIG_PACKAGE_*=y`**；
* `CONFIG_TARGET_MULTI_PROFILE=y`、`CONFIG_TARGET_PER_DEVICE_ROOTFS=y`；
* 每个 SoC 的关键包齐全：
  * 7581：an7581 NPU 固件、paged BOSA、MT7916、EN8811H、USB、block-mount、
    WiFi 历史/计划三个包；
  * 7583：an7583 NPU 固件、**EIP-93 + cryptodev + libopenssl-devcrypto**、
    EN8811H、USB、block-mount、PON/IPTV；
* 硬件包不串：7583 不能有 WiFi/7581 专用包，7581 不能有 EIP-93/an7583 固件；
* 只选 UBI 机型（7583 不允许再选非 UBI 的 `nokia_xg-040g-mf`）；
* **跨种子白名单对比**：凡是在一个种子里 `=y`、在另一个里没有的包，
  必须出现在脚本顶部的 `ONLY_7581` / `ONLY_7583` 硬件白名单里。
  这条能抓住"某个通用应用只从一边被删掉、但总数仍大于 400"的情况。

### 3.3 `build.sh` 接入

* `./build.sh --config=<target>`：**先跑种子自检，不通过就不动 `.config`、
  直接中止**。不会再出现"种子是小的，照样编完"。
* `defconfig` 后的掉包保护增加**绝对下限**（默认 400），
  和原来的 80% 相对保护同时生效。
* 普通 `./build.sh`：如果当前 `.config` 少于 400 个包，打印警告但不拦截
  （可能是有意精简）。
* 新增 `./build.sh --check-seeds`：只检查、不编译。

## 四、7583 硬件 AES 的核对

AN7583 的 Cortex-A53 带 ARMv8 Crypto Extensions；这部分在
`target/linux/airoha/an7583/config-6.18`，不在 `.config` 种子里：

```
CONFIG_CRYPTO_AES_ARM64=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_AES_ARM64_CE_BLK=y
CONFIG_CRYPTO_AES_ARM64_CE_CCM=y
CONFIG_CRYPTO_GHASH_ARM64_CE=y
CONFIG_CRYPTO_DEV_EIP93=m
CONFIG_CRYPTO_HW=y
CONFIG_CRYPTO_USER_API_{SKCIPHER,HASH,AEAD}=y
```

用户态和 EIP-93 驱动则必须由种子带进镜像，新种子已包含：

```
CONFIG_PACKAGE_kmod-crypto-hw-eip93=y
CONFIG_PACKAGE_kmod-cryptodev=y
CONFIG_PACKAGE_libopenssl-devcrypto=y
```

之前的固件也确实包含它们：`bin/targets/airoha/an7583/` 里 2026-10-23 19:09
那次构建（还是旧种子）的 manifest 仍有 `kmod-crypto-hw-eip93`、
`kmod-cryptodev`、`libopenssl-devcrypto`、`kmod-crypto-des/md5`；
2026-10-21 的镜像也同样有。所以"硬件 AES 没编进去"不是这次的问题，
**缺的是通用应用集**。反过来说，7581 没有 ARMv8 CE，EIP-93 这一组只属于
7583；新加的白名单/负向检查会阻止它误进 7581。

## 五、以后怎么维护

1. 改完 `.config`、确认这套包要进发布版后，刷新对应种子：

   ```sh
   # 当前 .config 就是该 target 的完整配置时
   cp .config configs/an7581.config     # 或 an7583
   ./build.sh --check-seeds
   ```

2. 新增/删除硬件相关包时，同步更新
   `scripts/check-config-seeds.sh` 顶部的 `ONLY_7581` / `ONLY_7583`
   和 `check_7581` / `check_7583` 里的关键包列表。

3. 每次正式出包前跑一次：

   ```sh
   ./build.sh --check-seeds
   ```

4. 看到 `!! 配置种子自检失败` 时不要绕过，也不要用 `MIN_PACKAGES=0`
   糊过去——那只是查看数量，不是修复。

## 六、快速验证

```sh
./build.sh --check-seeds
# 期望：
#   configs/an7581.config: 454 =y packages
#   configs/an7583.config: 443 =y packages
#   配置种子自检通过

# 模拟一次漂移：把下限抬高，确认会失败
MIN_PACKAGES=455 ./scripts/check-config-seeds.sh   # 应返回 1
```
