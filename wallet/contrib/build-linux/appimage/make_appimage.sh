#!/bin/bash

set -e

PROJECT_ROOT="$(dirname "$(readlink -e "$0")")/../../.."
CONTRIB="$PROJECT_ROOT/contrib"
CONTRIB_APPIMAGE="$CONTRIB/build-linux/appimage"
DISTDIR="${ELECTRUM_DISTDIR:-$CONTRIB_APPIMAGE/dist}"
BUILDDIR="$CONTRIB_APPIMAGE/build/appimage"
APPDIR="$BUILDDIR/electrum-blc.AppDir"
CACHEDIR="$CONTRIB_APPIMAGE/.cache/appimage"
export DLL_TARGET_DIR="$CACHEDIR/dlls"
PIP_CACHE_DIR="$CONTRIB_APPIMAGE/.cache/pip_cache"

export GCC_STRIP_BINARIES="1"

. "$CONTRIB"/build_tools_util.sh

# pinned versions
PYTHON_VERSION=3.9.15
PY_VER_MAJOR="3.9"  # as it appears in fs paths
PKG2APPIMAGE_COMMIT="a9c85b7e61a3a883f4a35c41c5decb5af88b6b5d"

VERSION="$(electrum_package_version "$PROJECT_ROOT")"
APPIMAGE="$DISTDIR/electrum-blc-$VERSION-x86_64.AppImage"

rm -rf "$BUILDDIR" "$DISTDIR"
mkdir -p "$APPDIR" "$CACHEDIR" "$PIP_CACHE_DIR" "$DISTDIR" "$DLL_TARGET_DIR"

# potential leftover from setuptools that might make pip put garbage in binary
rm -rf "$PROJECT_ROOT/build"


info "downloading some dependencies."
download_if_not_exist "$CACHEDIR/functions.sh" "https://raw.githubusercontent.com/AppImage/pkg2appimage/$PKG2APPIMAGE_COMMIT/functions.sh"
verify_hash "$CACHEDIR/functions.sh" "8f67711a28635b07ce539a9b083b8c12d5488c00003d6d726c7b134e553220ed"

download_if_not_exist "$CACHEDIR/appimagetool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
verify_hash "$CACHEDIR/appimagetool" "a6d71e2b6cd66f8e8d16c37ad164658985e0cf5fcaa950c90a482890cb9d13e0"

download_if_not_exist "$CACHEDIR/Python-$PYTHON_VERSION.tar.xz" "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz"
verify_hash "$CACHEDIR/Python-$PYTHON_VERSION.tar.xz" "12daff6809528d9f6154216950423c9e30f0e47336cb57c6aa0b4387dd5eb4b2"



info "building python."
tar xf "$CACHEDIR/Python-$PYTHON_VERSION.tar.xz" -C "$CACHEDIR"
(
    if [ -f "$CACHEDIR/Python-$PYTHON_VERSION/python" ]; then
        info "python already built, skipping"
        exit 0
    fi
    cd "$CACHEDIR/Python-$PYTHON_VERSION"
    LC_ALL=C export BUILD_DATE=$(date -u -d "@$SOURCE_DATE_EPOCH" "+%b %d %Y")
    LC_ALL=C export BUILD_TIME=$(date -u -d "@$SOURCE_DATE_EPOCH" "+%H:%M:%S")
    # Patch taken from Ubuntu http://archive.ubuntu.com/ubuntu/pool/main/p/python3.9/python3.9_3.9.5-3~21.04.debian.tar.xz
    patch -p1 < "$CONTRIB_APPIMAGE/patches/python-3.9-reproducible-buildinfo.diff"
    ./configure \
        --cache-file="$CACHEDIR/python.config.cache" \
        --prefix="$APPDIR/usr" \
        --enable-ipv6 \
        --enable-shared \
        -q
    make -j4 -s || fail "Could not build Python"
)
info "installing python."
(
    cd "$CACHEDIR/Python-$PYTHON_VERSION"
    make -s install > /dev/null || fail "Could not install Python"
    # When building in docker on macOS, python builds with .exe extension because the
    # case insensitive file system of macOS leaks into docker. This causes the build
    # to result in a different output on macOS compared to Linux. We simply patch
    # sysconfigdata to remove the extension.
    # Some more info: https://bugs.python.org/issue27631
    sed -i -e 's/\.exe//g' "${APPDIR}/usr/lib/python${PY_VER_MAJOR}"/_sysconfigdata*
)


if [ -f "$DLL_TARGET_DIR/libsecp256k1.so.0" ]; then
    info "libsecp256k1 already built, skipping"
else
    "$CONTRIB"/make_libsecp256k1.sh || fail "Could not build libsecp"
fi
cp -f "$DLL_TARGET_DIR/libsecp256k1.so.0" "$APPDIR/usr/lib/libsecp256k1.so.0" || fail "Could not copy libsecp to its destination"


# note: libxcb-util1 is not available in debian 10 (buster), only libxcb-util0. So we build it ourselves.
#       This pkg is needed on some distros for Qt to launch. (see #8011)
info "building libxcb-util1."
XCB_UTIL_VERSION="acf790d7752f36e450d476ad79807d4012ec863b"
XCB_UTIL_REPO="https://gitlab.freedesktop.org/xorg/lib/libxcb-util.git"
# ^ git tag 0.4.0
(
    if [ -f "$CACHEDIR/libxcb-util1/util/src/.libs/libxcb-util.so.1" ]; then
        info "libxcb-util1 already built, skipping"
        exit 0
    fi
    cd "$CACHEDIR"
    mkdir "libxcb-util1"
    cd "libxcb-util1"
    if [ ! -d util ]; then
        git clone --recursive "$XCB_UTIL_REPO" util
    fi
    cd util
    if ! git cat-file -e "${XCB_UTIL_VERSION}^{commit}" 2>/dev/null; then
        info "Could not find requested version $XCB_UTIL_VERSION in local clone; fetching..."
        git fetch --all
        git submodule update
    fi
    git reset --hard
    git clean -dfxq
    git checkout "${XCB_UTIL_VERSION}^{commit}"
    ./autogen.sh
    ./configure --enable-shared
    make -j4 -s || fail "Could not build libxcb-util1"
) || fail "Could build libxcb-util1"
cp "$CACHEDIR/libxcb-util1/util/src/.libs/libxcb-util.so.1" "$APPDIR/usr/lib/libxcb-util.so.1"


appdir_python() {
    env \
        PYTHONNOUSERSITE=1 \
        LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH+:$LD_LIBRARY_PATH}" \
        "$APPDIR/usr/bin/python${PY_VER_MAJOR}" "$@"
}

python='appdir_python'


info "installing pip."
"$python" -m ensurepip

break_legacy_easy_install


info "preparing electrum-blc-locale."
(
    cd "$PROJECT_ROOT"
    # Blakecoin: skip locale submodule (no translations yet)
    LOCALE="$PROJECT_ROOT/electrum_blc/locale/"
    mkdir -p "$LOCALE"
) || true


info "Installing build dependencies."
# note: re pip installing from PyPI,
#       we prefer compiling C extensions ourselves, instead of using binary wheels,
#       hence "--no-binary :all:" flags. However, we specifically allow
#       - PyQt5, as it's harder to build from source
#       - cryptography, as it's harder to build from source
#       - the whole of "requirements-build-base.txt", which includes pip and friends, as it also includes "wheel",
#         and I am not quite sure how to break the circular dependence there (I guess we could introduce
#         "requirements-build-base-base.txt" with just wheel in it...)
"$python" -m pip install --no-build-isolation --no-dependencies --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" -r "$CONTRIB/deterministic-build/requirements-build-base.txt"
"$python" -m pip install --no-build-isolation --no-dependencies --no-binary :all: --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" -r "$CONTRIB/deterministic-build/requirements-build-appimage.txt"

info "installing electrum and its dependencies."
"$python" -m pip install --no-build-isolation --no-dependencies --no-binary :all: --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" -r "$CONTRIB/deterministic-build/requirements.txt"
"$python" -m pip install --no-build-isolation --no-dependencies --no-binary :all: --only-binary PyQt5,PyQt5-Qt5,cryptography --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" -r "$CONTRIB/deterministic-build/requirements-binaries.txt"
"$python" -m pip install --no-build-isolation --no-dependencies --no-binary :all: --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" -r "$CONTRIB/deterministic-build/requirements-hw.txt"

"$python" -m pip install --no-build-isolation --no-dependencies --no-warn-script-location \
    --cache-dir "$PIP_CACHE_DIR" "$PROJECT_ROOT"

# was only needed during build time, not runtime
"$python" -m pip uninstall -y Cython


info "copying zbar"
cp "/usr/lib/x86_64-linux-gnu/libzbar.so.0" "$APPDIR/usr/lib/libzbar.so.0"


info "building Blake-256 C extension for Blakecoin PoW."
(
    cd "$PROJECT_ROOT/blake256"
    PYTHON_INCLUDE="$($python -c "import sysconfig; print(sysconfig.get_config_var('INCLUDEPY'))")"
    EXT_SUFFIX="$($python -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))")"
    gcc -shared -fPIC -O2 -I"$PYTHON_INCLUDE" -I. \
        -o "$APPDIR/usr/lib/python${PY_VER_MAJOR}/site-packages/_blake256${EXT_SUFFIX}" \
        blake256_wrapper.c blake.c || fail "Could not build Blake-256 extension"
)
info "Blake-256 extension built successfully."


info "desktop integration."
cp "$PROJECT_ROOT/electrum-blc.desktop" "$APPDIR/electrum-blc.desktop"
cp "$PROJECT_ROOT/electrum_blc/gui/icons/electrum-blc.png" "$APPDIR/electrum-blc.png"


# add launcher
cp "$CONTRIB_APPIMAGE/apprun.sh" "$APPDIR/AppRun"

info "finalizing AppDir."
(
    export PKG2AICOMMIT="$PKG2APPIMAGE_COMMIT"
    . "$CACHEDIR/functions.sh"

    cd "$APPDIR"
    # copy system dependencies
    copy_deps; copy_deps; copy_deps
    move_lib

    # apply global appimage blacklist to exclude stuff
    # move usr/include out of the way to preserve usr/include/python${PY_VER_MAJOR}.
    mv usr/include usr/include.tmp
    delete_blacklisted
    mv usr/include.tmp usr/include
) || fail "Could not finalize AppDir"

info "Copying additional libraries"
(
    # On some systems it can cause problems to use the system libusb (on AppImage excludelist)
    cp -f /usr/lib/x86_64-linux-gnu/libusb-1.0.so "$APPDIR/usr/lib/libusb-1.0.so" || fail "Could not copy libusb"
    # some distros lack libxkbcommon-x11
    cp -f /usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so.0 "$APPDIR"/usr/lib/x86_64-linux-gnu || fail "Could not copy libxkbcommon-x11"
    # some distros lack some libxcb libraries (see https://github.com/Electron-Cash/Electron-Cash/issues/2196)
    cp -f /usr/lib/x86_64-linux-gnu/libxcb-* "$APPDIR"/usr/lib/x86_64-linux-gnu || fail "Could not copy libxcb"
)

info "stripping binaries from debug symbols."
# "-R .note.gnu.build-id" also strips the build id
# "-R .comment" also strips the GCC version information
strip_binaries()
{
    chmod u+w -R "$APPDIR"
    {
        printf '%s\0' "$APPDIR/usr/bin/python${PY_VER_MAJOR}"
        find "$APPDIR" -type f -regex '.*\.so\(\.[0-9.]+\)?$' -print0
    } | xargs -0 --no-run-if-empty --verbose strip -R .note.gnu.build-id -R .comment
}
strip_binaries

remove_emptydirs()
{
    find "$APPDIR" -type d -empty -print0 | xargs -0 --no-run-if-empty rmdir -vp --ignore-fail-on-non-empty
}
remove_emptydirs


info "removing some unneeded stuff to decrease binary size."
rm -rf "$APPDIR"/usr/{share,include}
PYDIR="$APPDIR/usr/lib/python${PY_VER_MAJOR}"
rm -rf "$PYDIR"/{test,ensurepip,lib2to3,idlelib,turtledemo}
rm -rf "$PYDIR"/{ctypes,sqlite3,tkinter,unittest}/test
rm -rf "$PYDIR"/distutils/{command,tests}
rm -rf "$PYDIR"/config-3.*-x86_64-linux-gnu
rm -rf "$PYDIR"/site-packages/{opt,pip,setuptools,wheel}
rm -rf "$PYDIR"/site-packages/Cryptodome/SelfTest
rm -rf "$PYDIR"/site-packages/{psutil,qrcode,websocket}/tests
# rm lots of unused parts of Qt/PyQt. (assuming PyQt 5.15.3+ layout)
for component in connectivity declarative help location multimedia quickcontrols2 serialport webengine websockets xmlpatterns ; do
    rm -rf "$PYDIR"/site-packages/PyQt5/Qt5/translations/qt${component}_*
    rm -rf "$PYDIR"/site-packages/PyQt5/Qt5/resources/qt${component}_*
done
rm -rf "$PYDIR"/site-packages/PyQt5/Qt5/{qml,libexec}
rm -rf "$PYDIR"/site-packages/PyQt5/{pyrcc*.so,pylupdate*.so,uic}
rm -rf "$PYDIR"/site-packages/PyQt5/Qt5/plugins/{bearer,gamepads,geometryloaders,geoservices,playlistformats,position,renderplugins,sceneparsers,sensors,sqldrivers,texttospeech,webview}
for component in Bluetooth Concurrent Designer Help Location NetworkAuth Nfc Positioning PositioningQuick Qml Quick Sensors SerialPort Sql Test Web Xml ; do
    rm -rf "$PYDIR"/site-packages/PyQt5/Qt5/lib/libQt5${component}*
    rm -rf "$PYDIR"/site-packages/PyQt5/Qt${component}*
done
rm -rf "$PYDIR"/site-packages/PyQt5/Qt.so

# these are deleted as they were not deterministic; and are not needed anyway
find "$APPDIR" -path '*/__pycache__*' -delete
# although note that *.dist-info might be needed by certain packages...
# e.g. importlib-metadata, see https://gitlab.com/python-devs/importlib_metadata/issues/71
rm -rf "$PYDIR"/site-packages/*.dist-info/
rm -rf "$PYDIR"/site-packages/*.egg-info/


find -exec touch -h -d '2000-11-11T11:11:11+00:00' {} +


info "creating the AppImage."
(
    cd "$BUILDDIR"
    chmod +x "$CACHEDIR/appimagetool"
    # Extract appimagetool (avoids FUSE requirement during build)
    "$CACHEDIR/appimagetool" --appimage-extract 2>/dev/null || true
    # Use extracted appimagetool to create the AppImage
    env VERSION="$VERSION" ARCH=x86_64 ./squashfs-root/AppRun --no-appstream --verbose "$APPDIR" "$APPIMAGE"
)


info "done."
ls -la "$DISTDIR"
sha256sum "$DISTDIR"/*
