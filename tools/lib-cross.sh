#!/bin/sh
# ==========================================================
# Neonatox tools: cross-compilation support (HOST/TARGET)
# Shared by build-tools.sh, publish.sh and tools/*.sh builders.
# Requires TOOLS_DIR set by the sourcer.
#
# The TARGET is NEVER derived from uname -m. HOST comes from the
# real machine, TARGET is set explicitly (CROSS_ARCH + CROSS_COMPILER).
# ==========================================================

# ----------------------------------------------------------
# Host architecture (real machine; informational only, NEVER
# used as TARGET).
# ----------------------------------------------------------
host_arch() {
    case "$(uname -m)" in
        x86_64)                echo "x86_64" ;;
        aarch64|arm64)         echo "aarch64" ;;
        armv7l|armv6l|arm*)    echo "arm" ;;
        *)                     echo "$(uname -m)" ;;
    esac
}

# ----------------------------------------------------------
# Host libc (glibc vs musl) - informational + warning only.
# Uses the dynamic loader of a real host binary (definitive);
# falls back to ldd --version.
# ----------------------------------------------------------
host_libc() {
    LDR="$(command -v ldd >/dev/null 2>&1 && ldd /bin/sh 2>/dev/null | grep -oE 'ld-(linux|musl)[^ )]*' | head -1)"
    case "$LDR" in
        ld-linux*)                     echo "glibc"; return 0 ;;
        ld-musl*)                      echo "musl";  return 0 ;;
    esac
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi 'GNU libc'; then
        echo "glibc"
    else
        echo "unknown"
    fi
}

# ----------------------------------------------------------
# Map CROSS_ARCH -> canonical target triple (musl).
# ----------------------------------------------------------
target_triple() {
    case "$CROSS_ARCH" in
        armhf)    echo "arm-linux-musleabihf" ;;
        arm)      echo "arm-linux-musleabi" ;;
        aarch64|arm64) echo "aarch64-linux-musl" ;;
        *)        echo "" ;;
    esac
}

# ----------------------------------------------------------
# Linux kbuild ARCH name (make ARCH=...) for a cross target.
# ----------------------------------------------------------
kbuild_arch() {
    case "$CROSS_ARCH" in
        armhf|arm) echo "arm" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "$CROSS_ARCH" ;;
    esac
}

# ----------------------------------------------------------
# Resolve the compiler to use. Exports:
#   MUSLGCC / CC  - compiler (native musl or cross toolchain)
#   TOOLCHAIN_HOST - --host value for configure (TARGET)
#   CROSS_SYSROOT  - cross only: -print-sysroot of the toolchain
#   CROSS_PREFIX   - cross only: e.g. arm-linux-musleabihf-
#   CROSS_BIN      - cross only: dirname of the toolchain gcc
# Native mode keeps the exact same behaviour as before.
# ----------------------------------------------------------
resolve_compiler() {
    if [ -n "$CROSS_ARCH" ]; then
        if [ -z "$CROSS_COMPILER" ]; then
            echo "[ERROR] --target requires CROSS_COMPILER (tools/.env) or --cross-dir" >&2
            return 1
        fi
        if [ ! -x "$CROSS_COMPILER" ]; then
            echo "[ERROR] CROSS_COMPILER not executable: $CROSS_COMPILER" >&2
            return 1
        fi
        MUSLGCC="$CROSS_COMPILER"
        export MUSLGCC
        "$MUSLGCC" -dumpmachine >/dev/null 2>&1 || {
            echo "[ERROR] toolchain does not answer -dumpmachine: $CROSS_COMPILER" >&2
            return 1
        }
        TOOLCHAIN_HOST="$("$MUSLGCC" -dumpmachine 2>/dev/null)"
        CROSS_SYSROOT="$("$MUSLGCC" -print-sysroot 2>/dev/null)"
        CROSS_BIN="$(dirname "$MUSLGCC")"
        CROSS_PREFIX="$(basename "$MUSLGCC" | sed 's/-gcc$/-/')"
        [ "$CROSS_PREFIX" = "$(basename "$MUSLGCC")" ] && CROSS_PREFIX="$TOOLCHAIN_HOST-"
        PATH="$CROSS_BIN:$PATH"
        export TOOLCHAIN_HOST CROSS_SYSROOT CROSS_BIN CROSS_PREFIX PATH
        echo "[INFO] Cross compiler: $MUSLGCC ($TOOLCHAIN_HOST)"
        echo "[INFO] SYSROOT: ${CROSS_SYSROOT:-(not reported)}"
        echo "[INFO] CROSS_PREFIX: $CROSS_PREFIX"
    else
        for cc in musl-gcc x86_64-linux-musl-gcc; do
            MUSLGCC="$(command -v "$cc" 2>/dev/null || true)"
            [ -n "$MUSLGCC" ] && break
        done
        if [ -z "$MUSLGCC" ]; then
            echo "[ERROR] musl compiler not found in PATH" >&2
            return 1
        fi
        TOOLCHAIN_HOST="x86_64-linux-musl"
        export MUSLGCC TOOLCHAIN_HOST
        echo "[INFO] Using compiler: $MUSLGCC"
    fi
    CC="$MUSLGCC"
    export CC
    return 0
}

# ----------------------------------------------------------
# Set CROSS_COMPILER from a --cross-dir (pick the first -gcc)
# ----------------------------------------------------------
cross_resolve_from_dir() {
    DIR="$1"
    [ -d "$DIR/bin" ] || {
        echo "[ERROR] no bin/ dir in toolchain: $DIR" >&2
        return 1
    }
    for c in "$DIR"/bin/*gcc; do
        [ -x "$c" ] && {
            CROSS_COMPILER="$c"
            echo "[INFO] Toolchain gcc from --cross-dir: $CROSS_COMPILER"
            export CROSS_COMPILER
            return 0
        }
    done
    echo "[ERROR] no gcc found under $DIR/bin" >&2
    return 1
}

# ----------------------------------------------------------
# Validate every ELF artifact in a build dir:
# statically linked (always) + correct arch (cross only).
# ----------------------------------------------------------
check_cross_artifacts() {
    DIR="$1"
    [ -n "$CROSS_ARCH" ] || return 0
    [ -d "$DIR" ] || return 0
    FAIL=0
    for f in "$DIR"/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.version) continue ;;
        esac
        # shellcheck disable=SC2086
        file "$f" 2>/dev/null | grep -q "ELF" || continue
        if ! file "$f" | grep -q "statically linked"; then
            echo "[ERROR] $f is not statically linked"
            FAIL=1
        fi
        case "$CROSS_ARCH" in
            armhf|arm)
                if ! file "$f" | grep -q "ARM"; then
                    echo "[ERROR] $f is not an ARM binary"
                    FAIL=1
                fi
            ;;
        esac
    done
    return $FAIL
}