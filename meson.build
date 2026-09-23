project(
  'neonatox-boot',
  version : '0.10.0',
  meson_version : '>= 0.56',
  default_options : ['cpp_rtti=false', 'cpp_std=none', 'prefix=/usr']
)

# ÚNICO instalador del ecosistema (P9, §5.2.3 de PROPOSAL-modular-micro-init).
# Instala: binarios en PATH (mkinitramfs, lsinitramfs, neonatox-boot,
# neonatox-boot-build) + árbol completo del proyecto en <datadir>/neonatox-boot
# (directorio standalone que build.sh/build-tools.sh esperan) + hooks unificados
# §4.6 (data/hooks del backend + initramfs/hooks del proyecto) bajo
# <datadir>/neonatox-boot/hooks con symlink <datadir>/mkinitramfs/hooks.
# El meson.build del subtree (mkinitramfs/) queda retirado: este es EL meson.

sbindir = get_option('sbindir')
datadir = get_option('datadir')
share   = datadir / 'neonatox-boot'

# --- PATH: binarios de bajo nivel y orquestadores ---
install_data('mkinitramfs/src/mkinitramfs', install_dir : sbindir, install_mode : 'rwxr-xr-x')
install_data('mkinitramfs/src/lsinitramfs',  install_dir : sbindir, install_mode : 'rwxr-xr-x')
install_data('neonatox-boot',                 install_dir : sbindir, install_mode : 'rwxr-xr-x')
install_data('neonatox-boot-build',           install_dir : sbindir, install_mode : 'rwxr-xr-x')

# --- árbol completo del proyecto en <datadir>/neonatox-boot ---
# (sin tools/output, tools/src, tools/dist: artefactos de build-tools, gitignored)
install_data('build.sh',                   install_dir : share, install_mode : 'rwxr-xr-x')
install_data('build-tools.sh',             install_dir : share, install_mode : 'rwxr-xr-x')
install_data('neonatox-boot',              install_dir : share, install_mode : 'rwxr-xr-x')
install_data('neonatox-boot-build',        install_dir : share, install_mode : 'rwxr-xr-x')
install_data('HOOKS-AND-PHASES.md',        install_dir : share, install_mode : 'rw-r--r--')
install_subdir('initramfs',                install_dir : share)
install_subdir('mkinitramfs',              install_dir : share)
install_subdir('tools',                    install_dir : share,
               exclude_directories : ['output', 'dist', 'src', '.env'])

# --- hooks unificados (§4.6): backend + proyecto ---
install_subdir('mkinitramfs/data/hooks',   install_dir : share)
install_subdir('initramfs/hooks',          install_dir : share)

# symlink <datadir>/mkinitramfs/hooks -> <datadir>/neonatox-boot/hooks
# (mkinitramfs instalado resuelve HOOKDIR en <datadir>/mkinitramfs/hooks)
meson.add_install_script('meson-config/install-hooks.sh', datadir / 'mkinitramfs', datadir / 'neonatox-boot')