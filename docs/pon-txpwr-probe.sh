#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# pon-txpwr-probe.sh —— 在 EN7572 上直接施加"已标定 A2 表"的模拟参数，验证
# "发射功率 -40 dBm / 偏置 107 mA" 到底是不是 BOB A0 表为空造成的。
#
# 背景：Nokia XG-040G-MD 的 bosa 存储里只有 A2 页被标定，A0 页是 0xff。
# airoha-en7572.c 在 epon-10g-1g 模式下用 A0 表，于是把 IMOD/IAV/APC/ERC/PGA
# 全写成"擦除值"(全 1)，实测 IAV_CAL=0x1fff、偏置 107mA、发射功率寄存器 0x0001。
# 本脚本把 prepare() 的写入序列原样重放，但参数取自已标定的 A2 表：
#   DCL_CTRL_2(0x0210)  IMOD_CAL=0x0822 IAV_CAL=0x0578
#   APC_ANA_VMON_SEL(0x0124)[15:8]=0xd6
#   IMPD_SINK(0x0128)   ERC_DAC=0x0740 ERC_CDAC=0xd6
#   RESERVE_TIA(0x0130) TIA_CUR=0 tia=(TIA_BW<<3)|TIA_GAIN=0x23
#   REP_PH_CAP_SEL(0x013c)[18:16]=3 [6:5]=0
# 再拉一次 rg_loop_en(0x0208[0]) 提交。BEN 仅在写入期间关掉(<100ms)。
#
# 用法（光猫上 root）：
#   sh /tmp/pon-txpwr-probe.sh apply     # 用 A2 标定参数（默认）
#   sh /tmp/pon-txpwr-probe.sh restore   # 回到驱动当前的擦除值(A0 全 1)
#
set -u
DEV=0x51

rb() { i2ctransfer -f -y 0 w2@$DEV $(( $1 >> 8 )) $(( $1 & 0xff )) r4@$DEV; }
rr() { set -- $(rb $1); echo $(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 )); }
hx() { printf '0x%08x' $1; }
wr() {
	i2ctransfer -f -y 0 w6@$DEV $(( $1 >> 8 )) $(( $1 & 0xff )) \
		$(( $2 & 0xff )) $(( $2 >> 8 & 0xff )) $(( $2 >> 16 & 0xff )) $(( $2 >> 24 & 0xff ))
}
ddm() {
	printf 'DDMI: '
	printf 'temp=%s volt=%s bias=%s tx=%s rx=%s\n' \
		"$(hx $(rr 0x0060))" "$(hx $(rr 0x0062))" "$(hx $(rr 0x0064))" \
		"$(hx $(rr 0x0066))" "$(hx $(rr 0x0068))"
}
show() {
	for r in 0x0100 0x0124 0x0128 0x0130 0x013c 0x0208 0x0210; do
		printf '  %s = %s\n' $r "$(hx $(rr $r))"
	done
}

echo "=== before"; show; ddm
base=$(rr 0x0100)

if [ "${1:-apply}" = restore ]; then
	imod=$((0x0fff)); iav=$((0x1fff)); apc=$((0xff))
	erc_dac=$((0x0fff)); erc_cdac=$((0xff))
	tia_cur=1; tia=$((0x3f)); pga_gain=7; pga_cap=3
else
	imod=$((0x0822)); iav=$((0x0578)); apc=$((0xd6))
	erc_dac=$((0x0740)); erc_cdac=$((0xd6))
	tia_cur=0; tia=$((0x23)); pga_gain=3; pga_cap=0
fi

wr 0x0100 $(( (base & ~0x0c) | 0x08 ))
echo "BEN off : $(hx $(rr 0x0100))"

c=$(rr 0x0210); wr 0x0210 $(( (c & ~0x0fff1fff) | (imod << 16) | iav ))
echo "0x0210  : $(hx $(rr 0x0210))  IMOD=$(hx $imod) IAV=$(hx $iav)"

c=$(rr 0x0124); wr 0x0124 $(( (c & ~0xff00) | (apc << 8) ))
echo "0x0124  : $(hx $(rr 0x0124))  APC=$(hx $apc)"

c=$(rr 0x0128); wr 0x0128 $(( (c & ~0x0fff0f00) | (erc_dac << 16) | (erc_cdac << 8) ))
echo "0x0128  : $(hx $(rr 0x0128))  ERC_DAC=$(hx $erc_dac) ERC_CDAC=$(hx $erc_cdac)"

c=$(rr 0x0130); wr 0x0130 $(( (c & ~0x3f01) | (tia << 8) | tia_cur ))
echo "0x0130  : $(hx $(rr 0x0130))  tia=$(hx $tia) TIA_CUR=$tia_cur"

c=$(rr 0x013c); wr 0x013c $(( (c & ~0x00070060) | (pga_gain << 16) | (pga_cap << 5) ))
echo "0x013c  : $(hx $(rr 0x013c))  PGA_GAIN=$pga_gain PGA_CAP=$pga_cap"

c=$(rr 0x0208); wr 0x0208 $(( c & ~1 )); wr 0x0208 $(( c | 1 ))
echo "0x0208  : $(hx $(rr 0x0208))  (rg_loop_en 0->1)"

wr 0x0100 $(( base ))
echo "BEN norm: $(hx $(rr 0x0100))"

sleep 3; echo "=== after 3s";  ddm
sleep 7; echo "=== after 10s"; ddm
echo "=== analog regs"; show
