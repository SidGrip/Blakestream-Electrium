#!/usr/bin/env bash
set -euo pipefail

normalize_platform() {
    local raw="${1,,}"
    case "$raw" in
        linux|appimage)
            printf '%s\n' "linux"
            ;;
        windows|win|wine)
            printf '%s\n' "windows"
            ;;
        macos|mac|osx|darwin)
            printf '%s\n' "macos"
            ;;
        *)
            echo "unknown platform: $1" >&2
            return 1
            ;;
    esac
}

prune_workspace_caches() {
    local workspace="$1"
    local platform="$2"

    case "$platform" in
        linux)
            rm -rf \
                "$workspace/contrib/build-linux/appimage/.cache" \
                "$workspace/contrib/build-macos/.cache" \
                "$workspace/contrib/build-wine/.cache"
            ;;
        windows)
            rm -rf \
                "$workspace/contrib/build-linux/appimage/.cache" \
                "$workspace/contrib/build-macos/.cache"
            ;;
        macos)
            rm -rf \
                "$workspace/contrib/build-linux/appimage/.cache" \
                "$workspace/contrib/build-wine/.cache"
            rm -rf "$workspace/contrib/build-macos/.cache/python-extracted"
            ;;
    esac
}

seed_workspace_cache_from_repo() {
    local repo_root="$1"
    local workspace="$2"
    local platform="$3"

    case "$platform" in
        windows)
            if [[ -d "$repo_root/wallet/contrib/build-wine/.cache" ]]; then
                mkdir -p "$workspace/contrib/build-wine/.cache"
                rsync -a --delete \
                    "$repo_root/wallet/contrib/build-wine/.cache/" \
                    "$workspace/contrib/build-wine/.cache/"
            fi
            ;;
        macos)
            if [[ -d "$repo_root/wallet/contrib/build-macos/.cache" ]]; then
                mkdir -p "$workspace/contrib/build-macos/.cache"
                rsync -a --delete --exclude 'python-extracted/' \
                    "$repo_root/wallet/contrib/build-macos/.cache/" \
                    "$workspace/contrib/build-macos/.cache/"
            fi
            ;;
    esac
}

remove_path_force() {
    local path="$1"
    local parent
    local base

    [[ -e "$path" ]] || return 0
    if rm -rf "$path" 2>/dev/null; then
        return 0
    fi

    parent="$(dirname "$path")"
    base="$(basename "$path")"
    if command -v docker >/dev/null 2>&1; then
        docker run --rm -v "$parent":/cleanup busybox rm -rf "/cleanup/$base" >/dev/null
        return 0
    fi
    echo "could not remove path: $path" >&2
    return 1
}

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <COIN_CODE> <PLATFORM> [workspace-root] [artifact-root]" >&2
    exit 1
fi

COIN_CODE="${1^^}"
PLATFORM="$(normalize_platform "$2")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="${3:-$REPO_ROOT/build/workspaces}"
ARTIFACT_ROOT="${4:-$REPO_ROOT/build/dist}"
WORKSPACE="$WORKSPACE_ROOT/$COIN_CODE/$PLATFORM"
ARTIFACT_DIR="$ARTIFACT_ROOT/$COIN_CODE/$PLATFORM"
LOCK_DIR="$REPO_ROOT/build/locks"
LOCK_FILE="$LOCK_DIR/$COIN_CODE-$PLATFORM.lock"

mkdir -p "$WORKSPACE_ROOT" "$ARTIFACT_DIR" "$LOCK_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "build for $COIN_CODE/$PLATFORM is already running (lock: $LOCK_FILE)" >&2
    exit 1
fi

remove_path_force "$WORKSPACE"
python3 "$REPO_ROOT/scripts/prepare_wallet_variant.py" --coin "$COIN_CODE" --workspace "$WORKSPACE"
seed_workspace_cache_from_repo "$REPO_ROOT" "$WORKSPACE" "$PLATFORM"
prune_workspace_caches "$WORKSPACE" "$PLATFORM"

pushd "$WORKSPACE" >/dev/null
case "$PLATFORM" in
    linux)
        ./contrib/build-linux/appimage/build.sh
        shopt -s nullglob
        artifacts=(contrib/build-linux/appimage/dist/*.AppImage)
        shopt -u nullglob
        ;;
    windows)
        ./contrib/build-wine/build.sh
        shopt -s nullglob
        artifacts=(contrib/build-wine/dist/*.exe)
        shopt -u nullglob
        ;;
    macos)
        ./contrib/build-macos/build.sh
        shopt -s nullglob
        artifacts=(contrib/build-macos/dist/*.tar.gz)
        shopt -u nullglob
        ;;
esac

if [[ ${#artifacts[@]} -eq 0 ]]; then
    echo "no artifacts produced for $COIN_CODE/$PLATFORM" >&2
    exit 1
fi

cp -f "${artifacts[@]}" "$ARTIFACT_DIR"/
popd >/dev/null

echo "Built $COIN_CODE/$PLATFORM into $ARTIFACT_DIR"
