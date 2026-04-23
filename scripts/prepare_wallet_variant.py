#!/usr/bin/env python3
import argparse
import json
import re
import shutil
from pathlib import Path


TEXT_SUFFIXES = {
    ".py", ".sh", ".desktop", ".md", ".txt", ".cfg", ".ini", ".json",
    ".yml", ".yaml", ".spec", ".xml", ".xpm", ".rst", ".Dockerfile",
    ".nsi"
}
TEXT_NAMES = {
    "Dockerfile", "AppRun", "make_download", "add_cosigner", "run_electrum"
}
SKIP_DIRS = {".git", "__pycache__", "build", "dist", ".cache", ".pytest_cache"}


def load_coin(repo_root: Path, coin_code: str) -> dict:
    with (repo_root / "coin-overlays" / "coins.json").open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    try:
        return data[coin_code.upper()]
    except KeyError as exc:
        raise SystemExit(f"Unknown coin code: {coin_code}") from exc


def is_text_file(path: Path) -> bool:
    if path.name in TEXT_NAMES:
        return True
    return path.suffix in TEXT_SUFFIXES


def replace_text_in_tree(root: Path, replacements: list[tuple[str, str]]) -> None:
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel_parts = path.relative_to(root).parts
        if any(part in SKIP_DIRS for part in rel_parts):
            continue
        if not is_text_file(path):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        original = text
        for old, new in replacements:
            text = text.replace(old, new)
        if text != original:
            path.write_text(text, encoding="utf-8")


def regex_replace(path: Path, pattern: str, repl: str) -> None:
    text = path.read_text(encoding="utf-8")
    new_text, count = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if count == 0:
        raise RuntimeError(f"Pattern not found in {path}: {pattern}")
    path.write_text(new_text, encoding="utf-8")


def replace_class_attr(text: str, class_name: str, attr: str, value: str) -> str:
    pattern = rf"(class {class_name}\(.*?\):.*?^\s+{re.escape(attr)} = ).*?$"
    new_text, count = re.subn(pattern, rf"\g<1>{value}", text, count=1, flags=re.MULTILINE | re.DOTALL)
    if count == 0:
        raise RuntimeError(f"Could not patch {class_name}.{attr}")
    return new_text


def copy_overlay_assets(repo_root: Path, coin_code: str, workspace: Path) -> None:
    overlay_icons = repo_root / "coin-overlays" / coin_code / "icons"
    if not overlay_icons.is_dir():
        raise RuntimeError(f"Missing overlay icons for {coin_code}: {overlay_icons}")
    target_icons = workspace / "electrum_blc" / "gui" / "icons"
    for src in overlay_icons.iterdir():
        if src.is_file():
            shutil.copy2(src, target_icons / src.name)


def write_empty_network_files(workspace: Path) -> None:
    pkg = workspace / "electrum_blc"
    for name in ("servers.json", "servers_testnet.json", "servers_regtest.json", "servers_signet.json"):
        (pkg / name).write_text("{}\n", encoding="utf-8")
    for name in ("checkpoints.json", "checkpoints_testnet.json"):
        (pkg / name).write_text("[]\n", encoding="utf-8")


def clear_nested_dep_clones(workspace: Path) -> None:
    contrib = workspace / "contrib"
    for name in ("secp256k1", "libusb", "zbar"):
        path = contrib / name
        if path.exists():
            shutil.rmtree(path)


def patch_constants(workspace: Path, coin: dict) -> None:
    path = workspace / "electrum_blc" / "constants.py"
    text = path.read_text(encoding="utf-8")

    text = re.sub(r'GIT_REPO_URL = ".*?"', 'GIT_REPO_URL = "https://github.com/SidGrip/Blakestream-Electrium"', text)
    text = re.sub(r'GIT_REPO_ISSUES_URL = ".*?"', 'GIT_REPO_ISSUES_URL = "https://github.com/SidGrip/Blakestream-Electrium/issues"', text)

    text = replace_class_attr(text, "BitcoinMainnet", "WIF_PREFIX", f"0x{coin['wif_prefix']:02x}")
    text = replace_class_attr(text, "BitcoinMainnet", "ADDRTYPE_P2PKH", str(coin["p2pkh"]))
    text = replace_class_attr(text, "BitcoinMainnet", "ADDRTYPE_P2SH", str(coin["p2sh"]))
    text = replace_class_attr(text, "BitcoinMainnet", "SEGWIT_HRP", f'"{coin["segwit_hrp"]}"')
    text = replace_class_attr(text, "BitcoinMainnet", "BOLT11_HRP", "SEGWIT_HRP")
    text = replace_class_attr(text, "BitcoinMainnet", "GENESIS", f'"{coin["genesis"]}"')

    text = replace_class_attr(text, "BitcoinTestnet", "WIF_PREFIX", f"0x{coin['testnet_wif_prefix']:02x}")
    text = replace_class_attr(text, "BitcoinTestnet", "ADDRTYPE_P2PKH", str(coin["testnet_p2pkh"]))
    text = replace_class_attr(text, "BitcoinTestnet", "ADDRTYPE_P2SH", str(coin["testnet_p2sh"]))
    text = replace_class_attr(text, "BitcoinTestnet", "SEGWIT_HRP", f'"{coin["testnet_segwit_hrp"]}"')
    text = replace_class_attr(text, "BitcoinTestnet", "BOLT11_HRP", "SEGWIT_HRP")
    text = replace_class_attr(text, "BitcoinTestnet", "GENESIS", f'"{coin["testnet_genesis"]}"')

    text = replace_class_attr(text, "BitcoinRegtest", "SEGWIT_HRP", f'"{coin["regtest_segwit_hrp"]}"')
    text = replace_class_attr(text, "BitcoinRegtest", "BOLT11_HRP", "SEGWIT_HRP")
    text = replace_class_attr(text, "BitcoinRegtest", "GENESIS", f'"{coin["regtest_genesis"]}"')
    path.write_text(text, encoding="utf-8")


def patch_bitcoin_py(workspace: Path, coin: dict) -> None:
    path = workspace / "electrum_blc" / "bitcoin.py"
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"COINBASE_MATURITY = \d+", f'COINBASE_MATURITY = {coin["coinbase_maturity"]}', text)
    if "." in coin["max_supply_btc"]:
        if "from decimal import Decimal" not in text:
            text = text.replace("import hashlib\n", "import hashlib\nfrom decimal import Decimal\n", 1)
        replacement = f'TOTAL_COIN_SUPPLY_LIMIT_IN_BTC = Decimal("{coin["max_supply_btc"]}")'
    else:
        replacement = f'TOTAL_COIN_SUPPLY_LIMIT_IN_BTC = {coin["max_supply_btc"]}'
    text = re.sub(r"TOTAL_COIN_SUPPLY_LIMIT_IN_BTC = .*$", replacement, text, flags=re.MULTILINE)
    path.write_text(text, encoding="utf-8")


def patch_util(workspace: Path, coin: dict) -> None:
    path = workspace / "electrum_blc" / "util.py"
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"base_units = \{.*?\}", f"base_units = {{'{coin['ticker']}':8, 'm{coin['ticker']}':5, 'u{coin['ticker']}':2, 'sat':0}}", text)
    text = re.sub(r"base_units_list = \[.*?\]", f"base_units_list = ['{coin['ticker']}', 'm{coin['ticker']}', 'u{coin['ticker']}', 'sat']", text)
    text = re.sub(r"DECIMAL_POINT_DEFAULT = 8\s+# .*", f"DECIMAL_POINT_DEFAULT = 8  # {coin['ticker']}", text)
    text = re.sub(r"BITCOIN_BIP21_URI_SCHEME = '.*?'", f"BITCOIN_BIP21_URI_SCHEME = '{coin['uri_scheme']}'", text)
    text = re.sub(
        r"mainnet_block_explorers = \{.*?_block_explorer_default_api_loc = \{'tx': 'tx/', 'addr': 'address/'\}",
        "mainnet_block_explorers = {}\n\ntestnet_block_explorers = {}\n\nsignet_block_explorers = {}\n\n_block_explorer_default_api_loc = {'tx': 'tx/', 'addr': 'address/'}",
        text,
        flags=re.DOTALL
    )
    path.write_text(text, encoding="utf-8")


def patch_payment_and_contacts(workspace: Path, coin: dict) -> None:
    payment = workspace / "electrum_blc" / "paymentrequest.py"
    text = payment.read_text(encoding="utf-8")
    prefix = coin["payment_mime_prefix"]
    oa = coin["openalias_prefix"]
    text = text.replace("application/blakecoin-paymentrequest", f"application/{prefix}-paymentrequest")
    text = text.replace("application/blakecoin-payment", f"application/{prefix}-payment")
    text = text.replace("application/blakecoin-paymentack", f"application/{prefix}-paymentack")
    text = text.replace("dnssec+blc", f"dnssec+{oa}")
    payment.write_text(text, encoding="utf-8")

    contacts = workspace / "electrum_blc" / "contacts.py"
    text = contacts.read_text(encoding="utf-8")
    text = text.replace("prefix = 'blc'", f"prefix = '{oa}'")
    contacts.write_text(text, encoding="utf-8")


def patch_runtime_identity(workspace: Path, coin: dict) -> None:
    slug = coin["app_slug"]
    app_name = coin["app_name"]
    coin_name = coin["coin_name"]
    ticker = coin["ticker"]
    replacements = [
        ("electrum-blc", slug),
        ("Electrum-BLC", app_name),
        ("Electrum Blakecoin Wallet", coin["wallet_name"]),
        ("Blakecoin Wallet", f"{coin_name} Wallet"),
        ("Lightweight Blakecoin Wallet", f"Lightweight {coin_name} Wallet"),
        ("Lightweight Blakecoin Client", f"Lightweight {coin_name} Client"),
        ("Blakecoin", coin_name),
        ("blakecoin", coin["uri_scheme"]),
        ("BLC", ticker)
    ]
    replace_text_in_tree(workspace, replacements)
    build_sh = workspace / "contrib" / "build-linux" / "appimage" / "build.sh"
    if build_sh.exists():
        regex_replace(build_sh, r"-t electrum-appimage-builder-img", f"-t {slug}-appimage-builder-img")
        regex_replace(build_sh, r"--name electrum-appimage-builder-cont", f"--name {slug}-appimage-builder-cont")
        text = build_sh.read_text(encoding="utf-8")
        old = "    electrum-appimage-builder-img \\\n"
        new = f"    {slug}-appimage-builder-img \\\n"
        if old not in text:
            raise RuntimeError(f"Could not patch docker run image in {build_sh}")
        build_sh.write_text(text.replace(old, new, 1), encoding="utf-8")

    wine_build_sh = workspace / "contrib" / "build-wine" / "build.sh"
    if wine_build_sh.exists():
        regex_replace(wine_build_sh, r"-t electrum-wine-builder-img", f"-t {slug}-wine-builder-img")
        regex_replace(wine_build_sh, r"--name electrum-wine-builder-cont", f"--name {slug}-wine-builder-cont")
        text = wine_build_sh.read_text(encoding="utf-8")
        old = "    electrum-wine-builder-img \\\n"
        new = f"    {slug}-wine-builder-img \\\n"
        if old not in text:
            raise RuntimeError(f"Could not patch docker run image in {wine_build_sh}")
        wine_build_sh.write_text(text.replace(old, new, 1), encoding="utf-8")

    macos_build_sh = workspace / "contrib" / "build-macos" / "build.sh"
    if macos_build_sh.exists():
        regex_replace(macos_build_sh, r"--name electrum-macos-builder", f"--name {slug}-macos-builder-cont")


def rename_packaging_files(workspace: Path, coin: dict) -> None:
    slug = coin["app_slug"]
    desktop_src = workspace / "electrum-blc.desktop"
    desktop_dst = workspace / f"{slug}.desktop"
    if desktop_src.exists():
        desktop_src.rename(desktop_dst)

    script_src = workspace / "electrum_blc" / "electrum-blc"
    script_dst = workspace / "electrum_blc" / slug
    if script_src.exists():
        script_src.rename(script_dst)

    icon_dir = workspace / "electrum_blc" / "gui" / "icons"
    src_icon = icon_dir / "electrum-blc.png"
    dst_icon = icon_dir / f"{slug}.png"
    if src_icon.exists() and not dst_icon.exists():
        shutil.copy2(src_icon, dst_icon)


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare a coin-specific Electrium wallet workspace.")
    parser.add_argument("--coin", required=True, help="Coin code, e.g. BBTC")
    parser.add_argument("--workspace", required=True, help="Target workspace path")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    coin_code = args.coin.upper()
    coin = load_coin(repo_root, coin_code)
    source_wallet = repo_root / "wallet"
    workspace = Path(args.workspace).resolve()

    if workspace.exists():
        shutil.rmtree(workspace)
    shutil.copytree(
        source_wallet,
        workspace,
        ignore=shutil.ignore_patterns(".cache", "build", "dist", "__pycache__", "*.pyc", "*.pyo"),
    )

    copy_overlay_assets(repo_root, coin_code, workspace)
    write_empty_network_files(workspace)
    clear_nested_dep_clones(workspace)
    patch_runtime_identity(workspace, coin)
    patch_constants(workspace, coin)
    patch_bitcoin_py(workspace, coin)
    patch_util(workspace, coin)
    patch_payment_and_contacts(workspace, coin)
    rename_packaging_files(workspace, coin)

    print(f"Prepared {coin_code} workspace at {workspace}")


if __name__ == "__main__":
    main()
