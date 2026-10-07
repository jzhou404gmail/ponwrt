#!/bin/bash
# PonWrt 编译实时观察器（不依赖日志）
#
# 和 build-watch.sh 的区别：
#   build-watch.sh  读构建日志 —— 需要编译时把输出写进文件（./build.sh 会做）
#   build-live.sh   直接看【进程 + 文件系统】—— 任何启动方式都能用，包括裸 make -j$(nproc)
#
# 用法:
#   ./build-live.sh            # 每 20 秒一块
#   ./build-live.sh --iv=10    # 每 10 秒
#   ./build-live.sh --fast     # 跳过"文件改动统计"（那个较慢），只显示进程信息

cd "$(dirname "$0")" || exit 1
IV=20
FAST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--fast)  FAST=1; shift ;;
		--iv=*)  IV="${1#--iv=}"; shift ;;
		[0-9]*)  IV="$1"; shift ;;
		*) shift ;;
	esac
done

emit() {
	local load nproc elapsed
	load=$(cut -d' ' -f1 /proc/loadavg)
	nproc=$(nproc)

	# 已运行时长：把所有 make 进程的 etime 换算成秒，取最大的那个
	elapsed=$(ps -eo etime,cmd 2>/dev/null | grep -E '[m]ake -j|[m]ake -r|[m]ake --jobserver' | awk '{print $1}' | awk -F'[-:]' '
		{ n=NF; s=0
		  if (n==4) { s=$1*86400; s+= $2*3600 + $3*60 + $4 }
		  else if (n==3) { s=$1*3600 + $2*60 + $3 }
		  else if (n==2) { s=$1*60 + $2 }
		  else s=$1
		  if (s>max) { max=s; txt=$0 } }
		END { printf "%dh%02dm%02ds", max/3600, (max%3600)/60, max%60 }')
	[ -n "$elapsed" ] || elapsed="(未发现 make 进程)"

	echo "────────── $(date +%T) ──────────"

	if [ -z "$elapsed" ]; then
		echo "  ✗ 没有发现 make 进程 —— 编译没在跑？"
	fi
	echo "  系统负载: ${load} / ${nproc} 核"
	[ -n "$elapsed" ] && echo "  编译已运行: ${elapsed}"

	# 正在编译什么：从进程命令行里抽出 build_dir 路径
	local -a pkgs
	mapfile -t pkgs < <(
		ps -eo cmd 2>/dev/null \
		| grep -oE '(hostpkg|target-[a-z0-9_-]+)/[^ ]+' \
		| grep -vE '^(hostpkg|target-[a-z0-9_-]+)/?$' \
		| sed -e 's|^hostpkg/|host: |' -e 's|^target-[a-z0-9_-]*/|target: |' \
		| sed -e 's|/build/.$||' -e 's|/\.$||' -e 's|/.*||' \
		| sort -u | head -6
	)
	if [ "${#pkgs[@]}" -gt 0 ]; then
		echo "  正在编译:"
		for p in "${pkgs[@]}"; do echo "        $p"; done
	fi

	# 编译进程数
	local nc
	nc=$(ps -eo cmd 2>/dev/null | grep -cE '[c]c1|[g]\+\+|[c]lang|[a]s -|[l]d ')
	echo "  编译进程数: ${nc}"

	# 文件改动统计（较慢，--fast 可跳过）
	if [ "$FAST" -ne 1 ]; then
		local chg
		chg=$(timeout 25 find build_dir -newermt '-60 seconds' -type f 2>/dev/null | wc -l)
		echo "  近60秒改动: ${chg} 个文件  $([ "${chg:-0}" -gt 0 ] && echo '→ 在推进 ✓' || echo '→ 静止')"
	fi
}

if [ "${1:-}" = "--once" ]; then emit; exit 0; fi

echo "实时观察（每 ${IV}s 一块，Ctrl-C 退出）"
while :; do emit; sleep "$IV"; done
