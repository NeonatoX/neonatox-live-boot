#!/bin/bash
set -e

# ==========================================================
# Neonatox Live Boot Builder - your distro to bootable iso
# BIOS + UEFI + GRUB
# ==========================================================

# Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
    # El modo embedded vierta un árbol en output/ sin snapshot de "/",
    # sin grub/xorriso ni mksquashfs: no requiere root.
    if [[ "$*" != *"--make-embedded"* ]]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi
    echo "[INFO] Modo embedded: no requiere root"
fi

PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NLB_VERSION="v0.9"

# ---------------------------------------------
# Default values (safe fallback)
# ---------------------------------------------

ISO_NAME="nlb-linux-live"
VERSION="1"
ARCH="$(uname -m)"
LABEL="NLB_LINUX_LIVE"

# ---------------------------------------------
# Override only if /etc/os-release exists
# ---------------------------------------------
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release

    # Base name (lowercase, ISO filename)
    if [ -n "${ID:-}" ]; then
        BASE_NAME="$(printf '%s\n' "$ID" | tr '[:upper:]' '[:lower:]')"
    elif [ -n "${NAME:-}" ]; then
        BASE_NAME="$(printf '%s\n' "$NAME" \
            | tr '[:upper:]' '[:lower:]' \
            | tr ' ' '-' )"
    else
        BASE_NAME="linux"
    fi


    ISO_NAME="${BASE_NAME}-live"

    # Version
    if [ -n "${VERSION_ID:-}" ]; then
        VERSION="$VERSION_ID"
    fi

    # LABEL always uppercase
    LABEL="$(printf '%s_LIVE\n' "$BASE_NAME" | tr '[:lower:]' '[:upper:]')"
else
    # fallback consistency
    ISO_NAME="nlb-linux-live"
    LABEL="NLB_LINUX_LIVE"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)

# Function to check available space 
check_tmp_space() {  
    local required_gb=5  
    local tmp_space_kb
    tmp_space_kb=$(df -P /tmp | awk 'NR==2 {print $4}')  
    tmp_space_kb=${tmp_space_kb:-0}  
    local tmp_space_gb=$((tmp_space_kb / 1024 / 1024))  
      
    if [ "$tmp_space_gb" -lt "$required_gb" ]; then  
        echo -e "${YELLOW}[WARN]${NC} /tmp tiene solo ${tmp_space_gb}GB (< ${required_gb}GB)"  
        local var_space_kb  
        var_space_kb=$(df -P /var/tmp | awk 'NR==2 {print $4}')  
        var_space_kb=${var_space_kb:-0}  
        local var_space_gb=$((var_space_kb / 1024 / 1024))  
        if [ "$var_space_gb" -ge "$required_gb" ]; then  
            echo -e "${YELLOW}[INFO]${NC} Usando ruta alternativa: /var/tmp/neonatox-live"  
            WORKDIR="/var/tmp/neonatox-live"  
        else  
            echo -e "${RED}[ERROR]${NC} /var/tmp también insuficiente (${var_space_gb}GB)"  
            echo -e "${YELLOW}[INFO]${NC} Se necesita al menos ${required_gb}GB libres en /tmp o /var/tmp"  
            exit 1  
        fi  
    else  
        WORKDIR="/tmp/neonatox-live"  
    fi  
}

check_tmp_space
ISO_DIR="$WORKDIR/iso"
OUTDIR="$SCRIPT_DIR/output"
INITRAMFS_STAGING="$WORKDIR/initramfs"

BOOT_DIR="$ISO_DIR/boot"
GRUB_DIR="$BOOT_DIR/grub"
EFI_DIR="$ISO_DIR/EFI/BOOT"

SQUASHFS="$ISO_DIR/rootfs.squashfs"
INITRAMFS_IMG="$BOOT_DIR/initramfs.img"
BG_IMG="$SCRIPT_DIR/iso/background.png"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------
# ERROR HANDLING (section-aware)
# ----------------------------------------------------------
CURRENT_SECTION="initialization"

trap 'echo -e "${RED}[FATAL]${NC} error in section: $CURRENT_SECTION (line $LINENO)"; echo "Command: $BASH_COMMAND"; exit 99' ERR

# ----------------------------------------------------------
# ARGUMENT PARSER
# ----------------------------------------------------------

NETINSTALL_MODE=false
SYSTEM_MUSL=false
EMBEDDED_MODE=false
EMBED_TARGET=""
WITHOUT_MAKE_ISO=false
MAKE_ISO_ONLY=false
DO_CLEAN=false
DO_CLEAN_ALL=false
COMPRESSION="zstd"
TOOLS_MODE="auto"

show_help() {
    cat <<EOF
Uso: sudo ./build.sh [OPCIONES]

Opciones:
  --make-netinstall        Generar ISO netinstall (sin squashfs, con herramientas de red)
  --make-embedded          Generar sysroot embebido (output/neonatox-sysroot-<arch>) en vez de ISO
  --target ARCH            (embedded) arquitectura del sysroot: ARMHF o vacío = host
  --system-musl            (netinstall) nhopkg con soporte musl (repo-arch=x86_64-musl)
  --without-make-iso       Preparar artefactos sin empaquetar la ISO
  --make-iso               Solo empaquetar ISO desde artefactos existentes
  --clean                  Limpiar directorio de trabajo
  --clean-all              Limpiar workdir, fuentes de tools e ISOs generadas
  --compress FORMAT        Compresión initramfs: zstd (default, rápido) o xz (lento, menor tamaño)
  --decompress-kernel-modules  Descomprimir .ko.zst (para busybox modprobe que no soporta módulos comprimidos)
  --fetch-tools            Solo descargar tools precompiladas (nunca compilar)
  --compile-tools          Solo compilar tools (nunca descargar)
  --version                Muestra la version
  --help, -h               Mostrar esta ayuda

Sin argumentos: build completo + ISO live (comportamiento actual)
EOF
}

show_ver(){
echo "Neonatox Live Boot - ${NLB_VERSION} Carlos Sanchez - 2007-2026"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --make-netinstall) NETINSTALL_MODE=true ;;
        --make-embedded) EMBEDDED_MODE=true ;;
        --target) EMBED_TARGET="$2"; shift ;;
        --system-musl) SYSTEM_MUSL=true ;;
        --without-make-iso) WITHOUT_MAKE_ISO=true ;;
        --make-iso) MAKE_ISO_ONLY=true ;;
        --clean) DO_CLEAN=true ;;
        --clean-all) DO_CLEAN_ALL=true ;;
        --compress) COMPRESSION="$2"; shift ;;
        --decompress-kernel-modules) DECOMPRESS_MODULES=true ;;
        --fetch-tools) FETCH_TOOLS=true ;;
        --compile-tools) COMPILE_TOOLS=true ;;
        --version|-v) show_ver; exit 0 ;;
        --help|-h) show_help; exit 0 ;;
        *) echo -e "${RED}[ERROR]${NC} Argumento desconocido: $1" >&2; show_help; exit 1 ;;
    esac
    shift
done

# Validaciones entre flags
if [ "$MAKE_ISO_ONLY" = true ] && [ "$WITHOUT_MAKE_ISO" = true ]; then
    echo -e "${RED}[ERROR]${NC} --make-iso y --without-make-iso son contradictorios" >&2
    exit 1
fi

if [ "$FETCH_TOOLS" = true ] && [ "$COMPILE_TOOLS" = true ]; then
    echo -e "${RED}[ERROR]${NC} --fetch-tools y --compile-tools son contradictorios" >&2
    exit 1
fi
if [ "$FETCH_TOOLS" = true ]; then
    TOOLS_MODE="fetch"
elif [ "$COMPILE_TOOLS" = true ]; then
    TOOLS_MODE="compile"
fi

# --clean y --clean-all tienen prioridad y salen
if [ "$DO_CLEAN" = true ] || [ "$DO_CLEAN_ALL" = true ]; then
    echo -e "${YELLOW}[CLEAN]${NC} Limpiando workdir..."
    rm -rf "$WORKDIR"
    if [ "$DO_CLEAN_ALL" = true ]; then
        echo -e "${YELLOW}[CLEAN]${NC} Limpiando fuentes de tools..."
        rm -rf "$SCRIPT_DIR"/tools/*/ "$SCRIPT_DIR"/tools/*.tar.* 2>/dev/null || true
        echo -e "${YELLOW}[CLEAN]${NC} Limpiando ISOs generadas..."
        rm -f "$OUTDIR"/*.iso 2>/dev/null || true
    fi
    echo -e "${GREEN}[OK]${NC} Limpieza completada"
    exit 0
fi

# --make-netinstall: ajustar modo
if [ "$NETINSTALL_MODE" = true ]; then
    echo -e "${YELLOW}[INFO]${NC} Modo netinstall activado"
fi

# --system-musl solo tiene sentido en modo netinstall
if [ "$SYSTEM_MUSL" = true ] && [ "$NETINSTALL_MODE" = false ]; then
    echo -e "${RED}[ERROR]${NC} --system-musl solo es válido junto con --make-netinstall" >&2
    exit 1
fi

# --make-embedded es excluyente con --make-netinstall
if [ "$EMBEDDED_MODE" = true ] && [ "$NETINSTALL_MODE" = true ]; then
    echo -e "${RED}[ERROR]${NC} --make-embedded y --make-netinstall son excluyentes" >&2
    exit 1
fi

# --target solo tiene sentido junto a --make-embedded
if [ -n "$EMBED_TARGET" ] && [ "$EMBEDDED_MODE" = false ]; then
    echo -e "${RED}[ERROR]${NC} --target solo es válido junto con --make-embedded" >&2
    exit 1
fi

case "$COMPRESSION" in
    zst|zstd) COMPRESSION="zstd" ;;
    xz) ;;
    gz) ;;
    *) echo -e "${RED}[ERROR]${NC} Compresión no soportada: $COMPRESSION (zstd, xz, gz)" >&2; exit 1 ;;
esac

# ----------------------------------------------------------
# MODO EMBEDDED: perfil mkinitramfs → output/neonatox-sysroot-<arch>
# Espejo estructural de netinstall, pero vierta el árbol en vez de cpio,
# sin kernel, sin squashfs, sin grub/xorriso.
# ----------------------------------------------------------
if [ "$EMBEDDED_MODE" = true ]; then
    CURRENT_SECTION="embedded sysroot"

    # Resolución de arquitectura / dir de tools
    if [ -n "$EMBED_TARGET" ]; then
        EMBED_ARCH="$(echo "$EMBED_TARGET" | tr 'A-Z' 'a-z')"
        if [ "$EMBED_ARCH" != "armhf" ]; then
            echo -e "${RED}[ERROR]${NC} --target solo soporta ARMHF (fase 1)" >&2
            exit 1
        fi
        TOOLS_ARCH_DIR="$SCRIPT_DIR/tools/output/armhf"
    else
        EMBED_ARCH="$(uname -m)"
        TOOLS_ARCH_DIR="$SCRIPT_DIR/tools/output"
    fi

    SYSROOT_DIR="$OUTDIR/neonatox-sysroot-$EMBED_ARCH"
    EXTRA_DIR="$WORKDIR/extra"
    rm -rf "$SYSROOT_DIR"
    mkdir -p "$EXTRA_DIR" "$SYSROOT_DIR"

    echo -e "${YELLOW}[INFO]${NC} Modo embedded ($EMBED_ARCH): $SYSROOT_DIR"
    echo -e "${YELLOW}[INFO]${NC} Sysroot SIN kernel: el usuario aporta kernel y módulos"

    # Busybox del arch, obligatorio
    BUSYBOX_BIN="$TOOLS_ARCH_DIR/busybox"
    if [ ! -f "$BUSYBOX_BIN" ]; then
        if [ "$EMBED_ARCH" = "armhf" ]; then
            echo -e "${RED}[ERROR]${NC} $BUSYBOX_BIN no existe" >&2
            echo -e "${YELLOW}[HINT]${NC} Ejecute: ./build-tools.sh --target ARMHF --busybox (y --all)" >&2
            exit 1
        fi
        echo -e "${YELLOW}[INFO]${NC} Embedded: buscando busybox nativo..."
        "$SCRIPT_DIR/build-tools.sh" --fetch busybox && [ -f "$BUSYBOX_BIN" ] || "$SCRIPT_DIR/build-tools.sh" --busybox
        [ -f "$BUSYBOX_BIN" ] || { echo -e "${RED}[ERROR]${NC} busybox no disponible" >&2; exit 1; }
    fi
    # Busybox del arch, obligatorio. Validación POR ARCH:
    #   nativo: se ejecuta (check funcional);
    #   cross (armhf): no es ejecutable en el host x86, se valida con file(1)
    #   que sea un ELF ARM estático (ejecutarlo daría "Exec format error").
    if [ "$EMBED_ARCH" = "armhf" ]; then
        file "$BUSYBOX_BIN" | grep -qE "ARM.*statically linked" || {
            echo -e "${RED}[ERROR]${NC} no es un ELF ARM estático: $BUSYBOX_BIN" >&2; exit 1; }
    else
        [ -x "$BUSYBOX_BIN" ] && "$BUSYBOX_BIN" --help >/dev/null 2>&1 || {
            echo -e "${RED}[ERROR]${NC} busybox no funcional en $BUSYBOX_BIN" >&2; exit 1; }
    fi
    echo -e "${GREEN}[OK]${NC} busybox ready ($BUSYBOX_BIN)"

    # Tools del perfil (PROFILE_REQUIRES) en el dir de la arch
    # armhf: nunca se auto-construye (toolchain externo); error claro.
    EMBED_TOOLS="bash:bash e2fsprogs:mkfs.ext4 dropbear:dropbear \
wpa_supplicant:wpa_supplicant zstd:zstd btrfsprogs:btrfs"
    for spec in $EMBED_TOOLS; do
        tool="${spec%%:*}"
        bin="$TOOLS_ARCH_DIR/${spec##*:}"
        if [ ! -f "$bin" ]; then
            if [ "$EMBED_ARCH" = "armhf" ]; then
                echo -e "${RED}[ERROR]${NC} $bin no existe" >&2
                echo -e "${YELLOW}[HINT]${NC} Ejecute: ./build-tools.sh --target ARMHF --$tool" >&2
                exit 1
            fi
            echo -e "${YELLOW}[INFO]${NC} Embedded: buscando $tool nativo..."
            "$SCRIPT_DIR/build-tools.sh" --fetch "$tool" && [ -f "$bin" ] || "$SCRIPT_DIR/build-tools.sh" "--$tool"
            [ -f "$bin" ] || { echo -e "${RED}[ERROR]${NC} $tool no disponible en $bin" >&2; exit 1; }
        fi
    done

    # dropbearkey NATIVO del host para generar las keys (agnósticas de arch)
    NATIVE_DROPBEARKEY="$SCRIPT_DIR/tools/output/dropbearkey"
    if [ ! -f "$NATIVE_DROPBEARKEY" ]; then
        "$SCRIPT_DIR/build-tools.sh" --fetch dropbear && [ -f "$NATIVE_DROPBEARKEY" ] || "$SCRIPT_DIR/build-tools.sh" --dropbear
        [ -f "$NATIVE_DROPBEARKEY" ] || { echo -e "${RED}[ERROR]${NC} dropbearkey nativo no disponible" >&2; exit 1; }
    fi
    echo -e "${GREEN}[OK]${NC} tools del perfil ready ($TOOLS_ARCH_DIR)"

    # EXTRA_DIR (espejo de netinstall) + host keys POR IMAGEN + marcador de modo
    [ -f "$SCRIPT_DIR/initramfs/wifi-wizard.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/wifi-wizard.sh" "$EXTRA_DIR/"
    [ -f "$SCRIPT_DIR/initramfs/wifi-config.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/wifi-config.sh" "$EXTRA_DIR/"
    [ -f "$SCRIPT_DIR/initramfs/disk-wizard.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/disk-wizard.sh" "$EXTRA_DIR/"

    echo -e "${YELLOW}[INFO]${NC} Generando dropbear host keys POR IMAGEN..."
    mkdir -p "$EXTRA_DIR/ssh-hostkeys"
    rm -f "$EXTRA_DIR/ssh-hostkeys/"*
    "$NATIVE_DROPBEARKEY" -t ed25519 -f "$EXTRA_DIR/ssh-hostkeys/dropbear_ed25519_host_key" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR]${NC} dropbearkey ed25519 falló" >&2; exit 1; }
    "$NATIVE_DROPBEARKEY" -t rsa -s 2048 -f "$EXTRA_DIR/ssh-hostkeys/dropbear_rsa_host_key" >/dev/null 2>&1 || {
        echo -e "${RED}[ERROR]${NC} dropbearkey rsa falló" >&2; exit 1; }
    chmod 0600 "$EXTRA_DIR/ssh-hostkeys/"*
    echo "embedded" > "$EXTRA_DIR/neonatox-mode"
    echo -e "${GREEN}[OK]${NC} keys + marcador listos (ganan los que trae la imagen)"

    # mkinitramfs --profile embedded → vierta el árbol
    MKINITRAMFS=""
    for cand in \
        "$SCRIPT_DIR/neonatox-mkinitramfs/src/mkinitramfs" \
        "$SCRIPT_DIR/../neonatox-mkinitramfs/src/mkinitramfs" \
        /usr/sbin/mkinitramfs \
        /usr/bin/mkinitramfs; do
        if [ -x "$cand" ]; then
            MKINITRAMFS="$cand"
            break
        fi
    done
    if [ -z "$MKINITRAMFS" ]; then
        echo -e "${RED}[ERROR]${NC} mkinitramfs no encontrado"
        echo "Esperado en $SCRIPT_DIR/neonatox-mkinitramfs/src/mkinitramfs"
        exit 1
    fi

    export EXTRA_DIR="$EXTRA_DIR"
    echo -e "${YELLOW}[INFO]${NC} Running mkinitramfs --profile embedded..."

    "$MKINITRAMFS" \
        --profile embedded \
        --output "$SYSROOT_DIR" \
        --tools-dir "$TOOLS_ARCH_DIR" \
        --neonatox-dir "$SCRIPT_DIR/initramfs" \
        --hooks-dir "$SCRIPT_DIR/initramfs/hooks"

    echo -e "${GREEN}[OK]${NC} sysroot vierto..."

    # Verificación estructural (sin kernel, sin .ko, perfil correcto)
    echo -e "${YELLOW}[CHECK]${NC} verificando sysroot..."
    if [ ! -x "$SYSROOT_DIR/init" ]; then
        echo -e "${RED}[ERROR]${NC} falta /init en la sysroot" >&2; exit 1
    fi
    if [ "$(cat "$SYSROOT_DIR/etc/neonatox-mode" 2>/dev/null)" != "embedded" ]; then
        echo -e "${RED}[ERROR]${NC} marcador /etc/neonatox-mode no es 'embedded'" >&2; exit 1
    fi
    if [ -n "$(find "$SYSROOT_DIR" -name 'vmlinuz*' -o -name '*.ko' 2>/dev/null)" ]; then
        echo -e "${RED}[ERROR]${NC} la sysroot embedio kernel/módulos (contrato 'sin kernel')" >&2; exit 1
    fi

    echo "============================================"
    echo -e "${YELLOW}SYSROOT READY${NC}:"
    echo -e "${GREEN}$SYSROOT_DIR${NC}"
    echo "  arch    : $EMBED_ARCH"
    echo "  perfil  : embedded ($(cat "$SYSROOT_DIR/etc/neonatox-mode"))"
    echo "  init    : $(readlink -f "$SYSROOT_DIR/init")"
    echo "  bins    : busybox dropbear wpa_supplicant mkfs.ext4 zstd btrfs bash"
    echo "  ssh keys: generadas por imagen (fingerprint estable entre boots)"
    echo "  kernel  : NO incluido (añade el tuyo)"
    echo "============================================"
    exit 0
fi

# ----------------------------------------------------------
# PRE-CHECKS
# ----------------------------------------------------------
CURRENT_SECTION="pre-checks"

echo -e "${YELLOW}[CHECK]${NC} validating environment..."

# Binarios siempre requeridos
REQUIRED_BINS="
grub-mkimage
grub-mkstandalone
cpio
xz
sha256sum
depmod
modprobe
mknod
realpath
unxz
gunzip
unzstd
tools/output/busybox
"

# mksquashfs no necesario en modo netinstall
if [ "$NETINSTALL_MODE" = false ]; then
    REQUIRED_BINS="$REQUIRED_BINS
mksquashfs"
fi

# xorriso no necesario solo con --without-make-iso
if [ "$WITHOUT_MAKE_ISO" = false ]; then
    REQUIRED_BINS="$REQUIRED_BINS
xorriso"
fi

for bin in $REQUIRED_BINS; do
    # tools/output/busybox es un archivo, no un comando en PATH
    if [ "$bin" = "tools/output/busybox" ]; then
        if [ ! -f "$SCRIPT_DIR/$bin" ]; then
            # Si busybox está en PATH del host, copiarlo
            if command -v busybox >/dev/null 2>&1; then
                mkdir -p "$SCRIPT_DIR/tools/output"
                cp "$(command -v busybox)" "$SCRIPT_DIR/$bin"
            else
                echo -e "${RED}[ERROR]${NC} missing required binary: $bin"
                echo -e "${YELLOW}[HINT]${NC} Install busybox or run: ./build-tools.sh --busybox"
                exit 10
            fi
        fi
    elif ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} missing required binary: $bin"
        exit 10
    fi
done

REQUIRED_DIRS="
/boot
/usr/lib/grub
/lib/modules
"

for dir in $REQUIRED_DIRS; do
    if [ ! -d "$dir" ]; then
        echo -e "${RED}[ERROR]${NC} missing required directory: $dir"
        exit 11
    fi
done

[ -f "$BG_IMG" ] || {
    if [ "$MAKE_ISO_ONLY" = true ]; then
        echo -e "${YELLOW}[WARN]${NC} background image not found (not needed for --make-iso)"
    else
        echo -e "${RED}[ERROR]${NC} background image not found: $BG_IMG"
        exit 12
    fi
}

echo -e "${GREEN}[OK]${NC} environment valid"

# ----------------------------------------------------------
# MAKE ISO ONLY (skip build, repackage from existing artifacts)
# ----------------------------------------------------------
if [ "$MAKE_ISO_ONLY" = true ]; then
    echo -e "${YELLOW}[INFO]${NC} Modo solo empaquetado ISO"
    for f in "$SQUASHFS" "$INITRAMFS_IMG" "$GRUB_DIR/grub.cfg" "$GRUB_DIR/i386-pc/eltorito.img" "$EFI_DIR/BOOTX64.EFI"; do
        if [ ! -f "$f" ]; then
            echo -e "${RED}[ERROR]${NC} Artefacto faltante: $f" >&2
            echo -e "${RED}[ERROR]${NC} Ejecute ./build.sh --without-make-iso primero" >&2
            exit 1
        fi
    done

    echo -e "${YELLOW}[INFO]${NC} Building final ISO..."
    xorriso -as mkisofs \
      -iso-level 3 \
      -o "$OUTDIR/${ISO_NAME}-${VERSION}-${ARCH}.iso" \
      -V "$LABEL" \
      -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-catalog boot/grub/i386-pc/boot.cat \
      -eltorito-alt-boot \
         -e EFI/BOOT/BOOTX64.EFI \
         -no-emul-boot \
      "$ISO_DIR"

    echo "============================================"
    echo -e "${YELLOW}ISO READY${NC}:"
    echo -e "${GREEN}$OUTDIR/${ISO_NAME}-${VERSION}-${ARCH}.iso${NC}"
    echo "============================================"
    exit 0
fi

# ----------------------------------------------------------
# CLEANUP + CREATE DIRS
# ----------------------------------------------------------
CURRENT_SECTION="cleanup and directory setup"

rm -rf "$WORKDIR"
mkdir -p "$ISO_DIR" "$OUTDIR" "$BOOT_DIR" "$GRUB_DIR" "$EFI_DIR"

THEME_DIR="$GRUB_DIR/theme"
mkdir -p "$THEME_DIR"

cp "$BG_IMG" "$THEME_DIR/background.png"

# ----------------------------------------------------------
# MAKE ROOTFS SQUASHFS
# ----------------------------------------------------------
if [ "$NETINSTALL_MODE" = false ]; then
CURRENT_SECTION="rootfs squashfs"

clear
echo -e "${YELLOW}========${NC} ${GREEN}Neonatox Live Boot - ${NLB_VERSION} Carlos Sanchez - 2007-2026 ${YELLOW}========${NC}"
echo -e "${YELLOW}==========${NC} https://github.com/cargabsj175/neonatox-live-boot ${YELLOW}=========${NC}"

EXCLUDES_FILE="$SCRIPT_DIR/EXCLUDES"

if [ ! -f "$EXCLUDES_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} excludes file not found: $EXCLUDES_FILE"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Using excludes from $EXCLUDES_FILE"

echo -e "${YELLOW}[INFO]${NC} Creating squashfs rootfs..."

# Create pseudo file to recreate home/root dirs with original permissions
# and populate them with /etc/skel contents
PSEUDO_FILE=$(mktemp /tmp/squashfs-pseudo.XXXXXXXXXX)
trap 'rm -f "$PSEUDO_FILE"' EXIT

populate_skel() {
  local target="$1"
  local uid="$2"
  local gid="$3"
  [ -d /etc/skel ] || return 0
  find /etc/skel -mindepth 1 | while read -r src; do
    rel="${src#/etc/skel}"
    dest="$target$rel"
    if [ -d "$src" ]; then
      echo "${dest#/} d $(stat -c "%a" "$src") $uid $gid" >> "$PSEUDO_FILE"
    elif [ -f "$src" ]; then
      # f type executes a command; use cat to source the file content
      echo "${dest#/} f $(stat -c "%a" "$src") $uid $gid cat $src" >> "$PSEUDO_FILE"
    elif [ -L "$src" ]; then
      link=$(readlink "$src")
      echo "${dest#/} l $link" >> "$PSEUDO_FILE"
    fi
  done
}

for dir in /home /root; do
  [ -d "$dir" ] || continue
  ls -1 "$dir" | while read -r entry; do
    full="$dir/$entry"
    [ -d "$full" ] || continue
    mode=$(stat -c "%a" "$full")
    uid=$(stat -c "%u" "$full")
    gid=$(stat -c "%g" "$full")
    echo "${full#/} d $mode $uid $gid" >> "$PSEUDO_FILE"
    populate_skel "$full" "$uid" "$gid"
  done
done

mksquashfs / "$SQUASHFS" -ef "$EXCLUDES_FILE" -pf "$PSEUDO_FILE" \
  -comp xz -b 1024K -Xbcj x86 -always-use-fragments -no-xattrs -wildcards
echo -e "${GREEN}[OK]${NC} Squashfs rootfs created"    

echo -e "${YELLOW}[INFO]${NC} generating rootfs checksum..."
ROOTFS_HASH_FILE="$ISO_DIR/rootfs.sha256"

CURRENT_SECTION="rootfs checksum"
sha256sum "$SQUASHFS" | awk '{print $1}' > "$ROOTFS_HASH_FILE"
echo -e "${GREEN}[OK]${NC} rootfs checksum generated"
fi

# ----------------------------------------------------------
# CHOOSE KERNEL
# ----------------------------------------------------------
CURRENT_SECTION="kernel selection"

echo -e "${YELLOW}[INFO]${NC} Detecting running kernel from /proc/cmdline..."

VMLINUX=""
BOOT_IMAGE=""

# Extract BOOT_IMAGE
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        BOOT_IMAGE=*)
            BOOT_IMAGE="${arg#BOOT_IMAGE=}"
            break
            ;;
    esac
done

if [ -z "$BOOT_IMAGE" ]; then
    echo -e "${RED}[ERROR]${NC} BOOT_IMAGE not found in /proc/cmdline"
    exit 1
fi

# Resolve kernel path
if [ -f "$BOOT_IMAGE" ]; then
    VMLINUX="$BOOT_IMAGE"
elif [ -f "/boot$BOOT_IMAGE" ]; then
    VMLINUX="/boot$BOOT_IMAGE"
elif [ -f "/boot/$(basename "$BOOT_IMAGE")" ]; then
    VMLINUX="/boot/$(basename "$BOOT_IMAGE")"
else
    echo -e "${RED}[ERROR]${NC} Kernel image not found"
    echo "Tried:"
    echo "  $BOOT_IMAGE"
    echo "  /boot$BOOT_IMAGE"
    echo "  /boot/$(basename "$BOOT_IMAGE")"
    exit 1
fi

# Kernel real version
KVER="$(uname -r)"
# Kernel image (only name)
K_IMG_NAME=$(basename $BOOT_IMAGE)


if [ ! -d "/lib/modules/$KVER" ]; then
    echo -e "${RED}[ERROR]${NC} Kernel modules not found: /lib/modules/$KVER"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Kernel detected:"
echo "  BOOT_IMAGE : $K_IMG_NAME"
echo "  Kernel     : $VMLINUX"
echo "  Version    : $KVER"
echo "  Modules    : /lib/modules/$KVER"

# ----------------------------------------------------------
# KERNEL COPY
# ----------------------------------------------------------
CURRENT_SECTION="kernel copy"

cp "$VMLINUX" "$BOOT_DIR/${K_IMG_NAME}" || exit 1
chmod 0644 "$BOOT_DIR/${K_IMG_NAME}"

FULLVER="$KVER"

echo -e "${GREEN}[OK]${NC} Kernel copied to ISO"

# ----------------------------------------------------------
# INITRAMFS BUILD (using mkinitramfs)
# ----------------------------------------------------------
CURRENT_SECTION="initramfs build"

echo -e "${YELLOW}[INFO]${NC} Building initramfs..."

BUSYBOX_BIN="$SCRIPT_DIR/tools/output/busybox"
BASH_BIN="$SCRIPT_DIR/tools/output/bash"
BUILD_TOOLS="$SCRIPT_DIR/build-tools.sh"

# ----------------------------------------------------------
# ensure_tool <tool> <binary-path>
# Mode auto: fetch primero, compila si falla.
# Mode fetch/compile: solo una vía.
# ----------------------------------------------------------
ensure_tool() {
    local tool="$1" bin="$2"
    [ -f "$bin" ] && return 0
    echo -e "${YELLOW}[INFO]${NC} $tool not found at $bin"
    case "$TOOLS_MODE" in
        compile)
            "$SCRIPT_DIR/build-tools.sh" "--$tool" || true
            ;;
        fetch)
            "$SCRIPT_DIR/build-tools.sh" --fetch "$tool" || true
            ;;
        *)
            "$SCRIPT_DIR/build-tools.sh" --fetch "$tool" && return 0
            "$SCRIPT_DIR/build-tools.sh" "--$tool" || true
            ;;
    esac
    if [ ! -f "$bin" ]; then
        echo -e "${RED}[FATAL]${NC} $tool still missing after ensure_tool"
        return 1
    fi
    echo -e "${GREEN}[OK]${NC} $tool ready"
}

# ----------------------------------------------------------
# 1. Ensure + validate busybox
# ----------------------------------------------------------
if [ ! -f "$BUSYBOX_BIN" ]; then
    ensure_tool busybox "$BUSYBOX_BIN" || exit 1
fi

if [ ! -x "$BUSYBOX_BIN" ]; then
    echo -e "${RED}[ERROR]${NC} busybox exists but is not executable"
    exit 1
fi
if ! "$BUSYBOX_BIN" --help >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} busybox binary is not functional"
    exit 1
fi
if ! "$BUSYBOX_BIN" --list | grep -q "^switch_root$"; then
    echo -e "${RED}[FATAL]${NC} busybox was built without switch_root support"
    echo "Rebuild busybox with CONFIG_SWITCH_ROOT=y"
    exit 1
fi
echo -e "${GREEN}[OK]${NC} busybox validated"

# ----------------------------------------------------------
# 2. Auto-build netinstall tools if needed
# ----------------------------------------------------------
if [ "$NETINSTALL_MODE" = true ]; then
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring static bash..."
    [ ! -f "$SCRIPT_DIR/tools/output/bash" ] && ensure_tool bash "$SCRIPT_DIR/tools/output/bash" || true
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring e2fsprogs..."
    [ ! -f "$SCRIPT_DIR/tools/output/mkfs.ext4" ] && ensure_tool e2fsprogs "$SCRIPT_DIR/tools/output/mkfs.ext4" || true
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring dropbear..."
    [ ! -f "$SCRIPT_DIR/tools/output/dropbear" ] && ensure_tool dropbear "$SCRIPT_DIR/tools/output/dropbear" || true
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring wpa_supplicant..."
    [ ! -f "$SCRIPT_DIR/tools/output/wpa_supplicant" ] && ensure_tool wpa_supplicant "$SCRIPT_DIR/tools/output/wpa_supplicant" || true
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring static zstd..."
    [ ! -f "$SCRIPT_DIR/tools/output/zstd" ] && ensure_tool zstd "$SCRIPT_DIR/tools/output/zstd" || true
    echo -e "${YELLOW}[INFO]${NC} Netinstall: ensuring btrfs-progs..."
    [ ! -f "$SCRIPT_DIR/tools/output/btrfs" ] && ensure_tool btrfsprogs "$SCRIPT_DIR/tools/output/btrfs" || true
fi

if [ "$NETINSTALL_MODE" = false ]; then
    echo -e "${YELLOW}[INFO]${NC} Live: ensuring static zstd..."
    [ ! -f "$SCRIPT_DIR/tools/output/zstd" ] && ensure_tool zstd "$SCRIPT_DIR/tools/output/zstd" || true
    echo -e "${YELLOW}[INFO]${NC} Live: ensuring btrfs-progs..."
    [ ! -f "$SCRIPT_DIR/tools/output/btrfs" ] && ensure_tool btrfsprogs "$SCRIPT_DIR/tools/output/btrfs" || true
fi

# ----------------------------------------------------------
# 3. Populate EXTRA_DIR for hooks
# ----------------------------------------------------------
EXTRA_DIR="$WORKDIR/extra"
mkdir -p "$EXTRA_DIR"

# wifi-wizard (all modes), disk-wizard (netinstall), wifi-config.sh (netinstall fallback)
[ -f "$SCRIPT_DIR/initramfs/wifi-wizard.sh" ] && \
    cp "$SCRIPT_DIR/initramfs/wifi-wizard.sh" "$EXTRA_DIR/"

if [ "$NETINSTALL_MODE" = true ]; then
    [ -f "$SCRIPT_DIR/initramfs/wifi-config.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/wifi-config.sh" "$EXTRA_DIR/"
    [ -f "$SCRIPT_DIR/initramfs/netinstall-init.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/netinstall-init.sh" "$EXTRA_DIR/"
    [ -f "$SCRIPT_DIR/initramfs/disk-wizard.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/disk-wizard.sh" "$EXTRA_DIR/"

    # nhopkg (clone + meson install)
    echo -e "${YELLOW}[INFO]${NC} Cloning nhopkg..."
    rm -rf /tmp/nhopkg 2>/dev/null || true
    git clone https://github.com/cargabsj175/neonatox-nhopkg.git /tmp/nhopkg 2>/dev/null || {
            echo -e "${RED}[ERROR]${NC} nhopkg clone failed" >&2
            exit 1
        }
    echo -e "${YELLOW}[INFO]${NC} Installing nhopkg..."
    (
        cd /tmp/nhopkg
        sed -i 's/^NHOPKG_GETTEXT=.*/NHOPKG_GETTEXT=no/' src/nhopkg.conf.in 2>/dev/null || true
        if [ "$SYSTEM_MUSL" = true ]; then
            meson setup build \
                -D binlocate=plocate \
                -D repo-version=n27 \
                -D repo-arch=x86_64-musl \
                -D libc=musl \
                -D git-branch=musl \
                -D static-busybox=no \
                -D static-zstd=no \
                -D use-busybox=no 2>/dev/null || true
        else
            meson setup build \
                -D static-busybox=no \
                -D static-zstd=no \
                -D use-busybox=no 2>/dev/null || true
        fi
        cd build 2>/dev/null || exit 1
        DESTDIR="$PWD/DESTDIR" ninja install 2>/dev/null || true
        [ -d "$PWD/DESTDIR" ] && { mkdir -p "$EXTRA_DIR/nhopkg-install" && cp -r "$PWD/DESTDIR"/* "$EXTRA_DIR/nhopkg-install/" 2>/dev/null || true; }
    )
    echo -e "${GREEN}[OK]${NC} nhopkg installed"

    # neonatox-bootstrap (clone)
    echo -e "${YELLOW}[INFO]${NC} Cloning neonatox-bootstrap..."
    rm -rf /tmp/neonatox-bootstrap 2>/dev/null || true
    git clone https://github.com/cargabsj175/neonatox-bootstrap.git /tmp/neonatox-bootstrap 2>/dev/null || {
        echo -e "${YELLOW}[WARN]${NC} neonatox-bootstrap clone failed (non-fatal)"
    }
    if [ -d /tmp/neonatox-bootstrap ]; then
        cp -r /tmp/neonatox-bootstrap "$EXTRA_DIR/neonatox-bootstrap" 2>/dev/null || true
        echo -e "${GREEN}[OK]${NC} neonatox-bootstrap copied"
    fi
else
    # live-config.sh + rootfs.sha256
    [ -f "$SCRIPT_DIR/initramfs/live-config.sh" ] && \
        cp "$SCRIPT_DIR/initramfs/live-config.sh" "$EXTRA_DIR/"
    [ -f "$ROOTFS_HASH_FILE" ] && \
        cp "$ROOTFS_HASH_FILE" "$EXTRA_DIR/rootfs.sha256"
fi

# ----------------------------------------------------------
# 4. Call mkinitramfs
# ----------------------------------------------------------
MKINITRAMFS=""
for candidate in \
    "$SCRIPT_DIR/neonatox-mkinitramfs/src/mkinitramfs" \
    "$SCRIPT_DIR/../neonatox-mkinitramfs/src/mkinitramfs" \
    /usr/sbin/mkinitramfs \
    /usr/bin/mkinitramfs; do
    if [ -x "$candidate" ]; then
        MKINITRAMFS="$candidate"
        break
    fi
done

if [ -z "$MKINITRAMFS" ]; then
    echo -e "${RED}[ERROR]${NC} mkinitramfs not found"
    echo "Expected at $SCRIPT_DIR/neonatox-mkinitramfs/src/mkinitramfs"
    echo "or installed system-wide (neonatox-mkinitramfs)"
    exit 1
fi

export EXTRA_DIR="$EXTRA_DIR"

PROFILE="live"
[ "$NETINSTALL_MODE" = true ] && PROFILE="netinstall"

echo -e "${YELLOW}[INFO]${NC} Running mkinitramfs --profile $PROFILE..."

MKINITRAMFS_ARGS=(
    --profile "$PROFILE"
    --kernel "$KVER"
    --compress "$COMPRESSION"
    --output "$INITRAMFS_IMG"
    --staging "$INITRAMFS_STAGING"
    --tools-dir "$SCRIPT_DIR/tools/output"
    --neonatox-dir "$SCRIPT_DIR/initramfs"
    --hooks-dir "$SCRIPT_DIR/initramfs/hooks"
)
[ "$COMPRESSION" = xz ] && MKINITRAMFS_ARGS+=(--xz-extreme)
[ "$DECOMPRESS_MODULES" = true ] && MKINITRAMFS_ARGS+=(--decompress-kernel-modules)

"$MKINITRAMFS" "${MKINITRAMFS_ARGS[@]}"

echo -e "${GREEN}[OK]${NC} initramfs ready..."


# ----------------------------------------------------------
# GRUB CONFIG
# ----------------------------------------------------------
CURRENT_SECTION="grub configuration"

echo -e "${YELLOW}[INFO]${NC} Generating GRUB config..."
# Buscar .pf2 ya existente en ubicaciones comunes
unicode_pf2=""
for dir in /usr/share/grub /usr/share/grub/* /usr/share/fonts; do
    if [ -f "$dir/unicode.pf2" ]; then
        unicode_pf2="$dir/unicode.pf2"
        break
    fi
done

if [ -n "$unicode_pf2" ] && cp "$unicode_pf2" "$GRUB_DIR/font.pf2" 2>/dev/null; then
    echo -e "${GREEN}[OK]${NC} Found existing unicode.pf2"
else
    # Si no hay .pf2, buscar .pcf y convertir
    if [ -f "/usr/share/fonts/unifont/unifont.pcf" ]; then
        if command -v grub-mkfont >/dev/null 2>&1; then
            echo -e "${BLUE}[INFO]${NC} Converting unifont.pcf to pf2..."
            if grub-mkfont /usr/share/fonts/unifont/unifont.pcf -o "$GRUB_DIR/font.pf2" 2>/dev/null; then
                echo -e "${GREEN}[OK]${NC} Font converted successfully"
            else
                echo -e "${RED}[ERROR]${NC} Conversion failed"
            fi
        else
            echo -e "${YELLOW}[WARN]${NC} grub-mkfont not installed. Install grub-common"
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} No font found (non-fatal)"
    fi
fi

cat > "$GRUB_DIR/grub.cfg" <<EOF
set default=0
set timeout=15

# Configurar resolución de pantalla
set gfxmode=1024x768,800x600,auto
set gfxpayload=keep

insmod all_video
insmod png
insmod vbe
insmod video_bochs
insmod video_cirrus

# Si se pudo copiar la fuente unicode.pf2 usamos interfaz gráfica
# Si no, se cae a consola VGA para evitar los @@@@@@@ en pantalla
# (la fuente no se genera en musl porque grub-mkfont necesita freetype + unifont.pcf)
if [ -f /boot/grub/font.pf2 ]; then
  insmod gfxterm
  loadfont /boot/grub/font.pf2
  terminal_output gfxterm
  background_image /boot/grub/theme/background.png
fi

if [ "$NETINSTALL_MODE" = true ]; then

menuentry "${ISO_NAME%-live} Net Install" {
    linux /boot/${K_IMG_NAME} quiet netinstall=1 loglevel=3
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} Net Install (Failsafe graphics)" {
    linux /boot/${K_IMG_NAME} quiet netinstall=1 loglevel=3 nomodeset vga=normal
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} Net Install (Debug)" {
    linux /boot/${K_IMG_NAME} netinstall=1 debug=1 loglevel=7
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} Net Install (Initramfs debug)" {
    linux /boot/${K_IMG_NAME} quiet netinstall=1 initrd_debug=1
    initrd /boot/initramfs.img
}

else

menuentry "${ISO_NAME%-live} ${VERSION} live" {
    linux /boot/${K_IMG_NAME} quiet loglevel=3 zram=1
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} ${VERSION} live (Language & Live User Config)" {
    linux /boot/${K_IMG_NAME} quiet neoconfig=1 zram=1
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} ${VERSION} live (Failsafe graphics)" {
    linux /boot/${K_IMG_NAME} quiet nomodeset vga=normal zram=1
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} ${VERSION} live (DEBUG)" {
    linux /boot/${K_IMG_NAME} debug=1 loglevel=7 zram=1
    initrd /boot/initramfs.img
}

menuentry "${ISO_NAME%-live} ${VERSION} live (Initramfs debug)" {
    linux /boot/${K_IMG_NAME} quiet initrd_debug=1 zram=1
    initrd /boot/initramfs.img
}

fi

EOF
echo -e "${GREEN}[OK]${NC} GRUB config ready"

# ----------------------------------------------------------
# EFI STANDALONE
# ----------------------------------------------------------
CURRENT_SECTION="grub efi build"

echo -e "${YELLOW}[INFO]${NC} building UEFI bootloader..."
grub-mkstandalone \
  -O x86_64-efi \
  -d /usr/lib/grub/x86_64-efi \
  -o "$EFI_DIR/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$GRUB_DIR/grub.cfg"

echo -e "${GREEN}[OK]${NC} UEFI bootloader ready"
# ----------------------------------------------------------
# BIOS ENTRY
# ----------------------------------------------------------
CURRENT_SECTION="grub bios build"

echo -e "${YELLOW}[INFO]${NC} Building BIOS bootloader..."
mkdir -p "$GRUB_DIR/i386-pc"

cp -r /usr/lib/grub/i386-pc/* "$GRUB_DIR/i386-pc/" 2>/dev/null

grub-mkimage \
  -O i386-pc \
  -d /usr/lib/grub/i386-pc \
  -p /boot/grub \
  -o "$GRUB_DIR/i386-pc/core.img" \
  biosdisk iso9660 part_msdos normal search search_label configfile

cat \
  /usr/lib/grub/i386-pc/cdboot.img \
  "$GRUB_DIR/i386-pc/core.img" \
    > "$GRUB_DIR/i386-pc/eltorito.img"

echo -e "${GREEN}[OK]${NC} BIOS bootloader ready"
# ----------------------------------------------------------
# FINAL ISO BUILD
# ----------------------------------------------------------
if [ "$WITHOUT_MAKE_ISO" = false ]; then
CURRENT_SECTION="final iso build"

echo -e "${YELLOW}[INFO]${NC} Building final ISO..."

if [ "$NETINSTALL_MODE" = true ]; then
    ISO_NAME="${BASE_NAME}-netinstall"
fi

if [ "$SYSTEM_MUSL" = true ]; then
    ISO_NAME="${ISO_NAME}-musl"
fi

xorriso -as mkisofs \
  -iso-level 3 \
  -o "$OUTDIR/${ISO_NAME}-${VERSION}-${ARCH}.iso" \
  -V "$LABEL" \
  -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-catalog boot/grub/i386-pc/boot.cat \
  -eltorito-alt-boot \
     -e EFI/BOOT/BOOTX64.EFI \
     -no-emul-boot \
  "$ISO_DIR"

echo "============================================"
echo -e "${YELLOW}ISO READY${NC}:"
echo -e "${GREEN}$OUTDIR/${ISO_NAME}-${VERSION}-${ARCH}.iso${NC}"
echo "============================================"
fi
