#!/bin/sh
# SPDX-License-Identifier: MIT
# Replace only our already-installed backend with the user-session app IPC client.
set -eu
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
backend=/usr/libexec/cups/backend/rw403bble
if [ ! -f "$backend" ]; then echo 'No existing RW403B backend; use install.sh instead.' >&2; exit 1; fi
/usr/bin/codesign -d --verbose=2 "$backend" 2>&1 | /usr/bin/grep -q '^Identifier=org.local.rw403bble$'
if [ -n "$(/usr/bin/lpstat -o Munbyn_RW403B_BLE)" ]; then echo 'Review/cancel unfinished jobs before updating.' >&2; exit 1; fi
/usr/bin/shasum -a 256 -c SHA256SUMS
configured_uid=$(python3 configure.py --directory build/config --get uid)
uri=$(python3 configure.py --directory build/config --get uri)
if [ "${SUDO_UID:-}" != "$configured_uid" ]; then echo 'Run sudo from the configured login account.' >&2; exit 1; fi
if [ "$(cat /Library/Printers/RW403BOpenSource/device-uri)" != "$uri" ]; then echo 'Printer configuration changed; remove and reinstall instead.' >&2; exit 1; fi
/usr/bin/codesign --verify --strict build/rw403bble
/usr/bin/install -o root -g wheel -m 700 build/rw403bble "$backend"
echo 'Updated the RW403B CUPS backend to use the user-session Bluetooth app.'
