#!/bin/bash
# =============================================================================
# Electrum-BLC macOS Cross-Compile Build
# =============================================================================
# Builds a macOS .app bundle from Linux using the osxcross Docker container.
#
# Strategy:
#   1. Cross-compile Blake-256 and libsecp256k1 as .dylib using osxcross
#   2. Download official macOS Python 3.9 framework from python.org
#   3. Build .app bundle structure manually (no PyInstaller — can't run macOS binaries)
#   4. Package as .tar.gz
#
# Usage:
#   cd electrum-blc && contrib/build-macos/build.sh
#
# Requires: Docker with sidgrip/osxcross-base:latest
# =============================================================================

set -e

PROJECT_ROOT="$(dirname "$(readlink -e "$0")")/../.."
CONTRIB="$PROJECT_ROOT/contrib"
CONTRIB_OSX="$CONTRIB/build-macos"
DISTDIR="${ELECTRUM_DISTDIR:-$CONTRIB_OSX/dist}"

echo "=== Electrum-BLC macOS Cross-Compile Build ==="

# Build inside Docker
docker run \
    --name electrum-macos-builder \
    -v "$PROJECT_ROOT":/opt/electrum-blc \
    -e ELECTRUM_DISTDIR=/opt/electrum-blc/contrib/build-macos/dist \
    --rm \
    --workdir /opt/electrum-blc/contrib/build-macos \
    sidgrip/osxcross-base:latest \
    bash ./make_macos.sh

echo ""
echo "=== Build Complete ==="
ls -lh "$DISTDIR"/*.tar.gz 2>/dev/null || echo "Check dist/ for output"
