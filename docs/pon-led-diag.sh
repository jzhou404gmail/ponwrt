#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# pon-led-diag.sh —— 面板灯取证：把"哪个 sysfs 灯 = 面板哪个位置、什么颜色"和
# "上网灯为什么没亮"一次性查清，不用靠猜。
#
# 背景：驱动里的四个 PON 触发器（airoha-xpon-leds.c）语义是
#   pon0-registration : EPON 看 mpcp_state==REGISTERED / XG(S)PON 看 O5 → 常亮
#   pon0-los          : "线路在跑但没光" → 500ms 慢闪；有光 → 灭（传统语义）
#   pon0-signal       : 有光 → 常亮；线路在跑但没光 → 500ms 慢闪（本 fork 给"光信号"灯用）
#   pon0-online       : "线路在跑 + 有光 + service_ready" → 常亮
# service_ready 在 EPON 上只由用户态 OAM 代理（airoha-pond）在**CTC 认证通过**之后才写；
# 只跑 MPCP + PPPoE 的线路上它永远是 0。所以本 fork 的「上网」灯改成由
# /usr/libexec/pon-internet-led 主动探测互联网（通=常亮），这一段用 status 模式看。
#
# 用法（在光猫上跑，需要有 ponctl / pondctl）：
#   scp docs/pon-led-diag.sh root@<光猫IP>:/tmp/
#   sh /tmp/pon-led-diag.sh              # 只打印状态，不动任何灯
#   sh /tmp/pon-led-diag.sh walk         # 逐个点亮每个灯，默认每个 3 秒（盯着面板看）
#   sh /tmp/pon-led-diag.sh walk 5       # 每个灯亮 5 秒
#   sh /tmp/pon-led-diag.sh probe 1 9    # 直接拉某个 GPIO（可选，见 probe() 里的警告）
#
# walk 结束后会把每个灯的 trigger 恢复原样（脚本自己记着），不用重启。

set -u

MODE=${1:-status}
HOLD=${2:-3}
LEDS=/sys/class/leds

say() { printf '\n=== %s ===\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

show_status() {
	say "系统"
	[ -f /etc/openwrt_release ] && . /etc/openwrt_release &&
		printf '固件      : %s %s (%s)\n' "$DISTRIB_ID" "$DISTRIB_RELEASE" "$DISTRIB_REVISION"
	printf '内核      : %s\n' "$(uname -r)"
	[ -r /proc/device-tree/model ] && printf '机型      : %s\n' "$(tr -d '\0' </proc/device-tree/model)"
	printf '启动时长  : %s\n' "$(cut -d. -f1 /proc/uptime)s"

	say "xPON 链路（ponctl）"
	if have ponctl; then
		ponctl status --json 2>/dev/null || ponctl status 2>/dev/null || echo "ponctl 读取失败"
	else
		echo "没有 ponctl"
	fi

	say "线路上报模式 / PON 网口"
	for i in /sys/class/net/pon*; do
		[ -e "$i" ] || continue
		printf '%s: carrier=%s operstate=%s\n' "${i##*/}" \
			"$(cat "$i/carrier" 2>/dev/null)" "$(cat "$i/operstate" 2>/dev/null)"
	done

	say "内核注册状态（debugfs，若已挂载）"
	for d in /sys/kernel/debug/airoha-xpon-*/registration; do
		[ -r "$d" ] || continue
		echo "--- $d"
		cat "$d"
	done

	say "用户态 OAM/OMCI 代理（service_ready 的写入方）"
	if have pondctl; then
		pondctl status --line pon0 2>/dev/null || echo "pondctl 读取失败（代理没起来？）"
	else
		echo "没有 pondctl"
	fi
	ps w 2>/dev/null | grep '[a]iroha-pond' || echo "airoha-pond 没有在跑"

	say "「上网」灯：主动探测服务"
	if [ -x /usr/libexec/pon-internet-led ]; then
		/etc/init.d/pon-internet-led running >/dev/null 2>&1 &&
			echo "服务      : running" || echo "服务      : 没在跑（灯此时归内核触发器管）"
		/usr/libexec/pon-internet-led status
		echo "手动探一次  : pon-internet-led once   （只探一次、顺带更新灯）"
	else
		echo "没有 /usr/libexec/pon-internet-led（老固件？）"
	fi

	say "内核触发器与驱动的注册日志"
	dmesg 2>/dev/null | grep -iE 'PON LED triggers|LED .*trigger|leds-gpio' | tail -n 20

	say "LED 类设备（名字 / 当前触发器 / 亮度）"
	printf '%-34s %-16s %s\n' NAME TRIGGER BRIGHTNESS
	for d in "$LEDS"/*; do
		[ -r "$d/trigger" ] || continue
		trig=$(sed 's/.*\[\([^]]*\)\].*/\1/' "$d/trigger" 2>/dev/null)
		printf '%-34s %-16s %s\n' "${d##*/}" "$trig" "$(cat "$d/brightness" 2>/dev/null)"
	done

	say "GPIO 占用情况（gpiochip 全局编号 + 谁在用）"
	if [ -r /sys/kernel/debug/gpio ]; then
		cat /sys/kernel/debug/gpio
	else
		echo "debugfs 没挂（mount -t debugfs none /sys/kernel/debug 后可再看）"
	fi
}

# 直接驱动一个 GPIO（可选，用于"这个脚上是不是还挂着一颗灯珠"的排查）
#
# 只在已经确认过 /sys/kernel/debug/gpio 的前提下用：参数是 **gpiochip 全局编号**
# （不是板子丝印上的脚号）。脚本会拒绝已经被占用的脚和已知危险脚。
probe() {
	[ $# -gt 0 ] || {
		echo "用法: $0 probe <全局GPIO号> [<号> ...]   （先看 status 里的 gpiochip 段）" >&2
		exit 1
	}

	say "GPIO 点灯排查（每个脚 先拉低 2s、再拉高 2s；结束后 unexport）"
	echo "!! 只对 /sys/kernel/debug/gpio 里没有 consumer 的脚用；点之前想清楚这个脚可能接什么"
	for n in "$@"; do
		case "$n" in
		# 已知危险/占用的脚：并行 NAND(GPIO17-29)、PON TX_DISABLE(38)、复位键(35)、
		# 面板 LED(13/14/15/16/43-46)、USB 供电相关
		17|18|19|20|21|22|23|24|25|26|27|28|29|35|38|43|44|45|46)
			echo "跳过 $n：这是已知被占用的脚（NAND/TX_DISABLE/按键/面板灯）"
			continue ;;
		esac

		if grep -q "^gpio-$n  *(.*:.*)" /sys/kernel/debug/gpio 2>/dev/null; then
			echo "跳过 $n：已被占用 → $(grep "^gpio-$n " /sys/kernel/debug/gpio)"
			continue
		fi

		echo ">>> gpio-$n: 拉低（若该脚挂着低有效的灯，这时会亮）"
		echo "$n" >/sys/class/gpio/export 2>/dev/null || {
			echo "    export 失败（脚不存在或已被占用）"
			continue
		}
		echo out >"/sys/class/gpio/gpio$n/direction" 2>/dev/null || true
		echo 0 >"/sys/class/gpio/gpio$n/value" 2>/dev/null || true
		sleep 2
		echo ">>> gpio-$n: 拉高"
		echo 1 >"/sys/class/gpio/gpio$n/value" 2>/dev/null || true
		sleep 2
		echo "$n" >/sys/class/gpio/unexport 2>/dev/null || true
	done
	echo ">>> 排查结束"
}

walk() {
	say "逐个点亮（每个 ${HOLD} 秒，请对照面板记下位置和颜色）"
	for d in "$LEDS"/*; do
		[ -w "$d/brightness" ] || continue
		name=${d##*/}
		restore=$(sed 's/.*\[\([^]]*\)\].*/\1/' "$d/trigger" 2>/dev/null)
		[ -n "$restore" ] || restore=none

		printf '>>> %-34s (原触发器 %s) 请看面板\n' "$name" "$restore"

		echo "$restore" >"$d/trigger" 2>/dev/null || true
		echo none >"$d/trigger" 2>/dev/null || true
		echo 1 >"$d/brightness" 2>/dev/null || true
		sleep "$HOLD"
		echo 0 >"$d/brightness" 2>/dev/null || true
		sleep 1
		echo "$restore" >"$d/trigger" 2>/dev/null || true
	done
	echo ">>> 全部恢复原触发器"
}

case "$MODE" in
walk) show_status; walk ;;
probe) shift; probe "$@" ;;
status|"") show_status ;;
*) echo "用法: $0 [status|walk|probe <GPIO号>...] [每个灯亮的秒数]" >&2; exit 1 ;;
esac

exit 0
