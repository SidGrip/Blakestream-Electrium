#!/bin/bash
# =============================================================================
# Electrum-BLC macOS Build Script (runs inside osxcross Docker container)
# =============================================================================
# Creates a macOS .app bundle by:
#   1. Cross-compiling C libraries as .dylib
#   2. Downloading official macOS Python 3.9 framework
#   3. Assembling .app bundle with embedded Python + Electrum
# =============================================================================

set -e

PROJECT_ROOT="/opt/electrum-blc"
CONTRIB="$PROJECT_ROOT/contrib"
BUILDDIR="$CONTRIB/build-macos/build"
CACHEDIR="$CONTRIB/build-macos/.cache"
DISTDIR="${ELECTRUM_DISTDIR:-$CONTRIB/build-macos/dist}"

. "$CONTRIB"/build_tools_util.sh

PYTHON_VERSION="3.9.13"
APP_NAME="Electrum-BLC"
BUNDLE_ID="org.blakecoin.electrum-blc"
VENDORED_PYTHON_REQUIREMENTS=(
    "aiohttp==3.8.3"
    "aiohttp-socks==0.7.1"
    "aiorpcX==0.22.1"
    "aiosignal==1.2.0"
    "async-timeout==4.0.2"
    "attrs==22.1.0"
    "bitstring==3.1.9"
    "certifi==2022.9.24"
    "charset-normalizer==2.1.1"
    "dnspython==2.2.1"
    "frozenlist==1.3.1"
    "idna==3.4"
    "multidict==6.0.2"
    "protobuf==3.20.3"
    "python-socks==2.0.3"
    "QDarkStyle==3.1"
    "qrcode==7.3.1"
    "QtPy==2.2.1"
    "yarl==1.8.1"
)

# osxcross environment
export HOST=x86_64-apple-darwin25.2
export CC=${HOST}-clang
export CXX=${HOST}-clang++
export AR=${HOST}-ar
export RANLIB=${HOST}-ranlib
export STRIP=${HOST}-strip
export MACOSX_DEPLOYMENT_TARGET=11.0
export PREFIX=/opt/osxcross/target/macports/pkgs/opt/local

VERSION="$(electrum_package_version "$PROJECT_ROOT")"
ARTIFACT_VERSION="$VERSION"

echo "=== Building Electrum-BLC $VERSION for macOS ==="
echo "Host: $HOST"
echo ""

rm -rf "$BUILDDIR" "$DISTDIR"
mkdir -p "$BUILDDIR" "$CACHEDIR" "$DISTDIR"

APPDIR="$BUILDDIR/${APP_NAME}.app"
CONTENTS="$APPDIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
PYLIB="$RESOURCES/lib"

mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$PYLIB"


# =========================================================================
# Step 1: Cross-compile Blake-256 dylib
# =========================================================================
info() { echo "💬 INFO: $*"; }

info "Cross-compiling Blake-256 for macOS..."
(
    cd "$PROJECT_ROOT/blake256"
    $CC -shared -fPIC -O2 -I. \
        -dynamiclib -install_name @executable_path/../Frameworks/libblake256.dylib \
        -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET \
        -o "$FRAMEWORKS/libblake256.dylib" \
        blake.c
    # Also create a standalone C interface DLL
    cat > blake256_export.c << 'EOF'
#include "sph_blake.h"
void blake256_hash(const unsigned char *data, unsigned int len, unsigned char *out) {
    sph_blake256_context ctx;
    sph_blake256_init(&ctx);
    sph_blake256(&ctx, data, len);
    sph_blake256_close(&ctx, out);
}
EOF
    $CC -shared -fPIC -O2 -I. \
        -dynamiclib -install_name @executable_path/../Frameworks/libblake256.dylib \
        -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET \
        -o "$FRAMEWORKS/libblake256.dylib" \
        blake256_export.c blake.c
)
info "Blake-256 dylib built."


# =========================================================================
# Step 2: Cross-compile libsecp256k1 for macOS
# =========================================================================
info "Cross-compiling libsecp256k1 for macOS..."
(
    cd "$CACHEDIR"
    if [ ! -d secp256k1 ]; then
        git clone --depth 1 https://github.com/bitcoin-core/secp256k1.git
    fi
    cd secp256k1
    ./autogen.sh 2>/dev/null || true
    ./configure --host=$HOST --prefix="$CACHEDIR/secp-install" \
        --enable-module-recovery --enable-shared --disable-static \
        CC="$CC" CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    make install
)
# Copy whichever version was built (.0 or .6)
SECP_DYLIB=$(ls "$CACHEDIR/secp-install/lib"/libsecp256k1.*.dylib 2>/dev/null | grep -v '.la' | head -1)
if [ -n "$SECP_DYLIB" ]; then
    cp "$SECP_DYLIB" "$FRAMEWORKS/libsecp256k1.0.dylib"
else
    cp "$CACHEDIR/secp-install/lib/libsecp256k1.dylib" "$FRAMEWORKS/libsecp256k1.0.dylib"
fi
# Fix install name
${HOST}-install_name_tool -id @executable_path/../Frameworks/libsecp256k1.0.dylib \
    "$FRAMEWORKS/libsecp256k1.0.dylib" 2>/dev/null || true
info "libsecp256k1 built."


# =========================================================================
# Step 3: Download macOS Python framework
# =========================================================================
info "Downloading macOS Python $PYTHON_VERSION framework..."
PYTHON_PKG="python-${PYTHON_VERSION}-macos11.pkg"
if [ ! -f "$CACHEDIR/$PYTHON_PKG" ]; then
    # Try macOS 11 universal pkg first, fall back to 10.9
    apt-get update -qq > /dev/null 2>&1 && apt-get install -y -qq cpio xar 2>/dev/null || true
    curl -L -o "$CACHEDIR/$PYTHON_PKG" \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macos11.pkg" 2>/dev/null || \
    curl -L -o "$CACHEDIR/$PYTHON_PKG" \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macosx10.9.pkg"
fi

info "Extracting Python framework..."
PYEXTRACT="$CACHEDIR/python-extracted"
rm -rf "$PYEXTRACT"
mkdir -p "$PYEXTRACT"
(
    cd "$PYEXTRACT"
    # macOS pkg is a xar archive containing payloads
    if command -v xar &>/dev/null; then
        xar -xf "$CACHEDIR/$PYTHON_PKG"
        # Extract the framework payload
        for payload in */Payload Python_Framework.pkg/Payload; do
            if [ -f "$payload" ]; then
                cat "$payload" | gunzip -dc 2>/dev/null | cpio -id 2>/dev/null || true
            fi
        done
    else
        # Fallback: use 7z
        7z x "$CACHEDIR/$PYTHON_PKG" -o"$PYEXTRACT" 2>/dev/null || true
        find . -name 'Payload' -exec sh -c 'cat {} | gunzip -dc | cpio -id' \; 2>/dev/null || true
    fi
)

# Find the Python framework
PYFRAMEWORK=$(find "$PYEXTRACT" -type d -name "Python.framework" | head -1)
if [ -z "$PYFRAMEWORK" ]; then
    info "Python.framework not found via pkg extraction. Creating minimal Python bundle instead."
    # Minimal approach: just include the pure Python Electrum code
    # The user will need Python installed on their Mac
    PYFRAMEWORK=""
else
    info "Found Python.framework at: $PYFRAMEWORK"
    # Copy framework to app bundle
    cp -a "$PYFRAMEWORK" "$FRAMEWORKS/Python.framework"
fi


# =========================================================================
# Step 4: Bundle Electrum-BLC source code
# =========================================================================
info "Bundling Electrum-BLC source code..."

# Copy electrum_blc package
cp -r "$PROJECT_ROOT/electrum_blc" "$PYLIB/"
cp "$PROJECT_ROOT/run_electrum" "$PYLIB/"
mkdir -p "$PYLIB/electrum_blc/locale"

# Keep native dylibs alongside the Python package where ctypes loaders expect them.
cp "$FRAMEWORKS/libsecp256k1.0.dylib" "$PYLIB/electrum_blc/"
cp "$FRAMEWORKS/libblake256.dylib" "$PYLIB/electrum_blc/"
if [ -f "$FRAMEWORKS/libzbar.0.dylib" ]; then
    cp "$FRAMEWORKS/libzbar.0.dylib" "$PYLIB/electrum_blc/"
fi

# Remove unnecessary files
rm -rf "$PYLIB/electrum_blc/__pycache__"
find "$PYLIB" -name '*.pyc' -delete
find "$PYLIB" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true


# =========================================================================
# Step 4b: Vendor pure-Python runtime dependencies
# =========================================================================
info "Vendoring pure-Python runtime dependencies..."
if ! python3 -m pip --version >/dev/null 2>&1; then
    info "python3-pip missing in build container, installing it..."
    apt-get update -qq > /dev/null
    apt-get install -y -qq python3-pip > /dev/null
fi
export YARL_NO_EXTENSIONS=1
export MULTIDICT_NO_EXTENSIONS=1
export AIOHTTP_NO_EXTENSIONS=1
export FROZENLIST_NO_EXTENSIONS=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
python3 -m pip install \
    --no-deps \
    --no-compile \
    --no-binary :all: \
    --target "$PYLIB" \
    "${VENDORED_PYTHON_REQUIREMENTS[@]}"


# =========================================================================
# Step 5: Create launcher script
# =========================================================================
info "Creating launcher script..."

cat > "$MACOS/Electrum-BLC" << 'LAUNCHER'
#!/bin/bash
# Electrum-BLC macOS Launcher
DIR="$(cd "$(dirname "$0")" && pwd)"
CONTENTS="$(dirname "$DIR")"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

export DYLD_LIBRARY_PATH="$FRAMEWORKS:${DYLD_LIBRARY_PATH}"
export DYLD_FRAMEWORK_PATH="$FRAMEWORKS:${DYLD_FRAMEWORK_PATH}"

# Protobuf compatibility
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
BOOTSTRAP_DIR="$RESOURCES/bootstrap"
export PYTHONPATH="$BOOTSTRAP_DIR:$RESOURCES/lib:${PYTHONPATH}"

# Use bundled Python if available, otherwise system Python
if [ -x "$FRAMEWORKS/Python.framework/Versions/3.9/bin/python3.9" ]; then
    PYTHON="$FRAMEWORKS/Python.framework/Versions/3.9/bin/python3.9"
    NEED_BOOTSTRAP=0
elif command -v python3 &>/dev/null; then
    PYTHON="python3"
    NEED_BOOTSTRAP=1
else
    osascript -e 'display dialog "Python 3 is required. Please install from python.org" buttons {"OK"} default button "OK"'
    exit 1
fi

if [ "$NEED_BOOTSTRAP" = "1" ]; then
    mkdir -p "$BOOTSTRAP_DIR"
    BOOTSTRAP_PACKAGES=()
    if ! "$PYTHON" -s -c 'import PyQt5' >/dev/null 2>&1; then
        BOOTSTRAP_PACKAGES+=("PyQt5==5.15.7")
    fi
    if ! "$PYTHON" -s -c 'import cryptography' >/dev/null 2>&1 && \
       ! "$PYTHON" -s -c 'import Cryptodome' >/dev/null 2>&1; then
        BOOTSTRAP_PACKAGES+=("cryptography==38.0.3")
    fi
    if [ "${#BOOTSTRAP_PACKAGES[@]}" -gt 0 ]; then
        if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then
            "$PYTHON" -m ensurepip --upgrade >/dev/null 2>&1 || true
        fi
        "$PYTHON" -m pip install --target "$BOOTSTRAP_DIR" "${BOOTSTRAP_PACKAGES[@]}" || {
            osascript -e 'display dialog "Electrum-BLC could not install required Python packages (PyQt5 / cryptography). Please check your internet connection and try again." buttons {"OK"} default button "OK"'
            exit 1
        }
    fi
fi

exec "$PYTHON" -s "$RESOURCES/lib/run_electrum" "$@"
LAUNCHER
chmod +x "$MACOS/Electrum-BLC"


# =========================================================================
# Step 6: Create Info.plist
# =========================================================================
info "Creating Info.plist..."

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>English</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>Electrum-BLC</string>
    <key>CFBundleIconFile</key>
    <string>electrum-blc.icns</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>blakecoin</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>blakecoin</string>
            </array>
        </dict>
    </array>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Copy icon (use PNG if no .icns available)
if [ -f "$PROJECT_ROOT/electrum_blc/gui/icons/electrum.icns" ]; then
    cp "$PROJECT_ROOT/electrum_blc/gui/icons/electrum.icns" "$RESOURCES/electrum-blc.icns"
elif [ -f "$PROJECT_ROOT/electrum_blc/gui/icons/electrum-blc.png" ]; then
    cp "$PROJECT_ROOT/electrum_blc/gui/icons/electrum-blc.png" "$RESOURCES/electrum-blc.icns"
fi


# =========================================================================
# Step 7: Package as .tar.gz
# =========================================================================
info "Packaging..."
(
    cd "$BUILDDIR"
    tar czf "$DISTDIR/electrum-blc-${ARTIFACT_VERSION}-macos-x86_64.tar.gz" "${APP_NAME}.app"
)

info "macOS build complete!"
ls -lh "$DISTDIR/electrum-blc-${ARTIFACT_VERSION}-macos-x86_64.tar.gz"
echo ""
echo "Extract on macOS: tar xzf electrum-blc-${ARTIFACT_VERSION}-macos-x86_64.tar.gz"
echo "Run: open Electrum-BLC.app"
echo ""
echo "NOTE: If Python.framework was not bundled, the launcher will use"
echo "      system Python 3.9+ and bootstrap missing PyQt5 / cryptography"
echo "      into the app's Resources/bootstrap directory on first launch."
