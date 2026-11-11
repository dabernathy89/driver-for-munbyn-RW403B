#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
cd "$(dirname "$0")"
python3 configure.py --directory build/config --check
shasum -a 256 build/config/Config.h build/config/settings.json build/rw403bble RW403B.ppd LICENSES.txt \
  'build/RW403B Bluetooth.app/Contents/MacOS/rw403bbridge' \
  'build/RW403B Bluetooth.app/Contents/Info.plist' \
  'build/RW403B Bluetooth.app/Contents/Resources/LICENSES.txt' > SHA256SUMS
