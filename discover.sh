#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
cd "$(dirname "$0")"
case "${1:-}" in ''|--build-only) ;; *) echo 'Usage: sh discover.sh [--build-only]' >&2; exit 1;; esac
out=${RW_BUILD_DIR:-build}
app="$out/RW403B Discovery.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
python3 - "$app/Contents/Info.plist" <<'PYTHON'
import plistlib
import sys
with open('AppInfo.plist', 'rb') as source:
    info = plistlib.load(source)
info.update(CFBundleIdentifier='org.local.rw403bdiscovery', CFBundleName='RW403B Discovery',
            CFBundleDisplayName='RW403B Discovery', CFBundleExecutable='rw403bdiscovery', LSUIElement=False,
            NSBluetoothAlwaysUsageDescription='Find the Bluetooth UUID of your RW403B printer.',
            NSBluetoothPeripheralUsageDescription='Find the Bluetooth UUID of your RW403B printer.')
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(info, output)
PYTHON
cp LICENSE "$app/Contents/Resources/LICENSE"
xcrun clang -O2 -Wall -Wextra -Wno-deprecated-declarations -fobjc-arc src/Discover.m \
  -framework AppKit -framework CoreBluetooth -o "$app/Contents/MacOS/rw403bdiscovery"
codesign --force --sign - --identifier org.local.rw403bdiscovery "$app"
if [ "${1:-}" != --build-only ]; then open "$app"; fi
