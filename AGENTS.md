# AGENTS.md — PonWrt fork 的仓库原则

本文件是这个 fork 的最高优先级工作约定，适用于所有人和所有 agent。
[README.zh-CN.md](README.zh-CN.md) 记录“改了什么、为什么、怎么验证”；本文件只回答
**什么能进仓库、什么必须只留在本机**。

## 0. 第一原则：自有内容只留本地

> **凡是与“本人 / 本机 / 本人设备与网络”有关、但不属于可公开上游代码的内容，
> 一律只保存在本机：不 `git add`、不 commit、不 push、不上传 Release/Actions、
> 不贴进 issue / PR / 评论。**

“自有”包括但不限于：

| 类别 | 典型内容 |
|---|---|
| 自有基础设施 | 自有服务器的公网 IPv4/IPv6、域名、端口、VPS/机房/线路信息、代理节点链接 |
| 凭据 | 密码、Wi-Fi PSK、PPPoE/宽带账号、API token、Cloudflare token、SSH/签名私钥、证书私钥 |
| 设备身份 | PON SN、LOID、设备 MAC、原厂 factory/校准数据、分区与固件备份 |
| 个人资料 | 真实姓名、住址、电话、邮箱、家庭或单位网络拓扑、VLAN/IPTV 账号 |
| 本机状态 | 本机 `.config` 及备份、构建产物、日志、ccache、下载缓存、绝对路径、主机名 |
| 非公开资料 | 厂商 SDK/文档、闭源二进制、未获授权再分发的内容 |
| 过程记录 | 本地笔记、排障记录、实验计划、待办、抓包与寄存器 dump |

可以入库的：上游代码、可公开的修复与补丁、构建工具、`configs/` 种子、**已脱敏**的说明。
公开的*默认/示例*值（例如默认 Wi-Fi 初始密钥 `12345678`）不算自有；真实在用的密码才算。
注意：**本 fork 自己写的、可以公开的修复不属于“自有”**，照常提交；“自有”指带个人、
本机、设备身份或凭据属性的内容。

### 0.1 本地专属路径

以下路径已被 `.gitignore` 拒绝，**不要用 `git add -f` 强行加入**：

```text
docs/                 本地笔记、排障记录、实验计划（含设备身份/内网信息）
local/                新增自有脚本、配置、资料的首选位置
notes/  secrets/      其它本地记录与凭据
原厂备份/             原厂固件、分区、factory 数据
Airoha/               厂商资料与 SDK 拷贝
release/  bin/  logs/  build_dir/  staging_dir/  tmp/  dl/  feeds/
.config  .config.*  version
private-key.pem  public-key.pem
clone-sda/  shutdown-analyze.sh
scripts/cf-set-aaaa.sh   自有域名/IP 与 Cloudflare 操作
```

需要新增本地文件时，优先放进 `local/` 或 `docs/`，不要临时塞进 `scripts/`、`package/`
这类会被整体提交的目录。`files/` 是本机 overlay，同样只留本地。

### 0.2 提交与推送前的硬闸门

```sh
git status --short                          # 先看清改了什么
git add <明确路径>                          # 禁止 git add -A / git add .
./scripts/check-local-only.sh --staged      # 暂存区检查
git commit
./scripts/check-local-only.sh --all         # 推送前全树审计
git push
```

- **永远不用 `git add -A`、`git add .`、`git commit -a`**：这棵树里本机文件太多，
  它们等于把本地内容往仓库里扫。
- 不确定某个文件算不算“自有” → 按“算”处理，留在本地。
- 本机敏感字面量表在 `.git/info/local-denylist`（一行一个字面量，**不提交、不复制**）；
  `scripts/check-local-only.sh` 会用它拦截自有域名/IP/密码等。没有这张表时，
  私钥/token 等通用特征和路径规则仍然生效。
- 仓库自带 `.githooks/`。本仓库启用一次即可：

  ```sh
  ./scripts/check-local-only.sh --install-hooks
  ```

  `pre-commit` 检查暂存区，`pre-push` 检查整棵树和待推提交。
  **不要用 `--no-verify` 绕过**；绕过一次，闸门就形同虚设。

### 0.3 如果不小心已经提交 / 推送

1. **还没 push**：`git restore --staged <path>` 取消暂存，或 `git reset --soft HEAD~1`
   撤回提交；确认文件回到本地专属路径后再重来。
2. **已经 push**：按“凭据已泄露”处理 —— 先撤销/轮换密码、token、密钥，再评估是否
   需要清史（`git filter-repo`）并 force-push。**只 revert 不会把历史里的内容删掉。**
3. 清史 / force-push 前先备份，并确认没有别人正在基于这条分支工作。

## 1. 分支与推送

- 只保留一条主线 `master`（上游 `pbs05/ponwrt` + 本 fork 的全部改动），编译一律用它。
- `pr/*` 只是给上游提 PR 的提交快照，不是第二条主线；PR 合并后即可删除。
- `branch.master.pushRemote=fork`：站在 `master` 上 `git push` 推的是
  `jzhou404gmail/ponwrt`，不会误推到上游。细节见 README.zh-CN.md §5.2。

## 2. 发布

- 代码覆盖 12 款 AN7581 机型，但发布只出白名单里的 6 款（不带 SFP）+ AN7583 的 UBI 一款；
  白名单在 `scripts/check-config-seeds.sh` 的 `BUILD_7581_DEVICES`，策略见
  [docs/build-models-policy.md](docs/build-models-policy.md)。
- 发布只使用 `configs/` 里的项目种子（CI 也如此），**不使用任何人的本机 `.config`**。
- 本地 `release/` 里的镜像可能带本机 overlay 或默认值，默认只留本地；要发布就走
  GitHub Actions（`.github/workflows/release.yml`）。

## 3. 构建

- `build.sh` 默认**只做加法**：不传额外 make 变量、不改 `.config`；只有显式 `--config=`
  才重建，并先跑 `scripts/check-config-seeds.sh`。
- 改 feed 里的上游代码必须落到 `feed-patches/`（`feeds/` 不入库），由 `apply.sh` 幂等套用。
- 编译成功不等于能刷：`verify-images.sh` 必须过；不要发布没过闸的镜像。

## 4. 改动与验证习惯

- 先读代码/文档再改；diff 尽量小；不顺手格式化无关文件，不动与任务无关的本地改动。
- 提交信息写清“现象 → 根因 → 修法 → 验证”，与现有历史保持一致。
- 改完至少跑与改动直接相关的检查；不能声称没跑过的验证通过。

## 5. 自查清单（每个任务结束前）

```sh
git status --short
git diff --check
./scripts/check-local-only.sh --all
```

再人工确认一遍：`docs/`、`local/`、`.config*`、`原厂备份/`、`Airoha/`、`release/`、
私钥、本机 `.config` 备份都没有被加入版本控制。
