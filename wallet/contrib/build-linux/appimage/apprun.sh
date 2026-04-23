#!/bin/bash

set -e

APPDIR="$(dirname "$(readlink -e "$0")")"

export LD_LIBRARY_PATH="${APPDIR}/usr/lib/:${APPDIR}/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH+:$LD_LIBRARY_PATH}"
export PATH="${APPDIR}/usr/bin:${PATH}"
export LDFLAGS="-L${APPDIR}/usr/lib/x86_64-linux-gnu -L${APPDIR}/usr/lib"

# Blakecoin: protobuf compatibility (older generated code)
export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python

# Blakecoin: force X11/XCB on Wayland to avoid Qt warnings
if [ -z "$QT_QPA_PLATFORM" ] && [ -n "$WAYLAND_DISPLAY" ] && [ -n "$DISPLAY" ]; then
    export QT_QPA_PLATFORM=xcb
    export GDK_BACKEND=x11
fi
unset XDG_SESSION_TYPE

exec "${APPDIR}/usr/bin/python3" -s "${APPDIR}/usr/bin/electrum-blc" "$@"
