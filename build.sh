#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
cd "$(dirname "$0")"
config=${RW_CONFIG_DIR:-.local}
out=${RW_BUILD_DIR:-build}
python3 configure.py --directory "$config" --check
mkdir -p "$out/config"
chmod 700 "$out/config"
cp "$config/Config.h" "$config/settings.json" "$out/config/"
chmod 600 "$out/config/Config.h" "$out/config/settings.json"
python3 configure.py --directory "$out/config" --check
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -Ivendor/heatshrink -c vendor/heatshrink/heatshrink_encoder.c -o "$out/heatshrink_encoder.o"
xcrun clang -O2 -Wall -Wextra -Wno-deprecated-declarations -I"$out/config" src/Client.c -lcups -o "$out/rw403bble"
codesign --force --sign - --identifier org.local.rw403bble "$out/rw403bble"
app="$out/RW403B Bluetooth.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp AppInfo.plist "$app/Contents/Info.plist"
cp LICENSES.txt "$app/Contents/Resources/LICENSES.txt"
xcrun clang -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -fobjc-arc -Ivendor/heatshrink -I"$out/config" \
  src/App.m src/Protocol.m src/Raster.m src/Transport.m "$out/heatshrink_encoder.o" \
  -framework AppKit -framework Foundation -framework CoreBluetooth -framework IOBluetooth -lcups \
  -o "$app/Contents/MacOS/rw403bbridge"
codesign --force --sign - --identifier org.local.rw403bbridge "$app"
cupstestppd -q RW403B.ppd
