# PonWrt

[简体中文](README.md) | **English** | [Fork change log (Chinese)](README.zh-CN.md)

PonWrt is based on [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) and adds support for Airoha AN7581 and AN7583 PON devices.

> 📌 **This repository is a fork of [pbs05/ponwrt](https://github.com/pbs05/ponwrt).** It carries a
> batch of hardware fixes found by debugging real AN7581 / AN7583 ONUs on the bench. The full
> write-up — symptom, root cause, register-level evidence and how to verify each fix — is in
> **[README.zh-CN.md](README.zh-CN.md)** (Chinese). The Chinese version of this page is
> [README.md](README.md).

## What this fork adds

| Area | Change |
| --- | --- |
| Panel LAN LEDs | The netdev triggers were missing entirely (ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A, and the AN7583 XG-040G-MF): the EN8811H driver puts its LED outputs into user-defined mode and the LED core clears the driver's own rules at registration, so without a `netdev` trigger the jack stays dark even with the port linked. |
| Panel port order | The UNG00A factory DTB reverses the panel order, which left the real LAN4 jack dead. |
| HG5585F-CT | The GPY211C PHY ID is pinned in the device tree, so a warm reboot can no longer bind the non-negotiating Generic Clause 45 PHY and leave `lan1` at NO-CARRIER. |
| AN7583 crypto | Kernel AES was entirely software. The ARMv8 Crypto Extensions (AES + GHASH/PMULL), `CRYPTO_CBC`, `CRYPTO_AUTHENC`, AF_ALG and the EIP-93 engine are now enabled, together with the matching userspace packages (`kmod-crypto-hw-eip93`, `kmod-cryptodev`, `libopenssl-devcrypto`). |
| Wireless defaults | One set of defaults for the three wireless boards: country `CN`, 160 MHz on 5 GHz, separate 2.4/5 GHz SSIDs, WPA2-PSK. Needed because the world regulatory domain has no AP-capable 160 MHz block, so the 5 GHz radio silently disappears at 160 MHz. |
| PON panel LEDs | The "optical signal" LED keeps the conventional meaning (off when the link is healthy, slow blink when there is no light), and the "internet" LED follows a real reachability probe rather than the PON registration state. |
| `luci-app-airoha-npu` | The NPU dashboard ported with **WAN = the PON port** instead of the 2.5G copper port, with rewritten WiFi data sources and CDM1/CDM2 CPU DMA cards. |
| IPTV | Set-top boxes reporting "2001 network unreachable": MAC learning is kept off on the multicast VLAN port. |
| Build tooling | `build.sh` / `build-watch.sh` / `build-live.sh`, an idempotent mechanism for patching upstream feeds (`feed-patches/`), and `verify-images.sh`, which rejects images that compile but cannot boot. |

This fork keeps **a single main line**: `master` carries upstream plus every fork change, so that is
the only branch to build from.

## ⚠️ Disclaimer

PonWrt is an open-source firmware project intended for research and development.

Flashing firmware or modifying PON-related settings involves risks and may result in boot failure, loss of configuration or device-specific data, or failure to register with the PON network. Please back up the original firmware and device data before making any changes.

Users are responsible for ensuring that their use complies with applicable laws, regulations, and network operator requirements. Do not use this project for unauthorized network access, impersonating or cloning another device's identity, or interfering with operator networks.

The authors and contributors are not responsible for device damage, network service disruption, or other consequences resulting from flashing, configuring, or using this project.

## Supported devices

| SoC | Device | Profile | Stock calibration / identity data |
| --- | --- | --- | --- |
| AN7581 | FiberHome HG5382A | `fiberhome_hg5382a` | `factory` |
| AN7581 | FiberHome HG5585F CT | `fiberhome_hg5585f-ct` | `factory` |
| AN7581 | FiberHome HG5585F CU | `fiberhome_hg5585f-cu` | `factory` |
| AN7581 | Gemtek XG2010G | `gemtek_xg2010g` | `dsd` |
| AN7581 | Nokia XG-040G-MD UBI | `nokia_xg-040g-md-ubi` | `bosa`, `ri` |
| AN7581 | Nokia XG-040G-TF UBI | `nokia_xg-040g-tf-ubi` | `bosa`, `ri` |
| AN7581 | UnionMan UNG00A | `unionman_ung00a` | `reservearea` |
| AN7581 | ZNXT ZN504XG-D | `znxt_zn504xg-d` | `reservearea` |
| AN7581 | ZNXT ZN515XG-D | `znxt_zn515xg-d` | `reservearea` |
| AN7581 | H3C HM2004-DU | `h3c_hm2004-du` | `factory` |
| AN7583 | Nokia XG-040G-MF | `nokia_xg-040g-mf`, `nokia_xg-040g-mf-ubi` | `bosa`, `ri` |

## Build

```sh
#  Install the required toolchain and libraries for building
sudo apt update -y
sudo apt full-upgrade -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
  bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
  g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
  libglib2.0-dev libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
  libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
  ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
  python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs \
  upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd

#  Or use the ImmortalWrt one-click script to install dependencies
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'


#  Clone this fork (the fixes above live here); upstream is
#  https://github.com/pbs05/ponwrt.git
git clone https://github.com/jzhou404gmail/ponwrt.git
cd ponwrt


#  Update and install feeds (package sources)
./scripts/feeds update -a
./scripts/feeds install -a


#  Select a configuration, using 7581 as an example
cp configs/an7581.config .config
#  If the target is AN7583, use the following line instead:
cp configs/an7583.config .config



#  Start building
# -j$(nproc) means compiling in parallel with all CPU cores to speed things up
make defconfig
make -j$(nproc)
```

Images are written to `bin/targets/airoha/an7581/` or `bin/targets/airoha/an7583/`.

## Install

Use [AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) to back up the stock flash and install the UBI layout. Boot images and Web recovery are provided by [AN758x U-Boot](https://github.com/pbs05/uboot-an758x).

After installing PonWrt, restore the stock calibration and identity data through U-Boot Web or **Network → PON → Configuration → PON board data** in LuCI. Convert FiberHome `factory` backups with [FiberHome Factory](https://github.com/pbs05/fiberhome-factory) first. Restore converted FiberHome data, `reservearea`, or `dsd` backups to the PonWrt `factory` volume. Nokia `bosa` and `ri` backups use volumes with the same names.
