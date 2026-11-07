#!/bin/zsh
# Builds MATBridge, installs it as a background app (no Dock icon, no window) at
# ~/Library/Application Support/MATBridge/MATBridge.app, and adds a per-user LaunchAgent that starts it at login.
# The app bundle is what gives it the name "MATBridge" in System Settings → Login Items and in the microphone prompt.
# No sudo needed (install the virtual device first: scripts/build-driver.sh and scripts/install-driver.sh).
# Extra arguments are passed to `MATBridge run`, e.g.: scripts/install.sh --rate 192000
set -euo pipefail
cd "${0:A:h}/.."
label=io.ruiying.matbridge
support="$HOME/Library/Application Support/MATBridge"
app="$support/MATBridge.app"
bin="$app/Contents/MacOS/MATBridge"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/MATBridge.log"

swift build -c release
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop a running copy first so it restores the TV before the binary is replaced. bootout returns before the
# job is fully gone, so wait for it.
launchctl bootout "gui/$UID/$label" 2>/dev/null || true
for i in {1..50}; do launchctl print "gui/$UID/$label" >/dev/null 2>&1 || break; sleep 0.2; done
rm -rf "$app" "$support/bin"  # bin/: where older versions installed a bare binary
mkdir -p "$app/Contents/MacOS"
cp .build/release/MATBridge "$bin"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleName</key><string>MATBridge</string>
  <key>CFBundleDisplayName</key><string>MATBridge</string>
  <key>CFBundleExecutable</key><string>MATBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MATBridge captures system audio from its own virtual audio device and sends it over HDMI as Dolby TrueHD. It never uses a real microphone.</string>
</dict>
</plist>
EOF

# macOS asks once for microphone access (capturing from the virtual device counts as audio input). That grant
# is tied to the code signature: sign with a stable identity so it survives updates. Without a certificate the
# app is signed ad hoc, and macOS asks again after each reinstall.
identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
[[ -z $identity ]] && identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
codesign --force --sign "${identity:--}" "$app"
echo "signed:    ${identity:-ad hoc}"

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
  <key>AssociatedBundleIdentifiers</key><array><string>$label</string></array>
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

# Let Launch Services know the app, so System Settings can show its name.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true

# bootstrap can still fail briefly right after a bootout; retry for a few seconds.
for i in {1..10}; do launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null && break; sleep 0.5; done
launchctl print "gui/$UID/$label" >/dev/null 2>&1 || { echo "error: could not start $label (see: launchctl bootstrap gui/$UID \"$plist\")"; exit 1; }
echo "installed: $app"
echo "agent:     $plist"
echo "log:       $logfile   (tail -f it to watch)"
