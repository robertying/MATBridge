#!/bin/zsh
# Builds MATBridge, copies it to ~/Library/Application Support/MATBridge/bin and installs a
# per-user LaunchAgent that starts it at login. No sudo needed (install the virtual device first:
# scripts/build-driver.sh and scripts/install-driver.sh).
# Extra arguments are passed to `MATBridge run`, e.g.: scripts/install.sh --rate 192000
set -euo pipefail
cd "${0:A:h}/.."
label=io.ruiying.matbridge
support="$HOME/Library/Application Support/MATBridge"
bin="$support/bin/MATBridge"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/MATBridge.log"

swift build -c release
mkdir -p "$support/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop a running copy first so it restores the TV before the binary is replaced.
launchctl bootout "gui/$UID/$label" 2>/dev/null || true
cp .build/release/MATBridge "$bin"

# macOS asks once for microphone access (capturing from the virtual device counts as audio input). That grant
# is tied to the code signature: sign with a stable identity so it survives updates. Without a certificate the
# build's ad-hoc signature is kept, and macOS asks again after each reinstall.
identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
[[ -z $identity ]] && identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
if [[ -n $identity ]]; then
  codesign --force --identifier io.ruiying.matbridge --sign "$identity" "$bin"
  echo "signed:    $identity"
fi

args_xml="    <string>$bin</string>
    <string>run</string>"
for a in "$@"; do
  a=${a//&/&amp;}; a=${a//</&lt;}; a=${a//>/&gt;}
  args_xml+="
    <string>$a</string>"
done

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args_xml
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>ExitTimeOutSecs</key><integer>10</integer>
  <key>StandardOutPath</key><string>$logfile</string>
  <key>StandardErrorPath</key><string>$logfile</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$UID" "$plist"
echo "installed: $plist"
echo "log:       $logfile   (tail -f it to watch)"
