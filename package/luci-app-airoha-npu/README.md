# luci-app-airoha-npu (PonWrt port)

Real-time monitoring and management dashboard for the Airoha AN7581 SoC:
NPU offload, CPU frequency, Frame Engine internals and the PPE flow table.

This is a port of [rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)
v1.1.4 to **PonWrt**, where the WAN is the **PON port** instead of the EN8811
2.5G copper PHY.

## What changed compared to upstream

Upstream was written for a board where the upstream link was the 2.5G PHY on
GDM4 (netdev `wan`) and the PON data path on GDM2 was disabled in the DTS, so
the GDM2 card was hardcoded as "not active".

On PonWrt the roles are inverted:

| | upstream | PonWrt |
|---|---|---|
| WAN | GDM4 / EN8811 2.5G / `wan` | **GDM2 / XPON GEM / `pon0`** |
| 2.5G PHY | WAN | **LAN (`lan1`)** |
| LAN switch master | `dsa-mgr` (set by DTS) | `eth0` (no `netdev-name` in the DTS) |

Because none of those netdev names are stable across the boards PonWrt
supports, the GDM → netdev map is no longer hardcoded. The RPC backend
resolves it at runtime from the live device tree
(`/sys/class/net/*/of_node` → `ethernet@N` / `ethernet-port@M`), the same
source `/lib/preinit/04_set_netdev_label` uses to apply
`openwrt,netdev-name`. The PON port is additionally tagged by
`airoha,pon-data-path`.

Concretely:

- **GDM2 card** is now the active PON / WAN card. It shows live TX/RX, drops
  and the link state (`carrier`, which `airoha-xpon` drives from the ONU
  registration / service GEM state), and the resolved netdev name.
- **GDM4 card** is labeled as the 2.5G PHY (a LAN port here).
- **PSE port grid**: `P2` = GDM2 (PON/WAN), `P9` = GDM4 (2.5G); RX drops are
  collected for P1/P2/P9 instead of P1/P9.
- **`/usr/bin/ppe-verify`** resolves the WAN interface instead of assuming
  `wan`. It also no longer uses the `${var^^}` bashism (which aborts busybox
  ash) and no longer double-prints `0` when the PPE table is empty.
- Chinese (`zh_Hans`) translation added; the Spanish one was refreshed.

Everything else (register offsets, PPE debugfs parsing, CPU governor /
max-frequency / overclock controls, theme handling) is unchanged from
upstream v1.1.4.

## Features

- **CPU frequency** — current frequency bar, governor selection, max frequency
  selection, direct PLL overclock (500–1600 MHz) and overclock detection.
- **NPU & offload engine** — firmware version, clock, core count, bind state,
  reserved memory summary.
- **Frame Engine** — PSE shared buffer accounting, GDM port cards with live
  counters, PSE port queue grid (OQ/IQ reservations, drops).
- **PPE flow table** — first 100 entries with state, type, 5-tuple and MAC
  addresses, refreshed every 5 seconds.
- **Theme adaptive** — samples the page background luminance, works with any
  LuCI theme.

## Requirements

- PonWrt (`@TARGET_airoha`), LuCI 24.10+
- `/sys/kernel/debug/ppe/{entries,bind}` (debugfs is mounted by
  `/etc/init.d/boot`)
- `/dev/mem` + the busybox `devmem` applet for the Frame Engine PSE registers
  and for overclocking. Both are already enabled in the PonWrt default build
  (`CONFIG_KERNEL_DEVMEM=y`, `CONFIG_BUSYBOX_CONFIG_DEVMEM=y`). Without them the
  GDM/NPU/PPE cards keep working and only the PSE bar/grid is greyed out.
- `jsonfilter`, `strings` (busybox applet) — both enabled by default.

## Data sources

| Data | Source |
|------|--------|
| NPU status | `/sys/bus/platform/drivers/airoha-npu/`, `dmesg` |
| NPU firmware version | `fw_version` sysfs if the kernel exports it, else the `NPU fw version:` dmesg line |
| CPU frequency | `/sys/devices/system/cpu/cpufreq/policy0/` |
| Overclock PLL | `devmem` 0x1fa202b4 / 0x1fa202b8 |
| PPE entries | `/sys/kernel/debug/ppe/{entries,bind}` |
| Reserved memory | `dmesg` "OF: reserved mem:" lines |
| GDM counters | `/sys/class/net/<dev>/statistics/*` (kernel accumulated, avoids the read-to-clear MIB race) |
| GDM → netdev map | `/sys/class/net/*/of_node` (live device tree) |
| PSE shared buffer | `devmem` 0x1fb5008c / 0x1fb50090 |
| PSE port queues | `devmem` 0x1fb50080 / 0x1fb50084 (indirect read) |
| PSE IQ reservations | `devmem` 0x1fb50108 / 0x1fb5010c |

## RPC methods

| Method | Description | Parameters |
|--------|-------------|------------|
| `getStatus` | NPU, CPU, PPE summary | — |
| `getPpeEntries` | PPE flow table (first 100) | — |
| `getTokenInfo` | WiFi token pool & station stats (kept for parity; this board has no such WiFi path) | — |
| `getFrameEngine` | PSE/GDM register and netdev counters | — |
| `setGovernor` | Change CPU governor | `governor` |
| `setMaxFreq` | Set CPU max frequency | `freq` (kHz) |
| `setOverclock` | Direct PLL frequency set | `freq_mhz` |

## Verifying on the device

```sh
# GDM -> netdev map (the basis for the whole view)
for d in /sys/class/net/*; do echo "$(basename $d) -> $(basename $(readlink -f $d/of_node 2>/dev/null))"; done
cat /sys/class/net/pon0/of_node/airoha,pon-data-path

# NPU
dmesg | grep -i "NPU fw version"
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies

# Frame Engine
ls /sys/kernel/debug/ppe/; head -3 /sys/kernel/debug/ppe/entries
devmem 0x1fb5008c
dmesg | grep "OF: reserved mem:"
```

## License

Apache-2.0. Original author: Ryan Chen (rchen14b).
