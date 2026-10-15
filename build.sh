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

echo "==> 并行度 ${JOBS} · 已选 ${PKGS} 个包 · 机型 $(grep -cE '^CONFIG_TARGET_DEVICE_.*=y' .config 2>/dev/null || echo '?') 个"
echo "==> 详细日志: ${LOG} · 每个包的日志: logs/<包>/compile.txt   （也可另开终端跑 ./build.sh --watch）"
echo

# ---- 启动进度显示 ----
./build-watch.sh --log="$LOG" &
WATCH_PID=$!
# 注意：这里不要再设 trap —— 上面的 cleanup 已经负责杀 WATCH_PID 并删锁

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

	if [ "$RC" -eq 0 ]; then
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
