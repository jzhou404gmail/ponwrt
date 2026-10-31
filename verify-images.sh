#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# verify-images.sh —— 刷机前的最后一道闸：把生成的 .itb 逐个体检一遍。
#
# 为什么需要它（真实事故，2026-10-16）：
#   内核构建树被一次**被中断的构建**留在了 initramfs 配置上
#   （build_dir/.../linux-<board>/linux-*/.config 里 CONFIG_INITRAMFS_SOURCE 还在，
#   且 CONFIG_INITRAMFS_COMPRESSION_NONE=y）。下一次增量构建里"普通内核"那一步
#   认为产物是最新的，直接把已经变成 **initramfs 内核**的 arch/arm64/boot/Image
#   拷成 $(KERNEL_BUILD_DIR)/Image —— 于是 sysupgrade 镜像里塞进了 194 MB 的
#   "内核"（内含整个 rootfs 的 180 MB cpio），gzip 后 71 MB，整个 .itb 从 58 MB
#   涨到 117 MB。U-Boot 侧表现：
#       Uncompressing Kernel Image to 8a000000
#       Error: inflate() returned -5
#       Image too large: increase CONFIG_SYS_BOOTM_LEN
#       Must RESET board to recover
#   也就是"刷进去就无限重启"。
#
# 这个脚本就是针对那一类"能编译出来但根本不能刷"的产物做的体检，任何一条不过就
# 退出非 0，并在 build.sh 里让整次构建判为失败（不再打印"构建完成"）。
#
# 检查项（每个 *-squashfs-sysupgrade.itb / *-initramfs-recovery.itb）：
#   1. FIT 结构能解析，且能取出 kernel / rootfs 两个子镜像
#   2. 总大小在合理区间（sysupgrade 默认 ≤ 95 MB，recovery 默认 ≤ 70 MB）
#   3. sysupgrade 的 kernel：gzip 能解开；**解出来的内容里不许有 cpio 归档**
#      （cpio 魔数 070701/070702）—— 有就说明塞错了 initramfs 内核
#   4. kernel 自带的 arm64 头部 image_size 必须 ≤ 实际长度（截断检测）
#   5. kernel 解压后大小在合理区间（默认 8–80 MB）
#   6. rootfs 是 squashfs（魔数 hsqs）且大小合理（默认 ≥ 5 MB）
#   7. 同一机型：sysupgrade 的 kernel 与 recovery 的 kernel **必须是两个不同的文件**
#      （这才是本次事故的最直接指纹）
#
# 用法：
#   ./verify-images.sh                     # 校验 bin/targets 下所有产物
#   ./verify-images.sh <目录或.itb...>      # 只校验指定文件/目录
#   VERIFY_MAX_SYS_MB=95 ./verify-images.sh
#
# 退出码：0 = 全部通过；1 = 有产物不合格（不要刷机！）

set -u

# The FIT parser lives next to this script in scripts/; resolve it relative to
# this file so verification also works when called by absolute path or from a
# different working directory.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

MAX_SYS_MB=${VERIFY_MAX_SYS_MB:-95}
MAX_INIT_MB=${VERIFY_MAX_INIT_MB:-70}
MIN_ROOTFS_MB=${VERIFY_MIN_ROOTFS_MB:-5}
KERNEL_MIN_MB=${VERIFY_KERNEL_MIN_MB:-8}
KERNEL_MAX_MB=${VERIFY_KERNEL_MAX_MB:-80}

if [ "$#" -gt 0 ]; then
	targets="$*"
else
	targets="bin/targets"
fi

files=""
for t in $targets; do
	if [ -d "$t" ]; then
		files="$files $(find "$t" -name '*.itb' | sort)"
	else
		files="$files $t"
	fi
done

[ -n "$(echo $files)" ] || {
	echo "verify-images: 没找到任何 .itb（还没编译？）" >&2
	exit 1
}

fail=0
kernelfail=0

for f in $files; do
	[ -f "$f" ] || continue
	size=$(stat -c %s "$f")
	mb=$((size / 1024 / 1024))

	case "$f" in
	*-squashfs-sysupgrade.itb) kind=sys; limit=$MAX_SYS_MB ;;
	*-initramfs-recovery.itb) kind=init; limit=$MAX_INIT_MB ;;
	*) kind=other; limit=$MAX_SYS_MB ;;
	esac

	printf '== %s (%s MiB, %s)\n' "${f##*/}" "$mb" "$kind"

	# 1) 总大小
	if [ "$mb" -gt "$limit" ]; then
		printf '   !! 体积异常：%s MiB > %s MiB（正常 sysupgrade 约 58 MiB / recovery 约 50 MiB）\n' \
			"$mb" "$limit"
		fail=1
		kernelfail=1
	fi

	# 2~6) FIT 内部体检（python3 解析 FDT + zlib 解压）
	out=$(VERIFY_KIND=$kind VERIFY_FILE="$f" \
		VERIFY_KERNEL_MIN=$((KERNEL_MIN_MB * 1024 * 1024)) \
		VERIFY_KERNEL_MAX=$((KERNEL_MAX_MB * 1024 * 1024)) \
		VERIFY_ROOTFS_MIN=$((MIN_ROOTFS_MB * 1024 * 1024)) \
		python3 "$SELF_DIR/scripts/verify-fit.py" 2>&1) || fail=1
	printf '%s\n' "$out" | sed 's/^/   /'
	# 内核相关的失败（体积/截断/cpio/内核大小）属于"可自愈"这一类
	case "$out" in
	*"cpio 归档"*|*"kernel 大小异常"*|*"image_size"*|*"kernel 不是 gzip"*) kernelfail=1 ;;
	esac
done

# 7) sysupgrade / recovery 内核必须是两个不同的文件
echo
echo "== 交叉检查：同一机型的 sysupgrade 与 recovery 内核不能是同一个文件"
for sys in $(echo $files | tr ' ' '\n' | grep -v '^$' | grep -- '-squashfs-sysupgrade\.itb$' | sort -u); do
	[ -f "$sys" ] || continue
	init=$(echo "$sys" | sed 's/-squashfs-sysupgrade\.itb$/-initramfs-recovery.itb/')
	[ -f "$init" ] || continue

	a=$(VERIFY_FILE="$sys" VERIFY_HASH_ONLY=1 python3 "$SELF_DIR/scripts/verify-fit.py" 2>/dev/null)
	b=$(VERIFY_FILE="$init" VERIFY_HASH_ONLY=1 python3 "$SELF_DIR/scripts/verify-fit.py" 2>/dev/null)
	case "$a$b" in
	*[!0-9a-f]*|"") 
		echo "   ?? ${sys##*/}：有一侧读不到内核（$a / $b），跳过"
		continue ;;
	esac
	if [ "$a" = "$b" ]; then
		printf '   !! %s：sysupgrade 与 recovery 的内核完全相同（%s）\n' "${sys##*/}" "$a"
		echo "      → 这次事故的指纹：普通内核被 initramfs 内核顶替了，刷进去必重启循环"
		fail=1
		kernelfail=1
	else
		printf '   ok %s：两侧内核不同（sys=%s init=%s）\n' "${sys##*/}" \
			"$(echo "$a" | cut -c1-12)" "$(echo "$b" | cut -c1-12)"
	fi
done

echo
if [ "$fail" -ne 0 ]; then
	cat >&2 <<'EOF'
!! 有产物没通过体检 —— 请不要刷机。

最常见原因：内核构建树被一次"被中断的构建"（Ctrl-C / 被杀 / OOM）留在了
initramfs 配置上，增量构建于是把 initramfs 内核当成普通内核打了进去。修法：

    rm -rf build_dir/target-*/linux-airoha_an7581     # 或对应的 board 目录
    ./build.sh                                        # 重新编一遍内核与镜像

修完再跑一次 ./verify-images.sh，全 ok 才刷。
EOF
	# 2 = 内核类失败：构建树被中断过的构建弄坏了，build.sh 会自动清掉内核目录重编一次
	[ "$kernelfail" -eq 1 ] && exit 2
	exit 1
fi

echo "== 体检通过：所有产物都可以刷"
exit 0
