#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# feed-patches/apply.sh —— 把本仓库记录的上游 feed 补丁套到 feeds/ 检出上（幂等）
#
# 为什么要有这个目录：`pon_drivers` / `pon_userspace` 是上游 feed（见
# feeds.conf.default 里的 src-git），`feeds/` 不入库。如果修复只改 feeds/ 里的
# 检出，那么一次 `./scripts/feeds update -a` 就把它冲掉了，而且 `git log` 里
# 根本看不到这处修复。所以这类修复一律**以补丁形式存在本目录**，由本脚本套用。
#
# 目录约定：
#   feed-patches/<feed 名>/<包目录>/<编号>-<说明>.patch
# 补丁是相对 **feed 检出根目录** 的（即 `git -C feeds/<feed> apply` 可直接用）。
#
# 套用成功后，本脚本会删掉该包在 build_dir/ 里的旧拷贝和编译戳：OpenWrt 只会
# 在 prepare 阶段把本地源码**拷贝**到 build_dir，源码改了不会自动重拷，不删就会
# “改了源码但编译用的还是旧文件”。
#
# 用法：
#   ./feed-patches/apply.sh            # 套用（已套过的跳过，冲突则报错退出）
#   ./feed-patches/apply.sh --check    # 只看状态，不动任何文件
#   ./feed-patches/apply.sh --force    # 连“已套过”的也重新套（一般不用）
#
# build.sh 会在编译前自动调用它，所以正常流程里不需要手动跑。

set -e
cd "$(dirname "$0")/.."

ROOT=$(pwd)
CHECK_ONLY=0
FORCE=0

for arg in "$@"; do
	case "$arg" in
		--check) CHECK_ONLY=1 ;;
		--force) FORCE=1 ;;
		-h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "错误: 不认识参数 '$arg'" >&2; exit 1 ;;
	esac
done

patches=$(find feed-patches -name '*.patch' 2>/dev/null | sort)
[ -n "$patches" ] || exit 0

changed_pkgs=""

for patch in $patches; do
	# feed-patches/<feed>/<pkgdir>/<file>.patch
	rel=${patch#feed-patches/}
	feed=${rel%%/*}
	rest=${rel#*/}
	pkgdir=${rest%%/*}

	if [ -z "$feed" ] || [ "$pkgdir" = "$rest" ]; then
		echo "!! $patch 的路径不符合 feed-patches/<feed>/<包目录>/<文件>.patch，已跳过" >&2
		continue
	fi

	if [ ! -d "feeds/$feed/.git" ]; then
		echo "!! 找不到 feeds/$feed（feed 还没取下来？先跑 ./scripts/feeds update -a）" >&2
		echo "   跳过 $patch" >&2
		continue
	fi

	# 判定顺序（一个 feed 里可能叠着好几个补丁，后面的补丁会改动前面补丁的
	# 上下文行，所以"已套用"不能只靠 plain 反向检查，要允许缩小上下文的 -C1）：
	#   ① 能正向套  → 还没套，套上
	#   ② 能反向套  → 已经套过（-C1 兜住"被后面补丁改过上下文"的情况）
	#   ③ 都不行    → 上游改过同一段，报错退出让用户看清楚
	if git -C "feeds/$feed" apply --check "$ROOT/$patch" 2>/dev/null; then
		if [ "$CHECK_ONLY" -eq 1 ]; then
			echo "==> 需要套用（--check 未改动）: $patch"
			continue
		fi
		git -C "feeds/$feed" apply "$ROOT/$patch"
		echo "==> 已套用: $patch"
		changed_pkgs="$changed_pkgs $pkgdir"
		continue
	fi

	if git -C "feeds/$feed" apply --check --reverse "$ROOT/$patch" 2>/dev/null ||
		git -C "feeds/$feed" apply --check --reverse -C1 "$ROOT/$patch" 2>/dev/null; then
		if [ "$FORCE" -eq 1 ]; then
			if ! git -C "feeds/$feed" apply --reverse "$ROOT/$patch" 2>/dev/null &&
				! git -C "feeds/$feed" apply --reverse -C1 "$ROOT/$patch" 2>/dev/null; then
				echo "!! --force 反套失败: $patch" >&2
				exit 1
			fi
			git -C "feeds/$feed" apply "$ROOT/$patch"
			echo "==> 重新套用（--force）: $patch"
			changed_pkgs="$changed_pkgs $pkgdir"
		else
			echo "==> 已套用（跳过）: $patch"
		fi
		continue
	fi

	if [ "$CHECK_ONLY" -eq 1 ]; then
		# --check 不会真的套前面的补丁，所以同一 feed 里后面的补丁必然"对不上
		# 上下文" —— 这里只能说它还需要套用，不能当成冲突。
		echo "==> 需要套用（--check 不累积，同一 feed 里后面的补丁暂时对不上上下文）: $patch"
		continue
	fi

	echo "!! 套不上: $patch" >&2
	echo "!! feeds/$feed 已经被别的改动占住了，或者上游改过同一段代码。" >&2
	echo "!! 处理办法：cd feeds/$feed && git status 看清现状，再按需重做这个补丁。" >&2
	exit 1

	if [ "$CHECK_ONLY" -eq 1 ]; then
		echo "==> 需要套用（--check 未改动）: $patch"
		continue
	fi

	git -C "feeds/$feed" apply "$ROOT/$patch"
	echo "==> 已套用: $patch"
	changed_pkgs="$changed_pkgs $pkgdir"
done

[ "$CHECK_ONLY" -eq 1 ] && exit 0

# 清掉 build_dir 里的旧拷贝，让增量编译重新 prepare 并重编这些包
for pkg in $changed_pkgs; do
	for dir in build_dir/target-*/"$pkg"; do
		[ -d "$dir" ] || continue
		echo "==> 清理过期编译目录: $dir（下次 make 会重新拷贝源码并重编）"
		rm -rf "$dir"
	done
done
