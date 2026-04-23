#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <COIN_CODE> [workspace-root] [dist-root]" >&2
    exit 1
fi

COIN_CODE="${1^^}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="${2:-$REPO_ROOT/build/workspaces}"
DIST_ROOT="${3:-$REPO_ROOT/build/dist}"
WORKSPACE="$WORKSPACE_ROOT/$COIN_CODE"
DIST_DIR="$DIST_ROOT/$COIN_CODE"
LOCK_DIR="$REPO_ROOT/build/locks"
LOCK_FILE="$LOCK_DIR/$COIN_CODE.lock"

mkdir -p "$WORKSPACE_ROOT" "$DIST_DIR" "$LOCK_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "build for $COIN_CODE is already running (lock: $LOCK_FILE)" >&2
    exit 1
fi

python3 "$REPO_ROOT/scripts/prepare_wallet_variant.py" --coin "$COIN_CODE" --workspace "$WORKSPACE"

pushd "$WORKSPACE" >/dev/null
./contrib/build-linux/appimage/build.sh
cp -f contrib/build-linux/appimage/dist/*.AppImage "$DIST_DIR"/
popd >/dev/null

echo "Built $COIN_CODE into $DIST_DIR"
