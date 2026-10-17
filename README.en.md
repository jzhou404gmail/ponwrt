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
| **The UNG00A's LAN4 jack is dead** | The factory DTB reverses the panel order: panel LAN2 / LAN3 / LAN4 are really switch ports 3 / 2 / 1 (PHY `0x0b` / `0x0a` / `0x09`), while port4 (PHY `0x0c`) has **no jack wired to it** yet owns the name `lan4`. So the real LAN4 jack never came up. The true mapping was measured by moving one cable between the labelled jacks and watching which netdev gained carrier, then the port order was corrected and PHY1's LED0 enabled. |
| **The HG5585F-CT's 2.5G jack (lan1) does not come up after a warm reboot** | That 2.5G PHY is a MaxLinear **GPY211C**, described with a string compatible plus `ethernet-phy-ieee802.3-c45`. That combination makes the core read the C45 ID over MDIO **while scanning the bus, which happens before `mdio_probe()` releases the reset GPIO**; on a warm reboot the PHY can still be held in reset at that moment, the scan reads `0xffffffff`, and the kernel binds the non-negotiating `Generic Clause 45 PHY`, leaving lan1 at NO-CARRIER until the next cold boot. Spelling the PHY ID out (`ethernet-phy-id67c9.de10`) creates the device from the device tree, so the race cannot happen. |
| **Panel LAN LEDs stay dark (a whole batch of boards)** | ZN504XG-D / ZN515XG-D / Nokia MD & TF / UNG00A / the AN7583 XG-040G-MF: the netdev triggers were missing entirely. The EN8811H driver puts its LED outputs into user-defined mode and the LED core clears the driver's own rules at registration, so without a `netdev` trigger the jack stays dark even with the port linked. |
| **XG-040G-MF LAN LED class device names are not deterministic** | `gsw_phy2/3/4_led0` had only a colour and no function or enumerator, so the LED core named them by registration order (`green:lan`, `green:lan-1`, …) and which device belongs to which jack was not guaranteed - a trigger could bind to the wrong jack. They now carry the `lan` function and enumerators 2/3/4. |
| **AN7583 crypto** | Kernel AES was entirely software (`/proc/crypto` had 13 algorithms, all software/generic, and not even a software `cbc(aes)`). The ARMv8 Crypto Extensions (AES + GHASH/PMULL), `CRYPTO_CBC`, `CRYPTO_AUTHENC`, AF_ALG and the EIP-93 engine are now enabled, together with the matching userspace packages (`kmod-crypto-hw-eip93`, `kmod-cryptodev`, `libopenssl-devcrypto`). |
| **Wireless defaults** | One set of defaults for the three wireless boards: country `CN`, 160 MHz on 5 GHz, separate 2.4/5 GHz SSIDs, WPA2-PSK. Needed because the world regulatory domain has no AP-capable 160 MHz block, so the 5 GHz radio silently disappears at 160 MHz. |
| **PON panel LEDs (including the internet LED never lighting on EPON)** | (1) The "optical signal" LED keeps the conventional meaning - off when the link is healthy, slow blink when there is no light; a "lit while there is light" variant was tried and reverted after using it on the bench. (2) **EPON has no OMCI**, so `service_ready` is only written by the userspace OAM agent and only after CTC authentication, which a line registering with plain MPCP and running PPPoE never reaches - so `pon0-online` stayed dark forever. The patch treats a registered LLID as service-ready instead. (3) The "internet" LED is separately driven by a real reachability probe rather than the PON registration state. |
| **`luci-app-airoha-npu`** | The NPU dashboard ported with **WAN = the PON port** instead of the 2.5G copper port; the WiFi data sources rewritten for the MT7916D (upstream's only match the mt7996, so not a single band matched); CDM1 / CDM2 CPU DMA cards added to the Frame Engine section; the copper card now resolves its GDM at runtime instead of hardcoding gdm4; plus a kernel patch that exposes the **NPU firmware version through sysfs** so userspace does not have to scrape the boot log. |
| **IPTV** | Set-top boxes reporting "2001 network unreachable": MAC learning is kept off on the multicast VLAN port. |
| **Build tooling** | `build.sh`: **never alters the build inputs** (kind to incremental builds), `--config=` with a backup and a package-drop guard, a concurrency lock, per-package logs, **two self-healing paths** (a package's sub-build killed silently / the kernel tree left on the initramfs config), and a closing summary that reports the elapsed time and lists the artifacts this run produced. Plus `build-watch.sh` (progress from the log) and `build-live.sh` (no log needed - reads the processes and the filesystem). An idempotent mechanism for patching upstream feeds (`feed-patches/`); and `verify-images.sh`, which rejects images that compile but cannot boot. See section 5.3 of [README.zh-CN.md](README.zh-CN.md) for the full usage. |
| **CI releases** | The repository ships a GitHub Actions workflow (`.github/workflows/release.yml`). Run **`Release PonWrt`** manually with a tag and it builds `ponwrt-an7581.tar.zst` / `ponwrt-an7583.tar.zst` plus `sha256sums` and publishes a release - no local machine needed. It seeds `.config` from the project defaults in `configs/` (`kconfig.pl + configs/<target>.config configs/release.config`), never from anyone's local `.config`, which is not in the repository at all. The fork also had to add `feed-patches/apply.sh` and `verify-images.sh` to the job. See section 5.6 of [README.zh-CN.md](README.zh-CN.md). |
| **Other** | `feeds.conf.default` records the optional PassWall feeds as comments; `.gitignore` ignores local `.config` backups, stock firmware dumps and host-only scripts. |

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

> **`make` on its own is enough** — it applies the fork's upstream-feed patches
> (`feed-patches/`, see below) before anything is built, so a plain `make -j$(nproc)`
> produces the same firmware as `./build.sh`. `./build.sh` adds convenience on top:
> a progress display, a concurrency lock, per-package logs, two self-healing paths,
> a version/`git` preflight and the image check in section 5.5.
>
> **`git` must really be in `PATH`.** The check is silent when it fails: the feed-patch
> step reports a bogus "patch does not apply", and `scripts/getver.sh` returns `unknown`,
> which changes every package version in the tree (base-files goes from `1943~a57faf93c6`
> to `1943~unknown`) and makes unrelated packages fail to build 20 minutes later. Both
> `build.sh` and `make` now stop immediately and print the fix (`sudo apt-get install -y git`)
> — the whole story is section 5.1.1 of [README.zh-CN.md](README.zh-CN.md).

## Install

Use [AN758x-Stock2UBI](https://github.com/pbs05/an758x-stock2ubi) to back up the stock flash and install the UBI layout. Boot images and Web recovery are provided by [AN758x U-Boot](https://github.com/pbs05/uboot-an758x).

After installing PonWrt, restore the stock calibration and identity data through U-Boot Web or **Network → PON → Configuration → PON board data** in LuCI. Convert FiberHome `factory` backups with [FiberHome Factory](https://github.com/pbs05/fiberhome-factory) first. Restore converted FiberHome data, `reservearea`, or `dsd` backups to the PonWrt `factory` volume. Nokia `bosa` and `ri` backups use volumes with the same names.
