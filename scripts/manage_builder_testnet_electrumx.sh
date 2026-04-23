#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep public defaults self-contained under the repo, but continue to honor the
# older shared-runtime environment variables when a private staging environment
# wants to override them.
REPO_BUILD_ROOT="${REPO_ROOT}/build/electrumx"
LEGACY_DEVNET_ROOT="${BLAKESTREAM_DEVNET_ROOT:-}"
DEFAULT_RUNTIME_ROOT="${REPO_ROOT}/build/runtime"
BLAKESTREAM_RUNTIME_ROOT="${BLAKESTREAM_RUNTIME_ROOT:-${LEGACY_DEVNET_ROOT:-${DEFAULT_RUNTIME_ROOT}}}"
SHARED_RUNTIME_ROOT="${BLAKESTREAM_ELECTRUMX_RUNTIME_ROOT:-${BLAKESTREAM_RUNTIME_ROOT}/electrumx}"
VENV_DIR="${BLAKESTREAM_ELECTRUMX_VENV_DIR:-${REPO_BUILD_ROOT}/venv}"
PYDEPS_DIR="${BLAKESTREAM_ELECTRUMX_PYDEPS_DIR:-${VENV_DIR}-pydeps}"
STATE_DIR="${BLAKESTREAM_ELECTRUMX_STATE_DIR:-${SHARED_RUNTIME_ROOT}/state}"
LOG_DIR="${BLAKESTREAM_ELECTRUMX_LOG_DIR:-${SHARED_RUNTIME_ROOT}/logs}"
REPORT_HOST="${REPORT_HOST:-127.0.0.1}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
RPC_HOST="${RPC_HOST:-127.0.0.1}"
PYTHON_BIN="${VENV_DIR}/bin/python"
PIP_BIN="${VENV_DIR}/bin/pip"
SERVER_BIN="${VENV_DIR}/bin/electrumx_server"
RPC_BIN="${VENV_DIR}/bin/electrumx_rpc"
FALLBACK_SERVER_BIN="${REPO_ROOT}/server/electrumx_server"
FALLBACK_RPC_BIN="${REPO_ROOT}/server/electrumx_rpc"
FALLBACK_PYTHONPATH="${REPO_ROOT}/server:${REPO_ROOT}/wallet"

usage() {
    cat <<'EOF'
Usage: scripts/manage_builder_testnet_electrumx.sh <start|stop|restart|status>

Starts or manages the six BlakeStream ElectrumX backends against a local or
private testnet daemon cluster.

Environment overrides:
  REPORT_HOST   Advertised host for Electrum clients (default: 127.0.0.1)
  LISTEN_HOST   Bind host for Electrum TCP service (default: 0.0.0.0)
  RPC_HOST      Bind host for ElectrumX local RPC admin port (default: 127.0.0.1)
  BLAKESTREAM_RUNTIME_ROOT       Shared runtime root
  BLAKESTREAM_DEVNET_ROOT        Legacy shared runtime root
  BLAKESTREAM_ELECTRUMX_RUNTIME_ROOT  Shared ElectrumX runtime root
EOF
}

coins=(BLC BBTC ELT LIT PHO UMO)

coin_name() {
    case "$1" in
        BLC) echo "Blakecoin" ;;
        BBTC) echo "BlakeBitcoin" ;;
        ELT) echo "Electron-ELT" ;;
        LIT) echo "Lithium" ;;
        PHO) echo "Photon" ;;
        UMO) echo "UniversalMolecule" ;;
        *) return 1 ;;
    esac
}

daemon_url() {
    local code="$1"
    local override_var="BLAKESTREAM_DAEMON_URL_${code}"
    if [[ -n "${!override_var:-}" ]]; then
        echo "${!override_var}"
        return 0
    fi

    case "${code}" in
        # Override these with BLAKESTREAM_DAEMON_URL_<COIN> when wiring to a
        # different local or private daemon cluster.
        BLC) echo "http://auxpow:auxpow@127.0.0.1:39120/,http://auxpow:auxpow@127.0.0.1:39121/" ;;
        BBTC) echo "http://auxpow:auxpow@127.0.0.1:39140/,http://auxpow:auxpow@127.0.0.1:39141/" ;;
        ELT) echo "http://auxpow:auxpow@127.0.0.1:39220/,http://auxpow:auxpow@127.0.0.1:39221/" ;;
        LIT) echo "http://auxpow:auxpow@127.0.0.1:39160/,http://auxpow:auxpow@127.0.0.1:39161/" ;;
        PHO) echo "http://auxpow:auxpow@127.0.0.1:39180/,http://auxpow:auxpow@127.0.0.1:39181/" ;;
        UMO) echo "http://auxpow:auxpow@127.0.0.1:39200/,http://auxpow:auxpow@127.0.0.1:39201/" ;;
        *) return 1 ;;
    esac
}

service_port() {
    case "$1" in
        BLC) echo 51001 ;;
        BBTC) echo 52001 ;;
        ELT) echo 53001 ;;
        LIT) echo 54001 ;;
        PHO) echo 55001 ;;
        UMO) echo 56001 ;;
        *) return 1 ;;
    esac
}

admin_port() {
    case "$1" in
        BLC) echo 8101 ;;
        BBTC) echo 8102 ;;
        ELT) echo 8103 ;;
        LIT) echo 8104 ;;
        PHO) echo 8105 ;;
        UMO) echo 8106 ;;
        *) return 1 ;;
    esac
}

ensure_runtime() {
    mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${PYDEPS_DIR}"
    if [[ -x "${PYTHON_BIN}" && -x "${SERVER_BIN}" && -x "${RPC_BIN}" ]]; then
        return 0
    fi

    if python3 -m venv "${VENV_DIR}" >/dev/null 2>&1; then
        "${PIP_BIN}" install --quiet --upgrade pip setuptools wheel
        "${PIP_BIN}" install --quiet "${REPO_ROOT}/wallet/blake256"
        "${PIP_BIN}" install --quiet -e "${REPO_ROOT}/server"
        return 0
    fi

    # Some staging hosts do not ship python3-venv/ensurepip. In that case,
    # fall back to the checked-out ElectrumX source tree plus a repo-owned
    # dependency target instead of failing the whole proof harness just because
    # a throwaway venv cannot be created.
    if [[ -x "${FALLBACK_SERVER_BIN}" && -x "${FALLBACK_RPC_BIN}" ]]; then
        if [[ ! -e "${PYDEPS_DIR}/aiorpcx/__init__.py" ]]; then
            python3 -m pip install --quiet --target "${PYDEPS_DIR}" \
                'aiorpcX[ws]>=0.18.3,<0.19' attrs plyvel pylru 'aiohttp>=3.3'
        fi
        echo "warning: python3 -m venv unavailable; using source-tree ElectrumX runtime" >&2
        return 0
    fi

    echo "error: unable to create ElectrumX venv and no source-tree fallback exists" >&2
    return 1
}

active_server_bin() {
    if [[ -x "${SERVER_BIN}" ]]; then
        echo "${SERVER_BIN}"
    else
        echo "${FALLBACK_SERVER_BIN}"
    fi
}

active_rpc_bin() {
    if [[ -x "${RPC_BIN}" ]]; then
        echo "${RPC_BIN}"
    else
        echo "${FALLBACK_RPC_BIN}"
    fi
}

active_path() {
    if [[ -x "${SERVER_BIN}" ]]; then
        echo "${VENV_DIR}/bin:/usr/bin:/bin"
    else
        echo "/usr/bin:/bin"
    fi
}

active_pythonpath() {
    if [[ -x "${SERVER_BIN}" ]]; then
        echo "${PYTHONPATH:-}"
    else
        if [[ -n "${PYTHONPATH:-}" ]]; then
            echo "${PYDEPS_DIR}:${FALLBACK_PYTHONPATH}:${PYTHONPATH}"
        else
            echo "${PYDEPS_DIR}:${FALLBACK_PYTHONPATH}"
        fi
    fi
}

ensure_runtime
SERVER_ACTIVE_BIN="$(active_server_bin)"
RPC_ACTIVE_BIN="$(active_rpc_bin)"
ACTIVE_PATH_VALUE="$(active_path)"
ACTIVE_PYTHONPATH_VALUE="$(active_pythonpath)"

pid_file() {
    echo "${STATE_DIR}/$1.pid"
}

env_file() {
    echo "${STATE_DIR}/$1.env"
}

log_file() {
    echo "${LOG_DIR}/$1.log"
}

db_dir() {
    echo "${STATE_DIR}/$1-db"
}

is_running() {
    local pidfile
    pidfile="$(pid_file "$1")"
    [[ -f "${pidfile}" ]] || return 1
    kill -0 "$(cat "${pidfile}")" 2>/dev/null
}

write_env() {
    local code="$1"
    local name tcp_port rpc_port daemon
    name="$(coin_name "${code}")"
    tcp_port="$(service_port "${code}")"
    rpc_port="$(admin_port "${code}")"
    daemon="$(daemon_url "${code}")"

    mkdir -p "$(db_dir "${code}")"
    cat >"$(env_file "${code}")" <<EOF
COIN=${name}
NET=testnet
DB_DIRECTORY=$(db_dir "${code}")
DAEMON_URL=${daemon}
SERVICES=tcp://${LISTEN_HOST}:${tcp_port},rpc://${RPC_HOST}:${rpc_port}
REPORT_SERVICES=tcp://${REPORT_HOST}:${tcp_port}
PEER_DISCOVERY=self
PEER_ANNOUNCE=
LOG_LEVEL=info
EOF
}

start_one() {
    local code="$1"
    local pidfile logfile start_script
    pidfile="$(pid_file "${code}")"
    logfile="$(log_file "${code}")"
    write_env "${code}"

    if is_running "${code}"; then
        echo "${code}: already running (pid $(cat "${pidfile}"))"
        return 0
    fi

    start_script="$(mktemp "${STATE_DIR}/${code}.start.XXXXXX.sh")"
    cat >"${start_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
. "$(env_file "${code}")"
set +a
export PATH="${ACTIVE_PATH_VALUE}"
export PYTHONUNBUFFERED=1
export PYTHONPATH="${ACTIVE_PYTHONPATH_VALUE}"
# These are wrapper-only knobs used to render SERVICES / REPORT_SERVICES in the
# generated env file.  Do not leak them into ElectrumX itself, as upstream
# treats RPC_HOST / REPORT_HOST as obsolete environment variables.
unset RPC_HOST REPORT_HOST LISTEN_HOST
exec "${SERVER_ACTIVE_BIN}"
EOF
    chmod +x "${start_script}"
    nohup "${start_script}" >"${logfile}" 2>&1 &
    echo $! >"${pidfile}"
    echo "${code}: started pid $(cat "${pidfile}") log ${logfile}"
}

stop_one() {
    local code="$1"
    local pidfile
    pidfile="$(pid_file "${code}")"
    if ! is_running "${code}"; then
        rm -f "${pidfile}"
        echo "${code}: not running"
        return 0
    fi
    kill "$(cat "${pidfile}")"
    for _ in $(seq 1 20); do
        if ! kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
        kill -9 "$(cat "${pidfile}")"
    fi
    rm -f "${pidfile}"
    echo "${code}: stopped"
}

status_one() {
    local code="$1"
    local rpc_port
    rpc_port="$(admin_port "${code}")"
    if is_running "${code}"; then
        echo "== ${code} =="
        echo "pid: $(cat "$(pid_file "${code}")")"
        echo "log: $(log_file "${code}")"
        if [[ -x "${RPC_ACTIVE_BIN}" ]]; then
            PYTHONPATH="${ACTIVE_PYTHONPATH_VALUE}" "${RPC_ACTIVE_BIN}" -p "${rpc_port}" getinfo 2>/dev/null | sed 's/^/  /' || echo "  rpc: not ready yet"
        else
            echo "  rpc: runtime not installed yet"
        fi
    else
        echo "== ${code} =="
        echo "not running"
    fi
}

case "${ACTION}" in
    start)
        ensure_runtime
        for code in "${coins[@]}"; do
            start_one "${code}"
        done
        ;;
    stop)
        for code in "${coins[@]}"; do
            stop_one "${code}"
        done
        ;;
    restart)
        for code in "${coins[@]}"; do
            stop_one "${code}"
        done
        ensure_runtime
        for code in "${coins[@]}"; do
            start_one "${code}"
        done
        ;;
    status)
        for code in "${coins[@]}"; do
            status_one "${code}"
        done
        ;;
    *)
        usage
        exit 1
        ;;
esac
