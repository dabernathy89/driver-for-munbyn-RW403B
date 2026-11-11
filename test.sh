#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline checks only: no Bluetooth access, installation, or printing.
set -eu
cd "$(dirname "$0")"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/rw403b-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
python3 -m unittest discover -s tests -p 'test_*.py'
python3 configure.py --directory "$scratch/config" \
  --uuid 00000000-0000-4000-8000-000000000001 --mac 02:00:00:00:00:01
RW_CONFIG_DIR="$scratch/config" RW_BUILD_DIR="$scratch/build" sh build.sh
xcrun clang -O2 -Wall -Wextra -Ivendor/heatshrink -c vendor/heatshrink/heatshrink_decoder.c -o "$scratch/build/heatshrink_decoder.o"
xcrun clang -O2 -Wall -Wextra -Wno-deprecated-declarations -fobjc-arc -Isrc -Ivendor/heatshrink \
  tests/check.m src/Protocol.m src/Raster.m "$scratch/build/heatshrink_encoder.o" "$scratch/build/heatshrink_decoder.o" \
  -framework Foundation -lcups -o "$scratch/build/check"
"$scratch/build/check" "$scratch/test-data"
RW_BUILD_DIR="$scratch/build" sh discover.sh --build-only
for script in ./*.sh; do sh -n "$script"; done
