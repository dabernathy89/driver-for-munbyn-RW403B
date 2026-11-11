#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
backend=/usr/libexec/cups/backend/rw403bble
if [ -e "$backend" ]; then
  /usr/bin/codesign -d --verbose=2 "$backend" 2>&1 | /usr/bin/grep -q '^Identifier=org.local.rw403bble$'
fi
if /usr/bin/lpstat -p Munbyn_RW403B_BLE >/dev/null 2>&1; then
  uri=$(cat /Library/Printers/RW403BOpenSource/device-uri)
  case "$uri" in rw403bble://*) ;; *) echo 'Installed URI is invalid; no changes made.' >&2; exit 1;; esac
  case "$(LC_ALL=C /usr/bin/lpstat -v Munbyn_RW403B_BLE)" in
    *": $uri") ;;
    *) echo 'Queue URI has changed; refusing to remove it.' >&2; exit 1;;
  esac
  if [ -n "$(/usr/bin/lpstat -o Munbyn_RW403B_BLE)" ]; then
    echo 'This queue has unfinished jobs. Review/cancel them in Print Center before uninstalling.' >&2; exit 1
  fi
  /usr/sbin/lpadmin -x Munbyn_RW403B_BLE
fi
/bin/rm -f /usr/libexec/cups/backend/rw403bble
/bin/rm -f /Library/Printers/PPDs/Contents/Resources/RW403BOpenSource.ppd
/bin/rm -f /Library/Printers/RW403BOpenSource/LICENSES.txt /Library/Printers/RW403BOpenSource/device-uri
if [ -d /Library/Printers/RW403BOpenSource ]; then /bin/rmdir /Library/Printers/RW403BOpenSource; fi
echo 'Removed the RW403B queue and its installed files.'
