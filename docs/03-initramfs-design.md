# Initramfs Design

## Purpose of the Initramfs

The initramfs is not a mini-root filesystem intended to stay alive. Its only
job is to:

  * Detect boot media
  * Prepare the real root filesystem (or the recovery environment)
  * Hand control to the real init system — or to an interactive shell for
    netinstall/embedded profiles

Everything else is intentionally minimal.

## Single `/init`, Multiple Profiles

The project no longer ships a separate init per mode. A single orchestrator
(`initramfs/init`, the **μinit**) resolves the boot mode at runtime and loads
the matching profile library:

```
/init                     orchestrator (mode detection + phase loop)
/usr/lib/init-common.sh   shared colours, run_shell, emergency_shell, banner
/usr/lib/init-live.sh     live profile  (overlay, scan, ventoy, squashfs)
/usr/lib/init-net.sh      netinstall profile (DHCP, WiFi, NTP, dropbear)
/usr/lib/init-disk.sh     disk profile   (udev, raid/lvm, resume, mount root)
/usr/lib/init-embedded.sh embedded sysroot profile (red + shell + fs tools)
/libexec/10-mount-basic   runtime phases, sourced in lexical order
…
/libexec/99-hooks
```

`mkinitramfs` copies `init`, `lib/` and `libexec/` into **every** profile, so
live, netinstall, disk and embedded share the same boot logic. There is no
second, standalone disk init anymore.

### Profile selection

| Mode | Libraries sourced | `PROFILE_REQUIRES` |
|------|-------------------|--------------------|
| `live` | `init-live.sh` | `mkfs.ext4 fsck.ext4 zstd btrfs mkfs.btrfs` |
| `netinstall` | `init-live.sh` + `init-net.sh` | `bash dropbear dropbearkey wpa_supplicant wpa_cli wpa_passphrase zstd btrfs mkfs.btrfs mkfs.ext4 fsck.ext4` |
| `disk` | `init-disk.sh` | *(empty — no-op)* |
| `embedded` | `init-embedded.sh` | same as `netinstall` |

`PROFILE_REQUIRES` is a plain `PROFILE_REQUIRES="…"` line at the top of each
profile library. `mkinitramfs` reads it and installs those static binaries from
`--tools-dir` into `/usr/bin` of the initramfs.

### Mode detection

`/init` resolves `MODE` from, in order:

1. `netinstall=1` on the kernel command line,
2. the `/etc/neonatox-mode` marker baked into an embedded sysroot,
3. `root=` (any form) **only when no marker exists**,
4. fallback `live`.

The precedence guarantees that an embedded image booting with
`root=/dev/mmcblk0p2` stays in `embedded` instead of being mistaken for `disk`.
See [Boot Modes](10-boot-modes.md) for the user-facing view.

## Runtime Phase Contract

Phases live in `initramfs/libexec/` and are **sourced** (`.`) by `/init`, not
executed as subprocesses. They share the parent shell, so:

  * `$1` is `$MODE` (`live`, `netinstall`, `disk`, `embedded`).
  * They must `return 0` on success; any other value triggers
    `emergency_shell "Phase <name> failed"`.
  * They may `exec` to terminate the boot flow (e.g. `60-switch-root`).
  * Variables set by a phase are visible to later phases.

| Phase | Profiles | Responsibility |
|-------|----------|----------------|
| `10-mount-basic` | all | proc/sys/devpts/run, devtmpfs (disk) or `mdev -s`, loop nodes |
| `20-load-modules` | all | `modprobe` filesystems, media, USB/NVMe/HID; network + WiFi for netinstall/embedded |
| `30-scan-devices` | live | integrity check, Ventoy detection, block device scan |
| `40-overlay` | live | zram overlay, squashfs, overlayfs, live config, new root |
| `50-network` | netinstall, embedded | DHCP, WiFi, NTP, SSH |
| `60-switch-root` | all | `switch_root` (live/disk) or `run_shell` (netinstall/embedded) |
| `99-hooks` | all | source user runtime hooks from `/libexec/99-hooks.d/*` |

## Build-Time Hooks

`mkinitramfs` exposes four hook phases; each hook is an executable POSIX script
called with the initramfs work directory (`$WDIR`) and the environment variables
`TOOLS_DIR`, `NEONATOX_DIR`, `PROFILE`, `EXTRA_DIR`:

| Phase | When |
|-------|------|
| `pre-binaries` | after the basic tree exists, before binaries |
| `post-binaries` | after binaries + `PROFILE_REQUIRES`, before kernel modules |
| `pre-pack` | after binaries and modules, before `cpio` |
| `pre-microcode` | before prepending the CPU microcode |

The canonical contract lives in
[`HOOKS-AND-PHASES.md`](../HOOKS-AND-PHASES.md).

## Why BusyBox

BusyBox is used because:

  * It provides a predictable shell environment
  * It avoids dependency chains
  * It keeps the initramfs small and deterministic

Importantly, BusyBox does **not** provide a full device manager. This is a
design choice, not a limitation.

## /dev Handling Strategy

One of the most critical lessons learned during development was that device
management must be staged.

### What Was Tried (and Failed)

  * Mounting devtmpfs too early
  * Relying on hotplug helpers
  * Expecting /dev to populate automatically

These approaches resulted in:

  * Missing block devices
  * Broken dbus later in systemd
  * Non-interactive consoles

### The Working Model

Neonatox Live Boot uses:

  * devtmpfs for the `disk` profile (matching classic initramfs behaviour)
  * `mdev -s` for live, netinstall and embedded profiles
  * explicit `/dev/loop*` nodes created by `10-mount-basic`

This ensures that:

  * /dev is usable before systemd starts
  * systemd can take full control later

## Why /proc/sys/kernel/hotplug Is Not Used

Modern kernels no longer rely on `/proc/sys/kernel/hotplug`. Attempting to use it
results in:

```
sh: /proc/sys/kernel/hotplug: No such file or directory
```

This project intentionally avoids legacy hotplug mechanisms.
