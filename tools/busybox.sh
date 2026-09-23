#!/bin/sh
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${YELLOW}[INFO]${NC} Searching for musl compiler..."

. "$TOOLS_DIR/lib-cross.sh"
resolve_compiler || exit 1

echo -e "${YELLOW}[INFO]${NC} Using compiler: $MUSLGCC"

cd "$SRC_DIR"

# ----------------------------------------------------------
# Clone source if missing
# ----------------------------------------------------------
if [ ! -d busybox ]; then
    git clone https://git.busybox.net/busybox
fi

cd busybox

cp ../busybox-config .config
echo -e "${YELLOW}[INFO]${NC} Configuration copied"

# ----------------------------------------------------------
# Force static
# ----------------------------------------------------------
sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config || true

# Cross: set cross compiler prefix in the config
if [ -n "$CROSS_ARCH" ]; then
    sed -i "s|.*CONFIG_CROSS_COMPILER_PREFIX.*|CONFIG_CROSS_COMPILER_PREFIX=\"$CROSS_PREFIX\"|" .config
    sed -i 's/.*CONFIG_SWITCH_ROOT.*/CONFIG_SWITCH_ROOT=y/' .config || true
    echo -e "${YELLOW}[INFO]${NC} CROSS_COMPILER_PREFIX=$CROSS_PREFIX"
fi

echo -e "${YELLOW}[INFO]${NC} Updating config..."
yes "" | make oldconfig

# Drop stale objects from a previous (other-arch) build in this shared tree
[ -f Makefile ] && make clean >/dev/null 2>&1 || true

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

if [ -n "$CROSS_ARCH" ]; then
    KBUILD_ARCH="$(kbuild_arch)"
    make ARCH="$KBUILD_ARCH" CROSS_COMPILE="$CROSS_PREFIX" CC="$MUSLGCC" -j"$JOBS"
else
    make CC="$MUSLGCC" -j"$JOBS"
fi


# ----------------------------------------------------------
# Validate static build
# ----------------------------------------------------------
file busybox | grep -q "statically linked" || {
    echo -e "${RED}[ERROR]${NC} Busybox is not static!"
    exit 1
}

DEST="$OUT_DIR"
mkdir -p "$DEST"

install -m755 busybox "$DEST/busybox"

if [ -n "$CROSS_ARCH" ]; then
    # ARM binary can't run on the host: read the version tuple from the Makefile
    BUSYBOX_VER="$(awk '
        /^VERSION[[:space:]]*=/{v=$3}
        /^PATCHLEVEL[[:space:]]*=/{p=$3}
        /^SUBLEVEL[[:space:]]*=/{s=$3}
        END{printf "%s.%s.%s", v, p, s}' Makefile)"
else
    BUSYBOX_VER="$("$DEST/busybox" 2>&1 | head -1 | sed -n 's/.*BusyBox v\([0-9][0-9.]*\).*/\1/p')"
fi
echo "${BUSYBOX_VER:-unknown}" > "$DEST/busybox.version"

echo -e "${GREEN}[DONE]${NC} Busybox ready at $DEST"
