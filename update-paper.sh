#!/bin/sh
# SPDX-License-Identifier: MIT
# Update only this driver's installed PPD and existing queue's paper definitions.
set -eu
cd "$(dirname "$0")"
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
queue=Munbyn_RW403B_BLE
current=/etc/cups/ppd/Munbyn_RW403B_BLE.ppd
installed=/Library/Printers/PPDs/Contents/Resources/RW403BOpenSource.ppd
/usr/bin/grep -q '^\*PCFileName: "RW403BLE.PPD"$' "$current"
/usr/bin/grep -q '^\*PCFileName: "RW403BLE.PPD"$' "$installed"
case "$(/usr/bin/lpstat -v "$queue")" in *'rw403bble://'*) ;; *) echo 'Unexpected printer backend; no changes made.' >&2; exit 1;; esac
if [ -n "$(/usr/bin/lpstat -o "$queue")" ]; then echo 'Finish or cancel this printer’s jobs before updating.' >&2; exit 1; fi
/usr/bin/shasum -a 256 -c SHA256SUMS
/usr/bin/cupstestppd -q RW403B.ppd
backup=$(mktemp -d /private/tmp/rw403b-ppd.XXXXXX)
trap 'rm -rf "$backup"' EXIT HUP INT TERM
cp "$current" "$backup/queue.ppd"
cp "$installed" "$backup/installed.ppd"
/usr/bin/install -o root -g wheel -m 644 RW403B.ppd "$installed"
if ! /usr/sbin/lpadmin -p "$queue" -P "$installed"; then
  /usr/bin/install -o root -g wheel -m 644 "$backup/installed.ppd" "$installed"
  /usr/sbin/lpadmin -p "$queue" -P "$backup/queue.ppd"
  echo 'Paper definition update failed; restored the previous PPD.' >&2
  exit 1
fi
/usr/bin/lpoptions -p "$queue" -l
echo 'Updated paper definitions. Reopen any Print dialog that was already open. No job was sent.'
