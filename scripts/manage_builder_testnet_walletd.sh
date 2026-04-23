#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
TARGET_RAW="${2:-all}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep public defaults self-contained under the repo, but continue to honor the
# older shared-runtime environment variables when a private staging environment
# wants to override them.
REPO_BUILD_ROOT="${REPO_ROOT}/build/walletd"
LEGACY_DEVNET_ROOT="${BLAKESTREAM_DEVNET_ROOT:-}"
DEFAULT_RUNTIME_ROOT="${REPO_ROOT}/build/runtime"
BLAKESTREAM_RUNTIME_ROOT="${BLAKESTREAM_RUNTIME_ROOT:-${LEGACY_DEVNET_ROOT:-${DEFAULT_RUNTIME_ROOT}}}"
SHARED_RUNTIME_ROOT="${BLAKESTREAM_WALLETD_RUNTIME_ROOT:-${BLAKESTREAM_RUNTIME_ROOT}/walletd}"
WORKSPACE_ROOT="${BLAKESTREAM_WALLETD_WORKSPACE_ROOT:-${REPO_BUILD_ROOT}/workspaces}"
VENV_ROOT="${BLAKESTREAM_WALLETD_VENV_ROOT:-${REPO_BUILD_ROOT}/venvs}"
STATE_ROOT="${BLAKESTREAM_WALLETD_STATE_ROOT:-${SHARED_RUNTIME_ROOT}/state}"
LOG_ROOT="${BLAKESTREAM_WALLETD_LOG_ROOT:-${SHARED_RUNTIME_ROOT}/logs}"
HOME_ROOT="${BLAKESTREAM_WALLETD_HOME_ROOT:-${SHARED_RUNTIME_ROOT}/home}"
PREPARE_SCRIPT="${REPO_ROOT}/scripts/prepare_wallet_variant.py"
REPORT_HOST="${REPORT_HOST:-127.0.0.1}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
INSTANCE_SLUG="$(printf '%s' "${INSTANCE_SLUG:-}" | tr '[:upper:]' '[:lower:]')"
RPC_PORT_OFFSET="${RPC_PORT_OFFSET:-0}"
LIGHTNING_PORT_OFFSET="${LIGHTNING_PORT_OFFSET:-0}"

COINS=(BLC BBTC ELT LIT PHO UMO)

usage() {
    cat <<EOF
Usage: scripts/manage_builder_testnet_walletd.sh <start|stop|restart|status|smoke> [COIN|all]

Launcher for the six BlakeStream Electrium testnet wallet daemons.
Each coin gets its own prepared workspace, virtualenv, wallet home, RPC port,
and Lightning listener.

Coins:
  BLC   Blakecoin
  BBTC  BlakeBitcoin
  ELT   Electron-ELT
  LIT   Lithium
  PHO   Photon
  UMO   UniversalMolecule
  all   all six wallets

Environment overrides:
  REPORT_HOST   Advertised host for lightning_listen  (default: ${REPORT_HOST})
  FORCE_REBUILD Rebuild workspace + venv if set to 1  (default: ${FORCE_REBUILD})
  INSTANCE_SLUG Optional wallet node suffix, e.g. peer (default: empty)
  RPC_PORT_OFFSET        Added to the default per-coin RPC port (default: 0)
  LIGHTNING_PORT_OFFSET  Added to the default per-coin LN listen port (default: 0)
  BLAKESTREAM_RUNTIME_ROOT       Shared runtime root
  BLAKESTREAM_DEVNET_ROOT        Legacy shared runtime root
  BLAKESTREAM_WALLETD_RUNTIME_ROOT  Shared wallet runtime root

Examples:
  Primary nodes:
    scripts/manage_builder_testnet_walletd.sh start all

  Secondary Lightning peers:
    INSTANCE_SLUG=peer RPC_PORT_OFFSET=2000 LIGHTNING_PORT_OFFSET=100 \\
      scripts/manage_builder_testnet_walletd.sh start all
EOF
}

coin_label() {
    case "${1^^}" in
        BLC) printf '%s\n' "Blakecoin" ;;
        BBTC) printf '%s\n' "BlakeBitcoin" ;;
        ELT) printf '%s\n' "Electron-ELT" ;;
        LIT) printf '%s\n' "Lithium" ;;
        PHO) printf '%s\n' "Photon" ;;
        UMO) printf '%s\n' "UniversalMolecule" ;;
        *) return 1 ;;
    esac
}

load_coin() {
    COIN_CODE="${1^^}"
    case "${COIN_CODE}" in
        BLC)
            COIN_NAME="Blakecoin"
            HOME_BASENAME="blakecoin"
            RPC_PORT_BASE="7101"
            RPC_USER_BASE="blc"
            ELECTRUM_SERVER="127.0.0.1:51001:t"
            LIGHTNING_PORT_BASE="19735"
            ;;
        BBTC)
            COIN_NAME="BlakeBitcoin"
            HOME_BASENAME="blakebitcoin"
            RPC_PORT_BASE="7201"
            RPC_USER_BASE="bbtc"
            ELECTRUM_SERVER="127.0.0.1:52001:t"
            LIGHTNING_PORT_BASE="19736"
            ;;
        ELT)
            COIN_NAME="Electron-ELT"
            HOME_BASENAME="electron-elt"
            RPC_PORT_BASE="7301"
            RPC_USER_BASE="elt"
            ELECTRUM_SERVER="127.0.0.1:53001:t"
            LIGHTNING_PORT_BASE="19737"
            ;;
        LIT)
            COIN_NAME="Lithium"
            HOME_BASENAME="lithium"
            RPC_PORT_BASE="7401"
            RPC_USER_BASE="lit"
            ELECTRUM_SERVER="127.0.0.1:54001:t"
            LIGHTNING_PORT_BASE="19738"
            ;;
        PHO)
            COIN_NAME="Photon"
            HOME_BASENAME="photon"
            RPC_PORT_BASE="7501"
            RPC_USER_BASE="pho"
            ELECTRUM_SERVER="127.0.0.1:55001:t"
            LIGHTNING_PORT_BASE="19739"
            ;;
        UMO)
            COIN_NAME="UniversalMolecule"
            HOME_BASENAME="universalmolecule"
            RPC_PORT_BASE="7601"
            RPC_USER_BASE="umo"
            ELECTRUM_SERVER="127.0.0.1:56001:t"
            LIGHTNING_PORT_BASE="19740"
            ;;
        *)
            echo "Unknown coin: ${1}" >&2
            exit 1
            ;;
    esac

    FILE_TAG="${COIN_CODE}"
    COIN_DISPLAY="${COIN_NAME}"
    RPC_USER="${RPC_USER_BASE}"
    if [[ -n "${INSTANCE_SLUG}" ]]; then
        HOME_BASENAME="${HOME_BASENAME}-${INSTANCE_SLUG}"
        FILE_TAG="${COIN_CODE}-${INSTANCE_SLUG}"
        COIN_DISPLAY="${COIN_NAME} [${INSTANCE_SLUG}]"
        RPC_USER="${RPC_USER_BASE}-${INSTANCE_SLUG}"
    fi
    RPC_PASSWORD="${RPC_USER}-testnet-rpc"
    RPC_PORT="$((RPC_PORT_BASE + RPC_PORT_OFFSET))"
    LIGHTNING_PORT="$((LIGHTNING_PORT_BASE + LIGHTNING_PORT_OFFSET))"

    WORKSPACE="${WORKSPACE_ROOT}/${COIN_CODE}"
    VENV_DIR="${VENV_ROOT}/${COIN_CODE}"
    STATE_DIR="${STATE_ROOT}"
    LOG_DIR="${LOG_ROOT}"
    HOME_DIR="${HOME_ROOT}/${HOME_BASENAME}"
    TESTNET_DIR="${HOME_DIR}/testnet"
    CONFIG_PATH="${TESTNET_DIR}/config"
    WALLET_PATH="${TESTNET_DIR}/wallets/default_wallet"
    PID_FILE="${STATE_DIR}/${FILE_TAG}.pid"
    LOG_FILE="${LOG_DIR}/${FILE_TAG}.log"
    RUNTIME_SENTINEL="${STATE_DIR}/${COIN_CODE}.runtime.ready"
    RUN_BIN="${WORKSPACE}/run_electrum"
    PYTHON_BIN="${VENV_DIR}/bin/python"
    PIP_BIN="${VENV_DIR}/bin/pip"
    LIGHTNING_LISTEN="${REPORT_HOST}:${LIGHTNING_PORT}"
}

expand_targets() {
    local raw="${1:-all}"
    local upper="${raw^^}"
    if [[ -z "${upper}" || "${upper}" == "ALL" ]]; then
        printf '%s\n' "${COINS[@]}"
        return 0
    fi
    upper="${upper//,/ }"
    for item in ${upper}; do
        case "${item}" in
            BLC|BBTC|ELT|LIT|PHO|UMO)
                printf '%s\n' "${item}"
                ;;
            *)
                echo "Unknown target coin: ${item}" >&2
                exit 1
                ;;
        esac
    done
}

clean_workspace_build_artifacts() {
    local root="$1"
    rm -rf \
        "${root}/blake256/build" \
        "${root}/build"
    if [[ -d "${root}/blake256" ]]; then
        find "${root}/blake256" -maxdepth 1 -name '*.egg-info' -exec rm -rf {} +
    fi
    find "${root}" -maxdepth 1 -name '*.egg-info' -exec rm -rf {} +
}

create_python_env() {
    local target="$1"
    local err_file
    err_file="$(mktemp)"
    if python3 -m venv "${target}" 2>"${err_file}"; then
        rm -f "${err_file}"
        return 0
    fi
    if python3 -m virtualenv --version >/dev/null 2>&1; then
        python3 -m virtualenv "${target}"
        rm -f "${err_file}"
        return 0
    fi
    cat "${err_file}" >&2
    rm -f "${err_file}"
    echo "Failed to create virtualenv for ${target}. Install python3-venv or python3 -m pip install --user virtualenv." >&2
    return 1
}

prepare_workspace() {
    mkdir -p "${WORKSPACE_ROOT}"
    if [[ ! -d "${WORKSPACE}" || "${FORCE_REBUILD}" == "1" ]]; then
        rm -rf "${WORKSPACE}"
        python3 "${PREPARE_SCRIPT}" --coin "${COIN_CODE}" --workspace "${WORKSPACE}"
    fi
}

ensure_runtime() {
    mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${TESTNET_DIR}" "${VENV_ROOT}" "${HOME_ROOT}"
    prepare_workspace
    if [[ ! -x "${PYTHON_BIN}" || ! -x "${PIP_BIN}" || ! -f "${RUNTIME_SENTINEL}" || "${FORCE_REBUILD}" == "1" ]]; then
        rm -rf "${VENV_DIR}"
        rm -f "${RUNTIME_SENTINEL}"
        clean_workspace_build_artifacts "${WORKSPACE}"
        create_python_env "${VENV_DIR}"
        "${PIP_BIN}" install --quiet --upgrade pip setuptools wheel
        "${PIP_BIN}" install --quiet pycryptodomex cryptography
        "${PIP_BIN}" install --quiet "${WORKSPACE}/blake256"
        "${PIP_BIN}" install --quiet -e "${WORKSPACE}"
        touch "${RUNTIME_SENTINEL}"
    fi
}

write_config() {
    mkdir -p "$(dirname "${CONFIG_PATH}")"
    umask 077
    cat >"${CONFIG_PATH}" <<EOF
{
    "auto_connect": false,
    "config_version": 3,
    "lightning_forward_payments": true,
    "lightning_forward_trampoline_payments": true,
    "lightning_listen": "${LIGHTNING_LISTEN}",
    "lightning_to_self_delay": 144,
    "log_to_file": true,
    "oneserver": true,
    "rpchost": "127.0.0.1",
    "rpcpassword": "${RPC_PASSWORD}",
    "rpcport": ${RPC_PORT},
    "rpcsock": "tcp",
    "rpcuser": "${RPC_USER}",
    "server": "${ELECTRUM_SERVER}",
    "use_gossip": true
}
EOF
    chmod 600 "${CONFIG_PATH}"
}

create_wallet_if_missing() {
    if [[ -f "${WALLET_PATH}" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "${WALLET_PATH}")"
    "${PYTHON_BIN}" "${RUN_BIN}" \
        --testnet \
        -D "${HOME_DIR}" \
        --offline \
        create \
        --seed_type segwit >/dev/null
}

find_daemon_pid() {
    local pid=""
    if [[ -f "${PID_FILE}" ]]; then
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            printf '%s\n' "${pid}"
            return 0
        fi
    fi

    pid="$(
        ps -eo pid=,args= \
        | grep -F "run_electrum" \
        | grep -F -- "-D ${HOME_DIR} " \
        | grep -F " daemon" \
        | grep -v grep \
        | awk 'NR==1{print $1}'
    )"
    if [[ -n "${pid}" ]]; then
        printf '%s\n' "${pid}"
        return 0
    fi
    return 1
}

is_running() {
    local pid
    pid="$(find_daemon_pid)" || return 1
    kill -0 "${pid}" 2>/dev/null
}

rpc_call() {
    local method="$1"
    local params="${2:-[]}"
    curl -fsS \
        -u "${RPC_USER}:${RPC_PASSWORD}" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
        "http://127.0.0.1:${RPC_PORT}/"
}

wait_for_rpc() {
    local attempts=45
    for _ in $(seq 1 "${attempts}"); do
        if rpc_call ping >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "${COIN_CODE}: RPC did not come up on 127.0.0.1:${RPC_PORT}" >&2
    return 1
}

load_default_wallet() {
    "${PYTHON_BIN}" "${RUN_BIN}" \
        --testnet \
        -D "${HOME_DIR}" \
        --rpcuser "${RPC_USER}" \
        --rpcpassword "${RPC_PASSWORD}" \
        load_wallet >/dev/null
}

start_coin() {
    local start_script
    if is_running; then
        echo "${COIN_CODE}: already running (pid $(find_daemon_pid))"
        return 0
    fi

    ensure_runtime
    write_config
    create_wallet_if_missing

    start_script="$(mktemp "${STATE_DIR}/${COIN_CODE}.start.XXXXXX.sh")"
    cat >"${start_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="${VENV_DIR}/bin:/usr/bin:/bin"
export PYTHONUNBUFFERED=1
exec "${PYTHON_BIN}" "${RUN_BIN}" \
  --testnet \
  -D "${HOME_DIR}" \
  --rpcuser "${RPC_USER}" \
  --rpcpassword "${RPC_PASSWORD}" \
  daemon
EOF
    chmod +x "${start_script}"
    nohup "${start_script}" >"${LOG_FILE}" 2>&1 &
    echo $! >"${PID_FILE}"

    wait_for_rpc
    load_default_wallet

    echo "${FILE_TAG}: started"
    echo "  coin:       ${COIN_DISPLAY}"
    echo "  pid:        $(cat "${PID_FILE}")"
    echo "  rpc:        http://127.0.0.1:${RPC_PORT}/"
    echo "  user:       ${RPC_USER}"
    echo "  wallet:     ${WALLET_PATH}"
    echo "  electrumx:  ${ELECTRUM_SERVER}"
    echo "  lightning:  ${LIGHTNING_LISTEN}"
    echo "  log:        ${LOG_FILE}"
}

stop_coin() {
    local pid
    if ! is_running; then
        rm -f "${PID_FILE}"
        echo "${COIN_CODE}: not running"
        return 0
    fi
    pid="$(find_daemon_pid)"
    echo "${pid}" >"${PID_FILE}"
    kill "${pid}"
    for _ in $(seq 1 20); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -9 "${pid}"
    fi
    rm -f "${PID_FILE}"
    echo "${FILE_TAG}: stopped"
}

status_coin() {
    echo "== ${COIN_DISPLAY} (${FILE_TAG}) =="
    echo "home:       ${HOME_DIR}"
    echo "wallet:     ${WALLET_PATH}"
    echo "rpc:        http://127.0.0.1:${RPC_PORT}/"
    echo "user:       ${RPC_USER}"
    echo "electrumx:  ${ELECTRUM_SERVER}"
    echo "lightning:  ${LIGHTNING_LISTEN}"
    echo "config:     ${CONFIG_PATH}"
    echo "log:        ${LOG_FILE}"
    if is_running; then
        echo "pid:        $(find_daemon_pid)"
    else
        echo "pid:        not running"
        return 0
    fi

    echo ""
    echo "-- getinfo --"
    rpc_call getinfo | "${PYTHON_BIN}" -m json.tool
    echo ""
    echo "-- getbalance --"
    rpc_call getbalance | "${PYTHON_BIN}" -m json.tool || true
    echo ""
    echo "-- list_wallets --"
    rpc_call list_wallets | "${PYTHON_BIN}" -m json.tool || true
    echo ""
    echo "-- nodeid --"
    rpc_call nodeid | "${PYTHON_BIN}" -m json.tool || true
}

smoke_coin() {
    local addr
    start_coin
    echo ""
    echo "-- ${COIN_DISPLAY} JSON-RPC smoke --"
    echo "ping: $(rpc_call ping | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
    echo "connected: $(rpc_call getinfo | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["result"]["connected"])')"
    echo "server: $(rpc_call getinfo | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["result"]["server"])')"
    addr="$(rpc_call createnewaddress | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
    echo "createnewaddress: ${addr}"
    rpc_call getprivatekeys "[\"${addr}\"]" >/dev/null
    echo "getprivatekeys: ok (redacted)"
    echo "nodeid: $(rpc_call nodeid | "${PYTHON_BIN}" -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
}

run_for_targets() {
    local target
    local action="$1"
    shift
    while IFS= read -r target; do
        [[ -n "${target}" ]] || continue
        load_coin "${target}"
        case "${action}" in
            start) start_coin ;;
            stop) stop_coin ;;
            restart)
                stop_coin
                start_coin
                ;;
            status)
                ensure_runtime
                status_coin
                ;;
            smoke)
                ensure_runtime
                smoke_coin
                ;;
            *)
                echo "Unknown action: ${action}" >&2
                exit 1
                ;;
        esac
        echo ""
    done < <(expand_targets "${TARGET_RAW}")
}

case "${ACTION}" in
    start|stop|restart|status|smoke)
        run_for_targets "${ACTION}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
