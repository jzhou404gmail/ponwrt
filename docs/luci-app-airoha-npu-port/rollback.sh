#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# ============================================================================
# 一键回退 luci-app-airoha-npu 移植 —— 把工作区还原到「移植前」状态
#
# 用法：
#   ./docs/luci-app-airoha-npu-port/rollback.sh          # 回退
#   ./docs/luci-app-airoha-npu-port/rollback.sh --dry-run # 只看会做什么
#
# 工作区改动一共五处（可用 `diff` 自行核对）：
#   1. 新增目录  package/luci-app-airoha-npu/            （11 个文件）
#   2. .config                        + 3 行（含 1 行 "is not set" 注释）
#   3. configs/release.config         + 1 行
#   4. target/linux/airoha/an7581/base-files/etc/board.d/01_leds
#      （2.5G PHY 的 LED 触发：新增 znxt case，给 nokia/unionman 补 lan1 那行）
#   5. target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch
#      （给 NPU 加 fw_version / num_cores sysfs 属性，新增文件）
# 本脚本按备份精确还原 2、3、4，并删除 1、5 及由此产生的编译产物。
#
# 注意：不会删除 bin/targets 下已生成的固件（.itb）。
# ============================================================================

set -e

DRY=0
[ "$1" = "--dry-run" ] && DRY=1

TOPDIR=$(cd "$(dirname "$0")/../.." && pwd)
BACKUP="$TOPDIR/docs/luci-app-airoha-npu-port"
LEDS="$TOPDIR/target/linux/airoha/an7581/base-files/etc/board.d/01_leds"
cd "$TOPDIR"

run() {
	if [ "$DRY" = 1 ]; then
		echo "   [dry-run] $*"
	else
		"$@"
	fi
}

[ -f "$BACKUP/config.before" ] || { echo "错误：缺少 $BACKUP/config.before" >&2; exit 1; }
[ -f "$BACKUP/release.config.before" ] || { echo "错误：缺少 $BACKUP/release.config.before" >&2; exit 1; }
[ -f "$BACKUP/01_leds.before" ] || { echo "错误：缺少 $BACKUP/01_leds.before" >&2; exit 1; }

echo "==> 1/6 删除软件包目录"
run rm -rf "$TOPDIR/package/luci-app-airoha-npu"

echo "==> 2/6 还原配置（.config / configs/release.config）"
run cp -a "$BACKUP/config.before" "$TOPDIR/.config"
run cp -a "$BACKUP/release.config.before" "$TOPDIR/configs/release.config"

echo "==> 3/6 还原 LED 板级配置（01_leds）"
if [ -f "$LEDS" ]; then
	run cp -a "$BACKUP/01_leds.before" "$LEDS"
else
	echo "     跳过：$LEDS 不存在"
fi

echo "==> 4/6 删除 NPU fw_version sysfs 补丁"
for f in "$TOPDIR"/target/linux/airoha/patches-6.18/950-npu-expose-fw-version-sysfs.patch; do
	[ -e "$f" ] || continue
	run rm -f "$f"
done

echo "==> 5/6 清理编译产物"
for f in "$TOPDIR"/bin/packages/*/base/luci-app-airoha-npu-*.apk \
         "$TOPDIR"/bin/packages/*/base/luci-i18n-airoha-npu-*.apk \
         "$TOPDIR"/staging_dir/*/pkginfo/luci-app-airoha-npu.default.install \
         "$TOPDIR"/staging_dir/*/pkginfo/luci-i18n-airoha-npu-zh-cn.default.install \
         "$TOPDIR"/staging_dir/*/stamp/.luci-app-airoha-npu_installed \
         "$TOPDIR"/staging_dir/*/stamp/.luci-i18n-airoha-npu-zh-cn_installed; do
	[ -e "$f" ] || continue
	run rm -f "$f"
done
for d in "$TOPDIR"/build_dir/*/luci-app-airoha-npu; do
	[ -d "$d" ] || continue
	run rm -rf "$d"
done
for r in "$TOPDIR"/staging_dir/*/root-*; do
	[ -d "$r" ] || continue
	run rm -rf "$r/www/luci-static/resources/view/airoha_npu"
	run rm -f "$r/usr/libexec/rpcd/luci.airoha_npu" \
	          "$r/usr/bin/ppe-verify" \
	          "$r/usr/share/luci/menu.d/luci-app-airoha-npu.json" \
	          "$r/usr/share/rpcd/acl.d/luci-app-airoha-npu.json" \
	          "$r/usr/lib/lua/luci/i18n/luci-app-airoha-npu.zh-cn.lmo"
done

echo "==> 6/6 回退完成"
if [ "$DRY" = 1 ]; then
	echo "     （dry-run，未做任何修改）"
else
	echo "     残留检查（应无输出）:"
	ls -d package/luci-app-airoha-npu 2>/dev/null || true
	grep -n "luci-app-airoha-npu" .config configs/release.config 2>/dev/null || true
	ls target/linux/airoha/patches-6.18/950-* 2>/dev/null || true
	diff -q "$BACKUP/01_leds.before" "$LEDS" >/dev/null 2>&1 && echo "     (01_leds 已还原)" || true
	echo "     重新编译： ./build.sh"
fi
