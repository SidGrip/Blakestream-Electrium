#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
TARGET_RAW="${2:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SCRIPT="${REPO_ROOT}/scripts/manage_builder_testnet_walletd.sh"

usage() {
    cat <<'EOF'
Usage: scripts/manage_builder_testnet_lightning_pairs.sh <start|stop|restart|status|smoke> [COIN|all]

Runs the primary Electrium wallet node and a second Lightning peer wallet node
for each requested coin in a local or private testnet runtime.

Primary instance:
  - existing homes under runtime/electrum/walletd/home/<coin>
  - existing RPC ports 7101-7601
  - existing LN ports 19735-19740

Peer instance:
  - homes under runtime/electrum/walletd/home/<coin>-peer
  - RPC ports 9101-9601
  - LN ports 19835-19840
EOF
}

run_instance() {
    local title="$1"
    local slug="$2"
    local rpc_offset="$3"
    local ln_offset="$4"

    printf '### %s ###\n' "${title}"
    INSTANCE_SLUG="${slug}" \
    RPC_PORT_OFFSET="${rpc_offset}" \
    LIGHTNING_PORT_OFFSET="${ln_offset}" \
        bash "${BASE_SCRIPT}" "${ACTION}" "${TARGET_RAW}"
}

case "${ACTION}" in
    start|stop|restart|status|smoke)
        run_instance "primary nodes" "" 0 0
        echo ""
        run_instance "peer nodes" "peer" 2000 100
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
