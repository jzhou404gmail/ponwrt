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
#   ./feed-patches/apply.sh --reset    # 套不上时先把目标文件复位到 HEAD 再套
#                                      # （会丢弃这些文件上的手工改动 —— 那正是要修的）
#   ./feed-patches/apply.sh --force    # 连“已套过”的也重新套（一般不用）
#
# build.sh 会在编译前自动调用它，顶层的 `make` 也会（见 include/toplevel.mk 的
# feed-patches 目标），所以正常流程里不需要手动跑。

set -e
cd "$(dirname "$0")/.."

ROOT=$(pwd)
CHECK_ONLY=0
FORCE=0
RESET=0

for arg in "$@"; do
	case "$arg" in
		--check) CHECK_ONLY=1 ;;
		--reset) RESET=1 ;;
		--force) FORCE=1 ;;
		-h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "错误: 不认识参数 '$arg'" >&2; exit 1 ;;
	esac
done

# git 不在 PATH 里时兜一下本机那份用户态 git（README §5.1.1：系统 git 包被
# 2026-10-14 的自动 apt 升级删了，剩下的那份只在 ~/.local/bin，而那个目录不是
# 每个 shell 的 PATH 都有）。补不上就让下面的自检带着修法报错。
if ! command -v git >/dev/null 2>&1; then
	for d in "$HOME/.local/bin" /usr/local/bin; do
		if [ -x "$d/git" ]; then
			PATH="$d:$PATH"
			export PATH
			break
		fi
	done
fi

# git 不可用时的说明。必须与"补丁套不上"分开报：后者要你改补丁，前者要你修环境，
# 而 git 一坏，本脚本的三个 `git apply --check` 会**全部**失败，补丁看起来就像
# "既不是套之前的样子、也不是套之后的样子"—— 2026-10-17 就是这样白白查了半天。
git_broken() {
	echo "!! git 用不了：$1" >&2
	echo "!! 这不是补丁的问题：判断\"套没套上\"全靠 git，git 跑不起来就全都判不了。" >&2
	echo "!! 本机上 git 的来路（2026-10-14 的自动 apt 升级把系统 git 包删掉了）：" >&2
	echo "!!     ~/.local/bin/git -> \$HOME/.local/opt/git/usr/bin/git" >&2
	echo "!!     —— 一个包装脚本，依赖 PATH 里有 ~/.local/bin、且 \$HOME 正确。" >&2
	echo "!!     非登录 shell（桌面终端、sudo、cron）常常两样都不满足。" >&2
	echo "!! 先自查：git --version ; git -C feeds/$feed rev-parse --git-dir" >&2
	echo "!! 一劳永逸（恢复系统 git，PATH/HOME 怎么变都不会再踩）：" >&2
	echo "!!     sudo apt-get install -y git" >&2
}

patches=$(find feed-patches -name '*.patch' 2>/dev/null | sort)
[ -n "$patches" ] || exit 0

changed_pkgs=""

for patch in $patches; do
	# feed-patches/<feed>/<pkgdir>/<file>.patch
	rel=${patch#feed-patches/}
	feed=${rel%%/*}
	rest=${rel#*/}
	# 包目录允许嵌套：feeds/packages 里不少包在 devel/gn、net/xxx 这种两层目录下，
	# 补丁按同样层级摆放（feed-patches/packages/devel/gn/0001-*.patch）才对得上
	# `git -C feeds/<feed> apply` 里的 a/devel/gn/... 路径。取到文件名之前为止，
	# 一层目录（如 airoha-xpon）得到的结果与旧的 ${rest%%/*} 完全相同。
	pkgdir=${rest%/*}

	if [ -z "$feed" ] || [ "$pkgdir" = "$rest" ]; then
		echo "!! $patch 的路径不符合 feed-patches/<feed>/<包目录>/<文件>.patch，已跳过" >&2
		continue
	fi

	if [ ! -d "feeds/$feed/.git" ]; then
		echo "!! 找不到 feeds/$feed（feed 还没取下来？先跑 ./scripts/feeds update -a）" >&2
		echo "   跳过 $patch" >&2
		continue
	fi

	# git 先确认能用，再谈补丁。否则下面每个检查都失败，就会误报"套不上"：
	# 报告里写的是"文件既不是补丁前也不是补丁后"，读到的人只会去改补丁，
	# 而真正的问题（PATH/HOME 里没有可用的 git）却看不见。
	if ! command -v git >/dev/null 2>&1; then
		git_broken "PATH 里找不到 git（本脚本自己也要靠它）"
		exit 1
	fi
	if ! git_err=$(git -C "feeds/$feed" rev-parse --git-dir 2>&1); then
		git_broken "git 打不开 feeds/$feed 这个仓库：$git_err"
		exit 1
	fi

	# 补丁涉及哪些文件：不能用 `git apply --numstat` 取 —— 它 implies --check，
	# 对套不上的补丁直接报错退出、什么都不输出，所以直接读补丁里的 `+++ b/` 行。
	targets=$(sed -n 's|^+++ b/||p' "$ROOT/$patch")

	# 判定顺序（一个 feed 里可能叠着好几个补丁，后面的补丁会改动前面补丁的
	# 上下文行，所以"已套用"不能只靠 plain 反向检查，要允许缩小上下文的 -C1）：
	#   ① 能正向套  → 还没套，套上
	#   ② 能反向套  → 已经套过（-C1 兜住"被后面补丁改过上下文"的情况，
	#                --ignore-whitespace 兜住行尾/空白被动过的文件）
	#   ③ 都不行    → 真冲突：--reset 复位后重套，或照现状重做补丁
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
		git -C "feeds/$feed" apply --check --reverse -C1 "$ROOT/$patch" 2>/dev/null ||
		git -C "feeds/$feed" apply --check --reverse --ignore-whitespace "$ROOT/$patch" 2>/dev/null; then
		if [ "$FORCE" -eq 1 ]; then
			if ! git -C "feeds/$feed" apply --reverse "$ROOT/$patch" 2>/dev/null &&
				! git -C "feeds/$feed" apply --reverse -C1 "$ROOT/$patch" 2>/dev/null &&
				! git -C "feeds/$feed" apply --reverse --ignore-whitespace "$ROOT/$patch" 2>/dev/null; then
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

	# ③ 两个方向都不行：文件里既不是补丁前的样子、也不是补丁后的样子 —— 真冲突。
	#    这就是下面 a)/b) 两种成因，处理方式相反，所以先把文件列表和命令写出来。
	if [ "$RESET" -eq 1 ]; then
		# a) 的自动版：把补丁涉及的文件复位到 HEAD，再套一次。会丢弃这些文件上
		# 的手工改动 —— 那正是它要修的东西。
		echo "==> --reset：先把 $targets 复位到 HEAD，再套 $patch"
		for f in $targets; do
			git -C "feeds/$feed" checkout -- "$f"
		done
		if git -C "feeds/$feed" apply "$ROOT/$patch"; then
			echo "==> 已套用（--reset）: $patch"
			changed_pkgs="$changed_pkgs $pkgdir"
			continue
		fi

		# 复位到 HEAD 之后还套不上，就不可能是"手工改过"，只剩原因 b)。
		echo "!! 复位到 HEAD 之后仍然套不上: $patch" >&2
		echo "!! 那就不是文件被改乱了，而是上游动过同一段代码（例如跑过 ./scripts/feeds update -a）。" >&2
		echo "!! 需要照 feeds/$feed 的现状重做这个补丁，并把 feed-patches/ 下这份同步更新。先看清楚差在哪：" >&2
		echo "!!     git -C feeds/$feed status --short" >&2
		echo "!!     git -C feeds/$feed diff" >&2
		git -C "feeds/$feed" apply --check "$ROOT/$patch" 2>&1 | sed 's/^/!!     /' >&2
		exit 1
	fi

	echo "!! 套不上: $patch" >&2
	echo "!! feeds/$feed 里这些文件既不是套补丁前的样子，也不是套完补丁的样子：" >&2
	for f in $targets; do
		echo "!!     $f" >&2
	done
	echo "!! 常见两种原因：" >&2
	echo "!!   a) 文件被手工改过，改法与补丁不完全一致 —— 复位后重跑本脚本即可" >&2
	echo "!!      （补丁会重新套上，所以不会有东西丢失）：" >&2
	echo "!!        ./feed-patches/apply.sh --reset   # = 下面两条，省事" >&2
	for f in $targets; do
		echo "!!        git -C feeds/$feed checkout -- $f" >&2
	done
	echo "!!        ./feed-patches/apply.sh" >&2
	echo "!!   b) 上游改过同一段代码（例如跑过 ./scripts/feeds update -a）——" >&2
	echo "!!      需要照 feeds/$feed 的现状重做这个补丁，并把 feed-patches/ 下这份同步更新。" >&2
	echo "!! 先看清楚差在哪：" >&2
	echo "!!     git -C feeds/$feed status --short" >&2
	echo "!!     git -C feeds/$feed diff" >&2
	echo "!! git 自己报的错（上面两条判定命令里被藏起来的那份）：" >&2
	git -C "feeds/$feed" apply --check --reverse "$ROOT/$patch" 2>&1 | sed 's/^/!!     /' >&2
	exit 1
done

[ "$CHECK_ONLY" -eq 1 ] && exit 0

# 清掉 build_dir 里的旧拷贝，让增量编译重新 prepare 并重编这些包。
#
# 三个位置都要清：普通包在 build_dir/target-*/<包>，**kmod 包在
# build_dir/target-*/linux-<板>_<子目标>/<包>**（PKG_BUILD_DIR 默认是
# $(KERNEL_BUILD_DIR)/<包名>），而 **host 包在 build_dir/host/<包>-<版本>**。
# 只清第一个等于没清：2026-10-17 查到 linux-airoha_an7583/airoha-xpon 里躺着
# 10-05 的旧源码（补丁前），而这个脚本每次都报"已套用/已清理"，编译出来的
# 模块却还是旧的。host 那一处是 2026-10-20 补上的：feeds/packages 的 gn 补丁
# 改的是 Host/Configure，build_dir/host 里那份旧配置不删就永远不会重跑，
# 补丁"套上了"而编译行为没变 —— 与上面那个旧源码是同一类坑。
#
# 目录名取包目录的 basename：pkgdir 可能是 devel/gn 这样的嵌套路径，而
# build_dir 下按包名（gn）命名，不按 feeds 里的目录层级。
for pkg in $changed_pkgs; do
	base=${pkg##*/}
	for dir in build_dir/target-*/"$base" build_dir/target-*/linux-*/"$base" build_dir/host/"$base"-*; do
		[ -d "$dir" ] || continue
		echo "==> 清理过期编译目录: $dir（下次 make 会重新拷贝源码并重编）"
		rm -rf "$dir"
	done
done
