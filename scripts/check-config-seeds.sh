#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# check-config-seeds.sh - refuse to build from a release seed that has drifted
# back to the old minimal baseline.
#
# Why this exists
# ---------------
# There are two different configs in this tree:
#
#   .config                     what a plain `./build.sh` builds
#   configs/<target>.config     what `./build.sh --config=<target>` builds
#
# They drift apart silently.  A package set grows in .config (a feature is
# restored, a handful of apps are selected by hand), but the seed is never
# refreshed.  A plain build keeps working, so nobody notices until someone
# runs --config=<other-target> and gets a stripped image.
#
# That is exactly what happened here: the working an7581 .config had 454
# packages while configs/an7583.config still produced 275.  The old build.sh
# guard could not catch it: it only compared the post-defconfig count with the
# seed it was given (80% floor), and a seed that was already too small passed
# that comparison.
#
# What is checked
# ---------------
#   * an absolute package floor (default 400 `=y` packages) for both seeds;
#   * the packages that must be present on each SoC (NPU firmware, 2.5G PHY,
#     EIP-93/AES, PON/IPTV, the six release apps);
#   * that hardware/WiFi packages of one target are not leaking into the other;
#   * the exact set of device profiles that produce firmware: the six AN7581
#     models the owner actually has (no SFP variants), and
#     nokia_xg-040g-mf-ubi on AN7583.  Code changes still have to work for
#     every profile of the SoC; this list only limits what gets built.
#     See docs/build-models-policy.md.
#   * cross-seed parity: any package present in only one seed must be in the
#     explicit ONLY_7581 / ONLY_7583 hardware allowlists below.  This is what
#     catches "someone deleted 40 ordinary packages from one seed" even when
#     the remaining count is still above 400.
#
# Usage
# -----
#   scripts/check-config-seeds.sh            # check both + parity
#   scripts/check-config-seeds.sh an7581     # check one seed only
#   scripts/check-config-seeds.sh an7583
#
#   MIN_PACKAGES=420 scripts/check-config-seeds.sh
#
# Exit status: 0 = both seeds look like release seeds, 1 = at least one failed.

set -u
cd "$(dirname "$0")/.." || exit 1

MIN_PACKAGES="${MIN_PACKAGES:-400}"
TARGET="${1:-all}"
fail=0

err() {
	echo "!! $*" >&2
	fail=1
}

pkg_y() {
	grep -q "^CONFIG_PACKAGE_$1=y$" "$2"
}

pkg_set() {
	grep -q "^CONFIG_PACKAGE_$1=[ym]$" "$2"
}

pkg_unset() {
	! pkg_set "$1" "$2"
}

# Packages the two SoCs genuinely cannot share.  Keep this list in step with
# the hardware: an7581 has WiFi (MT7916) and paged BOSA; an7583 has ARMv8
# Crypto Extensions + EIP-93 and no radio.  The two kmods listed for an7581
# (thermal, xhci-mtk) are built into the an7583 kernel instead of being
# separate packages.
ONLY_7581="
airoha-en7581-npu-firmware
hostapd-common
iw
kmod-airoha-paged-bosa
kmod-cfg80211
kmod-mac80211
kmod-mt76-connac
kmod-mt76-core
kmod-mt7915e
kmod-mt7916-firmware
kmod-thermal
kmod-usb-xhci-mtk
MAC80211_DEBUGFS
MAC80211_MESH
trusted-firmware-a-an7581-bl2
trusted-firmware-a-an7581-bl31
u-boot-an7581_nokia_xg-040g-md
ucode-mod-nl80211
wifi-scripts
wireless-regdb
"
ONLY_7583="
airoha-an7583-npu-firmware
kmod-crypto-des
kmod-cryptodev
kmod-crypto-hw-eip93
kmod-crypto-md5
libopenssl-devcrypto
trusted-firmware-a-an7583-bl2
trusted-firmware-a-an7583-bl31
u-boot-an7583_nokia_xg-040g-mf
"

# ---------------------------------------------------------------------------
# 出固件的机型白名单（2026-10-25 定，未来都适用）
#
# 改代码按 target 写，必须覆盖 AN7581 的全部 12 个 profile（含 SFP 变体）
# 和 AN7583 的 XG-040G-MF；但出固件只出用户手上这几台，带 SFP 的变体和
# 其它机型一律不选。要调整发布范围，先改这里和 configs/*.config，否则
# build.sh 会在动手前直接拒绝编译。
#
#   7581：5382A / HG5585F-CT / HG5585F-CU / XG-040G-MD / UNG00A / ZN504XG-D
#   7583：XG-040G-MF，且只出 UBI 固件（nokia_xg-040g-mf-ubi）
# ---------------------------------------------------------------------------
BUILD_7581_DEVICES="
fiberhome_hg5382a
fiberhome_hg5585f-ct
fiberhome_hg5585f-cu
nokia_xg-040g-md-ubi
unionman_ung00a
znxt_zn504xg-d
"
BUILD_7583_DEVICES="
nokia_xg-040g-mf-ubi
"

check_common() {
	seed="$1"
	for p in \
		luci-app-airoha-npu \
		adblock-fast adblock-fast-ponwrt \
		luci-app-upnp mount-utils \
		kmod-sched-cake kmod-tcp-bbr kmod-wireguard \
		luci-app-passwall luci-app-samba4 luci-app-diskman \
		luci-app-ddns luci-app-ttyd luci-app-vlmcsd \
		netdata collectd wireguard-tools
	do
		pkg_y "$p" "$seed" || err "$seed: missing CONFIG_PACKAGE_$p=y"
	done
}

check_count() {
	seed="$1"
	n=$(grep -c '^CONFIG_PACKAGE_.*=y' "$seed" 2>/dev/null || true)
	[ -n "$n" ] || n=0
	echo "==> $seed: $n =y packages"
	[ "$n" -ge "$MIN_PACKAGES" ] || \
		err "$seed has only $n =y packages (minimum $MIN_PACKAGES); it has drifted back to a minimal config"
	grep -q '^CONFIG_TARGET_MULTI_PROFILE=y$' "$seed" || \
		err "$seed: CONFIG_TARGET_MULTI_PROFILE is not y"
	grep -q '^CONFIG_TARGET_PER_DEVICE_ROOTFS=y$' "$seed" || \
		err "$seed: CONFIG_TARGET_PER_DEVICE_ROOTFS is not y"
}

selected_devices() {
	# $1 = target conf (airoha_an7581), $2 = seed file
	grep '^CONFIG_TARGET_DEVICE_'"$1"'_DEVICE_.*=y$' "$2" |
		sed 's/.*DEVICE_//; s/=y$//' | sort
}

check_build_devices() {
	seed="$1"
	target="$2"
	allow="$3"
	allowed="/tmp/ponwrt-build-allow.$$"
	selected="/tmp/ponwrt-build-selected.$$"

	printf '%s\n' $allow | sort > "$allowed"
	selected_devices "$target" "$seed" > "$selected"

	extra=$(comm -13 "$allowed" "$selected")
	missing=$(comm -23 "$allowed" "$selected")
	rm -f "$allowed" "$selected"

	[ -z "$extra" ] || \
		err "$seed: 多选了不该出固件的机型（规则见 docs/build-models-policy.md）：$(echo $extra)"
	[ -z "$missing" ] || \
		err "$seed: 缺少出固件的机型：$(echo $missing)"
}

check_7581() {
	seed=configs/an7581.config
	[ -f "$seed" ] || { err "$seed missing"; return; }
	check_count "$seed"
	check_common "$seed"
	grep -q '^CONFIG_TARGET_SUBTARGET="an7581"$' "$seed" || err "$seed: wrong subtarget"
	for p in \
		airoha-en7581-npu-firmware kmod-airoha-paged-bosa \
		kmod-mt7916-firmware kmod-phy-airoha-en8811h \
		airoha-en8811h-firmware kmod-usb3 block-mount
	do
		pkg_y "$p" "$seed" || err "$seed: missing CONFIG_PACKAGE_$p=y"
	done
	for p in luci-app-wifihistory luci-app-wifischedule wifischedule; do
		pkg_set "$p" "$seed" || err "$seed: missing CONFIG_PACKAGE_$p (=m) for the WiFi devices"
	done
	for p in airoha-an7583-npu-firmware kmod-crypto-hw-eip93 kmod-cryptodev libopenssl-devcrypto; do
		pkg_unset "$p" "$seed" || err "$seed: contains an7583-only CONFIG_PACKAGE_$p"
	done
	check_build_devices "$seed" airoha_an7581 "$BUILD_7581_DEVICES"
	if grep -q '^CONFIG_TARGET_DEVICE_airoha_an7583_DEVICE_.*=y$' "$seed"; then
		err "$seed: selects an an7583 device"
	fi
}

check_7583() {
	seed=configs/an7583.config
	[ -f "$seed" ] || { err "$seed missing"; return; }
	check_count "$seed"
	check_common "$seed"
	grep -q '^CONFIG_TARGET_SUBTARGET="an7583"$' "$seed" || err "$seed: wrong subtarget"
	# ARMv8 Crypto Extensions are in target/linux/airoha/an7583/config-6.18;
	# these packages are what put the EIP-93 driver and the OpenSSL engine into
	# the image.  Losing them is silent: the build still succeeds, /proc/crypto
	# just falls back to the generic implementations.
	for p in \
		airoha-an7583-npu-firmware \
		kmod-crypto-hw-eip93 kmod-cryptodev libopenssl-devcrypto \
		kmod-phy-airoha-en8811h airoha-en8811h-firmware \
		kmod-usb3 block-mount luci-app-pon luci-app-iptv
	do
		pkg_y "$p" "$seed" || err "$seed: missing CONFIG_PACKAGE_$p=y"
	done
	for p in \
		luci-app-wifihistory luci-app-wifischedule wifischedule \
		airoha-en7581-npu-firmware kmod-airoha-paged-bosa kmod-mt7916-firmware
	do
		pkg_unset "$p" "$seed" || err "$seed: contains radio/7581-only CONFIG_PACKAGE_$p"
	done
	check_build_devices "$seed" airoha_an7583 "$BUILD_7583_DEVICES"
	if grep -q '^CONFIG_TARGET_DEVICE_airoha_an7583_DEVICE_nokia_xg-040g-mf=y$' "$seed"; then
		err "$seed: non-UBI nokia_xg-040g-mf is selected"
	fi
	if grep -q '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_.*=y$' "$seed"; then
		err "$seed: selects an an7581 device"
	fi
}

set_y() {
	grep '^CONFIG_PACKAGE_.*=y' "$1" | sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort -u
}

in_list() {
	# $1 word, $2 newline-separated list
	printf '%s\n' "$2" | grep -Fqx "$1"
}

check_parity() {
	[ -f configs/an7581.config ] && [ -f configs/an7583.config ] || return
	set_y configs/an7581.config > /tmp/ponwrt-seed-7581.$$
	set_y configs/an7583.config > /tmp/ponwrt-seed-7583.$$

	# Present on 7581 only: must be in ONLY_7581.
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		grep -Fqx "$p" /tmp/ponwrt-seed-7583.$$ && continue
		in_list "$p" "$ONLY_7581" || \
			err "configs/an7581.config has $p=y but configs/an7583.config does not (and it is not in ONLY_7581)"
	done < /tmp/ponwrt-seed-7581.$$

	# Present on 7583 only: must be in ONLY_7583.
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		grep -Fqx "$p" /tmp/ponwrt-seed-7581.$$ && continue
		in_list "$p" "$ONLY_7583" || \
			err "configs/an7583.config has $p=y but configs/an7581.config does not (and it is not in ONLY_7583)"
	done < /tmp/ponwrt-seed-7583.$$

	rm -f /tmp/ponwrt-seed-7581.$$ /tmp/ponwrt-seed-7583.$$
}

case "$TARGET" in
	an7581) check_7581 ;;
	an7583) check_7583 ;;
	all) check_7581; check_7583; check_parity ;;
	*) err "unknown target '$TARGET' (use an7581, an7583 or all)" ;;
esac

if [ "$fail" -ne 0 ]; then
	echo "" >&2
	echo "!! 配置种子自检失败。请用一份已验证的 .config 刷新对应的" >&2
	echo "!! configs/<target>.config，再重新编译；不要手工删包凑数。" >&2
	echo "!! 只想查看数量：MIN_PACKAGES=0 scripts/check-config-seeds.sh" >&2
	exit 1
fi

echo "==> 配置种子自检通过：两个种子均 >= ${MIN_PACKAGES} 个 =y 包，硬件差异仅限白名单，出固件机型符合白名单"
