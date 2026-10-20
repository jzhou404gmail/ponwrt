#!/bin/sh
#
# airoha-common.sh — shared helpers for Airoha LuCI RPC backends
#
# This file is sourced by the backend scripts. It provides:
#   _run_with_deadline — run a probe behind a wall-clock deadline
#   airoha_has_wifi    — authoritative /sys/class/ieee80211 presence (true/false)
#
# Kept separate from the RPC dispatcher so hardware readers remain reusable.

# Run a command behind a wall-clock deadline so a blocking debugfs snapshot
# cannot hang rpcd forever.
# Usage: _run_with_deadline <seconds> <tag> <cmd> [args...]
# Prints the command's stdout on success; returns 0 on success, 1 on command
# failure, 124 on timeout. Does NOT touch the circuit-breaker file.
_run_with_deadline() {
	local seconds="$1"
	local tag="$2"
	local base output done child_file
	local worker timer child rc
	shift 2

	# /tmp is world-writable and the caller (rpcd) runs as root: a name built
	# from $$ is guessable, and a symlink planted there would be followed by
	# the redirections below. mktemp gives an unpredictable base instead.
	base="$(mktemp "/tmp/airoha-common.${tag}.XXXXXX" 2>/dev/null)" || return 1
	rm -f "$base"
	output="$base.out"
	done="$base.done"
	child_file="$base.child"

	(
		"$@" >"$output" 2>/dev/null &
		child=$!
		printf '%s\n' "$child" >"$child_file"
		wait "$child"
		printf '%s\n' "$?" >"$done"
	) >/dev/null 2>&1 &
	worker=$!

	sleep "$seconds" >/dev/null 2>&1 &
	timer=$!

	wait -n 2>/dev/null
	if kill -0 "$worker" 2>/dev/null && kill -0 "$timer" 2>/dev/null; then
		local elapsed=0
		while [ "$elapsed" -lt "$seconds" ] && [ ! -e "$done" ]; do
			sleep 1
			elapsed=$((elapsed + 1))
		done
	fi

	if [ -e "$done" ]; then
		kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
		wait "$worker" 2>/dev/null
		read -r rc <"$done" 2>/dev/null
		if [ "${rc:-1}" -eq 0 ]; then
			[ ! -s "$output" ] || cat "$output"
			rm -f "$output" "$done" "$child_file"
			return 0
		fi
		rm -f "$output" "$done" "$child_file"
		return 1
	fi

	[ -s "$child_file" ] && { read -r child <"$child_file" 2>/dev/null; kill -9 "$child" 2>/dev/null; }
	kill -9 "$worker" 2>/dev/null; wait "$worker" 2>/dev/null
	kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
	rm -f "$output" "$done" "$child_file"
	return 124
}

# Authoritative wireless presence: does the board expose any ieee80211 phy?
# Prints "true" or "false". The frontend uses this to decide whether to build
# the WiFi gauges and band tables at all.
#
# This is deliberately independent of `iw dev`: on a radio-less board (e.g. the
# XG2010G) iw may still be installed and simply report no interfaces, and
# get_wifi_stats cannot distinguish "no radio" from "radio present, no clients".
# /sys/class/ieee80211/phy* is the ground truth.
airoha_has_wifi() {
	local phy
	for phy in /sys/class/ieee80211/phy*; do
		[ -e "$phy" ] && { echo "true"; return 0; }
	done
	echo "false"
	return 1
}

# `strings` walks the whole firmware blob (hundreds of kB) and getStatus is
# polled every few seconds, so the version is resolved once per boot and keyed
# on the blob it came from. A blob that is not there yet is not cached - an
# early call during boot must not pin "Unknown" for the rest of the uptime.
airoha_npu_version_cache=/tmp/airoha-npu-version.cache

airoha_npu_version() {
	local firmware name version
	local cached_fw="" cached_ver=""

	name=$(airoha_dt_read "soc/npu@1e900000/firmware-name")
	if [ -n "$name" ]; then
		firmware="/lib/firmware/$name"
	elif [ ! -f /lib/firmware/airoha/en7581_npu_rv32.bin ] &&
	     [ -f /lib/firmware/airoha/en7581_MT7996_npu_rv32.bin ]; then
		firmware=/lib/firmware/airoha/en7581_MT7996_npu_rv32.bin
	else
		firmware=/lib/firmware/airoha/en7581_npu_rv32.bin
	fi

	if [ -r "$airoha_npu_version_cache" ]; then
		{ read -r cached_fw; read -r cached_ver; } < "$airoha_npu_version_cache" 2>/dev/null
		if [ -n "$cached_ver" ] && [ "$cached_fw" = "$firmware" ]; then
			printf '%s' "$cached_ver"
			return 0
		fi
	fi

	version=$(strings "$firmware" 2>/dev/null | grep -oE '([0-9]+\.[0-9]+\.[0-9]+-)?TLB[0-9.]+[-_v0-9]*' | head -1)
	if [ -n "$version" ]; then
		printf '%s\n%s\n' "$firmware" "$version" > "$airoha_npu_version_cache" 2>/dev/null
	fi
	printf '%s' "${version:-Unknown}"
}

airoha_bridge_offload_supported() {
	case "$(airoha_board_compat)" in
		gemtek,xg2010g|gemtek,xg2010g-ubi|gemtek,xg2010g-recovery|\
		gemtek,xg2010g-2g|gemtek,xg2010g-2g-ubi|gemtek,xg2010g-2g-recovery) return 1 ;;
		*) return 0 ;;
	esac
}

airoha_ppe_parse() {
	awk -v state_filter="$2" -v limit="${3:-1024}" \
		-f /usr/libexec/airoha-ppe.awk "$1"
}

# >>> airoha-topo-helpers >>>
# ---------------------------------------------------------------------------
# Device-tree-driven port topology and PON facts shared by the LuCI RPC
# backends. POSIX sh; safe to call on
# both the XR1710G (router) and the XG2010G (PON ONU); never writes to stderr.
# ---------------------------------------------------------------------------

# Minimal JSON string sanitiser: drop quotes, backslashes and newlines.
# One tr instead of three: on the topology hot path this helper ran 6 times per
# port, so the old chain cost 18 execs per port for a job one call can do.
# The set is the union of the old three ('"' , '\\', then '\n\r') and is quoted
# so tr - not the shell - sees the backslash: '\\' is tr's escape for one
# backslash, '\r' and '\n' its escapes for CR and LF.
_airoha_json_str() {
	printf '%s' "$1" | tr -d '"\\\r\n'
}

# airoha_dt_read <relpath> — first NUL-terminated string of the DT property.
airoha_dt_read() {
	local path="/proc/device-tree/$1"
	[ -e "$path" ] || return 0
	tr '\0' '\n' < "$path" 2>/dev/null | sed -n '1p'
	return 0
}

# airoha_dt_node_okay <relpath> — 0 iff the node exists and is enabled
# (status "okay", or no status property: the device-tree default).
airoha_dt_node_okay() {
	local node="/proc/device-tree/$1"
	[ -e "$node" ] || return 1
	[ -e "$node/status" ] || return 0
	[ "$(airoha_dt_read "$1/status")" = "okay" ]
}

# Board identity.
airoha_board_model() {
	airoha_dt_read "model"
}

airoha_board_compat() {
	airoha_dt_read "compatible"
}

# Kernel PSE port index for a GDM (matches the frame-engine port map).
airoha_pse_for_gdm() {
	case "$1" in
		1) echo 1 ;;
		2) echo 2 ;;
		3) echo 3 ;;
		4) echo 9 ;;
		*) return 0 ;;
	esac
}

# PON presence.
airoha_pon_present() {
	if [ -d /sys/class/net/pon0 ] || [ -d /proc/xgpon ] || [ -d /proc/epon ] ||
	   [ -e /sys/module/xpon_10g/parameters/mode ] ||
	   { airoha_dt_node_okay "soc/ethernet@1fb50000/ethernet@2" &&
	     [ -e /proc/device-tree/soc/ethernet@1fb50000/ethernet@2/airoha,pon-data-path ]; }; then
		echo 1
	else
		echo 0
	fi
}

# Negotiated PON mode (integer), or nothing.
airoha_pon_mode_int() {
	local f="/sys/module/xpon_10g/parameters/mode"
	[ -r "$f" ] || return 0
	cat "$f" 2>/dev/null
	return 0
}

# Negotiated PON mode name, "unknown" when unrecognised.
airoha_pon_mode_name() {
	case "$(airoha_pon_mode_int)" in
		0) echo auto ;;
		1) echo gpon ;;
		2) echo epon ;;
		3) echo 10g-1g-epon ;;
		4) echo 10g-10g-epon ;;
		5) echo 1g-1g-epon ;;
		6) echo xgpon ;;
		7) echo xgspon ;;
		8) echo ngpon2-10g-10g ;;
		9) echo ngpon2-10g-2g ;;
		10) echo ngpon2-2g-2g ;;
		11) echo gpon-sym ;;
		12) echo turbo-epon ;;
		*)
			local mode
			mode=$(awk '$1 == "active_mode:" { print $2; exit }' /sys/kernel/debug/airoha-xpon-pon0/line 2>/dev/null)
			case "$mode" in
				gpon|xgpon|xgspon|epon|epon-10g-1g|epon-10g-10g) echo "$mode" ;;
				*) echo unknown ;;
			esac
			;;
	esac
}

# PON line rates "<down_mbps> <up_mbps>", "0 0" when unknown. The kernel does
# not expose line rates anywhere, so they are derived from the mode only.
airoha_pon_rates() {
	case "$(airoha_pon_mode_name)" in
		xgpon)          echo "10000 2500" ;;
		xgspon)         echo "10000 10000" ;;
		gpon)           echo "2488 1244" ;;
		gpon-sym)       echo "2488 2488" ;;
		epon)           echo "1250 1250" ;;
		10g-1g-epon|epon-10g-1g) echo "10000 1000" ;;
		10g-10g-epon|epon-10g-10g) echo "10000 10000" ;;
		1g-1g-epon)     echo "1000 1000" ;;
		ngpon2-10g-10g) echo "10000 10000" ;;
		ngpon2-10g-2g)  echo "10000 2000" ;;
		ngpon2-2g-2g)   echo "2000 2000" ;;
		turbo-epon)     echo "2000 2000" ;;
		*)              echo "0 0" ;;
	esac
}

# Optical LOS. /proc/tc3162/los_status uses INVERTED polarity:
#   0 = no light (LOS asserted) -> echo 1 ; 1 = light present -> echo 0 ; else nothing.
airoha_pon_los() {
	local f="/proc/tc3162/los_status"
	local signal=""
	if [ -r "$f" ]; then
		# One less fork per poll, in the read shape documented at
		# _airoha_net_number() below: emptied first because a failed redirect
		# leaves the variable untouched, and -r guarded because 2>/dev/null
		# cannot silence the redirect failure itself. A file that reads empty
		# falls through to the *) branch exactly as an empty $(cat) did.
		# IFS= because `read` would otherwise strip the leading and trailing
		# blanks that a plain $(cat) kept - this attribute is compared verbatim.
		IFS= read -r signal < "$f"
	else
		signal=$(awk '$1 == "optical_signal:" { print $2; exit }' /sys/kernel/debug/airoha-xpon-pon0/line 2>/dev/null)
	fi
	case "$signal" in
		0) echo 1 ;;
		1) echo 0 ;;
		*) return 0 ;;
	esac
}

# GPON ONU state (e.g. "O5"), or nothing.
airoha_pon_onu_state() {
	local f="/proc/xgpon/state"
	local state=""
	if [ -r "$f" ]; then
		# One less fork per poll, in the read shape documented at
		# _airoha_net_number() below: emptied first because a failed redirect
		# leaves the variable untouched, and -r guarded because 2>/dev/null
		# cannot silence the redirect failure itself. IFS= because the value is
		# emitted verbatim. The guard keeps an empty file from printing a bare
		# newline that a plain $(cat) would not have produced.
		IFS= read -r state < "$f"
		[ -n "$state" ] && printf '%s\n' "$state"
	else
		awk '$1 == "onu_state:" && $2 ~ /^O[1-9]$/ { print $2; exit }' \
			/sys/kernel/debug/airoha-xpon-pon0/registration 2>/dev/null
	fi
	return 0
}

# PON datapath netdev (uci pon.line0.device, default "pon").
airoha_pon_netdev() {
	local dev
	dev=$(uci -q get pon.line0.device 2>/dev/null)
	[ -n "$dev" ] || dev="pon0"
	echo "$dev"
}

# Negotiated link speed (Mbps) of a netdev, empty when unavailable
# (missing interface, driver error, link down with "-1" reporting).
_airoha_netdev_speed_mbps() {
	local dev="$1" s=""
	[ -n "$dev" ] || return 0
	[ -e "/sys/class/net/$dev" ] || return 0
	# The guard above tests the interface directory, not the attribute, so the
	# read needs its own -r test. Pre-cleared and -r guarded for the reasons
	# spelled out at _airoha_net_number() below: an unreadable speed file must
	# report "unavailable", not the previous interface's speed. IFS= keeps the
	# value byte-identical to the $(cat) it replaces.
	[ -r "/sys/class/net/$dev/speed" ] && IFS= read -r s < "/sys/class/net/$dev/speed"
	case "$s" in ''|*[!0-9]*) return 0 ;; esac
	[ "$s" -gt 0 ] 2>/dev/null || return 0
	echo "$s"
	return 0
}

# Resolve a GDM node's netdev: prefer openwrt,netdev-name; else the
# /sys/class/net device whose of_node is that node.
_airoha_gdm_netdev() {
	local rel="$1" name iface base onode
	name=$(airoha_dt_read "$rel/openwrt,netdev-name")
	if [ -n "$name" ]; then
		printf '%s' "$name"
		return 0
	fi
	base=$(readlink -f "/proc/device-tree/$rel")
	for iface in /sys/class/net/*; do
		[ -e "$iface/of_node" ] || continue
		onode=$(readlink -f "$iface/of_node" 2>/dev/null)
		[ "$onode" = "$base" ] || continue
		name=$(basename "$iface")
		break
	done
	printf '%s' "${name:-}"
	return 0
}

# Unknown/down-link sysfs values must not look like measured zero counters.
#
# The value is pulled with the `read` builtin instead of $(cat F): this helper
# runs once per port per counter (8 counters + carrier + speed per port), and
# each $(...) costs a fork+exec of ~7 ms on these boards. Two properties of
# `read` force the shape below:
#   1. a failed redirect makes ash skip `read` entirely, so the variable would
#      keep the PREVIOUS port's number and silently duplicate a counter -> the
#      variable is emptied first, preserving "unreadable == null";
#   2. "2>/dev/null" does NOT silence the redirect failure itself (ash reports
#      it while opening the file, before that redirection is in effect), so the
#      -r test guards the read instead - otherwise every missing sysfs node
#      would print a diagnostic on rpcd's stderr.
_airoha_net_number() {
	local value
	value=""
	[ -r "$1" ] && read -r value < "$1"
	case "$value" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$value" ;; esac
}

# Cache fields are line-oriented, so strip the delimiter as well as line breaks.
# The values are sanitized again for JSON when the cached structure is emitted.
_airoha_topology_field() {
	printf '%s' "$1" | tr -d '|\n\r'
}

# Resolve only the boot-stable portion of a port. Live carrier, negotiation and
# counters are deliberately absent: caching any of those would freeze the page.
_airoha_port_struct() {
	local rel="$1" kind="$2" reg="$3" nbq="$4"
	local netdev mode role pse key
	mode=$(airoha_dt_read "$rel/phy-mode")
	if [ "$kind" = "gsw" ]; then
		netdev=$(airoha_dt_read "$rel/label")
		[ -n "$netdev" ] || return
		pse=1
		key="gsw$reg"
		role=lan
		[ -n "$mode" ] || mode=internal
	else
		netdev=$(_airoha_gdm_netdev "$rel")
		pse=$(airoha_pse_for_gdm "$reg")
		key="gdm$reg"
		[ "$nbq" = null ] || key="$key-$nbq"
		role=lan
		[ "$reg" = 2 ] && role=wan
		[ "$mode" = internal ] && role=conduit
		[ -e "/proc/device-tree/$rel/airoha,pon-data-path" ] && role=pon
	fi
	printf 'port|%s|%s|%s|%s|%s|%s|%s|%s' \
		"$(_airoha_topology_field "$netdev")" "$key" "$kind" "$reg" \
		"$nbq" "$pse" "$role" "$(_airoha_topology_field "$mode")"
}

# Join cached identity with the sysfs values that must remain fresh on every
# poll. Keep this key order in lockstep with the original topology contract.
_airoha_cached_port_json() {
	local netdev="$1" key="$2" kind="$3" reg="$4"
	local nbq="$5" pse="$6" role="$7" mode="$8"
	local base field present=false duplex="" carrier speed rates down up=null
	base="/sys/class/net/$netdev"
	[ -n "$netdev" ] && [ -d "$base" ] && present=true
	# Same read-not-cat rule as _airoha_net_number(): emptied first so a failed
	# redirect reports "", and -f guarded so the redirect never fails loudly.
	[ -f "$base/duplex" ] && read -r duplex < "$base/duplex"
	carrier=$(_airoha_net_number "$base/carrier")
	speed=$(_airoha_net_number "$base/speed")
	# The xpon driver publishes speed/duplex sysfs attributes that are always
	# empty, so a PON port that is up and carrying traffic still rendered
	# "N/A". Fall back to the line rate derived from the PON mode
	# (airoha_pon_rates(): XGPON 10G/2.5G, XGSPON 10G/10G, 10G-EPON 10G/1G or
	# 10G/10G, GPON 2.5G/1.25G, ...), and to a flat 10G only when the mode
	# itself could not be read ("0 0"). Two deliberate limits:
	#   - only while carrier is up, so a dark fibre still reads as unknown;
	#   - only when the attribute is genuinely unreadable, so a future driver
	#     that does report the negotiated rate keeps winning.
	# Reached at most once per poll, and only on boards with a PON port.
	# Duplex stays empty on purpose: PON has no duplex attribute to report.
	if [ "$role" = pon ] && [ "$carrier" = 1 ] && [ "$speed" = null ]; then
		rates=$(airoha_pon_rates)
		down="${rates%% *}"
		up="${rates##* }"
		case "$down" in ''|*[!0-9]*) down=0 ;; esac
		case "$up" in ''|*[!0-9]*) up=null ;; esac
		if [ "$down" -gt 0 ] 2>/dev/null; then
			speed="$down"
		else
			# Mode unreadable: there is no up rate to stand behind either, so
			# the placeholder must not claim a 2.5G upstream.
			speed=10000
			up=null
		fi
	fi
	printf '{"key":"%s","kind":"%s","reg":%s,"port":%s,"nbq":%s,"pse":%s,"netdev":"%s","role":"%s","mode":"%s","present":%s' \
		"$(_airoha_json_str "$key")" "$(_airoha_json_str "$kind")" "$reg" "$reg" "$nbq" "$pse" \
		"$(_airoha_json_str "$netdev")" "$(_airoha_json_str "$role")" "$(_airoha_json_str "$mode")" "$present"
	printf ',"carrier":%s,"speed_mbps":%s,"duplex":"%s"' \
		"$carrier" "$speed" "$(_airoha_json_str "$duplex")"
	for field in rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
		printf ',"%s":%s' "$field" "$(_airoha_net_number "$base/statistics/$field")"
	done
	# PON is the only asymmetric link on these boards, so the port row carries
	# its upstream rate too; every other port leaves it null. Appended last so
	# the established key order in front of it is untouched.
	printf ',"speed_up_mbps":%s' "$up"
	printf '}'
}

# Build the device-tree/sysfs identity map once. The temporary name is unique
# per rpcd child and mv publishes only a complete file to concurrent readers.
_airoha_topology_cache_build() {
	local cache="$1" tmp="${1}.$$"
	local model compatible ports="" lan_raw="" lan_lines=""
	local wan_netdev="" lan_count=0 wan_count=0 has_pon port_count=0
	local n rel netdev x child nbq entry children

	model=$(_airoha_topology_field "$(airoha_board_model)")
	compatible=$(_airoha_topology_field "$(airoha_board_compat)")

	# Enabled GDM ports: soc/ethernet@1fb50000/ethernet@N.
	for n in 1 2 3 4; do
		rel="soc/ethernet@1fb50000/ethernet@$n"
		airoha_dt_node_okay "$rel" || continue
		children=0
		for child in /proc/device-tree/"$rel"/ethernet-port@*; do
			[ -d "$child" ] || continue
			children=1
			child="${child#/proc/device-tree/}"
			airoha_dt_node_okay "$child" || continue
			nbq="${child##*@}"
			case "$nbq" in ''|*[!0-9a-fA-F]*) continue ;; esac
			entry=$(_airoha_port_struct "$child" gdm "$n" "$((0x$nbq))")
			# Counted as they are appended rather than by re-scanning $ports:
			# the count is a header record the validator checks, so it has to
			# come from the same pass that produced the rows.
			if [ -n "$entry" ]; then
				ports="${ports}${entry}
"
				port_count=$((port_count + 1))
			fi
		done
		[ "$children" = 0 ] || continue
		entry=$(_airoha_port_struct "$rel" gdm "$n" null)
		if [ -n "$entry" ]; then
			ports="${ports}${entry}
"
			port_count=$((port_count + 1))
		fi
		netdev=$(_airoha_gdm_netdev "$rel")
		if [ "$n" = 2 ]; then
			[ -n "$netdev" ] && wan_netdev="$netdev"
		fi
	done

	# Enabled, labelled DSA user ports: soc/switch@1fb58000/ports/port@N.
	# The switch CPU/conduit port (@6) carries no label and is skipped.
	for n in 1 2 3 4; do
		rel="soc/switch@1fb58000/ports/port@$n"
		airoha_dt_node_okay "$rel" || continue
		netdev=$(airoha_dt_read "$rel/label")
		[ -n "$netdev" ] || continue
		entry=$(_airoha_port_struct "$rel" gsw "$n" null)
		if [ -n "$entry" ]; then
			ports="${ports}${entry}
"
			port_count=$((port_count + 1))
		fi
		lan_raw="${lan_raw}${netdev}
"
	done

	# LAN membership is structural for a booted board. Store one record per
	# netdev instead of embedding JSON, which keeps the cache POSIX-sh friendly.
	local d
	for d in /sys/class/net/lan*; do
		[ -e "$d" ] || continue
		lan_raw="${lan_raw}$(basename "$d")
"
	done
	for x in $(printf '%s' "$lan_raw" | grep -E '^lan[0-9]+$' | sort -u); do
		lan_lines="${lan_lines}lan|$(_airoha_topology_field "$x")
"
		lan_count=$((lan_count + 1))
	done

	wan_netdev=$(_airoha_topology_field "$wan_netdev")
	[ -n "$wan_netdev" ] && wan_count=1
	has_pon=$(airoha_pon_present)

	# Publication time, so the reader can expire the file: structure is static,
	# but not everything is present at the first poll - the xpon module and any
	# late DSA port load after it, and without an expiry has_pon would stay
	# pinned at whatever that first sample saw and null the PON block forever.
	# Left empty when date is unavailable; the validator then trusts the file
	# rather than rebuilding on every call.
	local now
	now=$(date +%s 2>/dev/null)
	case "$now" in ''|*[!0-9]*) now="" ;; esac

	rm -f "$tmp"
	(umask 077; {
		printf 'version|1\n'
		printf 'model|%s\n' "$model"
		printf 'compatible|%s\n' "$compatible"
		printf 'wan_netdev|%s\n' "$wan_netdev"
		printf 'lan_count|%s\n' "$lan_count"
		printf 'wan_count|%s\n' "$wan_count"
		printf 'has_pon|%s\n' "$has_pon"
		# Port rows are last in the file, so a tail truncation drops them and
		# nothing else: without this record the validator cannot tell 9 ports
		# from 8 and accepts a silently short topology.
		printf 'port_count|%s\n' "$port_count"
		printf 'ts|%s\n' "$now"
		# INVARIANT: every row ends with a newline, so a complete file always
		# ends with one. _airoha_topology_cache_valid() rejects a tail the
		# shell had to rescue from EOF, and that is only sound while this
		# holds - drop the newline on the last row and every cache would be
		# rejected, turning a once-a-minute rebuild into one per poll. Perf
		# only, no wrong values, which is why the check errs that way.
		printf '%s' "$lan_lines"
		printf '%s' "$ports"
	} > "$tmp") 2>/dev/null || { rm -f "$tmp"; return 1; }
	[ -s "$tmp" ] && mv -f "$tmp" "$cache" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
}

# Reject partial or malformed cache files before using them, and expire them so
# hardware that appears after the first poll is picked up. This makes a
# power-loss/truncated file self-healing on the next dashboard request.
_airoha_topology_cache_valid() {
	local cache="$1" record f1 f2 f3 f4 f5 f6 f7 f8 extra
	local version_seen=0 model_seen=0 compatible_seen=0 wan_seen=0
	local lan_count_seen=0 wan_count_seen=0 pon_seen=0
	local port_count_seen=0 ts_seen=0
	local lan_count=0 port_count=0
	local cached_lan_count="" cached_port_count="" cached_ts="" now age
	local partial=0
	[ -s "$cache" ] || return 1
	# `|| { partial=1; [ -n "$record" ]; }` pulls a final line with no trailing
	# newline into the body instead of letting read drop it - a complete cache
	# always ends with one, every row being appended with it, so a rescued tail
	# can only come from a write that was cut short. It is rejected outright
	# rather than field-checked: a row cut inside its last field is still
	# field-valid, and would otherwise pass every check below and publish a
	# silently wrong value.
	while IFS='|' read -r record f1 f2 f3 f4 f5 f6 f7 f8 extra || { partial=1; [ -n "$record" ]; }; do
		[ "$partial" = 1 ] && return 1
		case "$record" in
			version)
				[ "$version_seen" = 0 ] && [ "$f1" = 1 ] && [ -z "$f2" ] || return 1
				version_seen=1
				;;
			model)
				[ "$model_seen" = 0 ] && [ -z "$f2" ] || return 1
				model_seen=1
				;;
			compatible)
				[ "$compatible_seen" = 0 ] && [ -z "$f2" ] || return 1
				compatible_seen=1
				;;
			wan_netdev)
				[ "$wan_seen" = 0 ] && [ -z "$f2" ] || return 1
				wan_seen=1
				;;
			lan_count)
				[ "$lan_count_seen" = 0 ] && [ -z "$f2" ] || return 1
				case "$f1" in ''|*[!0-9]*) return 1 ;; esac
				cached_lan_count="$f1"
				lan_count_seen=1
				;;
			wan_count)
				[ "$wan_count_seen" = 0 ] && [ -z "$f2" ] || return 1
				case "$f1" in 0|1) ;; *) return 1 ;; esac
				wan_count_seen=1
				;;
			has_pon)
				[ "$pon_seen" = 0 ] && [ -z "$f2" ] || return 1
				case "$f1" in 0|1) ;; *) return 1 ;; esac
				pon_seen=1
				;;
			port_count)
				[ "$port_count_seen" = 0 ] && [ -z "$f2" ] || return 1
				case "$f1" in ''|*[!0-9]*) return 1 ;; esac
				cached_port_count="$f1"
				port_count_seen=1
				;;
			ts)
				[ "$ts_seen" = 0 ] && [ -z "$f2" ] || return 1
				case "$f1" in
					'') cached_ts="" ;;
					*[!0-9]*) return 1 ;;
					*) cached_ts="$f1" ;;
				esac
				ts_seen=1
				;;
			lan)
				[ -n "$f1" ] && [ -z "$f2" ] || return 1
				lan_count=$((lan_count + 1))
				;;
			port)
				[ -n "$f2" ] && [ -n "$f3" ] && [ -n "$f7" ] && [ -z "$extra" ] || return 1
				case "$f4" in ''|*[!0-9]*) return 1 ;; esac
				case "$f5" in null) ;; ''|*[!0-9]*) return 1 ;; esac
				case "$f6" in ''|*[!0-9]*) return 1 ;; esac
				port_count=$((port_count + 1))
				;;
			*) return 1 ;;
		esac
	done < "$cache"
	[ "$version_seen$model_seen$compatible_seen$wan_seen$lan_count_seen$wan_count_seen$pon_seen$port_count_seen$ts_seen" = 111111111 ] || return 1
	[ "$lan_count" -eq "$cached_lan_count" ] 2>/dev/null || return 1
	[ "$port_count" -eq "$cached_port_count" ] 2>/dev/null || return 1
	# Only a clock the cache itself was stamped with can expire it: an empty ts
	# means date was missing at build time, and rebuilding every poll on such a
	# box would be far worse than trusting a slightly old structure.
	[ -n "$cached_ts" ] || return 0
	now=$(date +%s 2>/dev/null)
	case "$now" in ''|*[!0-9]*) return 0 ;; esac
	# A cache stamped in the future is clock skew, not corruption: without this
	# the age below goes negative and "-le 60" would accept it by accident.
	[ "$now" -ge "$cached_ts" ] 2>/dev/null || return 0
	age=$((now - cached_ts))
	# Strictly less than, matching the PPE cache: a 2 s TTL there means
	# [0, 2), so 60 s here means [0, 60) and a cache is fresh for 60 whole
	# seconds, expiring on the 61st.
	[ "$age" -lt 60 ]
}

# Include split GDM/NBQ children as separate netdevs, never shared MIB samples.
# Only structure is cached; all link/MIB values and the whole PON block are read
# live so registration and traffic changes remain visible between polls.
airoha_port_topology_json() {
	local cache="/tmp/airoha-topology.struct"
	local model="" compatible="" wan_netdev="" lan_count=0 wan_count=0 has_pon=0
	local record f1 f2 f3 f4 f5 f6 f7 f8 extra entry
	local ports="" lan_json="" first=1

	if ! _airoha_topology_cache_valid "$cache"; then
		_airoha_topology_cache_build "$cache" || {
			printf '{"model":"","compatible":"","lan_netdevs":[],"wan_netdev":"","lan_count":0,"wan_count":0,"has_pon":0,"ports":[],"pon":null}'
			return
		}
		if ! _airoha_topology_cache_valid "$cache"; then
			printf '{"model":"","compatible":"","lan_netdevs":[],"wan_netdev":"","lan_count":0,"wan_count":0,"has_pon":0,"ports":[],"pon":null}'
			return
		fi
	fi

	while IFS='|' read -r record f1 f2 f3 f4 f5 f6 f7 f8 extra; do
		case "$record" in
			model) model="$f1" ;;
			compatible) compatible="$f1" ;;
			wan_netdev) wan_netdev="$f1" ;;
			lan_count) lan_count="$f1" ;;
			wan_count) wan_count="$f1" ;;
			has_pon) has_pon="$f1" ;;
			lan)
				[ "$first" = 1 ] || lan_json="${lan_json},"
				first=0
				lan_json="${lan_json}\"$(_airoha_json_str "$f1")\""
				;;
			port)
				entry=$(_airoha_cached_port_json "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" "$f7" "$f8")
				[ -z "$ports" ] || ports="$ports,"
				ports="$ports$entry"
				;;
		esac
	done < "$cache"
	lan_json="[${lan_json}]"

	local pon_json
	if [ "$has_pon" = 1 ]; then
		local pmode pname pdown pup plos ponu pdev rates
		rates=$(airoha_pon_rates)
		pmode=$(airoha_pon_mode_int)
		case "$pmode" in ''|*[!0-9]*) pmode=null ;; esac
		pname=$(airoha_pon_mode_name)
		pdown=$(printf '%s' "$rates" | awk '{print $1}')
		pup=$(printf '%s' "$rates" | awk '{print $2}')
		case "$pdown" in ''|*[!0-9]*) pdown=0 ;; esac
		case "$pup" in ''|*[!0-9]*) pup=0 ;; esac
		plos=$(airoha_pon_los)
		case "$plos" in ''|*[!0-9]*) plos=null ;; esac
		ponu=$(airoha_pon_onu_state)
		pdev=$(airoha_pon_netdev)
		pon_json="{\"present\":${has_pon},\"mode\":${pmode},\"mode_name\":\"$(_airoha_json_str "$pname")\",\"down_mbps\":${pdown},\"up_mbps\":${pup},\"los\":${plos},\"onu_state\":\"$(_airoha_json_str "$ponu")\",\"netdev\":\"$(_airoha_json_str "$pdev")\"}"
	else
		pon_json="null"
	fi

	printf '{"model":"%s","compatible":"%s","lan_netdevs":%s,"wan_netdev":"%s","lan_count":%d,"wan_count":%d,"has_pon":%d,"ports":[%s],"pon":%s}' \
		"$(_airoha_json_str "$model")" "$(_airoha_json_str "$compatible")" "$lan_json" "$(_airoha_json_str "$wan_netdev")" \
		"$lan_count" "$wan_count" "$has_pon" "$ports" "$pon_json"
}
# <<< airoha-topo-helpers <<<

# Per-band wireless health shared by the unified NPU page. XR1710G exposes
# three MT7996 bands; XG2010G has no radio and returns has_wifi=false.
airoha_wifi_stats_json() {
	local all_ifaces iface band_idx freq d
	local dump0="" dump1="" dump2="" ifaces0="" ifaces1="" ifaces2=""

	if ! command -v iw >/dev/null 2>&1; then
		printf '{"available":false,"has_wifi":%s,"bands":[]}' "$(airoha_has_wifi)"
		return
	fi

	all_ifaces=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type AP/{print iface}')
	[ -n "$all_ifaces" ] || {
		printf '{"available":true,"has_wifi":%s,"bands":[]}' "$(airoha_has_wifi)"
		return
	}

	for iface in $all_ifaces; do
		band_idx=$(printf '%s' "$iface" | sed -n 's/^[^.]*\.\([0-9][0-9]*\)-.*/\1/p')
		if [ -z "$band_idx" ]; then
			freq=$(iw dev "$iface" info 2>/dev/null | grep 'channel' | \
				grep -oE '[0-9]+' | awk '$0+0 > 1000 { print $0+0; exit }')
			case "$freq" in ''|*[!0-9]*) continue ;; esac
			if [ "$freq" -ge 5925 ]; then band_idx=2
			elif [ "$freq" -ge 5000 ]; then band_idx=1
			else band_idx=0
			fi
		fi

		case "$band_idx" in
			0) ifaces0="${ifaces0} ${iface}" ;;
			1) ifaces1="${ifaces1} ${iface}" ;;
			2) ifaces2="${ifaces2} ${iface}" ;;
			*) continue ;;
		esac

		d=$(iw dev "$iface" station dump 2>/dev/null)
		[ -n "$d" ] || continue
		case "$band_idx" in
			0) dump0="${dump0}
${d}" ;;
			1) dump1="${dump1}
${d}" ;;
			2) dump2="${dump2}
${d}" ;;
		esac
	done

	local now sta_tx0 sta_tx1 sta_tx2 tx_values tx0_mbps tx1_mbps tx2_mbps
	now=$(date +%s 2>/dev/null || awk '{printf "%d",$1}' /proc/uptime)
	sta_tx0=$(printf '%s\n' "$dump0" | awk '/tx bytes:/{t+=$NF} END{printf "%d",t+0}')
	sta_tx1=$(printf '%s\n' "$dump1" | awk '/tx bytes:/{t+=$NF} END{printf "%d",t+0}')
	sta_tx2=$(printf '%s\n' "$dump2" | awk '/tx bytes:/{t+=$NF} END{printf "%d",t+0}')
	tx_values=$(awk -v now="$now" -v c0="$sta_tx0" -v c1="$sta_tx1" -v c2="$sta_tx2" '
		BEGIN {
			pf = "/tmp/npu-wifi-bytes.prev"; tx0="0.0"; tx1="0.0"; tx2="0.0"
			if ((getline line < pf) > 0) {
				split(line, a); dt = now - (a[1]+0)
				if (a[1]+0 > 0 && dt > 0) {
					d0=c0-a[2]; if (d0<0) d0=0
					d1=c1-a[3]; if (d1<0) d1=0
					d2=c2-a[4]; if (d2<0) d2=0
					tx0=sprintf("%.1f",d0/dt/125000)
					tx1=sprintf("%.1f",d1/dt/125000)
					tx2=sprintf("%.1f",d2/dt/125000)
				}
			}
			printf "%s %s %s", tx0, tx1, tx2
		}' /dev/null)
	printf '%s %s %s %s\n' "$now" "$sta_tx0" "$sta_tx1" "$sta_tx2" > /tmp/npu-wifi-bytes.prev
	tx0_mbps=$(printf '%s\n' "$tx_values" | awk '{print $1}')
	tx1_mbps=$(printf '%s\n' "$tx_values" | awk '{print $2}')
	tx2_mbps=$(printf '%s\n' "$tx_values" | awk '{print $3}')

	local bands_json="" dump tx_mbps stats sta_tx_raw
	for band_idx in 0 1 2; do
		case "$band_idx" in
			0) [ -n "$ifaces0" ] || continue; dump="$dump0"; tx_mbps="$tx0_mbps"; sta_tx_raw="$sta_tx0" ;;
			1) [ -n "$ifaces1" ] || continue; dump="$dump1"; tx_mbps="$tx1_mbps"; sta_tx_raw="$sta_tx1" ;;
			2) [ -n "$ifaces2" ] || continue; dump="$dump2"; tx_mbps="$tx2_mbps"; sta_tx_raw="$sta_tx2" ;;
		esac

		stats=$(printf '%s\n' "$dump" | awk '
			BEGIN { stations=0; tx_pkts=0; tx_retries=0; tx_failed=0; sum_phy=0; sum_exp=0; phy_n=0; exp_n=0; sum_sig=0; sig_n=0; min_sig=0 }
			/^Station / { stations++ }
			/tx packets:/ { tx_pkts += $3+0 }
			/tx retries:/ { tx_retries += $3+0 }
			/tx failed:/ { tx_failed += $3+0 }
			/tx bitrate:/ { sum_phy += $3+0; phy_n++ }
			/expected throughput:/ { v=$3+0; if (v>0) { sum_exp+=v; exp_n++ } }
			/signal avg:/ {
				for (i=1; i<=NF; i++) if ($i ~ /^-[0-9]+$/) {
					sig=$i+0; sum_sig+=sig; sig_n++; if (sig_n==1 || sig<min_sig) min_sig=sig; break
				}
			}
			END {
				avg_phy=phy_n ? sum_phy/phy_n : 0; avg_exp=exp_n ? sum_exp/exp_n : 0
				eff=avg_phy>0 ? int(avg_exp/avg_phy*100) : 0
				retry=(tx_pkts+tx_retries)>0 ? int(tx_retries/(tx_pkts+tx_retries)*100) : 0
				avg_sig=sig_n ? int(sum_sig/sig_n) : 0
				printf "%d %d %d %d %.1f %.1f %d %d %d %d", stations, tx_pkts, tx_retries, tx_failed, avg_phy, avg_exp, eff, retry, avg_sig, min_sig
			}')
		set -- $stats
		[ -n "$bands_json" ] && bands_json="${bands_json},"
		bands_json="${bands_json}{\"band\":${band_idx},\"stations\":${1:-0},\"tx_packets\":${2:-0},\"tx_retries\":${3:-0},\"tx_failed\":${4:-0},\"avg_phy_rate\":${5:-0},\"avg_exp_throughput\":${6:-0},\"airtime_efficiency\":${7:-0},\"retry_pct\":${8:-0},\"avg_signal\":${9:-0},\"min_signal\":${10:-0},\"tx_mbps\":${tx_mbps:-0},\"tx_bytes_raw\":${sta_tx_raw:-0}}"
	done

	printf '{"available":true,"has_wifi":%s,"bands":[%s]}' "$(airoha_has_wifi)" "$bands_json"
}
