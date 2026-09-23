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

VERSION="5.2.37"
ARCHIVE="bash-$VERSION.tar.gz"
URL="https://ftp.gnu.org/gnu/bash/$ARCHIVE"

# ----------------------------------------------------------
# Download source if missing
# ----------------------------------------------------------
if [ ! -d "bash-$VERSION" ]; then
    if [ ! -f "$ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading Bash source..."
        wget "$URL"
    fi

    echo -e "${YELLOW}[INFO]${NC} Extracting source..."
    tar xf "$ARCHIVE"
fi

cd "bash-$VERSION"

echo -e "${YELLOW}[INFO]${NC} Configuring static Bash..."

[ -f Makefile ] && make distclean || true

# Cross: GCC >=14 (C23 default) breaks the mkbuiltins HOST generator
# (old-style xmalloc() prototype) unless CFLAGS_FOR_BUILD carries -std=gnu11.
BUILD_CFLAGS="-static -Os -s -std=gnu11"
[ -n "$CROSS_ARCH" ] && BUILD_CFLAGS="-std=gnu11"

# GCC >=14: implicit-function-declaration is an ERROR by default (C99+/C23),
# and bash-5.2.37's bundled lib/termcap/tparam.c relies on the old implicit
# write(); keep -Wno-error so the termcap compile degrades to a warning in
# BOTH native and cross (pre-existing upstream portability bug).
CFLAGS="$CFLAGS -Wno-error=implicit-function-declaration"

CC="$MUSLGCC" CFLAGS="$CFLAGS -static -Os -s -std=gnu11 -fcommon -fno-link-libatomic" LDFLAGS="-static -fno-link-libatomic" \
CFLAGS_FOR_BUILD="$BUILD_CFLAGS" \
./configure   --host="$TOOLCHAIN_HOST" \
              --enable-static-link \
              --without-bash-malloc \
              --disable-largefile \
              --disable-nls \
              --prefix=/

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo -e "${YELLOW}[INFO]${NC} Compiling..."
make -j$JOBS bash

# ----------------------------------------------------------
# Validate static build
# ----------------------------------------------------------
if ! file bash | grep -q "statically linked"; then
    echo -e "${RED}[ERROR]${NC} Bash is not static!"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Static Bash verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"

install -m755 bash "$DEST/bash"

echo "$VERSION" > "$DEST/bash.version"

echo -e "${GREEN}[DONE]${NC} Bash copied to initramfs"

