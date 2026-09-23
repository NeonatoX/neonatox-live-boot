#!/bin/sh
set -e

# ==========================================================
# Neonatox Tools Publisher
# Packages zips (tools/dist/) and uploads them as GitHub
# Release assets via the REST API (curl). No gh required.
# Carlos Sanchez - 2007-2026
# ==========================================================
# Uso:
#   GITHUB_TOKEN=xxx ./tools/publish.sh            # empaqueta y publica todo
#   GITHUB_TOKEN=xxx ./tools/publish.sh busybox    # solo un tool
#   TOOLS_TAG=tools-0.9.1 GITHUB_TOKEN=xxx ./tools/publish.sh
# Token: env GITHUB_TOKEN o tools/.env (gitignored).
# Tag:  env TOOLS_TAG o el último tag tools-* del repo.
# ==========================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
TOOLS_DIR="$SCRIPT_DIR/tools"
SRC_DIR="$TOOLS_DIR/src"
OUT_DIR="$TOOLS_DIR/output"
export SRC_DIR OUT_DIR TOOLS_DIR

. "$TOOLS_DIR/lib-pack.sh"
. "$TOOLS_DIR/lib-cross.sh"

# ----------------------------------------------------------
# Env (tools/.env, gitignored): GITHUB_TOKEN, CROSS_COMPILER
# ----------------------------------------------------------
if [ -f "$TOOLS_DIR/.env" ]; then
    . "$TOOLS_DIR/.env"
fi

# ----------------------------------------------------------
# Arg: --target <arch> (ARMHF) to publish cross artifacts
# ----------------------------------------------------------
if [ "$1" = "--target" ]; then
    case "$(echo "$2" | tr '[:lower:]' '[:upper:]')" in
        ARMHF) export CROSS_ARCH="armhf" ;;
        "")    echo "[ERROR] --target requires an arch (ARMHF)" >&2; exit 1 ;;
        *)     echo "[ERROR] Unsupported target: $2" >&2; exit 1 ;;
    esac
    shift 2
fi

if [ -n "$CROSS_ARCH" ]; then
    if [ -z "$CROSS_COMPILER" ]; then
        echo "[ERROR] CROSS_ARCH=$CROSS_ARCH requires CROSS_COMPILER in tools/.env" >&2
        exit 1
    fi
    resolve_compiler || exit 1
    OUT_DIR="$TOOLS_DIR/output/$CROSS_ARCH"
    export OUT_DIR
    echo "[INFO] Publishing cross artifacts for $CROSS_ARCH from $OUT_DIR"
fi

# ----------------------------------------------------------
# Token (env o tools/.env)
# ----------------------------------------------------------
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo "[ERROR] GITHUB_TOKEN not set (env GITHUB_TOKEN o tools/.env)" >&2
    exit 1
fi

TOOLS_TAG="${TOOLS_TAG:-$(current_tools_tag)}"
REPO="${TOOLS_REPO:-NeonatoX/neonatox-live-boot}"

AVAILABLE_TOOLS="$(cd "$TOOLS_DIR" 2>/dev/null && ls *.sh 2>/dev/null | sed 's/.sh$//' | grep -v -E '^(lib-pack|lib-cross|publish)$' | tr '\n' ' ')"

if [ $# -gt 0 ]; then
    case "$*" in
        *--all*|*all*) SELECTED="$AVAILABLE_TOOLS" ;;
        *)             SELECTED="$*" ;;
    esac
else
    SELECTED="$AVAILABLE_TOOLS"
fi

# ----------------------------------------------------------
# 1. Package + manifest
# ----------------------------------------------------------
PACKAGED=""
for t in $SELECTED; do
    t="${t#--}"
    case " $AVAILABLE_TOOLS " in
        *" $t "*)
            if package_tool "$t"; then
                manifest_add "$t"
                PACKAGED="$PACKAGED $t"
            fi
        ;;
        *)
            echo "[WARN] unknown tool: $t"
        ;;
    esac
done

[ -n "$PACKAGED" ] || { echo "[ERROR] nothing to publish (no built binaries)"; exit 1; }

# ----------------------------------------------------------
# 2. Find or create release for TOOLS_TAG
# ----------------------------------------------------------
EXISTING_RELEASE="$(curl -s \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases/tags/$TOOLS_TAG")"

RELEASE_ID="$(echo "$EXISTING_RELEASE" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*' || true)"

if [ -z "$RELEASE_ID" ]; then
    echo "[INFO] Creating release $TOOLS_TAG ..."
    RESP="$(curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/releases" \
        -d "{\"tag_name\":\"$TOOLS_TAG\",\"name\":\"Tools $TOOLS_TAG\",\"body\":\"Zips precompilados de Neonatox tools\"}")"
    RELEASE_ID="$(echo "$RESP" | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*' || true)"
    if [ -z "$RELEASE_ID" ]; then
        echo "[ERROR] release creation failed:" >&2
        echo "$RESP" >&2
        exit 1
    fi
fi

echo "[INFO] Release ID: $RELEASE_ID"

# ----------------------------------------------------------
# 3. Upload assets
# ----------------------------------------------------------
for t in $PACKAGED; do
    VER="$(tool_version "$t")"
    ARCH="$(detect_arch)"
    REV="${BUILD_REV:-r1}"
    ASSET="neonatox-$t-$VER-$ARCH-$REV.zip"
    ZIP="$TOOLS_DIR/dist/$ASSET"

    [ -f "$ZIP" ] || { echo "[WARN] missing $ZIP"; continue; }

    echo "[INFO] Uploading $ASSET ..."
    OUT="$(curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Content-Type: application/zip" \
        --data-binary "@$ZIP" \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET")"
    if echo "$OUT" | grep -q '"id"'; then
        echo "[OK] $ASSET uploaded"
    elif echo "$OUT" | grep -qi 'already_exists'; then
        # Replace: delete the existing asset (same name), then re-upload, so
        # republishes stay consistent with the (deterministic) manifest shas.
        echo "[INFO] $ASSET already exists, replacing..."
        EXISTING_ID="$(curl -s -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$REPO/releases/$RELEASE_ID/assets?per_page=100" \
            | grep -E -B4 '"name": "'"$ASSET"'"' | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*' || true)"
        if [ -n "$EXISTING_ID" ]; then
            curl -s -X DELETE -H "Authorization: token $TOKEN" \
                "https://api.github.com/repos/$REPO/releases/assets/$EXISTING_ID" >/dev/null
            sleep 1
        else
            echo "[WARN] could not find existing asset id for $ASSET"
        fi
        OUT="$(curl -s -X POST \
            -H "Authorization: token $TOKEN" \
            -H "Content-Type: application/zip" \
            --data-binary "@$ZIP" \
            "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET")"
        if echo "$OUT" | grep -q '"id"'; then
            echo "[OK] $ASSET replaced"
        else
            echo "[WARN] $ASSET replace response: $(echo "$OUT" | head -c 200)"
        fi
    else
        echo "[WARN] $ASSET upload response: $(echo "$OUT" | head -c 200)"
    fi
done

echo "[DONE] Published $TOOLS_TAG. Manifest: $TOOLS_DIR/releases.sha256"
echo "      Commit the manifest bump on the branch you want to consume these tools."
