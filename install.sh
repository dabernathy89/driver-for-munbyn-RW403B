#!/bin/sh
# SPDX-License-Identifier: MIT
# Install the already-built local backend, PPD, and license notices only.
set -eu
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
backend=/usr/libexec/cups/backend/rw403bble
ppd=/Library/Printers/PPDs/Contents/Resources/RW403BOpenSource.ppd
notices=/Library/Printers/RW403BOpenSource
for target in "$backend" "$ppd" "$notices"; do
  if [ -e "$target" ]; then echo "Already exists: $target. Remove the previous installation with uninstall.sh before reinstalling." >&2; exit 1; fi
done
if /usr/bin/lpstat -p Munbyn_RW403B_BLE >/dev/null 2>&1; then echo 'Queue Munbyn_RW403B_BLE already exists; no changes made.' >&2; exit 1; fi
/usr/bin/shasum -a 256 -c SHA256SUMS
configured_uid=$(python3 configure.py --directory build/config --get uid)
uri=$(python3 configure.py --directory build/config --get uri)
if [ "${SUDO_UID:-}" != "$configured_uid" ]; then echo 'Run sudo from the login account used to configure this build.' >&2; exit 1; fi
/usr/bin/codesign --verify --strict build/rw403bble
/usr/bin/cupstestppd -q RW403B.ppd
/usr/bin/install -o root -g wheel -m 700 build/rw403bble "$backend"
/usr/bin/install -d -o root -g wheel -m 755 /Library/Printers/PPDs/Contents/Resources "$notices"
/usr/bin/install -o root -g wheel -m 644 RW403B.ppd "$ppd"
/usr/bin/install -o root -g wheel -m 644 LICENSES.txt "$notices/LICENSES.txt"
printf '%s\n' "$uri" > "$notices/device-uri"
/bin/chmod 600 "$notices/device-uri"
/usr/sbin/lpadmin -p Munbyn_RW403B_BLE -E \
  -D 'MUNBYN RW403B Bluetooth' \
  -v "$uri" \
  -P "$ppd" -o printer-is-shared=false -o printer-error-policy=abort-job \
  -o PageSize=Label4x6 -o ColorModel=Gray
/usr/bin/lpstat -p Munbyn_RW403B_BLE
echo 'Installed the RW403B backend and queue. No test job has been sent.'
