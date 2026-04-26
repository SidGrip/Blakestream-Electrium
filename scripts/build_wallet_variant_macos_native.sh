#!/usr/bin/env bash
set -euo pipefail

normalize_coin() {
    printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]'
}

usage() {
    cat <<'EOF'
usage: build_wallet_variant_macos_native.sh <COIN_CODE> [workspace-root] [artifact-root]

Build one Electrium wallet natively on macOS using contrib/osx/make_osx.sh.

Environment:
  MACOS_SUDO_PASS                    Optional sudo password for non-interactive runs
  ELECTRIUM_SKIP_PYTHON_PKG_INSTALL  Set to 1 to skip the python.org pkg install
  ELECTRIUM_SKIP_BREW_INSTALLS       Set to 1 to skip brew install steps inside make_osx.sh
EOF
}

setup_brew_env() {
    local brew_bin=""
    local prefix=""

    if command -v brew >/dev/null 2>&1; then
        brew_bin="$(command -v brew)"
    else
        for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew "$HOME/homebrew/bin/brew"; do
            [[ -x "$brew_bin" ]] && break
        done
    fi

    if [[ -z "$brew_bin" || ! -x "$brew_bin" ]]; then
        return 0
    fi

    eval "$("$brew_bin" shellenv)" >/dev/null 2>&1 || true
    export PATH="$(dirname "$brew_bin"):$PATH"

    for formula in gettext coreutils qt@5 openssl@3; do
        prefix="$("$brew_bin" --prefix "$formula" 2>/dev/null || true)"
        [[ -n "$prefix" && -d "$prefix/bin" ]] && export PATH="$prefix/bin:$PATH"
        [[ -n "$prefix" && -d "$prefix/libexec/gnubin" ]] && export PATH="$prefix/libexec/gnubin:$PATH"
    done

    return 0
}

brew_formula_installed() {
    local formula="$1"

    command -v brew >/dev/null 2>&1 || return 1
    brew list --versions "$formula" >/dev/null 2>&1
}

can_skip_brew_installs() {
    local formula
    local required_formulas=(
        autoconf
        automake
        libtool
        gettext
        coreutils
        pkgconf
        openssl@3
    )

    for formula in "${required_formulas[@]}"; do
        brew_formula_installed "$formula" || return 1
    done

    command -v msgfmt >/dev/null 2>&1
}

required_python_version() {
    python3 - "$WORKSPACE/contrib/osx/make_osx.sh" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r'^PYTHON_VERSION=(.+)$', text, re.MULTILINE)
if not match:
    raise SystemExit("failed to locate PYTHON_VERSION")
print(match.group(1).strip())
PY
}

python_runtime_matches() {
    local expected="$1"
    local found=""

    found="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true)"
    [[ -n "$found" && "$found" == "$expected" ]]
}

prime_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    if [[ -n "${MACOS_SUDO_PASS:-}" ]]; then
        printf '%s\n' "$MACOS_SUDO_PASS" | sudo -S -p '' -v
        return 0
    fi
    sudo -v
}

patch_make_osx_for_workspace() {
    local path="$1"

    python3 - "$path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

python_block_old = (
    'info "Installing Python $PYTHON_VERSION"\n'
    'PKG_FILE="python-${PYTHON_VERSION}-macosx10.9.pkg"\n'
    'if [ ! -f "$CACHEDIR/$PKG_FILE" ]; then\n'
    '    curl -o "$CACHEDIR/$PKG_FILE" "https://www.python.org/ftp/python/${PYTHON_VERSION}/$PKG_FILE"\n'
    'fi\n'
    'echo "167c4e2d9f172a617ba6f3b08783cf376dec429386378066eb2f865c98030dd7  $CACHEDIR/$PKG_FILE" | shasum -a 256 -c \\\n'
    '    || fail "python pkg checksum mismatched"\n'
    'sudo installer -pkg "$CACHEDIR/$PKG_FILE" -target / \\\n'
    '    || fail "failed to install python"\n'
    '\n'
    '# sanity check "python3" has the version we just installed.\n'
    'FOUND_PY_VERSION=$(python3 -c \'import sys; print(".".join(map(str, sys.version_info[:3])))\')\n'
    'if [[ "$FOUND_PY_VERSION" != "$PYTHON_VERSION" ]]; then\n'
    '    fail "python version mismatch: $FOUND_PY_VERSION != $PYTHON_VERSION"\n'
    'fi\n'
)

python_block_new = (
    'FOUND_PY_VERSION=$(python3 -c \'import sys; print(".".join(map(str, sys.version_info[:3])))\' 2>/dev/null || true)\n'
    'if [[ "$FOUND_PY_VERSION" != "$PYTHON_VERSION" ]]; then\n'
    '    if [[ "${ELECTRIUM_SKIP_PYTHON_PKG_INSTALL:-0}" == "1" ]]; then\n'
    '        fail "python version mismatch: $FOUND_PY_VERSION != $PYTHON_VERSION"\n'
    '    fi\n'
    '    info "Installing Python $PYTHON_VERSION"\n'
    '    PKG_FILE="python-${PYTHON_VERSION}-macosx10.9.pkg"\n'
    '    if [ ! -f "$CACHEDIR/$PKG_FILE" ]; then\n'
    '        curl -o "$CACHEDIR/$PKG_FILE" "https://www.python.org/ftp/python/${PYTHON_VERSION}/$PKG_FILE"\n'
    '    fi\n'
    '    echo "167c4e2d9f172a617ba6f3b08783cf376dec429386378066eb2f865c98030dd7  $CACHEDIR/$PKG_FILE" | shasum -a 256 -c \\\n'
    '        || fail "python pkg checksum mismatched"\n'
    '    sudo installer -pkg "$CACHEDIR/$PKG_FILE" -target / \\\n'
    '        || fail "failed to install python"\n'
    '    FOUND_PY_VERSION=$(python3 -c \'import sys; print(".".join(map(str, sys.version_info[:3])))\')\n'
    'fi\n'
    'if [[ "$FOUND_PY_VERSION" != "$PYTHON_VERSION" ]]; then\n'
    '    fail "python version mismatch: $FOUND_PY_VERSION != $PYTHON_VERSION"\n'
    'fi\n'
)

if python_block_old not in text:
    raise SystemExit(f"failed to locate Python install block in {path}")
text = text.replace(python_block_old, python_block_new, 1)

brew_build_deps_old = """info "Installing some build-time deps for compilation..."
brew install autoconf automake libtool gettext coreutils pkgconfig
"""
brew_build_deps_new = """if [[ "${ELECTRIUM_SKIP_BREW_INSTALLS:-0}" == "1" ]]; then
    info "Using preinstalled build-time Homebrew deps"
else
    info "Installing some build-time deps for compilation..."
    brew install autoconf automake libtool gettext coreutils pkgconfig
fi
"""
if brew_build_deps_old not in text:
    raise SystemExit(f"failed to locate brew build deps block in {path}")
text = text.replace(brew_build_deps_old, brew_build_deps_new, 1)

brew_openssl_old = """info "Installing dependencies specific to binaries..."
brew install openssl
"""
brew_openssl_new = """info "Installing dependencies specific to binaries..."
if [[ "${ELECTRIUM_SKIP_BREW_INSTALLS:-0}" != "1" ]]; then
    brew install openssl
fi
"""
if brew_openssl_old not in text:
    raise SystemExit(f"failed to locate openssl brew block in {path}")
text = text.replace(brew_openssl_old, brew_openssl_new, 1)

locale_block_new = """info "generating locale"
(
    if ! which msgfmt > /dev/null 2>&1; then
        if [[ "${ELECTRIUM_SKIP_BREW_INSTALLS:-0}" == "1" ]]; then
            fail "msgfmt missing and brew installs disabled"
        fi
        brew install gettext
        brew link --force gettext
    fi
    LOCALE="$PROJECT_ROOT/electrum_blc/locale/"
    LOCALE_SRC="$CONTRIB/deterministic-build/electrum-blc-locale/locale/"
    # we want the binary to have only compiled (.mo) locale files; not source (.po) files
    rm -rf "$LOCALE"
    if [ -d "$LOCALE_SRC" ]; then
        "$CONTRIB/build_locale.sh" "$LOCALE_SRC" "$LOCALE"
    else
        mkdir -p "$LOCALE"
        warn "Locale source missing at $LOCALE_SRC; continuing without translations."
    fi
) || fail "failed generating locale"
"""
locale_block_re = re.compile(
    r'info "generating locale"\n\(\n.*?\n\) \|\| fail "failed generating locale"\n',
    re.DOTALL,
)
text, count = locale_block_re.subn(locale_block_new, text, count=1)
if count != 1:
    raise SystemExit(f"failed to locate locale generation block in {path}")

path.write_text(text, encoding="utf-8")
PY
}

restore_shared_cache() {
    local workspace="$1"
    local shared_cache_root="$2"
    local shared_osx_cache="$shared_cache_root/osx-cache"
    local target_osx_cache="$workspace/contrib/osx/.cache"

    if [[ ! -d "$shared_osx_cache" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$target_osx_cache")"
    rm -rf "$target_osx_cache"
    cp -R "$shared_osx_cache" "$target_osx_cache"
}

update_shared_cache() {
    local workspace="$1"
    local shared_cache_root="$2"
    local source_osx_cache="$workspace/contrib/osx/.cache"
    local shared_osx_cache="$shared_cache_root/osx-cache"

    if [[ ! -d "$source_osx_cache" ]]; then
        return 0
    fi

    if [[ -d "$shared_osx_cache" ]]; then
        return 0
    fi

    mkdir -p "$shared_cache_root"
    cp -R "$source_osx_cache" "$shared_osx_cache"
}

init_workspace_git() {
    local workspace="$1"
    local version=""

    version="$(
        python3 - "$workspace/electrum_blc/version.py" <<'PY'
import sys
ns = {}
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    exec(fh.read(), ns)
print(ns["ELECTRUM_VERSION"])
PY
    )"

    (
        cd "$workspace"
        git init -q
        git config user.name "BlakeStream Builder"
        git config user.email "builder@localhost"
        git add -A
        git commit -qm "Prepare ${version} macOS native build"
        git tag -f "$version" >/dev/null
    )
}

copy_artifacts() {
    local workspace="$1"
    local artifact_dir="$2"
    local coin_code="$3"
    local coin_code_lower
    local item
    local base_name
    local target_name

    coin_code_lower="$(printf '%s\n' "$coin_code" | tr '[:upper:]' '[:lower:]')"
    rm -rf "$artifact_dir"
    mkdir -p "$artifact_dir"

    shopt -s nullglob
    for item in "$workspace"/dist/*.dmg; do
        base_name="$(basename "$item")"
        target_name="${base_name/electrium-${coin_code_lower}/Electrium-${coin_code}}"
        cp -f "$item" "$artifact_dir/$target_name"
    done
    for item in "$workspace"/dist/*.app; do
        base_name="$(basename "$item")"
        target_name="${base_name/electrium-${coin_code_lower}/Electrium-${coin_code}}"
        cp -R "$item" "$artifact_dir/$target_name"
    done
    shopt -u nullglob
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage >&2
    exit 1
fi

COIN_CODE="$(normalize_coin "$1")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="${2:-$REPO_ROOT/build/macos-native-workspaces}"
ARTIFACT_ROOT="${3:-$REPO_ROOT/outputs}"
WORKSPACE="$WORKSPACE_ROOT/$COIN_CODE"
ARTIFACT_DIR="$ARTIFACT_ROOT/$COIN_CODE/macos-native"
SHARED_CACHE_ROOT="$WORKSPACE_ROOT/_shared-cache"
LOCK_DIR="$REPO_ROOT/build/locks"
LOCK_PATH="$LOCK_DIR/$COIN_CODE-macos-native.lock"

mkdir -p "$WORKSPACE_ROOT" "$ARTIFACT_DIR" "$LOCK_DIR" "$SHARED_CACHE_ROOT"

if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    echo "build for $COIN_CODE/macos-native is already running (lock: $LOCK_PATH)" >&2
    exit 1
fi
trap 'rm -rf "$LOCK_PATH"' EXIT

rm -rf "$WORKSPACE"
python3 "$REPO_ROOT/scripts/prepare_wallet_variant.py" --coin "$COIN_CODE" --workspace "$WORKSPACE"
patch_make_osx_for_workspace "$WORKSPACE/contrib/osx/make_osx.sh"
restore_shared_cache "$WORKSPACE" "$SHARED_CACHE_ROOT"
init_workspace_git "$WORKSPACE"
setup_brew_env
if [[ -z "${ELECTRIUM_SKIP_BREW_INSTALLS:-}" ]] && can_skip_brew_installs; then
    export ELECTRIUM_SKIP_BREW_INSTALLS=1
fi
PYTHON_VERSION_EXPECTED="$(required_python_version)"
if python_runtime_matches "$PYTHON_VERSION_EXPECTED"; then
    export ELECTRIUM_SKIP_PYTHON_PKG_INSTALL=1
fi
if [[ "${ELECTRIUM_SKIP_BREW_INSTALLS:-0}" != "1" || "${ELECTRIUM_SKIP_PYTHON_PKG_INSTALL:-0}" != "1" ]]; then
    prime_sudo
fi
export PYINSTALLER_CONFIG_DIR="$WORKSPACE/.pyinstaller"
export PIP_CACHE_DIR="$WORKSPACE/.pip-cache"

pushd "$WORKSPACE" >/dev/null
./contrib/osx/make_osx.sh
popd >/dev/null

update_shared_cache "$WORKSPACE" "$SHARED_CACHE_ROOT"
copy_artifacts "$WORKSPACE" "$ARTIFACT_DIR" "$COIN_CODE"

artifact_found=0
shopt -s nullglob
for item in "$ARTIFACT_DIR"/*.dmg "$ARTIFACT_DIR"/*.app; do
    artifact_found=1
    break
done
shopt -u nullglob

if (( artifact_found == 0 )); then
    echo "no macOS native Electrium artifacts produced for $COIN_CODE" >&2
    exit 1
fi

echo "Built $COIN_CODE/macos-native into $ARTIFACT_DIR"
