#!/bin/sh
# Device-side probe for the CDM (CPU DMA) counter bank behind the CDM1/CDM2
# cards of the Airoha SoC status page.
#
# Run it ON the router (it needs /dev/mem and the busybox devmem applet):
#
#   scp docs/luci-app-airoha-npu-port/tests/cdm_regs.sh root@<router>:/tmp/
#   ssh root@<router> 'sh /tmp/cdm_regs.sh'                     # registers only
#   ssh root@<router> 'sh /tmp/cdm_regs.sh <peer-ip> [lan-dev...]'
#
# With a peer address it also checks what the counters mean: it reads them,
# pings that address, reads them again, and compares the deltas against the
# netdev counters. The LAN-side netdevs to sum can be named after the address
# (default "eth0 lan1" - CDM1 carries every LAN GDM, see below).
#
# What the verification showed (HG5585F-CT 192.168.1.1 and ZN504XG-D
# 192.168.32.254, 2026-10-10):
#   * CDM1 TX_OK tracks the SUM of the LAN-side netdev TX. The two are read
#     at different instants, so they agree to within the traffic that crossed
#     in between: exactly equal in two runs (504: +54793 == eth0 +38324 plus
#     lan1 +16469; 5855F: == lan1 alone, eth0 being idle) and 7 packets apart
#     in a third - the 504 carries a ~2500 pps IPTV stream, so milliseconds of
#     skew are worth tens of packets.
#   * CDM2 TX_OK ~ pon0 tx, CDM2 RXCPU_OK ~ pon0 rx (the WAN side).
#   * RXHWF_OK only moves when traffic really is hardware-forwarded:
#     +2 while idle for 20 s, +344 in a short download, but +40196 during one
#     sustained 60 s download whose flow showed up as BND in the PPE table.
#   * Not read-to-clear: four consecutive reads of CDM1 TX_OK returned
#     113/114/115/116.
#
# Register map (airoha_regs.h: CDM1_BASE=0x0400, CDM2_BASE=0x1400, FE_BASE=
# 0x1fb50000), each CDM block owning its counter bank at +0x180:
#   +0x180 TX_OK      CONFIRMED counter
#   +0x190 RXCPU_OK   CONFIRMED counter
#   +0x194 RXHWF_OK   CONFIRMED counter
#   +0x1a0 / +0x1a4 / +0x1a8  UNCONFIRMED. The upstream reference calls
#     +0x1a0/+0x1a4 RXCPU_DROP/RXHWF_DROP, but on the ZN504XG-D +0x1a4 and
#     +0x1a8 read a constant 24 on CDM1 (0 on CDM2) which never moves while
#     traffic flows, and +0x184+24 == +0x198 exactly - a configuration
#     constant, not a drop count. They are printed below for whoever wants to
#     keep investigating, and are deliberately NOT shown in the status page.
# The kernel driver never reads any of these (airoha_eth.c only touches the
# CDM *configuration* registers), so reading them here steals nothing.

CDM1=0x1fb50400
CDM2=0x1fb51400
OFF_TX=0x180
OFF_RXCPU=0x190
OFF_RXHWF=0x194
OFF_RXCPU_DROP=0x1a0
OFF_RXHWF_DROP=0x1a4

if [ ! -e /dev/mem ] || ! command -v devmem > /dev/null 2>&1; then
	echo "!! needs /dev/mem (CONFIG_KERNEL_DEVMEM=y) and the devmem applet"
	exit 1
fi

r() { echo $(( $(devmem "$1" 32) )); }
cdm_tx()   { r $(( $1 + OFF_TX )); }
cdm_rxcpu(){ r $(( $1 + OFF_RXCPU )); }
cdm_hwf()  { r $(( $1 + OFF_RXHWF )); }
cdm_cd()   { r $(( $1 + OFF_RXCPU_DROP )); }
cdm_hd()   { r $(( $1 + OFF_RXHWF_DROP )); }

snap() {
	printf 'cdm1: tx=%-10s rx_cpu=%-10s rx_hwf=%-8s drop=%s/%s\n' \
		"$(cdm_tx $CDM1)" "$(cdm_rxcpu $CDM1)" "$(cdm_hwf $CDM1)" \
		"$(cdm_cd $CDM1)" "$(cdm_hd $CDM1)"
	printf 'cdm2: tx=%-10s rx_cpu=%-10s rx_hwf=%-8s drop=%s/%s\n' \
		"$(cdm_tx $CDM2)" "$(cdm_rxcpu $CDM2)" "$(cdm_hwf $CDM2)" \
		"$(cdm_cd $CDM2)" "$(cdm_hd $CDM2)"
	for nd in $(ls /sys/class/net); do
		[ "$nd" = "lo" ] && continue
		printf '%-8s tx=%-10s rx=%-10s\n' "$nd" \
			"$(cat /sys/class/net/$nd/statistics/tx_packets)" \
			"$(cat /sys/class/net/$nd/statistics/rx_packets)"
	done
}

echo "=== CDM registers (FE_BASE 0x1fb50000) ==="
for pair in "$CDM1:CDM1 (PSE P0) -> CPU DMA 1" "$CDM2:CDM2 (PSE P5) -> CPU DMA 2"; do
	base=${pair%%:*}; name=${pair#*:}
	printf '%s\n' "$name"
	printf '  TX_OK       (base+0x180 = 0x%08x) = %s\n' "$(( base + OFF_TX ))"        "$(cdm_tx $base)"
	printf '  RXCPU_OK    (base+0x190 = 0x%08x) = %s\n' "$(( base + OFF_RXCPU ))"     "$(cdm_rxcpu $base)"
	printf '  RXHWF_OK    (base+0x194 = 0x%08x) = %s\n' "$(( base + OFF_RXHWF ))"    "$(cdm_hwf $base)"
	printf '  RXCPU_DROP  (base+0x1a0 = 0x%08x) = %s\n' "$(( base + OFF_RXCPU_DROP ))" "$(cdm_cd $base)"
	printf '  RXHWF_DROP  (base+0x1a4 = 0x%08x) = %s\n' "$(( base + OFF_RXHWF_DROP ))" "$(cdm_hd $base)"
done

echo
echo "=== read-to-clear check (4 consecutive reads of CDM1 TX_OK) ==="
i=1
while [ $i -le 4 ]; do printf '  read%d = %s\n' "$i" "$(cdm_tx $CDM1)"; i=$((i + 1)); done
echo "  (a read-to-clear register would collapse to 0 on the second read)"

[ -n "$1" ] || { echo; echo "Pass an address to also run the TX/RX correlation check."; exit 0; }

echo
peer="$1"
echo "=== correlation: egress only (device pings $peer) ==="
# The LAN GDMs CDM1 carries: named on the command line, default eth0 + lan1.
shift
[ $# -gt 0 ] || set -- eth0 lan1
LAN_DEVS="$*"
echo "  (summing these LAN netdevs: $LAN_DEVS)"

sum_stat() {	# $1 = tx|rx, $2.. = netdevs
	local field="$1" total=0 v; shift
	for nd in "$@"; do
		v=$(cat "/sys/class/net/$nd/statistics/${field}_packets" 2>/dev/null)
		[ -n "$v" ] && total=$(( total + v ))
	done
	echo "$total"
}

t0_tx=$(cdm_tx $CDM1); t0_rx=$(cdm_rxcpu $CDM1)
n0_tx=$(sum_stat tx "$@"); n0_rx=$(sum_stat rx "$@")
# busybox ping on this target rejects a sub-second interval, and a rejected
# ping makes this check silently measure nothing - keep the 0.2 s default.
ping -c 40 "$peer" > /dev/null 2>&1 || echo "  (ping reported an error; deltas below may be empty)"
t1_tx=$(cdm_tx $CDM1); t1_rx=$(cdm_rxcpu $CDM1)
n1_tx=$(sum_stat tx "$@"); n1_rx=$(sum_stat rx "$@")
d_tx=$(( t1_tx - t0_tx )); d_rx=$(( t1_rx - t0_rx ))
n_tx=$(( n1_tx - n0_tx )); n_rx=$(( n1_rx - n0_rx ))
printf '  cdm1 TX_OK   delta = %s\n' "$d_tx"
printf '  cdm1 RXCPU   delta = %s\n' "$d_rx"
printf '  LAN tx (sum) delta = %s\n' "$n_tx"
printf '  LAN rx (sum) delta = %s\n' "$n_rx"
if [ "$d_tx" = "0" ] && [ "$n_tx" = "0" ]; then
	echo "  !! no traffic was generated - nothing was measured"
else
	diff=$(( d_tx - n_tx )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
	# The register and the netdev counters are sampled at different instants,
	# so a few packets of skew is expected; a real mismatch would be an order
	# of magnitude larger than the traffic crossing in those milliseconds.
	if [ "$diff" -le 100 ]; then
		echo "  OK: CDM1 TX_OK tracks the LAN netdevs' TX (differ by $diff packets)"
	else
		echo "  !! CDM1 TX_OK ($d_tx) does not match the LAN TX sum ($n_tx), off by $diff"
	fi
fi
echo "  (RXCPU_OK also carries the replies and the SSH session, so it usually"
echo "   differs from the LAN rx sum by a few packets)"
echo
snap
