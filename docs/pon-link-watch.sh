#!/bin/sh
# pon-link-watch.sh — 采样 PON 光口的"热状态 + 光功率 + 注册计数器"，用于定位"高温掉光/掉注册"。
#
# 为什么需要它：注册计数器（deregisters / reregisters / register_nacks /
# registered_lifetime_ms）和光前端温度都只存在于运行内存里，设备一旦重启或掉电就
# 全没了。掉线那一刻若没有记录，事后只能猜。让它在后台周期采样，掉线时就能看到
# "温度爬到多少 → 是谁把注册踢掉了"。
#
# 关键判读（LED 语义来自驱动 airoha-xpon-leds.c）：
#   红灯 LOS：仅当"线路在跑但没光"时才 500ms 慢闪；不闪 = 下游有光
#   蓝灯(注册灯)：仅当 EPON mpcp_state == REGISTERED 时亮；灭 = 丢了注册
#   ⇒ 红灯不闪 + 蓝灯灭 = "下游有光、注册丢了"，再看是哪一类：
#        dereg 上涨   → OLT 主动发 DeRegister（多半是 OLT 收不到我们的上行突发）
#        nack  上涨   → OLT 拒绝注册（认证/白名单/冲突）
#        sync_loss/recoveries 上涨 → 本地 PCS 失步（下游侧）
#        last_reg_ms 很短 → 注册反复建立又被踢（闪断）
#
# 部署（在 ONU/路由器上跑，需要固件自带 ponctl）：
#   scp docs/pon-link-watch.sh root@192.168.32.254:/tmp/
#   setsid sh /tmp/pon-link-watch.sh /tmp/pon-watch.log 30 </dev/null >/dev/null 2>&1 &
#   tail -f /tmp/pon-watch.log
#
# 参数：$1 日志文件（默认 /tmp/pon-watch.log） $2 采样间隔秒（默认 30） $3 PON 口（默认 pon0）
# 停止：ps | grep pon-link-watch  然后 kill 对应 pid
set -u

LOG=${1:-/tmp/pon-watch.log}
IV=${2:-30}
DEV=${3:-pon0}
DBG="/sys/kernel/debug/airoha-xpon-$DEV/registration"

# 从单行 JSON 里取一个键的值（键名在本接口内唯一，够用且不依赖 jq）。
jfield() {
	printf '%s' "$1" | sed -n 's/.*"'"$2"'":\([^,}]*\).*/\1/p' | head -n1
}

soc_c() {
	awk '{printf "%.1f", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || printf '?'
}

leds() {
	for d in /sys/class/leds/*/; do
		[ -r "$d/brightness" ] || continue
		printf '%s=%s ' "${d#/sys/class/leds/}" "$(cat "$d/brightness" 2>/dev/null)"
	done
}

echo "# pon-link-watch start $(date '+%F %T') dev=$DEV interval=${IV}s" >>"$LOG"
echo "# 判读：蓝灯(注册灯)灭+红灯不闪 = 下游有光但丢注册 → 看 dereg/nack/sync_loss 谁在涨" >>"$LOG"
printf '# %s\n' \
	"ts soc_C fe_C rx_dbm tx_dbm bias_mA volt optical pcs_sync lifecycle mpcp llid reg_ms last_reg_ms dereg rereg nack mpcp_to sync_loss recov reinit leds" >>"$LOG"

prev_state=''
prev_counters=''
while :; do
	json=$(ponctl --device "$DEV" status --json 2>/dev/null) || json=$(ponctl status --json 2>/dev/null)
	if [ -z "$json" ]; then
		echo "$(date '+%F %T') ponctl-unavailable" >>"$LOG"
		sleep "$IV"
		continue
	fi

	# debugfs 可能没挂载（精简固件/容器），那就退化成只用 ponctl 的计数器。
	reg=''
	[ -r "$DBG" ] && reg=$(cat "$DBG" 2>/dev/null)

	rget() {
		if [ -n "$reg" ]; then
			printf '%s' "$reg" | sed -n 's/^'"$1"':[[:space:]]*//p' | head -n1
		else
			jfield "$json" "$1"
		fi
	}

	optical=$(jfield "$json" optical_signal)
	pcs=$(jfield "$json" pcs_sync)
	state="$optical/$pcs"
	counters="$(rget deregisters)/$(rget reregisters)/$(rget register_nacks)/$(rget mpcp_timeouts)/$(rget sync_losses)/$(rget recoveries)"

	printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
		"$(date '+%F %T')" "$(soc_c)" "$(jfield "$json" temperature_celsius)" \
		"$(jfield "$json" rx_power_dbm)" "$(jfield "$json" tx_power_dbm)" \
		"$(jfield "$json" tx_bias_ma)" "$(jfield "$json" voltage_volts)" \
		"$optical" "$pcs" "$(jfield "$json" lifecycle)" \
		"$(rget mpcp_state)" "$(rget llid)" \
		"$(rget registered_lifetime_ms)" "$(rget last_registration_lifetime_ms)" \
		"$(rget deregisters)" "$(rget reregisters)" "$(rget register_nacks)" \
		"$(rget mpcp_timeouts)" "$(rget sync_losses)" "$(rget recoveries)" \
		>>"$LOG"
	printf '#   %s\n' "$(leds)" >>"$LOG"

	# 链路状态跳变 或 任一注册计数器变化：立刻留证，这是定位的关键证据。
	if [ "$state" != "$prev_state" ] || [ "$counters" != "$prev_counters" ]; then
		echo "### 事件 $(date '+%F %T'): state $prev_state -> $state, counters $prev_counters -> $counters" >>"$LOG"
		[ -n "$reg" ] && printf '%s\n' "$reg" | sed 's/^/###   /' >>"$LOG"
		dmesg | grep -iE 'pon|optical|en7572|bosa|los|sync|deregister|denied|register|link' |
			tail -n 25 | sed 's/^/###   /' >>"$LOG"
		prev_state="$state"
		prev_counters="$counters"
	fi

	sleep "$IV"
done
