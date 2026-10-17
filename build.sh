#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# PonWrt 固件编译入口
#
# 设计原则：**只做加法，绝不改动构建输入**
#   —— 不传任何额外的 make 变量、不重写 .config，保证 OpenWrt 的增量判断
#      完全按你原来那套走，改动过的部分才重编。
#
# 用法：
#   ./build.sh                    # 默认：完全沿用现有 .config，绝不修改它
#   ./build.sh --config=an7581    # 显式用 configs/an7581.config 重建 .config
#                                 # （会先自动备份 + 掉包保护，缩水超 20% 自动中止还原）
#   JOBS=2 ./build.sh             # 降并行（内存紧张时避免 OOM）
#   ./build.sh --watch            # 只做进度监视，不编译
#   ./build.sh --force            # 忽略并发保护（危险，确认没有别的构建再用）
#
# 进度显示：make 的原始输出全部写入 tmp/build.log，
#           控制台只打印 build-watch.sh 生成的进度块（阶段 / 里程碑 / 正在编译什么）。
#           想事后翻细节：less tmp/build.log
#
# 收尾汇总：编译结束（成功 / 失败 / 被 Ctrl-C 中断）都会打印
#           开始时间、结束时间、总共耗时，并追加一行到 tmp/build.log。

set -e
cd "$(dirname "$0")"

# 计时起点：从脚本一启动就算，包含套用配置、defconfig 等前置步骤
START_EPOCH=$(date +%s)
START_TIME=$(date '+%F %T')

CONFIG_NAME=""
WATCH_ONLY=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--config=*) CONFIG_NAME="${arg#--config=}" ;;
		--watch)    WATCH_ONLY=1 ;;
		--force)    FORCE=1 ;;
		-h|--help)
			sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*)
			echo "错误: 不认识参数 '$arg'" >&2
			echo "提示: 想套用 configs/*.config 请用 --config=<名字>；默认直接 ./build.sh 即可。" >&2
			exit 1 ;;
	esac
done

LOG="tmp/build.log"

# ---------- 耗时显示 ----------
fmt_duration() {
	local s="$1"
	local h=$(( s / 3600 ))
	local m=$(( (s % 3600) / 60 ))
	local sec=$(( s % 60 ))

	if [ "$h" -gt 0 ]; then
		echo "${h} 小时 ${m} 分 ${sec} 秒"
	elif [ "$m" -gt 0 ]; then
		echo "${m} 分 ${sec} 秒"
	else
		echo "${sec} 秒"
	fi
}

# $1 = 结尾语（完成 / 失败 / 被中断）
# 只会打印一次：被 Ctrl-C 时 cleanup() 先打过，后面失败分支就不再重复。
print_summary() {
	local end_epoch end_time elapsed

	if [ -n "$SUMMARY_DONE" ]; then
		return 0
	fi
	SUMMARY_DONE=1

	end_epoch=$(date +%s)
	end_time=$(date '+%F %T')
	elapsed=$(( end_epoch - START_EPOCH ))

	echo
	{
		echo "==> 编译$1"
		printf '    开始时间 : %s\n' "$START_TIME"
		printf '    结束时间 : %s\n' "$end_time"
		printf '    总共耗时 : %s（%s 秒）\n' "$(fmt_duration "$elapsed")" "$elapsed"
	} | tee -a "$LOG" || true
	echo
}

if [ "$WATCH_ONLY" = 1 ]; then
	exec ./build-watch.sh --log="$LOG"
fi

# ---------- 仅在显式 --config=<名字> 时才重建 .config ----------
if [ -n "$CONFIG_NAME" ]; then
	SRC="configs/${CONFIG_NAME}.config"
	if [ ! -f "$SRC" ]; then
		echo "错误: 找不到 $SRC" >&2
		ls -1 configs/*.config 2>/dev/null | sed 's|^|  可用: |' >&2
		exit 1
	fi

	BAK=".config.bak-ponwrt-$(date +%Y%m%d-%H%M%S)"
	if [ -f .config ]; then
		cp -a .config "$BAK"
		echo "==> 已备份原 .config → ${BAK}"
	fi

	before_pkgs=$(grep -c '^CONFIG_PACKAGE_.*=y' .config 2>/dev/null || true)
	[ -n "$before_pkgs" ] || before_pkgs=0

	cat "$SRC" configs/release.config > .config
	echo "==> 已套用 ${SRC} + configs/release.config，执行 make defconfig"
	make defconfig </dev/null >/dev/null 2>&1 || true

	after_pkgs=$(grep -c '^CONFIG_PACKAGE_.*=y' .config 2>/dev/null || true)
	[ -n "$after_pkgs" ] || after_pkgs=0

	if [ "$before_pkgs" -gt 0 ] && [ "$after_pkgs" -lt $((before_pkgs * 8 / 10)) ]; then
		echo "" >&2
		echo "!! 已中止：包选择从 ${before_pkgs} 个掉到 ${after_pkgs} 个，疑似覆盖了你的手工配置。" >&2
		echo "!! 已把原配置还回去：${BAK} -> .config" >&2
		cp -a "$BAK" .config
		exit 1
	fi
	echo "==> 包选择数量: ${before_pkgs} -> ${after_pkgs}"
fi

if [ ! -f .config ]; then
	echo "错误: 没有 .config，请先配置：make menuconfig" >&2
	exit 1
fi

mkdir -p tmp

# ---------- 环境自检：git 必须真的能用 ----------
# 这台机器（2026-10-14 的自动 apt 升级起）没有系统 git 包了：那次升级顺手把
# git 删掉，只留下 ~/.local/bin/git —— 一个包装脚本，要求 PATH 里有 ~/.local/bin
# 且 $HOME 指向 /home/jzhou。于是"有没有 git"取决于你从哪个 shell 跑。
#
# 缺 git 时**不会**有像样的报错，只会静默走样，2026-10-17 那次两条路一起翻车：
#   * feed-patches/apply.sh 的三个 `git apply --check` 全失败 → 误报"套不上"，
#     让人以为是补丁坏了（真去改补丁就白费功夫）；
#   * scripts/getver.sh 拿不到版本 → REVISION=unknown，整棵树的包版本换一套
#     （base-files 从 1943~a57faf93c6 变成 1943~unknown），增量状态错乱，
#     随机包报 "failed to build" —— 那次是 25 分钟之后才在 base-files 上炸。
# 所以在开工前先拦下来，并把修法写在脸上。
git_hint() {
	echo "" >&2
	echo "!! 编译前自检没过：git 用不了（$1）" >&2
	echo "!! 缺 git 不会报错，只会静默走样：补丁判定全失败（误报“套不上”）、" >&2
	echo "!! 版本号变成 unknown（整棵树的包版本换一套，随机包 failed to build）。" >&2
	echo "!! 先自查：git --version ; git -C \"\$PWD\" rev-parse --git-dir ; scripts/getver.sh" >&2
	echo "!! 一劳永逸（恢复系统 git，PATH/HOME 怎么变都不会再踩）：" >&2
	echo "!!     sudo apt-get install -y git" >&2
	echo "" >&2
}

# PATH 里没有 git 时先兜一下本机那份用户态 git（README §5.1.1）。这一步很关键：
# build.sh 的 PATH 会传给 make，于是 getver.sh 也能拿到正确版本；不兜的话，连
# build.sh 自己都会被下面的自检拦住。
if ! command -v git >/dev/null 2>&1; then
	for d in "$HOME/.local/bin" /usr/local/bin; do
		if [ -x "$d/git" ]; then
			echo "==> PATH 里没有 git，改用 $d/git（README §5.1.1；一劳永逸的修法是 sudo apt-get install -y git）"
			PATH="$d:$PATH"
			export PATH
			break
		fi
	done
fi

if ! command -v git >/dev/null 2>&1; then
	git_hint "PATH 里找不到 git"
	exit 1
fi
if ! git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1; then
	git_hint "git 打不开 $PWD 这个仓库"
	exit 1
fi
REVISION_NOW=$(scripts/getver.sh 2>/dev/null || true)
if [ "$REVISION_NOW" = "unknown" ] || [ -z "$REVISION_NOW" ]; then
	git_hint "scripts/getver.sh 给出的版本是 '${REVISION_NOW:-空}'"
	exit 1
fi

# ---------- 上游 feed 补丁（幂等） ----------
# feeds/ 不入库，我们改在上游驱动里的修复以补丁形式存在 feed-patches/，
# 这里在 make 之前套一遍：套过了就跳过，刚套上的会清掉 build_dir 旧拷贝，
# 保证增量编译用的是改过的源码。细节见 feed-patches/apply.sh 顶部注释。
# （顶层的 `make` 也会做这一步，见 include/toplevel.mk 的 feed-patches-apply 目标，
#   所以直接跑 make 不会漏掉补丁。）
if [ -x feed-patches/apply.sh ]; then
	./feed-patches/apply.sh
fi

# ---------- 并发保护 ----------
# 同一棵树里并行跑两个 make 会同时写 build_dir/ 与 staging_dir/，
# 症状是 libunistring/perl 之类完全无关的包"随机"编译失败 —— 极难排查。
LOCK="tmp/build.lock"
if [ -f "$LOCK" ] && [ "$FORCE" -ne 1 ]; then
	age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
	if [ "$age" -lt 21600 ]; then
		echo "!! 检测到已有构建在进行（$LOCK，$(( age / 60 )) 分钟前创建）：" >&2
		sed 's/^/     /' "$LOCK" >&2
		echo "!! 同一棵树并发编译会导致随机失败，已中止。" >&2
		echo "!! 确认真没有别的构建在跑，就加 --force 重试。" >&2
		exit 1
	fi
	echo "==> 发现过期锁（$(( age / 3600 )) 小时前），已忽略"
fi
{
	echo "pid     = $$"
	echo "started = $(date '+%F %T')"
	echo "log     = ${LOG}"
} > "$LOCK"
WATCH_PID=""
MAKE_PID=""
cleanup() {
	# 关键：包装脚本被杀时必须连 make 一起收掉，否则 make 变成孤儿继续跑，
	# 而锁已经被删掉了 —— 这时再启动一次构建就会变成并发编译（随机失败）。
	if [ -n "$MAKE_PID" ]; then
		kill "$MAKE_PID" 2>/dev/null || true
		print_summary "被中断（Ctrl-C / 被 kill）"
	fi
	if [ -n "$WATCH_PID" ]; then
		kill "$WATCH_PID" 2>/dev/null || true
	fi
	rm -f "$LOCK"
	# 兜底：任何没走到正常收尾的退出（例如刚进 defconfig 阶段就被中断）也把耗时打出来，
	# print_summary 自带去重，正常路径下这里不会再打一遍
	print_summary "结束（未走完正常收尾）"
}
trap cleanup EXIT INT TERM
# --------------------------------

date +%s > "$LOG.start"
: > "$LOG"

JOBS="${JOBS:-$(nproc)}"
PKGS=$(grep -c '^CONFIG_PACKAGE_.*=y' .config 2>/dev/null || true)
[ -n "$PKGS" ] || PKGS=0

# 每个包的完整输出单独落盘到 logs/<包>/compile.txt
# （OpenWrt 自带机制，体积很小：整棵树约 2.5MB。任何一个包失败时，它的
#  真实报错只在这份日志里，tmp/build.log 只有一行 "ERROR: ... failed to build."）
export BUILD_LOG=1

echo "==> 并行度 ${JOBS} · 已选 ${PKGS} 个包 · 机型 $(grep -cE '^CONFIG_TARGET_DEVICE_.*=y' .config 2>/dev/null || echo '?') 个 · 版本 ${REVISION_NOW}"
echo "==> 详细日志: ${LOG} · 每个包的日志: logs/<包>/compile.txt   （也可另开终端跑 ./build.sh --watch）"
echo

# ---- 启动进度显示 ----
./build-watch.sh --log="$LOG" &
WATCH_PID=$!
# 注意：这里不要再设 trap —— 上面的 cleanup 已经负责杀 WATCH_PID 并删锁

# ---------- 开编前：把内核构建树上一次留下的 initramfs 配置复位 ----------
# 非「separate ramdisk」模式下，生成 recovery 镜像那一步会**就地**把内核构建树的
# .config 改成 CONFIG_INITRAMFS_SOURCE="<rootfs> ..."，而且构建结束也不还原。
# 于是下一次构建的"普通内核"用的就是这份配置：arch/arm64/boot/Image 变成 194 MB 的
# initramfs 内核，被拷成 $(KERNEL_BUILD_DIR)/Image，sysupgrade 里于是塞进假内核
# （体积翻倍 + U-Boot inflate 失败 → 无限重启）。verify-images.sh 能拦下它，但代价
# 是白编一遍内核。这里改成**开编前**先复位：.config ← .config.set（Kernel/Configure
# 自己生成的那份干净配置，INITRAMFS_SOURCE=""），内核只需增量重链，镜像就是对的。
#
# 只动主版本目录（如 linux-6.18.52），跳过每机型副本（linux-6.18.52.<hash>）：
# 那些副本每次由 Kernel/PrepareConfigPerRootfs 从主树重建，修好主树就够了。
kernel_tree_heal() {
	local kcfg kdir name set_cfg healed=0
	for kcfg in build_dir/target-*/linux-*/linux-*/.config; do
		[ -f "$kcfg" ] || continue
		kdir=${kcfg%/.config}
		name=${kdir##*/}                       # linux-6.18.52 / linux-6.18.52.2284f8a8
		case "$name" in *.*.*.*) continue ;; esac
		# "空串"是正常配置（CONFIG_INITRAMFS_SOURCE=""），只有非空的才说明被改过
		grep -q '^CONFIG_INITRAMFS_SOURCE="[^"]' "$kcfg" || continue

		set_cfg="${kdir}/.config.set"
		if [ ! -s "$set_cfg" ]; then
			echo "!! ${kdir}/.config 里留着 initramfs 配置，但没有 .config.set 可复位" >&2
			echo "!! 只能整棵删掉重编：rm -rf ${kdir}" >&2
			continue
		fi
		if grep -q '^CONFIG_INITRAMFS_SOURCE="[^"]' "$set_cfg"; then
			echo "!! ${kdir}/.config.set 本身也带 initramfs 配置，跳过（请整棵删掉重编）" >&2
			continue
		fi

		echo "==> 内核构建树被上一次构建留成 initramfs 配置：${name}"
		echo "    复位 .config ← .config.set（普通内核会重新链接，镜像体积恢复正常）"
		cp "$set_cfg" "$kcfg"
		healed=1
	done
	[ "$healed" -eq 0 ] || echo
}

kernel_tree_heal

# ---------- 失败自愈 ----------
# 已知的一种时序性失败：某个包的子 make 被"静默打断"—— 现象是 tmp/build.log 里
# 只有一行 "ERROR: <包> failed to build."，而它自己的 logs/<包>/compile.txt
# 一个字都没有（连 time.pl 的 "time: <包>/compile#..." 都没有）。
# 这不是编译报错，重编一次就好；这里自动单独重编该包，然后继续整个构建。
failed_packages() {
	grep -oE '^ *ERROR: [^ ]+ failed to build' "$LOG" 2>/dev/null |
		sed 's/^ *ERROR: //; s/ failed to build$//' | sort -u
}

silently_failed_packages() {
	local p
	for p in $(failed_packages); do
		[ -s "logs/${p}/compile.txt" ] || echo "$p"
	done
}

RETRY_MAX=2
ATTEMPT=0
KERNEL_REBUILT=0

while :; do
	ATTEMPT=$((ATTEMPT + 1))
	if [ "$ATTEMPT" -gt 1 ]; then
		echo "==> 第 ${ATTEMPT} 次尝试（上一次的静默失败已修复）"
	fi

	# ---- 正式编译：原始输出只进日志，不传任何额外 make 变量 ----
	make -j"${JOBS}" >> "$LOG" 2>&1 &
	MAKE_PID=$!

	RC=0
	wait "$MAKE_PID" || RC=$?
	# 编译已结束：收尾与耗时由下面负责，cleanup() 不再按"被中断"处理
	MAKE_PID=""

	# ---- 编译成功：再过一道产物体检（verify-images.sh） ----
	# 只编译得出来的产物不等于能刷：内核构建树被"被中断的构建"留在 initramfs 配置上时，
	# sysupgrade 镜像里会塞进 initramfs 内核（体积翻倍、U-Boot inflate 失败 → 无限重启）。
	# 见 verify-images.sh 顶部的复盘。
	if [ "$RC" -eq 0 ]; then
		echo
		echo "==> 产物体检（verify-images.sh）：确认每个 .itb 都能刷"
		# 注意 ①：必须先把退出码存下来再判断 —— if cmd; then ...; fi 这个复合命令
		# 自身返回 0，$? 拿不到 cmd 的真实状态。
		# 注意 ②：脚本开头是 `set -e`，裸跑 `./verify-images.sh` 在它返回非 0 时会
		# **直接结束整个脚本**（下面的自愈代码一行都执行不到，只会看到"编译结束
		# （未走完正常收尾）"）。所以必须用 `|| VRC=$?` 把失败"接住"，让它变成
		# 一个被判断的值。2026-10-17 实测踩到：体检报了"内核是 initramfs 的"，
		# 自愈却没跑，镜像就那么留在 bin/ 里。
		VRC=0
		./verify-images.sh || VRC=$?
		if [ "$VRC" -eq 0 ]; then
			break
		fi

		if [ "$VRC" -eq 2 ] && [ "$KERNEL_REBUILT" -eq 0 ]; then
			KERNEL_REBUILT=1
			BOARD=$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"/\1/p' .config)
			SUBTARGET=$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"/\1/p' .config)
			echo
			echo "!! 内核产物不对（这一类是可以自愈的）：清掉内核构建树重新编一遍"
			# 目录名是 KERNEL_BUILD_DIR = $(BUILD_DIR)/linux-$(BOARD)_$(SUBTARGET)
			# （include/kernel.mk:46）—— 是 `linux-airoha_an7581`，不是
			# `airoha_an7581`。原先少了 `linux-` 前缀，rm 什么都没删掉，
			# "自愈"其实是空转，重编出来的还是那份 initramfs 内核。
			for kdir in build_dir/target-*/linux-"${BOARD}_${SUBTARGET}"; do
				[ -d "$kdir" ] || continue
				echo "!! 目录: $kdir"
				rm -rf "$kdir"
			done
			RC=1
			continue
		fi

		echo
		echo "!! 产物体检不过 —— 这次构建的镜像**不要刷**（上面有具体原因）" >&2
		RC=1
		break
	fi

	SILENT=$(silently_failed_packages)
	if [ -z "$SILENT" ] || [ "$ATTEMPT" -gt "$RETRY_MAX" ]; then
		break
	fi

	echo
	echo "!! 检测到 ${SILENT} 的子构建被静默打断（logs/<包>/compile.txt 为空 = 不是编译报错）"
	echo "!! 先单独把它编好，再继续整个构建："
	for p in $SILENT; do
		echo "     make ${p}/compile"
		make "${p}/compile" >> "$LOG" 2>&1 || true
	done
	echo "!! 继续构建"
	echo
done

kill $WATCH_PID 2>/dev/null || true
WATCH_PID=""

echo
if [ "$RC" -ne 0 ]; then
	# Ctrl-C / kill 的情况 cleanup() 已经收尾并打过耗时了，这里不再当成"编译失败"报一遍
	if [ -n "$SUMMARY_DONE" ]; then
		exit "$RC"
	fi
	echo "!! 构建失败 (rc=${RC})。日志末尾："
	tail -25 "$LOG" | sed 's/^/    /'
	echo
	echo "   完整日志: $LOG"
	echo "   常见定位: grep -nE 'ERROR:|build failed' \"$LOG\" | tail"
	print_summary "失败"
	exit "$RC"
fi

echo "==> 构建完成。产物："
find bin/targets -name '*.itb' -newer "$LOG.start" 2>/dev/null | sort | sed 's/^/    /'
echo
echo "==> 烧录自检："
echo "    cat /etc/openwrt_release        # 看 DISTRIB_REVISION"
print_summary "完成"
