#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
cd "$(dirname "$0")"
/usr/bin/shasum -a 256 -c SHA256SUMS
configured_uid=$(python3 configure.py --directory build/config --get uid)
if [ "$(id -u)" != "$configured_uid" ]; then echo 'Run as the configured login user, without sudo.' >&2; exit 1; fi
app="$HOME/Applications/RW403B Bluetooth.app"
agent="$HOME/Library/LaunchAgents/org.local.rw403bbridge.plist"
if [ -e "$app" ] || [ -e "$agent" ]; then echo 'RW403B app or login item already exists; remove it with uninstall-user.sh before updating.' >&2; exit 1; fi
/usr/bin/codesign --verify --strict 'build/RW403B Bluetooth.app'
/bin/mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
/usr/bin/ditto 'build/RW403B Bluetooth.app' "$app"
python3 - "$agent" "$app" <<'PYTHON'
import plistlib
import sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'Label': 'org.local.rw403bbridge',
                  'ProgramArguments': ['/usr/bin/open', '-a', sys.argv[2]],
                  'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua'}, output)
PYTHON
/bin/chmod 644 "$agent"
/bin/launchctl bootstrap "gui/$configured_uid" "$agent"
echo 'Installed the user-session Bluetooth app and login item.'
