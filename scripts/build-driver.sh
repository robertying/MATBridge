#!/bin/zsh
# Builds the "MATBridge" virtual audio device: BlackHole v0.7.2 (GPL-3.0, github.com/ExistentialAudio/BlackHole)
# with 6 channels, 48/96/192 kHz only, and driver/reported-output-latency.patch, which makes the device tell apps
# how late its audio is actually heard (so video players delay the picture to match), without adding any delay.
#
# usage: scripts/build-driver.sh [latency-ms] [signing identity]
#   latency-ms  what to report. Default 98 = capture 5 + pipeline (--target-ms) 70 + TV output 22.8, as MATBridge
#               logs at start ("Latency: ..."). The receiver's own decode time is unknown and not included.
#   identity    codesign identity; default: the first "Developer ID Application" one, else "Apple Development",
#               else ad-hoc.
# Output: driver/build/MATBridge.driver   Install with scripts/install-driver.sh (needs sudo).
set -euo pipefail
cd "${0:A:h}/.."
latency_ms=${1:-98}
identity=${2:-}
tag=v0.7.2
root=$PWD/driver/build
src=$root/BlackHole

if [[ -z $identity ]]; then
  identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
  [[ -z $identity ]] && identity=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)
  [[ -z $identity ]] && identity=-
fi

mkdir -p "$root"
if [[ ! -d $src ]]; then
  git -c advice.detachedHead=false clone -q --branch $tag --depth 1 https://github.com/ExistentialAudio/BlackHole.git "$src"
fi
git -C "$src" checkout -q -- .
git -C "$src" apply "$PWD/driver/reported-output-latency.patch"

latency_us=$(( latency_ms * 1000 ))
bundle=io.ruiying.matbridge.driver
rm -rf "$root/xcode"
xcodebuild -quiet \
  -project "$src/BlackHole.xcodeproj" \
  -scheme BlackHole \
  -configuration Release \
  -derivedDataPath "$root/xcode" \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=$bundle \
  GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS
  kDriver_Name=\"MATBridge\"
  kDevice_Name=\"MATBridge\"
  kHas_Driver_Name_Format=false
  kPlugIn_BundleID=\"'$bundle'\"
  kPlugIn_Icon=\"BlackHole.icns\"
  kManufacturer_Name=\"MATBridge\"
  kNumber_Of_Channels=6
  kSampleRates=48000,96000,192000
  kReported_Output_Latency_Us='$latency_us

built=$(find "$root/xcode" -name '*.driver' -maxdepth 5 -type d | head -1)
rm -rf "$root/MATBridge.driver"
cp -R "$built" "$root/MATBridge.driver"
if [[ $identity == - ]]; then
  codesign --force --sign - "$root/MATBridge.driver"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$root/MATBridge.driver"
fi
codesign --verify --strict --verbose=1 "$root/MATBridge.driver"
echo "built $root/MATBridge.driver (6ch, reports ${latency_ms} ms output latency, signed: $identity)"
