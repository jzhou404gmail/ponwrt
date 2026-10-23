#!/bin/sh
# usb-bench.sh - USB 存储读写测速（OpenWrt / BusyBox 环境）
#
# 用法:
#   usb-bench.sh /mnt/sda1 /mnt/sdb2 ...
#   READ_MB=1024 WRITE_MB=64 SMALL_MB=64 usb-bench.sh /mnt/sdb2
#
# 说明:
#   * 只写临时文件 .usb_bench.tmp / .usb_bench4k.tmp，测完删除，不改动用户数据
#   * 读测试用 O_DIRECT 绕过页缓存；写测试 oflag=direct + conv=fsync
#   * 需要 dd 支持 iflag=direct / oflag=direct（BusyBox >= 1.31 一般都有）

READ_MB=${READ_MB:-512}
WRITE_MB=${WRITE_MB:-64}
SMALL_MB=${SMALL_MB:-32}

now() { cut -d' ' -f1 /proc/uptime; }

run() { # run <描述> <字节数> <命令...>
	d=$1; b=$2; shift 2
	t0=$(now)
	"$@" >/dev/null 2>&1; rc=$?
	t1=$(now)
	awk -v d="$d" -v b="$b" -v t0="$t0" -v t1="$t1" -v rc="$rc" 'BEGIN{
		t = t1 - t0; if (t < 0.005) t = 0.005;
		printf "  %-44s %7.1f MB / %7.3f s = %7.2f MB/s%s\n",
			d, b/1048576, t, b/1048576/t, (rc ? "  [rc=" rc "]" : "")
	}'
}

drop() { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; }

raw_dev() { # 从分区设备名推出整盘设备名：sdb2 -> sdb, mmcblk0p1 -> mmcblk0
	case "$1" in
		*mmcblk*p*) echo "${1%p*}" ;;
		*nvme*n*)   echo "${1%p*}" ;;
		*)          echo "$1" | sed 's/[0-9]*$//' ;;
	esac
}

for mp in "$@"; do
	[ -d "$mp" ] || { echo "跳过不存在的挂载点: $mp"; continue; }
	dev=$(df -P "$mp" 2>/dev/null | awk 'NR==2{print $1}')
	[ -b "$dev" ] || { echo "跳过：$mp 不是块设备挂载点（$dev）"; continue; }
	raw=$(raw_dev "$dev")

	echo "===== $mp  ($dev, 底层 $raw) ====="
	drop
	run "裸设备顺序读 ${READ_MB}M (1M direct)" $((READ_MB*1048576)) \
		dd if="$raw" of=/dev/null bs=1M count=$READ_MB iflag=direct

	drop
	run "4K 小块顺序读 ${SMALL_MB}M (direct)" $((SMALL_MB*1048576)) \
		dd if="$raw" of=/dev/null bs=4k count=$((SMALL_MB*256)) iflag=direct

	drop
	run "顺序写 ${WRITE_MB}M (direct+fsync)" $((WRITE_MB*1048576)) \
		dd if=/dev/zero of="$mp/.usb_bench.tmp" bs=1M count=$WRITE_MB oflag=direct conv=fsync

	drop
	run "回读 ${WRITE_MB}M (direct)" $((WRITE_MB*1048576)) \
		dd if="$mp/.usb_bench.tmp" of=/dev/null bs=1M iflag=direct

	rm -f "$mp/.usb_bench.tmp"
	echo "  剩余空间: $(df -h "$mp" | awk 'NR==2{print $4" / "$2}')"
	echo
done
