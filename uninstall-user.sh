#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
user_id=$(id -u)
if [ "$user_id" -eq 0 ]; then echo 'Run as the login user, without sudo.' >&2; exit 1; fi
if [ -n "$(/usr/bin/lpstat -o Munbyn_RW403B_BLE 2>/dev/null || true)" ]; then echo 'Review/cancel unfinished RW403B jobs before removing the app.' >&2; exit 1; fi
agent="$HOME/Library/LaunchAgents/org.local.rw403bbridge.plist"
app="$HOME/Applications/RW403B Bluetooth.app"
if [ -f "$agent" ]; then /bin/launchctl bootout "gui/$user_id" "$agent" 2>/dev/null || true; /bin/rm -f "$agent"; fi
if [ -d "$app" ]; then
  /usr/bin/pkill -u "$user_id" -x rw403bbridge 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! /usr/bin/pgrep -u "$user_id" -x rw403bbridge >/dev/null; then break; fi
    /bin/sleep 0.2
  done
  if /usr/bin/pgrep -u "$user_id" -x rw403bbridge >/dev/null; then echo 'Stop rw403bbridge in Activity Monitor before uninstalling.' >&2; exit 1; fi
  /bin/rm -rf "$app"
fi
/bin/rm -f "$HOME/Library/Logs/RW403B/bridge.log" "$HOME/Library/Logs/RW403B/bridge.log.previous"
/bin/rmdir "$HOME/Library/Logs/RW403B" 2>/dev/null || true
/bin/rm -f "/private/tmp/rw403b-$user_id"/print.sock
/bin/rmdir "/private/tmp/rw403b-$user_id" 2>/dev/null || true
echo 'Removed the RW403B app, login item, private socket, and logs.'
