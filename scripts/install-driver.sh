#!/bin/zsh
# Installs driver/build/MATBridge.driver into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod.
# Needs sudo. All audio stops for a moment. Build it first with scripts/build-driver.sh.
# Remove it with:  sudo rm -rf /Library/Audio/Plug-Ins/HAL/MATBridge.driver && sudo killall AirPlayXPCHelper coreaudiod
set -euo pipefail
cd "${0:A:h}/.."
drv=driver/build/MATBridge.driver
[[ -d $drv ]] || { echo "build it first: scripts/build-driver.sh"; exit 1; }
codesign --verify --strict "$drv"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MATBridge.driver
sudo cp -R "$drv" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/MATBridge.driver
# Restart AirPlayXPCHelper too: it re-registers its AirPlay driver once for every registration it has made so far,
# so each coreaudiod restart on its own doubles the work until Core Audio hangs (seen after ~10 restarts).
sudo killall AirPlayXPCHelper coreaudiod 2>/dev/null || sudo killall coreaudiod
echo "installed /Library/Audio/Plug-Ins/HAL/MATBridge.driver; coreaudiod restarted"
