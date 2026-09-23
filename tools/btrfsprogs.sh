#!/bin/sh
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${YELLOW}[INFO]${NC} Searching for musl compiler..."
. "$TOOLS_DIR/lib-cross.sh"
resolve_compiler || exit 1
echo -e "${YELLOW}[INFO]${NC} Using compiler: $MUSLGCC"

cd "$SRC_DIR"
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
DEPS_PREFIX="/tmp/btrfs-deps${CROSS_ARCH:+-$CROSS_ARCH}"
rm -rf "$DEPS_PREFIX"
mkdir -p "$DEPS_PREFIX/lib" "$DEPS_PREFIX/include"

# ----------------------------------------------------------
# Build zlib static
# ----------------------------------------------------------
ZLIB_V="1.3.2"
ZLIB_ARCHIVE="zlib-$ZLIB_V.tar.gz"
ZLIB_URL="https://zlib.net/$ZLIB_ARCHIVE"

if [ ! -d "zlib-$ZLIB_V" ]; then
    [ -f "$ZLIB_ARCHIVE" ] || wget "$ZLIB_URL"
    tar xf "$ZLIB_ARCHIVE"
fi
cd "zlib-$ZLIB_V"
[ -f Makefile ] && make distclean || true
CC="$MUSLGCC" CFLAGS="-static -Os -s -std=gnu11 -fno-link-libatomic" \
./configure --static --prefix="$DEPS_PREFIX"
make -j$JOBS
make install
cd "$SRC_DIR"

# ----------------------------------------------------------
# Build util-linux (minimal: libuuid + libblkid static)
# ----------------------------------------------------------
UL_V="2.40.4"
UL_ARCHIVE="util-linux-$UL_V.tar.gz"
UL_URL="https://mirrors.kernel.org/pub/linux/utils/util-linux/v${UL_V%.*}/$UL_ARCHIVE"

if [ ! -d "util-linux-$UL_V" ]; then
    [ -f "$UL_ARCHIVE" ] || wget "$UL_URL"
    tar xf "$UL_ARCHIVE"
fi
cd "util-linux-$UL_V"
[ -f Makefile ] && make distclean || true
CC="$MUSLGCC" \
CFLAGS="-static -Os -s -std=gnu11 -fno-link-libatomic" \
LDFLAGS="-static -fno-link-libatomic" \
./configure \
    --host="$TOOLCHAIN_HOST" \
    --disable-all-programs \
    --enable-libuuid --enable-libblkid \
    --disable-shared --enable-static \
    --prefix="$DEPS_PREFIX"
make -j$JOBS
make install
cd "$SRC_DIR"

# ----------------------------------------------------------
# Build btrfs-progs static
# ----------------------------------------------------------
BTRFS_V="7.0"
BTRFS_ARCHIVE="btrfs-progs-v${BTRFS_V}.tar.gz"
BTRFS_URL="https://mirrors.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/${BTRFS_ARCHIVE}"

if [ ! -d "btrfs-progs-v${BTRFS_V}" ]; then
    [ -f "$BTRFS_ARCHIVE" ] || wget "$BTRFS_URL"
    tar xf "$BTRFS_ARCHIVE"
fi
cd "btrfs-progs-v${BTRFS_V}"
# btrfs-progs has no 'distclean' target; 'make clean' removes stale .o and
# .deps/*.o.d (which may embed paths from a previous arch build in this shared tree)
[ -f Makefile ] && make clean >/dev/null 2>&1 || true

export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig"
export CFLAGS="-static -Os -s -std=gnu11 -fno-link-libatomic -I$DEPS_PREFIX/include"
export LDFLAGS="-static -fno-link-libatomic -L$DEPS_PREFIX/lib"

# Cross fix: autoconf can't run the malloc(0)/realloc(0) runtime test, which
# would #define malloc rpl_malloc (undefined). Assert both are fine (musl).
ac_cv_func_malloc_0_nonnull=yes \
ac_cv_func_realloc_0_nonnull=yes \
CC="$MUSLGCC" \
./configure \
    --host="$TOOLCHAIN_HOST" \
    --disable-documentation \
    --disable-backtrace \
    --disable-convert \
    --disable-zoned \
    --disable-zstd \
    --disable-lzo \
    --disable-libudev \
    --disable-python \
    --disable-shared \
    --enable-static \
    --with-crypto=builtin

echo -e "${YELLOW}[INFO]${NC} Compiling btrfs and mkfs.btrfs..."
make -j$JOBS btrfs mkfs.btrfs

for bin in btrfs mkfs.btrfs; do
    if [ -f "$bin" ] && ! file "$bin" | grep -q "statically linked"; then
        echo -e "${RED}[ERROR]${NC} $bin is not static!"
        exit 1
    fi
done
echo -e "${GREEN}[OK]${NC} Static btrfs binaries verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"
install -m755 btrfs       "$DEST/btrfs"
install -m755 mkfs.btrfs  "$DEST/mkfs.btrfs"

echo "$BTRFS_V" > "$DEST/btrfsprogs.version"

echo -e "${GREEN}[DONE]${NC} btrfs binaries copied to initramfs"
