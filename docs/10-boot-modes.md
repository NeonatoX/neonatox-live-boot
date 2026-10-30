# Boot Modes - Neonatox Live Boot

Official boot options and kernel flags for the Neonatox Live system.

## Overview

Neonatox Live Boot uses a fully custom **initramfs** designed for robust
hardware detection, optional RAM-based overlays, Ventoy compatibility, and
controlled debugging.

All boot flags are parsed and acted upon **before switch_root**.

Since v0.10 the initramfs ships a single orchestrator (`/init`) that selects a
**profile** at boot time. The four profiles share the same phase pipeline
(`/libexec/`) but load different libraries from `/lib/`.

## Mode Selection

The mode is resolved in this order:

| Priority | Condition | Mode |
|----------|-----------|------|
| 1 | `netinstall=1` on the kernel command line | `netinstall` |
| 2 | `/etc/neonatox-mode` marker present | its content (`embedded`) |
| 3 | `root=` (any form) **and no marker** | `disk` |
| 4 | none of the above | `live` (default) |

A `root=` entry never overrides `netinstall=1`, and an embedded marker always
wins over `root=`.

* * *

## 1\. Live (Default)

```
linux /boot/vmlinuz quiet loglevel=3
```

  * Fast boot
  * tmpfs overlay (RAM)
  * No interactive configuration
  * No integrity re-check
  * Ends with `switch_root` into systemd

### Live (Language & Live User Config)

```
linux /boot/vmlinuz quiet neoconfig=1
```

  * Language selection
  * Keyboard layout
  * Timezone
  * Live user setup

### Live (Failsafe graphics)

```
linux /boot/vmlinuz quiet nomodeset vga=normal
```

  * Disables KMS
  * Recommended for legacy GPUs and virtual machines

### Live (Kernel DEBUG)

```
linux /boot/vmlinuz debug=1 loglevel=7
```

  * Maximum kernel verbosity
  * Driver and hardware diagnostics
  * Does not affect initramfs logic

### Live (Initramfs Debug Levels)

Neonatox provides **three deterministic initramfs debug breakpoints**. Each
level stops the boot process at a precise stage.

```
linux /boot/vmlinuz initrd_debug=1|2|3
```

#### initrd_debug=1 – Early initramfs

  * Console and virtual filesystems mounted
  * Kernel modules loaded
  * Before ZRAM and device scan

#### initrd_debug=2 – Storage & integrity stage

  * ZRAM overlay configured (if enabled)
  * Ventoy environment detected
  * Devices scanned
  * rootfs.squashfs located and verified
  * squashfs mounted

#### initrd_debug=3 – Pre-switch_root

  * Overlay filesystem mounted
  * newroot prepared
  * Live configuration executed (if enabled)
  * System ready to switch_root

**Note:** All debug levels drop into an emergency shell. Boot will not continue
automatically.

* * *

## 2\. Netinstall

```
linux /boot/vmlinuz quiet netinstall=1
```

  * Loads the `netinstall` profile (`init-live.sh` + `init-net.sh`)
  * Brings up every network interface with DHCP
  * Optional WiFi (`wifi_ssid=` / `wifi_psk=`) and NTP
  * Starts Dropbear SSH (`root` / `neonatox` by default)
  * Does **not** mount a squashfs root and does **not** `switch_root`
  * Ends in an interactive shell showing the assigned IP and a quick install
    guide

`netinstall=1` has the highest precedence: it wins over a baked marker and over
any `root=` argument.

* * *

## 3\. Disk

```
linux /boot/vmlinuz root=UUID=<uuid> ro
```

Any `root=` form is accepted: `/dev/sdX`, `UUID=`, `PARTUUID=` or `LABEL=`.

  * Loads the `disk` profile (`init-disk.sh`)
  * Uses devtmpfs instead of `mdev -s`
  * Starts the host `udevd`, activates RAID and LVM
  * Honors `rootdelay=`, `rootfstype=`, `rootflags=`, `resume=` and `splash=`
  * Mounts the real root on `/.root` and ends with `switch_root` into `/sbin/init`
    (or the path given by `init=`)

`root=` is only treated as `disk` when there is **no** `/etc/neonatox-mode`
marker, so embedded images booting with `root=/dev/mmcblk0pN` are not
misdetected.

* * *

## 4\. Embedded

Embedded images bake a marker at build time:

```
/etc/neonatox-mode  →  embedded
```

  * Loads the `embedded` profile (`init-embedded.sh`)
  * Network + WiFi + NTP + Dropbear (same phase as `netinstall`)
  * Ships filesystem tools (`btrfs`, `mkfs.btrfs`, `mkfs.ext4`, `fsck.ext4`, `zstd`)
  * No kernel modules are copied into the sysroot
  * Ends in an interactive shell on the target device

The marker takes precedence over `root=`, which is required because embedded
targets normally boot with `root=/dev/…`.

* * *

## Optional Performance & Safety Flags

### ZRAM Overlay

```
linux /boot/vmlinuz zram=1
```

  * Uses compressed RAM as overlay upper layer
  * Automatic sizing based on total memory
  * lz4 compression when available
  * Falls back to tmpfs if unavailable

### RootFS Integrity Verification

```
linux /boot/vmlinuz checkhash=1
```

  * Full SHA256 verification of rootfs.squashfs
  * Applies to both physical media and Ventoy ISOs
  * Slower but ensures full integrity

* * *

## Supported Kernel Flags

| Flag | Effect |
|------|--------|
| `netinstall=1` | Select the `netinstall` profile |
| `root=` | Select the `disk` profile (only without a mode marker) |
| `rootdelay=` | Seconds to wait for the root device (`disk`) |
| `rootfstype=` | Root filesystem type, default `auto` (`disk`) |
| `rootflags=` | Extra mount options for the root filesystem (`disk`) |
| `resume=` | Resume device for hibernation (`disk`) |
| `noresume` | Skip hibernation resume (`disk`) |
| `splash=plymouth` | Plymouth boot splash (`disk`) |
| `init=` | Path to the init to execute after `switch_root` (`disk`) |
| `neoconfig=1` | Interactive live setup |
| `zram=1` | Enable ZRAM overlay |
| `checkhash=1` | Full rootfs hash verification |
| `initrd_debug=1` | Early initramfs shell |
| `initrd_debug=2` | Storage & integrity shell |
| `initrd_debug=3` | Pre-switch_root shell |
| `debug=1` | Kernel debug |
| `loglevel=7` | Maximum kernel verbosity |
| `nomodeset` | Disable KMS |

* * *

## Boot Flow Summary

```
Firmware (BIOS/UEFI)
        ↓
GRUB
        ↓
Linux Kernel
        ↓
μinit (/init)  ← MODE = netinstall | embedded | disk | live
        ↓
profile library (/lib/init-*.sh)
        ↓
runtime phases (/libexec/10-… → 99-…)
        ↓
live / disk      → (optional) ZRAM, Ventoy, checkhash, live-config
                 → switch_root → systemd
netinstall       → DHCP / WiFi / NTP / Dropbear → interactive shell
embedded         → DHCP / WiFi / NTP / Dropbear → interactive shell
```
