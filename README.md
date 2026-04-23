# Blakestream-Electrium

Shared Electrium workspace for the BlakeStream wallet family.

Supported wallet targets:

- Blakecoin (`BLC`)
- BlakeBitcoin (`BBTC`)
- Electron-ELT (`ELT`)
- Lithium (`LIT`)
- Photon (`PHO`)
- UniversalMolecule (`UMO`)

AuxPoW support in this repo applies to the five merged-mined coins:

- BlakeBitcoin (`BBTC`)
- Electron-ELT (`ELT`)
- Lithium (`LIT`)
- Photon (`PHO`)
- UniversalMolecule (`UMO`)

This repository contains the shared Electrium client/server source tree,
per-coin overlays, branding assets, and release helpers for the BlakeStream
15.21 wallet line.

## Repo layout

- `coin-overlays/` per-coin constants, branding, icons, and packaging overrides
- `wallet/` shared Electrium wallet source
- `server/` shared ElectrumX server source
- `scripts/` release and QA helper scripts

## Build helpers

Tracked helper entry points:

- `scripts/prepare_wallet_variant.py`
- `scripts/build_wallet_variant.sh`
- `scripts/build_wallet_variant_macos_native.sh`
- `scripts/manage_builder_testnet_electrumx.sh`
- `scripts/manage_builder_testnet_walletd.sh`
- `scripts/manage_builder_testnet_lightning_pairs.sh`

The release and QA helper scripts are configurable through environment
variables. Public repo defaults are kept generic so they can be adapted to
local, CI, or private builder environments without editing tracked files.

## Notes

- Local staging notes and private environment-specific files are intentionally
  kept out of the tracked public repo.
- BIP143 witness-v0 signing follows double SHA-256, while transaction IDs stay
  single SHA-256.
- Desktop release artifacts are staged under `outputs/` when builds are run.
