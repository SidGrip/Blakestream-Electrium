#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_COINS=(BLC BBTC ELT LIT PHO UMO)
COINS=("${DEFAULT_COINS[@]}")
JOBS=2
WORKSPACE_ROOT="$REPO_ROOT/build/macos-native-workspaces"
ARTIFACT_ROOT="$REPO_ROOT/outputs"
LOG_ROOT="$REPO_ROOT/outputs/logs"

usage() {
    cat <<'EOF'
usage: build_wallet_matrix_macos_native.sh [options]

Options:
  --coins <csv>          Coin list, e.g. BLC,BBTC,ELT
  --jobs <count>         Max concurrent builds (default: 2)
  --workspace-root <p>   Workspace root
  --artifact-root <p>    Artifact root
  --log-root <p>         Log root
  -h, --help             Show this help
EOF
}

parse_coin_list() {
    local raw="$1"
    local item
    IFS=',' read -r -a COINS <<<"$raw"
    for item in "${!COINS[@]}"; do
        COINS[$item]="${COINS[$item]//[[:space:]]/}"
        COINS[$item]="$(printf '%s\n' "${COINS[$item]}" | tr '[:lower:]' '[:upper:]')"
    done
}

timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

run_one() {
    local coin="$1"
    local log_path="$LOG_ROOT/${coin}-macos-native.log"

    mkdir -p "$(dirname "$log_path")"
    {
        printf '[%s] start %s/macos-native\n' "$(timestamp)" "$coin"
        if "$REPO_ROOT/scripts/build_wallet_variant_macos_native.sh" \
            "$coin" "$WORKSPACE_ROOT" "$ARTIFACT_ROOT"; then
            printf '[%s] done %s/macos-native\n' "$(timestamp)" "$coin"
        else
            status=$?
            printf '[%s] failed %s/macos-native (exit %s)\n' "$(timestamp)" "$coin" "$status"
            exit "$status"
        fi
    } >>"$log_path" 2>&1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coins)
            parse_coin_list "$2"
            shift 2
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --workspace-root)
            WORKSPACE_ROOT="$2"
            shift 2
            ;;
        --artifact-root)
            ARTIFACT_ROOT="$2"
            shift 2
            ;;
        --log-root)
            LOG_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$WORKSPACE_ROOT" "$ARTIFACT_ROOT" "$LOG_ROOT"

active_jobs=0
failures=0
declare -a pids=()

set +e
for coin in "${COINS[@]}"; do
    while (( active_jobs >= JOBS )); do
        wait "${pids[0]}"
        status=$?
        pids=("${pids[@]:1}")
        ((active_jobs--))
        if (( status != 0 )); then
            failures=1
        fi
    done
    echo "Queued $coin/macos-native"
    run_one "$coin" &
    pids+=("$!")
    ((active_jobs++))
done

while (( active_jobs > 0 )); do
    wait "${pids[0]}"
    status=$?
    pids=("${pids[@]:1}")
    ((active_jobs--))
    if (( status != 0 )); then
        failures=1
    fi
done
set -e

if (( failures != 0 )); then
    echo "one or more native macOS Electrium builds failed; inspect $LOG_ROOT" >&2
    exit 1
fi

find "$ARTIFACT_ROOT" -maxdepth 3 -type f | LC_ALL=C sort
