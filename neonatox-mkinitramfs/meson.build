project(
  'mkinitramfs',
  version : '1.1.0',
  meson_version : '>= 0.56',
  default_options : ['cpp_rtti=false', 'cpp_std=none']
)

# No ourselves, solo instalamos scripts
# Usamos 'none' para que Meson no proteste

sbindir = get_option('sbindir')
datadir = get_option('datadir')
docdir  = join_paths(datadir, 'doc', 'mkinitramfs')

# Fuentes a instalar
mkinitramfs_src = files('src/mkinitramfs')
lsinitramfs_src = files('src/lsinitramfs')
initin_src = files('data/init.in')

# Script principal
install_data(
  mkinitramfs_src,
  install_dir : sbindir,
  install_mode : 'rwxr-xr-x'
)

# lsinitramfs
install_data(
  lsinitramfs_src,
  install_dir : sbindir,
  install_mode : 'rwxr-xr-x'
)

# init del initramfs
install_data(
  initin_src,
  install_dir : join_paths(datadir, 'mkinitramfs'),
  install_mode : 'rwxr-xr-x'
)

# Hooks
install_subdir(
  'data/hooks',
  install_dir : join_paths(datadir, 'mkinitramfs')
)

# Configuración de ejemplo
install_data(
  'data/mkinitramfs.conf',
  install_dir : join_paths(datadir, 'doc', 'mkinitramfs'),
  install_mode : 'rwxr-xr-x'
)

# Documentación
install_data(
  'README.html',
  install_dir : docdir
)
