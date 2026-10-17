#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache build/icon
xcrun swift -module-cache-path build/module-cache MakeIcon.swift build/icon/AppIcon.iconset
# Let macOS choose each representation's encoding. PNG data in manually assembled
# icp4/icp5 chunks can decode as scrambled pixels in Finder and Activity Monitor.
iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
cp build/icon/AppIcon.icns Resources/AppIcon.icns
echo "Updated Resources/AppIcon.icns; run ./build.sh to update the app."
