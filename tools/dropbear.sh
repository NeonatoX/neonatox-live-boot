#!/bin/sh
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}[INFO]${NC} Searching for musl compiler..."

. "$TOOLS_DIR/lib-cross.sh"
resolve_compiler || exit 1

echo -e "${YELLOW}[INFO]${NC} Using compiler: $MUSLGCC"

cd "$SRC_DIR"

VERSION="2026.91"
ARCHIVE="DROPBEAR_${VERSION}.tar.gz"
URL="https://github.com/mkj/dropbear/archive/refs/tags/${ARCHIVE}"

if [ ! -d "dropbear-${VERSION}" ]; then
    if [ ! -f "$ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading Dropbear source..."
        wget "$URL"
    fi
    echo -e "${YELLOW}[INFO]${NC} Extracting source..."
    tar xf "$ARCHIVE"
fi

cd "dropbear-DROPBEAR_${VERSION}"

echo -e "${YELLOW}[INFO]${NC} Configuring static Dropbear..."

[ -f Makefile ] && make distclean || true

CC="$MUSLGCC" CFLAGS="-static -Os -s -fno-link-libatomic" LDFLAGS="-static -fno-link-libatomic" \
./configure --host="$TOOLCHAIN_HOST" --enable-static --disable-shared \
            --disable-zlib --prefix=/

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo -e "${YELLOW}[INFO]${NC} Compiling..."
make -j$JOBS

if ! file dropbear | grep -q "statically linked"; then
    echo -e "${RED}[ERROR]${NC} dropbear is not static!" >&2
    exit 1
fi

if ! file dropbearkey | grep -q "statically linked"; then
    echo -e "${RED}[ERROR]${NC} dropbearkey is not static!" >&2
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Static Dropbear verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"

install -m755 dropbear    "$DEST/dropbear"
install -m755 dropbearkey "$DEST/dropbearkey"

echo "$VERSION" > "$DEST/dropbear.version"

echo -e "${GREEN}[DONE]${NC} Dropbear copied to initramfs"
