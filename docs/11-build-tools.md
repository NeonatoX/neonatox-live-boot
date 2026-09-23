# Neonatox Live Boot Tools Builder (`build-tools.sh`)

The Neonatox Live Boot Tools Builder is part of the initramfs build workflow. Its purpose is to compile essential system binaries in a fully **static** manner using `musl`.

This ensures:

*   Portability
*   Host system independence
*   Compatibility with minimal environments
*   Predictable runtime behavior

* * *

## General Architecture

The system is structured around a **central dispatcher** (`build-tools.sh`) that discovers and executes individual tool-specific build scripts.

Each tool script is fully self-contained and responsible for:

*   Fetching its source code
*   Configuring a minimal build
*   Enforcing static linking
*   Validating the resulting binary
*   Installing it into the initramfs staging area

This modular design allows selective or full builds while maintaining a clean and debuggable pipeline.

* * *

## Included Tools

### Bash

A statically linked and optimized version of the GNU Bash shell is compiled with only essential features enabled.

The resulting binary is validated to confirm that it contains **no dynamic dependencies** before being integrated into the initramfs.

Reference: `bash.sh`

* * *

### BusyBox

BusyBox is compiled as a single static binary providing multiple core utilities required by the initramfs.

A predefined configuration is used to ensure deterministic behavior, and static linking is enforced during compilation.

Reference: `busybox.sh`

* * *

### e2fsprogs

A minimal subset of e2fsprogs is compiled, focusing only on essential ext filesystem utilities.

Unnecessary components are disabled to reduce binary size and complexity.

Reference: `e2fsprogs.sh`

* * *

### Dropbear

A static SSH client/server, built minimal (dropbear, dropbearkey) for remote
access during netinstall mode.

Reference: `dropbear.sh`

* * *

### btrfs-progs

Static btrfs utilities (btrfs, mkfs.btrfs). Requires static zlib and minimal
libuuid/libblkid from util-linux, built locally into `/tmp/btrfs-deps[-<arch>]`.

Reference: `btrfsprogs.sh`

* * *

### wpa_supplicant

Static wpa_supplicant plus standalone `wpa_cli` and `wpa_passphrase` CLI tools.
Static libnl-3 is built locally into `/tmp/libnl-install[-<arch>]`; the build
must point `PKG_CONFIG_PATH` at that prefix so `drivers.mak` resolves libnl via
`pkg-config` instead of leaking host `-I/usr/include` paths.

Reference: `wpa_supplicant.sh`

* * *

### zstd

Static zstd compression utility (Zstandard), used for squashfs compression
support in the live image.

Reference: `zstd.sh`

* * *

## Key Features

*   Fully static compilation
*   Complete host system independence
*   Modular and extensible structure
*   Automatic binary validation
*   Direct integration into initramfs

* * *

## Execution Flow

The central builder supports selective execution:

./build-tools.sh --all
./build-tools.sh --busybox
./build-tools.sh --bash --busybox
./build-tools.sh --package-all
./build-tools.sh --fetch busybox
./build-tools.sh --fetch armhf:busybox
./build-tools.sh --target ARMHF --busybox
./build-tools.sh --target ARMHF --cross-dir /opt/toolchain --all
./build-tools.sh --clean

Flags:

*   `--toolname` / `--all` — build one tool or all available tools
*   `--package [tool]` / `--package-all` — pack built binaries into versioned,
    deterministic zips under `tools/dist/` and update `tools/releases.sha256`
*   `--fetch [arch:]tool` / `--fetch-all [arch]` — download prebuilt tools from
    the GitHub release instead of building (e.g. `--fetch armhf:busybox`)
*   `--target ARCH` — cross-compile for an external target (`ARMHF`) instead of
    the native host; requires `CROSS_COMPILER` in `tools/.env` or `--cross-dir`
*   `--cross-dir PATH` — toolchain root override (Bootlin-style wrapper dir)
*   `--list` — list available tools; `--clean` — remove build artifacts inside
    `tools/`; `--version` / `--help`

Dispatched build scripts are discovered automatically from `tools/*.sh` (`lib-
pack.sh`, `lib-cross.sh` and `publish.sh` are excluded).

* * *

## Cross-compilation

`--target ARMHF` builds the full toolset for a 32-bit ARM hard-float target
using an external musl toolchain (Bootlin `arm-buildroot-linux-musleabihf-*`).
All cross outputs are written to `tools/output/<ARCH>/` (e.g. `tools/output/
armhf`), keeping them separate from native `tools/output/`.

The cross toolchain is strict: any `-I/usr/*` (or other host path) leaks in the
command line are rejected. Sources are shared with native builds, so every tool
recipe must clean its tree (`distclean`/`clean`/`rm -rf build`) before compiling
to avoid stale state from a previous arch — this is the origin of most cross
bugs (see `PROPOSAL-embedded-build.md`).

* * *

## Packaging and releases

`--package-all` produces one zip per tool + `SHA256SUMS` in `tools/dist/`.
Zips are deterministic: file mtimes are pinned with `SOURCE_DATE_EPOCH`
(default `1577836800`, 2020-01-01) so repeated packaging yields identical
artifacts and an unchanged `tools/releases.sha256` manifest. The manifest holds
one row per (arch, tool) pair.

`tools/publish.sh` uploads the zips to the `tools-*` GitHub release (tag from
`current_tools_tag()` unless `TOOLS_TAG` is set). Existing assets are replaced
on mismatch, so republishing deterministic zips converges to the manifest.
Publishing requires `GITHUB_TOKEN` in `tools/.env`. Native `bash` cannot be
rebuilt locally (autoconf C23/musl probe issue, rc=77) — its native asset is
published from CI and stays untouched.

* * *

## Design Notes

The toolchain prioritizes:

*   Minimalism
*   Full runtime control
*   System reproducibility
*   Isolation of build components

Each tool is built independently, keeping the build process transparent and easy to debug.

* * *

## Philosophical Alignment

The Tools Builder reinforces the educational philosophy of Neonatox Live Boot:

*   No opaque dependency chains
*   No reliance on host system libraries
*   No unpredictable runtime behavior

Everything included in the initramfs is compiled deliberately, validated explicitly, and understood completely.
