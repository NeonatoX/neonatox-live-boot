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

VERSION="1.47.1"
ARCHIVE="e2fsprogs-${VERSION}.tar.gz"
URL="https://sourceforge.net/projects/e2fsprogs/files/e2fsprogs/v${VERSION}/${ARCHIVE}/download"

# ----------------------------------------------------------
# Download source if missing
# ----------------------------------------------------------
if [ ! -d "e2fsprogs-${VERSION}" ]; then
    if [ ! -f "$ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading e2fsprogs source..."
        wget -O "$ARCHIVE" "$URL" || {
            echo -e "${RED}[ERROR]${NC} Download failed" >&2
            exit 1
        }
    fi

    echo -e "${YELLOW}[INFO]${NC} Extracting source..."
    tar xf "$ARCHIVE"
fi

cd "e2fsprogs-${VERSION}"

echo -e "${YELLOW}[INFO]${NC} Patching for GCC 14+ / musl compatibility..."

# GCC 14 treats implicit function declarations as error; the
# SIZEOF_LONG==SIZEOF_LONG_LONG branch (x86_64) defines "llseek" but forgets
# to alias my_llseek too. musl does not provide _syscall5, so the ARM branch
# must use syscall(__NR__llseek) directly. Both patches are guarded (idempotent).
LLSEEK="lib/blkid/llseek.c"
if ! grep -q 'Neonatox musl llseek patch' "$LLSEEK"; then
    sed -i 's|^#define llseek lseek$|#define llseek lseek\n#define my_llseek llseek|' "$LLSEEK"
    awk '
        /^#ifndef __i386__$/ && !patched {
            print "static blkid_loff_t my_llseek(int fd, blkid_loff_t offset, int origin)";
            print "{";
            print "\tblkid_loff_t result;";
            print "\tint retval;";
            print "";
            print "\tretval = syscall(__NR__llseek, fd, ((unsigned long long) offset) >> 32,";
            print "\t\t         ((unsigned long long)offset) & 0xffffffff,";
            print "\t\t         &result, origin);";
            print "\treturn (retval == -1 ? (blkid_loff_t) retval : result);";
            print "}";
            print "";
            print "/* Neonatox musl llseek patch applied */";
            skip=1; patched=1; next;
        }
        skip { if ($0 == "}") skip=0; next }
        { print }
    ' "$LLSEEK" > "$LLSEEK.new" && mv "$LLSEEK.new" "$LLSEEK"
fi

echo -e "${YELLOW}[INFO]${NC} Configuring static e2fsprogs (minimal for initramfs)..."

[ -f Makefile ] && make distclean || true

# ----------------------------------------------------------
# Minimalist + static setup
# ----------------------------------------------------------

export UUID_LIBS=""
export UUID_CFLAGS=""
export BLKID_LIBS=""
export BLKID_CFLAGS=""

CC="$MUSLGCC" \
CFLAGS="-static -Os -s -std=gnu11 -Wno-error=implicit-function-declaration -fno-stack-protector -U_FORTIFY_SOURCE -fno-link-libatomic" \
LDFLAGS="-static -fno-link-libatomic" \
./configure \
    --host="$TOOLCHAIN_HOST" \
    --build=$(gcc -dumpmachine) \
    --disable-fsck \
    --disable-fuse2fs \
    --disable-e2initrd-helper \
    --disable-tls \
    --disable-nls \
    --disable-debugfs \
    --disable-imager \
    --disable-resizer \
    --disable-defrag \
    --disable-rpath \
    --disable-backtrace \
    --prefix=/

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo -e "${YELLOW}[INFO]${NC} Compiling essential parts..."
make -j"$JOBS" libs
make -j"$JOBS" -C misc mke2fs tune2fs badblocks
make -j"$JOBS" -C e2fsck e2fsck

# ----------------------------------------------------------
# Strip para reducir tamaño (strip del toolchain en cross)
# ----------------------------------------------------------
STRIP_BIN="strip"
[ -n "$CROSS_ARCH" ] && STRIP_BIN="$CROSS_PREFIX"strip
find . -type f -executable -exec "$STRIP_BIN" --strip-unneeded {} \; 2>/dev/null || true

# ----------------------------------------------------------
# Validate static build
# ----------------------------------------------------------
for bin in misc/mke2fs e2fsck/e2fsck misc/tune2fs; do
    if [ -f "$bin" ] && ! file "$bin" | grep -q "statically linked"; then
        echo -e "${RED}[ERROR]${NC} $bin is not static!"
        exit 1
    fi
done

echo -e "${GREEN}[OK]${NC} Static binaries verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"

# Copy ONLY the real binaries
install -m755 misc/mke2fs    "$DEST/mkfs.ext4"
install -m755 e2fsck/e2fsck  "$DEST/fsck.ext4"
# install -m755 misc/tune2fs   "$DEST/tune2fs"
# install -m755 misc/badblocks "$DEST/badblocks"

echo "$VERSION" > "$DEST/e2fsprogs.version"

echo -e "${GREEN}[DONE]${NC} Binaries copied to initramfs"
