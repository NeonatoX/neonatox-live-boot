# Hooks build-time y Fases runtime

Documento de contrato entre el generador `mkinitramfs` (build-time) y el init
unificado (runtime). Las partes que lo implementan viven en
`neonatox-mkinitramfs/` (backend) y `initramfs/` (proyecto): los hooks del
proyecto se inyectan con `--hooks-dir initramfs/hooks`.

## Hook de build-time

Ejecutables (POSIX, `chmod +x`), llamados con **un argumento** `$WORKDIR`
(`$WDIR`, el árbol del initramfs en construcción). Variables disponibles:
`TOOLS_DIR`, `NEONATOX_DIR`, `PROFILE` (disk|live|netinstall|embedded),
`EXTRA_DIR`. Exit 0 = OK; distinto de 0 aborta el build.

| Fase | Cuándo | Uso típico |
|------|--------|-----------|
| `pre-binaries` | tras la estructura básica, antes de copiar binarios | añadir binarios/libs/configuración temprana |
| `post-binaries` | tras copiar binarios + `PROFILE_REQUIRES`, antes de módulos del kernel | modificar configuración / añadir ficheros con semántica "ya hay toolchain" |
| `pre-pack` | tras binarios y módulos, antes del cpio | último retoque del árbol |
| `pre-microcode` | antes de anteponer el microcódigo CPU | tocar el initramfs ya empaquetado |

Hooks del proyecto (`initramfs/hooks/`):

| Hook | Fase | Perfiles | Qué hace |
|------|------|----------|----------|
| `10-reboot-poweroff` | pre-binaries | todos | wrappers `reboot`/`poweroff` vía sysrq (busybox los excluye del `--list`) |
| `20-passwd-shadow` | pre-binaries | todos | passwd/shadow root (hash SHA-512 generado en build) |
| `30-devices` | pre-binaries | todos | nodos base `/dev/{zero,tty,tty0-4}` |
| `40-wifi-wizard` | pre-pack | todos | `wifi-wizard.sh` desde EXTRA_DIR (tools wifi solo si las trae el perfil) |
| `50-live-config` | pre-pack | live | `live-config.sh` + `rootfs.sha256` desde EXTRA_DIR |
| `55-ssh-hostkeys` | pre-pack | netinstall, embedded | keys dropbear POR IMAGEN + marcador `/etc/neonatox-mode` (embedded) |
| `60-netinstall-config` | pre-pack | netinstall, embedded | wifi-config, disk-wizard, udhcpc, profile, fakes nhopkg |
| `70-bootstrap` | pre-pack | netinstall | micro-init + nhopkg clonado en build |

## Fases runtime (`initramfs/libexec/`)

Scripts POSIX, ejecutados por `init` **en orden lexicográfico** con un
argumento `$1=$MODE` (mismo valor que `MODE`):

```sh
for phase in /libexec/[0-9][0-9]-*; do
    PHASE="${phase##*/}"
    . "$phase" "$MODE" || emergency_shell "Phase $PHASE failed"
done
```

Contrato de fase runtime:
- Se **sourcean** (`.`), no se ejecutan como procesos: comparten shell y
  variables. `$1` es el modo; `set -- "$MODE"` puede restablecerse.
- Deben `return 0` en éxito. Un `return != 0` dispara `emergency_shell`.
- Pueden `exec` para terminar el flujo (p. ej. `60-switch-root`).
- `$?` de una fase sourceada es el código devuelto por su último comando.

Variables compartidas disponibles en runtime: `CMDLINE`, `MODE` (como `$1`),
`PROFILE_NAME`, constantes de `init-common.sh` (colores), funciones
`run_shell` / `emergency_shell` / `debug_shell` / `phase_kill_children` /
`show_banner`, y por perfil: `init-live.sh` (`ISO_MNT`, `ISO_TEST`,
`FOUND_DEV`, `FOUND_MATCH`, `VENTOY_MODE`, `OVERLAY_TYPE`),
`init-net.sh` (estado de red), `init-disk.sh` (`root`, `rootfstype`,
`rootflags`, `resume`, `noresume`, `SPLASH`, `INIT`, `UDEVD`).

| Fase | Perfiles | Qué hace |
|------|----------|----------|
| `10-mount-basic` | todos | proc/sys/devpts/run; devtmpfs (disk) o `mdev -s`; `/dev/loop*`; symlinks std |
| `20-load-modules` | todos | `modprobe` de filesystems + media (loop/scsi/nvme/usb/zram); red+y wifi en netinstall/embedded |
| `30-scan-devices` | live | `check_rootfs_hash` (checkhash=1), detección ventoy, escaneo de devices/bloques |
| `40-overlay` | live | `setup_overlay`, `mount_squashfs`, `mount_overlay`, `run_live_config`, `setup_newroot` |
| `50-network` | netinstall, embedded | `dhcp_all`, `wifi_config`, `ntp_sync`, `setup_ssh` |
| `60-switch-root` | todos | live/disk: `exec switch_root`; netinstall/embedded: `show_ip`+`show_guide`+`run_shell`; disk además udev, raid, lvm, resume, monta `/.root` |
| `99-hooks` | todos | fuente de `/libexec/99-hooks.d/*` (hooks runtime del usuario) |

## Detección de `MODE` (implementada en `init`)

Precedencia (contrato P0/P0b):

1. `netinstall=1` en cmdline → **netinstall**
2. `/etc/neonatox-mode` (sysroot embedded horneado en build) → su contenido
3. `root=` (cualquier forma: `/dev/`, `UUID=`, `PARTUUID=`, `LABEL=`),
   **solo sin marcador** → **disk**
4. ninguna → **live**