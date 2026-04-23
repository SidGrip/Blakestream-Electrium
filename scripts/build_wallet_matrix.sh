#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILDER="${ELECTRIUM_BUILDER:-}"
DEFAULT_REMOTE_REPO="${ELECTRIUM_REMOTE_REPO:-}"
DEFAULT_COINS=(BLC BBTC ELT LIT PHO UMO)
DEFAULT_PLATFORMS=(linux windows macos)

MODE="local"
BUILDER="$DEFAULT_BUILDER"
REMOTE_REPO="$DEFAULT_REMOTE_REPO"
JOBS=""
COINS=("${DEFAULT_COINS[@]}")
PLATFORMS=("${DEFAULT_PLATFORMS[@]}")

usage() {
    cat <<'EOF'
usage: build_wallet_matrix.sh [options]

Build all six Electrium wallets for Linux AppImage, Windows, and macOS, then
sync artifacts into outputs/.

Options:
  --mode <local|remote>     local stages to a remote builder; remote builds in place
  --builder <user@host>     SSH target for local mode
  --remote-repo <path>      Remote repo path for local mode
  --jobs <count>            Max concurrent wallet builds in remote mode
  --coins <csv>             Coin list, e.g. BLC,BBTC,ELT
  --platforms <csv>         Platform list: linux,windows,macos
  -h, --help                Show this help
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

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
            die "unknown platform: $1"
            ;;
    esac
}

parse_coin_list() {
    local raw="$1"
    local item
    IFS=',' read -r -a COINS <<<"$raw"
    for item in "${!COINS[@]}"; do
        COINS[$item]="${COINS[$item]//[[:space:]]/}"
        COINS[$item]="${COINS[$item]^^}"
    done
}

parse_platform_list() {
    local raw="$1"
    local items=()
    local item
    IFS=',' read -r -a items <<<"$raw"
    PLATFORMS=()
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        PLATFORMS+=("$(normalize_platform "$item")")
    done
}

join_csv() {
    local IFS=','
    printf '%s' "$*"
}

clean_selected_outputs() {
    local artifact_root="$1"
    local coin
    local platform

    mkdir -p "$artifact_root" "$artifact_root/logs"
    for coin in "${COINS[@]}"; do
        for platform in "${PLATFORMS[@]}"; do
            rm -rf "$artifact_root/$coin/$platform"
            rm -f "$artifact_root/logs/$coin-$platform.log"
        done
    done
}

resolve_jobs() {
    local detected
    if [[ -n "$JOBS" ]]; then
        printf '%s\n' "$JOBS"
        return
    fi
    detected="$(nproc 2>/dev/null || printf '1\n')"
    detected=$((detected / 2))
    if (( detected < 1 )); then
        detected=1
    fi
    if (( detected > 12 )); then
        detected=12
    fi
    printf '%s\n' "$detected"
}

run_remote_job() {
    local coin="$1"
    local platform="$2"
    local artifact_root="$REPO_ROOT/outputs"
    local log_path="$artifact_root/logs/$coin-$platform.log"

    mkdir -p "$(dirname "$log_path")"
    {
        printf '[%s] start %s/%s\n' "$(date -Is)" "$coin" "$platform"
        if "$REPO_ROOT/scripts/build_wallet_variant.sh" \
            "$coin" "$platform" "$REPO_ROOT/build/workspaces" "$artifact_root"; then
            printf '[%s] done %s/%s\n' "$(date -Is)" "$coin" "$platform"
        else
            status=$?
            printf '[%s] failed %s/%s (exit %s)\n' "$(date -Is)" "$coin" "$platform" "$status"
            exit "$status"
        fi
    } >>"$log_path" 2>&1
}

generate_checksums() {
    local artifact_root="$REPO_ROOT/outputs"
    local checksum_file="$artifact_root/SHA256SUMS"

    (
        cd "$artifact_root"
        mapfile -t files < <(find . -type f \
            \( -name '*.AppImage' -o -name '*.exe' -o -name '*.tar.gz' \) \
            | LC_ALL=C sort)
        if (( ${#files[@]} == 0 )); then
            rm -f "$checksum_file"
            exit 0
        fi
        sha256sum "${files[@]}" >"$checksum_file"
    )
}

run_remote_mode() {
    local artifact_root="$REPO_ROOT/outputs"
    local max_jobs
    local active_jobs=0
    local failures=0
    local coin
    local platform
    local status

    max_jobs="$(resolve_jobs)"
    clean_selected_outputs "$artifact_root"

    echo "Remote build mode"
    echo "Repo: $REPO_ROOT"
    echo "Coins: ${COINS[*]}"
    echo "Platforms: ${PLATFORMS[*]}"
    echo "Concurrency: $max_jobs"

    set +e
    for coin in "${COINS[@]}"; do
        for platform in "${PLATFORMS[@]}"; do
            while (( active_jobs >= max_jobs )); do
                wait -n
                status=$?
                ((active_jobs--))
                if (( status != 0 )); then
                    failures=1
                fi
            done
            echo "Queued $coin/$platform"
            run_remote_job "$coin" "$platform" &
            ((active_jobs++))
        done
    done

    while (( active_jobs > 0 )); do
        wait -n
        status=$?
        ((active_jobs--))
        if (( status != 0 )); then
            failures=1
        fi
    done
    set -e

    (( failures == 0 )) || die "one or more wallet builds failed; inspect outputs/logs/"

    generate_checksums
    find "$artifact_root" -maxdepth 3 -type f | LC_ALL=C sort
}

run_local_mode() {
    local artifact_root="$REPO_ROOT/outputs"
    local coins_csv
    local platforms_csv
    local remote_cmd
    local sync_cmd=(
        rsync -az --delete
        --exclude '.git/'
        --exclude 'outputs/'
        --exclude 'build/'
        --exclude 'wallet/contrib/build-linux/appimage/.cache/'
        --exclude 'wallet/contrib/build-wine/.cache/'
        --exclude 'wallet/contrib/build-macos/.cache/'
        "$REPO_ROOT/"
        "$BUILDER:$REMOTE_REPO/"
    )

    [[ -n "$BUILDER" ]] || die "local mode requires --builder or ELECTRIUM_BUILDER"
    [[ -n "$REMOTE_REPO" ]] || die "local mode requires --remote-repo or ELECTRIUM_REMOTE_REPO"

    clean_selected_outputs "$artifact_root"
    coins_csv="$(join_csv "${COINS[@]}")"
    platforms_csv="$(join_csv "${PLATFORMS[@]}")"

    echo "Syncing repo to $BUILDER:$REMOTE_REPO"
    ssh "$BUILDER" "mkdir -p '$REMOTE_REPO'"
    "${sync_cmd[@]}"

    remote_cmd="cd '$REMOTE_REPO' && ./scripts/build_wallet_matrix.sh --mode remote --coins '$coins_csv' --platforms '$platforms_csv'"
    if [[ -n "$JOBS" ]]; then
        remote_cmd+=" --jobs '$JOBS'"
    fi

    echo "Starting remote build on $BUILDER"
    ssh "$BUILDER" "bash -lc $(printf '%q' "$remote_cmd")"

    echo "Syncing artifacts back into $artifact_root"
    rsync -az "$BUILDER:$REMOTE_REPO/outputs/" "$artifact_root/"
    find "$artifact_root" -maxdepth 3 -type f | LC_ALL=C sort
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --builder)
            BUILDER="$2"
            shift 2
            ;;
        --remote-repo)
            REMOTE_REPO="$2"
            shift 2
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --coins)
            parse_coin_list "$2"
            shift 2
            ;;
        --platforms)
            parse_platform_list "$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

case "$MODE" in
    local)
        run_local_mode
        ;;
    remote)
        run_remote_mode
        ;;
    *)
        die "unknown mode: $MODE"
        ;;
esac
