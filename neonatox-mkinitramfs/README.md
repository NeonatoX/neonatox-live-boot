[![License: GPLv3+](https://img.shields.io/badge/license-GPLv3%2B-blue.svg)](LICENSE)[![Language: Bash](https://img.shields.io/badge/language-Bash-green.svg)](https://www.gnu.org/software/bash/)[![Build system: Meson](https://img.shields.io/badge/build-Meson-orange.svg)](https://mesonbuild.com/)[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/cargabsj175/neonatox-mkinitramfs)

mkinitramfs
==========

mkinitramfs is a simple and transparent initramfs generator, designed following the Linux From Scratch (BLFS) philosophy. It avoids heavy automation and generates a predictable, fully controlled initramfs image.

Origin
------

This project is based on the BLFS documentation:

[https://www.linuxfromscratch.org/blfs/view/systemd/postlfs/initramfs.html](https://www.linuxfromscratch.org/blfs/view/systemd/postlfs/initramfs.html)

Features
--------

- Minimal and predictable initramfs generation
- Module blacklist support via `/etc/modprobe.d/`
- Automatic firmware extraction from kernel modules
- Configurable compression: gzip, xz, or zstd (default)
- Hooks system for extensibility
- Microcode (Intel/AMD) prepending support

Installed files
--------------

- `/usr/sbin/mkinitramfs` – initramfs generator
- `/usr/sbin/lsinitramfs` – list initramfs contents
- `/usr/share/mkinitramfs/init.in` – init script inside initramfs
- `/usr/share/mkinitramfs/hooks/` – hooks directory

Usage
-----

```bash
mkinitramfs -k <kernel-version>   # kernel version (default: uname -r)
mkinitramfs -r <release>         # release suffix
mkinitramfs -c <compress>       # compression: gz, xz, zstd (default: zstd)
```

```bash
lsinitramfs -l <initramfs>        # list contents
```

Dependencies
------------

Required at runtime:

- **cpio** – mandatory
- **zstd** or **xz** or **gzip** – for compression

Optional (only if the root filesystem requires them):

- **LVM2 >= 2.03.37**
- **mdadm >= 4.4**

Installation
------------
```
meson setup builddir --prefix=/usr
ninja -C builddir
sudo ninja -C builddir install
```

Hooks System
-----------

Hooks are executable scripts in `/usr/share/mkinitramfs/hooks/<phase>/`:

- `pre-binaries` – before copying binaries
- `pre-pack` – before packaging initramfs
- `pre-microcode` – before embedding microcode

Each hook receives the work directory as argument and should exit 0 on success.

Notes
-----

This mkinitramfs implementation is intentionally minimal. Only the components strictly required to mount the root filesystem are included.