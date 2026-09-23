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

JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

LIBNL_PREFIX="/tmp/libnl-install${CROSS_ARCH:+-$CROSS_ARCH}"
rm -rf "$LIBNL_PREFIX"

# ----------------------------------------------------------
# Build libnl3 (static, required by wpa_supplicant nl80211)
# ----------------------------------------------------------



LIBNL_V="3.12.0"
LIBNL_ARCHIVE="libnl-${LIBNL_V}.tar.gz"
LIBNL_URL="https://github.com/thom311/libnl/releases/download/libnl3_12_0/${LIBNL_ARCHIVE}"

if [ ! -d "libnl-${LIBNL_V}" ]; then
    if [ ! -f "$LIBNL_ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading libnl source..."
        wget "$LIBNL_URL"
    fi
    echo -e "${YELLOW}[INFO]${NC} Extracting libnl..."
    tar xf "$LIBNL_ARCHIVE"
fi

cd "libnl-${LIBNL_V}"

echo -e "${YELLOW}[INFO]${NC} Configuring static libnl..."

[ -f Makefile ] && make distclean || true

CC="$MUSLGCC" CFLAGS="-static -Os -s -fno-link-libatomic" LDFLAGS="-static -fno-link-libatomic" \
./configure --host="$TOOLCHAIN_HOST" --enable-static --disable-shared --prefix="$LIBNL_PREFIX"

echo -e "${YELLOW}[INFO]${NC} Compiling libnl..."
make -j$JOBS
make install
cd "$SRC_DIR"

echo -e "${GREEN}[OK]${NC} libnl static build ready"

# ----------------------------------------------------------
# Build wpa_supplicant (static musl)
# ----------------------------------------------------------
WPA_V="2.11"
WPA_ARCHIVE="wpa_supplicant-${WPA_V}.tar.gz"
WPA_URL="https://w1.fi/releases/${WPA_ARCHIVE}"

if [ ! -d "wpa_supplicant-${WPA_V}" ]; then
    if [ ! -f "$WPA_ARCHIVE" ]; then
        echo -e "${YELLOW}[INFO]${NC} Downloading wpa_supplicant source..."
        wget "$WPA_URL"
    fi
    echo -e "${YELLOW}[INFO]${NC} Extracting wpa_supplicant..."
    tar xf "$WPA_ARCHIVE"
fi

cd "wpa_supplicant-${WPA_V}/wpa_supplicant"

echo -e "${YELLOW}[INFO]${NC} Configuring wpa_supplicant (minimal netinstall)..."

[ -f .config ] && rm -f .config

cat > .config << 'CONFIG_EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_DRIVER_WEXT=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_IEEE80211W=y
CONFIG_NO_STDOUT_DEBUG=y
CONFIG_NO_WPA_MSG=y
CONFIG_NO_WPA_PASSPHRASE=n
CONFIG_EOF

# The wpa Makefile (src/drivers/drivers.mak) injects
#   $(shell $(PKG_CONFIG) --cflags libnl-3.0)
# On the host that resolves to -I/usr/include/libnl3, which the cross
# toolchain wrapper rejects. Point PKG_CONFIG_PATH at our libnl prefix so
# pkg-config returns the correct per-arch include path (native too).
export PKG_CONFIG_PATH="$LIBNL_PREFIX/lib/pkgconfig"

# When CONFIG_LIBNL32=y, upstream drivers.mk (legacy variant) also injects a
# HOST literal (-I/usr/include/libnl3). In cross mode the compiler rejects
# hostel paths; redirect it to our cross libnl prefix.
if [ -n "${CROSS_ARCH:-}" ]; then
    sed -i 's| -I/usr/include/libnl3| -I'"$LIBNL_PREFIX"'/include/libnl3|' "$SRC_DIR/wpa_supplicant-${WPA_V}/src/drivers/drivers.mk"
fi

# Drop stale build/ objects from previous (other-arch) runs in this shared tree
rm -rf build

export CFLAGS="-static -Os -s -fno-link-libatomic -I$LIBNL_PREFIX/include/libnl3"
export LDFLAGS="-static -fno-link-libatomic -L$LIBNL_PREFIX/lib"
export LIBS="-Wl,--start-group -lnl-3 -lnl-genl-3 -Wl,--end-group"

# Verify libnl static libs exist
for lib in "$LIBNL_PREFIX"/lib/libnl-3.a "$LIBNL_PREFIX"/lib/libnl-genl-3.a; do
    if [ ! -f "$lib" ]; then
        echo -e "${RED}[ERROR]${NC} Missing static library: $lib" >&2
        exit 1
    fi
done

echo -e "${YELLOW}[INFO]${NC} Compiling wpa_supplicant + wpa_cli..."
CC="$MUSLGCC" make -j$JOBS wpa_supplicant wpa_cli

if [ ! -f wpa_supplicant ]; then
    echo -e "${RED}[ERROR]${NC} wpa_supplicant build failed" >&2
    exit 1
fi

if ! file wpa_supplicant | grep -q "statically linked"; then
    echo -e "${RED}[ERROR]${NC} wpa_supplicant is not static!" >&2
    exit 1
fi

# wpa_passphrase can't be built from wpa_supplicant sources (no standalone pbkdf2.c)
# Try linking against host libcrypto first, then fall back to standalone
echo -e "${YELLOW}[INFO]${NC} Building wpa_passphrase..."

# Try 1: link host libcrypto (libressl/openssl) with the pre-compiled wpa_passphrase.o
WPA_PP_OBJ="wpa_passphrase.o"
if [ ! -f "$WPA_PP_OBJ" ] && [ -f "build/wpa_supplicant/wpa_passphrase.o" ]; then
    WPA_PP_OBJ="build/wpa_supplicant/wpa_passphrase.o"
fi

WPA_PP_LINKED=false

if [ -f "$WPA_PP_OBJ" ]; then
    $MUSLGCC -static -Os -s -o wpa_passphrase_test "$WPA_PP_OBJ" -lcrypto 2>/dev/null && \
    file wpa_passphrase_test | grep -q "statically linked" && {
        mv wpa_passphrase_test wpa_passphrase
        WPA_PP_LINKED=true
        echo -e "${GREEN}[OK]${NC} wpa_passphrase linked with libcrypto"
    } || true
    rm -f wpa_passphrase_test
fi

# Try 2: write standalone wpa_passphrase with built-in SHA1+PBKDF2
if [ "$WPA_PP_LINKED" != true ]; then
    echo -e "${YELLOW}[INFO]${NC} Building standalone wpa_passphrase (embedded SHA1+PBKDF2)..."
    cat > wpa_passphrase_standalone.c << 'STDALONE'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

/* Minimal SHA-1 implementation (public domain) */
#define SHA1_BLOCK_SIZE 64
#define SHA1_DIGEST_SIZE 20

typedef struct {
    uint32_t state[5];
    uint64_t count;
    uint8_t buffer[SHA1_BLOCK_SIZE];
} sha1_ctx;

static uint32_t sha1_rol(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void sha1_transform(sha1_ctx *ctx, const uint8_t *block) {
    uint32_t w[80], a, b, c, d, e, temp;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)block[i*4] << 24) | ((uint32_t)block[i*4+1] << 16) |
               ((uint32_t)block[i*4+2] << 8) | (uint32_t)block[i*4+3];
    for (i = 16; i < 80; i++)
        w[i] = sha1_rol(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2];
    d = ctx->state[3]; e = ctx->state[4];
    for (i = 0; i < 80; i++) {
        if (i < 20)      temp = sha1_rol(a, 5) + ((b & c) | (~b & d)) + e + w[i] + 0x5A827999;
        else if (i < 40) temp = sha1_rol(a, 5) + (b ^ c ^ d) + e + w[i] + 0x6ED9EBA1;
        else if (i < 60) temp = sha1_rol(a, 5) + ((b & c) | (b & d) | (c & d)) + e + w[i] + 0x8F1BBCDC;
        else              temp = sha1_rol(a, 5) + (b ^ c ^ d) + e + w[i] + 0xCA62C1D6;
        e = d; d = c; c = sha1_rol(b, 30); b = a; a = temp;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c;
    ctx->state[3] += d; ctx->state[4] += e;
}

static void sha1_init(sha1_ctx *ctx) {
    ctx->state[0] = 0x67452301; ctx->state[1] = 0xEFCDAB89;
    ctx->state[2] = 0x98BADCFE; ctx->state[3] = 0x10325476;
    ctx->state[4] = 0xC3D2E1F0;
    ctx->count = 0;
}

static void sha1_update(sha1_ctx *ctx, const uint8_t *data, size_t len) {
    size_t i, idx = (size_t)(ctx->count % SHA1_BLOCK_SIZE);
    ctx->count += len;
    for (i = 0; i < len; i++) {
        ctx->buffer[idx++] = data[i];
        if (idx == SHA1_BLOCK_SIZE) { sha1_transform(ctx, ctx->buffer); idx = 0; }
    }
}

static void sha1_final(sha1_ctx *ctx, uint8_t *digest) {
    uint64_t bits = ctx->count * 8;
    size_t idx = (size_t)(ctx->count % SHA1_BLOCK_SIZE);
    ctx->buffer[idx++] = 0x80;
    if (idx > 56) { memset(ctx->buffer + idx, 0, SHA1_BLOCK_SIZE - idx); sha1_transform(ctx, ctx->buffer); idx = 0; }
    memset(ctx->buffer + idx, 0, 56 - idx);
    for (int i = 0; i < 8; i++) ctx->buffer[56 + i] = (uint8_t)(bits >> (56 - i * 8));
    sha1_transform(ctx, ctx->buffer);
    for (int i = 0; i < 5; i++) { digest[i*4] = ctx->state[i] >> 24; digest[i*4+1] = ctx->state[i] >> 16; digest[i*4+2] = ctx->state[i] >> 8; digest[i*4+3] = ctx->state[i]; }
}

/* HMAC-SHA1 */
static void hmac_sha1(const uint8_t *key, size_t klen, const uint8_t *msg, size_t mlen, uint8_t *out) {
    uint8_t k[SHA1_BLOCK_SIZE], ipad[SHA1_BLOCK_SIZE], opad[SHA1_BLOCK_SIZE];
    sha1_ctx ctx;
    memset(k, 0, SHA1_BLOCK_SIZE);
    if (klen > SHA1_BLOCK_SIZE) { sha1_ctx kctx; sha1_init(&kctx); sha1_update(&kctx, key, klen); sha1_final(&kctx, k); }
    else memcpy(k, key, klen);
    for (int i = 0; i < SHA1_BLOCK_SIZE; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    sha1_init(&ctx); sha1_update(&ctx, ipad, SHA1_BLOCK_SIZE); sha1_update(&ctx, msg, mlen); sha1_final(&ctx, out);
    sha1_init(&ctx); sha1_update(&ctx, opad, SHA1_BLOCK_SIZE); sha1_update(&ctx, out, SHA1_DIGEST_SIZE); sha1_final(&ctx, out);
}

/* PBKDF2-HMAC-SHA1 */
static void pbkdf2_sha1(const char *pw, const uint8_t *salt, size_t slen, int iter, uint8_t *dk, size_t dklen) {
    size_t plen = strlen(pw);
    for (uint32_t block = 1; dklen > 0; block++) {
        uint8_t u[SHA1_DIGEST_SIZE], t[SHA1_DIGEST_SIZE];
        uint8_t b[4] = {(uint8_t)(block >> 24), (uint8_t)(block >> 16), (uint8_t)(block >> 8), (uint8_t)block};
        size_t clen = slen + 4;
        uint8_t *cmsg = malloc(clen);
        memcpy(cmsg, salt, slen); memcpy(cmsg + slen, b, 4);
        hmac_sha1((const uint8_t*)pw, plen, cmsg, clen, u);
        memcpy(t, u, SHA1_DIGEST_SIZE);
        for (int i = 1; i < iter; i++) {
            hmac_sha1((const uint8_t*)pw, plen, u, SHA1_DIGEST_SIZE, u);
            for (int j = 0; j < SHA1_DIGEST_SIZE; j++) t[j] ^= u[j];
        }
        free(cmsg);
        size_t copy = dklen < SHA1_DIGEST_SIZE ? dklen : SHA1_DIGEST_SIZE;
        memcpy(dk, t, copy); dk += copy; dklen -= copy;
    }
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: wpa_passphrase <ssid> <passphrase>\n");
        return 1;
    }
    uint8_t psk[32];
    pbkdf2_sha1(argv[2], (const uint8_t*)argv[1], strlen(argv[1]), 4096, psk, 32);
    printf("network={\n");
    printf("\tssid=\"%s\"\n", argv[1]);
    printf("\tpsk=");
    for (int i = 0; i < 32; i++) printf("%02x", psk[i]);
    printf("\n}\n");
    return 0;
}
STDALONE

    echo -e "${YELLOW}[INFO]${NC} Compiling standalone wpa_passphrase..."
    $MUSLGCC -static -Os -s -o wpa_passphrase wpa_passphrase_standalone.c 2>&1 | head -5
    if [ -f wpa_passphrase ] && file wpa_passphrase | grep -q "statically linked"; then
        WPA_PP_LINKED=true
    fi
fi

if [ "$WPA_PP_LINKED" != true ]; then
    echo -e "${YELLOW}[WARN]${NC} wpa_passphrase not built (non-fatal, wifi-config will use wpa_cli)" >&2
else
    echo -e "${GREEN}[OK]${NC} wpa_passphrase ready"
fi

echo -e "${GREEN}[OK]${NC} Static wpa_supplicant verified"

DEST="$OUT_DIR"
mkdir -p "$DEST"

install -m755 wpa_supplicant    "$DEST/wpa_supplicant"
install -m755 wpa_cli           "$DEST/wpa_cli"
[ -f wpa_passphrase ] && install -m755 wpa_passphrase "$DEST/wpa_passphrase"

echo "$WPA_V" > "$DEST/wpa_supplicant.version"

echo -e "${GREEN}[DONE]${NC} wpa_supplicant tools copied to initramfs"
