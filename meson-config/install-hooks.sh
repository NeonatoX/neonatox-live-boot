#!/bin/sh
# Crea el symlink unificado de hooks (§4.6):
#   <datadir>/mkinitramfs/hooks -> <datadir>/neonatox-boot/hooks
# Recibe: $1 = <datadir>/mkinitramfs, $2 = <datadir>/neonatox-boot
set -e

mki_dir="$1"
nb_dir="$2"
dest="${MESON_INSTALL_DESTDIR_PREFIX:-/}/${mki_dir%/}/hooks"

mkdir -p "$(dirname "$dest")"
rm -f "$dest"
# target relativo: desde <datadir>/mkinitramfs/hooks sube a <datadir>/ y baja a neonatox-boot/hooks
ln -s "../$(basename "$nb_dir")/hooks" "$dest"