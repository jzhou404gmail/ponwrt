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

set -e
cd "$(dirname "$0")"

CONFIG_NAME=""
WATCH_ONLY=0
FORCE=0
for arg in "$@"; do
	case "$arg" in
		--config=*) CONFIG_NAME="${arg#--config=}" ;;
		--watch)    WATCH_ONLY=1 ;;
		--force)    FORCE=1 ;;
		-h|--help)
			sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*)
			echo "错误: 不认识参数 '$arg'" >&2
			echo "提示: 想套用 configs/*.config 请用 --config=<名字>；默认直接 ./build.sh 即可。" >&2
			exit 1 ;;
	esac
done

LOG="tmp/build.log"

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
	[ -n "$MAKE_PID" ] && kill "$MAKE_PID" 2>/dev/null
	[ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
	rm -f "$LOCK"
}
trap cleanup EXIT INT TERM
# --------------------------------

date +%s > "$LOG.start"
: > "$LOG"

JOBS="${JOBS:-$(nproc)}"
PKGS=$(grep -c '^CONFIG_PACKAGE_.*=y' .config 2>/dev/null || true)
[ -n "$PKGS" ] || PKGS=0

echo "==> 并行度 ${JOBS} · 已选 ${PKGS} 个包 · 机型 $(grep -cE '^CONFIG_TARGET_DEVICE_.*=y' .config 2>/dev/null || echo '?') 个"
echo "==> 详细日志: ${LOG}   （也可另开终端跑 ./build.sh --watch）"
echo

# ---- 启动进度显示 ----
./build-watch.sh --log="$LOG" &
WATCH_PID=$!
# 注意：这里不要再设 trap —— 上面的 cleanup 已经负责杀 WATCH_PID 并删锁

# ---- 正式编译：原始输出只进日志，不传任何额外 make 变量 ----
make -j"${JOBS}" >> "$LOG" 2>&1 &
MAKE_PID=$!

RC=0
wait "$MAKE_PID" || RC=$?

kill $WATCH_PID 2>/dev/null
WATCH_PID=""

echo
if [ "$RC" -ne 0 ]; then
	echo "!! 构建失败 (rc=${RC})。日志末尾："
	tail -25 "$LOG" | sed 's/^/    /'
	echo
	echo "   完整日志: $LOG"
	echo "   常见定位: grep -nE 'ERROR:|build failed' \"$LOG\" | tail"
	exit "$RC"
fi

echo "==> 构建完成。产物："
find bin/targets -name '*.itb' -newer "$LOG.start" 2>/dev/null | sort | sed 's/^/    /'
echo
echo "==> 烧录自检："
echo "    cat /etc/openwrt_release        # 看 DISTRIB_REVISION"
