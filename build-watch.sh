#!/bin/bash
# PonWrt 编译进度显示
#
# 用法:
#   ./build-watch.sh                          # 自动找日志，持续监视（每 20s）
#   ./build-watch.sh --once                   # 只打印一次
#   ./build-watch.sh --log=tmp/build.log      # 指定日志
#   ./build-watch.sh --iv=10                  # 指定刷新间隔秒数
#
# 关键点：进度条"看起来不动"通常是正常的 —— make 只在开始编某个包时打一行，
# 遇到 samba4/nfs-utils 这种大包会静默几十分钟。所以这里除了绝对状态，
# 还给出【活性指标】：
#   * 系统负载      —— 接近核数说明正在满负荷编译
#   * 日志静默时长  —— 静默本身正常，配合负载一起看
#   * 任务增量 +N   —— 距上次刷新新增了多少个编译任务
#   * 近 N 分钟改动文件数（每 3 次刷新统计一次，统计较慢）

LOG=""
IV=20
ONCE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--once)  ONCE=1; shift ;;
		--log=*) LOG="${1#--log=}"; shift ;;
		--iv=*)  IV="${1#--iv=}"; shift ;;
		[0-9]*)  IV="$1"; shift ;;     # 兼容旧写法：纯数字当间隔
		*)       LOG="$1"; shift ;;
	esac
done

if [ -z "$LOG" ]; then
	LOG=$(ls -t tmp/build.log tmp/fullbuild.log tmp/*fullbuild*.log tmp/*build*.log 2>/dev/null | head -1)
	[ -n "$LOG" ] || LOG=$(ls -t tmp/*.log 2>/dev/null | head -1)
	[ -n "$LOG" ] && echo "（自动选中日志: $LOG）"
fi
[ -n "$LOG" ] && [ -f "$LOG" ] || {
	echo "找不到构建日志（编译还没开始？）"
	ls -lt tmp/*.log 2>/dev/null | sed 's/^/    /' || echo "    (tmp/ 下没有 .log)"
	echo "也可显式指定： ./build-watch.sh --log=tmp/xxx.log"
	exit 1
}

SF="$LOG.start"
[ -f "$SF" ] || date +%s > "$SF"

MILES="target/compile|编译内核/设备树
package/compile|编译软件包
package/install|安装软件包
target/install|组装 rootfs + 生成镜像
package/index|生成软件包索引"

humans() {
	local d=$1
	if [ "$d" -ge 3600 ]; then printf '%dh%02dm%02ds' $((d/3600)) $((d%3600/60)) $((d%60))
	else printf '%dm%02ds' $((d/60)) $((d%60)); fi
}

LAST_TASKS=0
TICK=0
CACHED_CHG="(统计中…)"

emit() {
	local phase sub err_n el nproc load1 silence started ninja delta
	local -a inflight

	phase=$(grep -E '^---- 阶段' "$LOG" 2>/dev/null | tail -1 | sed 's/^---- //;s/ ----$//')
	sub=$(grep -oE '^ make\[[0-9]+\] [a-z/]+' "$LOG" 2>/dev/null | tail -1 | sed 's/^ make\[[0-9]*\] //')
	el=$(humans $(( $(date +%s) - $(cat "$SF") )))

	started=$(grep -cE '^ make\[[0-9]+\] -C ' "$LOG" 2>/dev/null | head -1)
	[ -n "$started" ] || started=0
	delta=$(( started - LAST_TASKS ))
	LAST_TASKS=$started

	err_n=$(grep -cE '^ *ERROR:|build failed|错误 [0-9]' "$LOG" 2>/dev/null | head -1)
	[ -n "$err_n" ] || err_n=0

	# --- 活性指标 ---
	nproc=$(nproc)
	load1=$(cut -d' ' -f1 /proc/loadavg)
	silence=$(( $(date +%s) - $(stat -c %Y "$LOG" 2>/dev/null || echo 0) ))
	TICK=$(( TICK + 1 ))
	if [ $(( TICK % 3 )) -eq 1 ]; then
		n=$(timeout 25 find build_dir staging_dir -newermt '-3 minutes' -type f 2>/dev/null | wc -l)
		[ -n "$n" ] && CACHED_CHG="$n"
	fi

	mapfile -t inflight < <(grep -oE '^ make\[[0-9]+\] -C [^ ]+' "$LOG" 2>/dev/null | tail -4 | sed 's/^ make\[[0-9]*\] -C //')

	echo "────────── $(date +%T) · 已运行 $el ──────────"
	[ -n "$phase" ] && echo "  $phase"
	echo "  活性: 系统负载 ${load1}/$(nproc)核 · 日志静默 $(humans $silence) · 近3分钟改动 ${CACHED_CHG} 个文件"

	if grep -q '^ make\[1\] world' "$LOG" 2>/dev/null; then
		echo "  里程碑:"
		echo "$MILES" | while IFS='|' read -r key desc; do
			if grep -qE "^ make\[[0-9]+\] ${key}\b" "$LOG" 2>/dev/null; then mark="✓"; else mark="○"; fi
			printf '      [%s] %s\n' "$mark" "$desc"
		done
	fi

	ninja=$(grep -oE '^\[[0-9]+/[0-9]+\]' "$LOG" 2>/dev/null | tail -1)
	[ -n "$ninja" ] && echo "  ninja 子步骤: $ninja"

	if [ "$delta" -gt 0 ]; then
		echo "  已启动编译任务: $started 项  (+$delta)"
	else
		echo "  已启动编译任务: $started 项  (与上次相同)"
	fi
	if [ "${#inflight[@]}" -gt 0 ]; then
		echo "  最近启动编译的包（可能还在编）:"
		for c in "${inflight[@]}"; do echo "        $c"; done
	fi

	if [ "$err_n" -gt 0 ]; then
		echo "  ⚠ 检出错误行: $err_n   (grep -nE 'ERROR:|build failed' $LOG)"
	fi

	if grep -qE '^world rc=' "$LOG" 2>/dev/null; then
		echo "  ✔ 构建已结束: $(grep -E '^world rc=' "$LOG" | tail -1)"
	fi
}

if [ "$ONCE" = 1 ]; then emit; exit 0; fi

echo "监视 $LOG（每 ${IV}s 刷新，Ctrl-C 退出）"
while :; do emit; sleep "$IV"; done
