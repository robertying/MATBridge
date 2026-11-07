#!/bin/zsh
# Stops and removes the LaunchAgent, restores the TV and the default output, removes the installed binary.
# Leaves the MATBridge driver installed (remove it with: sudo rm -rf /Library/Audio/Plug-Ins/HAL/MATBridge.driver && sudo killall coreaudiod).
set -uo pipefail
label=io.ruiying.matbridge
support="$HOME/Library/Application Support/MATBridge"
plist="$HOME/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$UID/$label" 2>/dev/null && echo "stopped $label"
if [[ -x "$support/bin/MATBridge" ]]; then
  "$support/bin/MATBridge" recover
elif [[ -x "${0:A:h}/../.build/release/MATBridge" ]]; then
  "${0:A:h}/../.build/release/MATBridge" recover
fi
rm -f "$plist"
rm -rf "$support/bin"
echo "uninstalled (state file and log kept: $support/state.json, ~/Library/Logs/MATBridge.log)"
