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

VERSION="1.5.6"
ARCHIVE="zstd-$VERSION.tar.gz"
URL="https://github.com/facebook/zstd/releases/download/v$VERSION/$ARCHIVE"

if [ ! -d "zstd-$VERSION" ]; then
    if [ ! -f "$ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading zstd source..."
        wget "$URL"
    fi
    echo -e "${YELLOW}[INFO]${NC} Extracting source..."
    tar xf "$ARCHIVE"
fi

cd "zstd-$VERSION"

echo -e "${YELLOW}[INFO]${NC} Configuring static zstd..."
[ -f programs/Makefile ] && make -C programs clean || true

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo -e "${YELLOW}[INFO]${NC} Compiling..."
CFLAGS="-DZSTD_NO_TERMINAL_GUARD -Os -s -fno-link-libatomic" \
CC="$MUSLGCC" ZSTD_LIBS="-static" LDFLAGS="-static" \
make -j$JOBS -C programs zstd

if ! file programs/zstd | grep -q "statically linked"; then
    echo -e "${RED}[ERROR]${NC} zstd is not static!" >&2
    exit 1
fi

echo -e "${GREEN}[OK]${NC} Static zstd verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"

install -m755 programs/zstd "$DEST/zstd"

echo "$VERSION" > "$DEST/zstd.version"

echo -e "${GREEN}[DONE]${NC} zstd copied to initramfs (with symlinks)"
