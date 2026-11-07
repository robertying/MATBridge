#!/bin/zsh
# Stops and removes the LaunchAgent, restores the TV and the default output, removes the installed app.
# Leaves the MATBridge driver installed (remove it with: sudo rm -rf /Library/Audio/Plug-Ins/HAL/MATBridge.driver && sudo killall AirPlayXPCHelper coreaudiod).
# The driver's shared-memory ring (/io.ruiying.matbridge, about 1.5 MB) stays until the next restart.
set -uo pipefail
label=io.ruiying.matbridge
support="$HOME/Library/Application Support/MATBridge"
app="$support/MATBridge.app"
plist="$HOME/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$UID/$label" 2>/dev/null && echo "stopped $label"
for b in "$app/Contents/MacOS/MATBridge" "${0:A:h}/../.build/release/MATBridge"; do
  if [[ -x $b ]]; then "$b" recover; break; fi
done
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null
rm -f "$plist"
rm -rf "$app"
echo "uninstalled (state file and log kept: $support/state.json, ~/Library/Logs/MATBridge.log)"
