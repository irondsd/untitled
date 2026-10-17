#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache build/icon
xcrun swift -module-cache-path build/module-cache MakeIcon.swift build/icon/AppIcon.iconset
xcrun swift -module-cache-path build/module-cache MakeDocumentIcon.swift build/icon/DocumentIcon.iconset
# Let macOS choose each representation's encoding. PNG data in manually assembled
# icp4/icp5 chunks can decode as scrambled pixels in Finder and Activity Monitor.
iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
iconutil -c icns build/icon/DocumentIcon.iconset -o build/icon/DocumentIcon.icns
cp build/icon/AppIcon.icns Resources/AppIcon.icns
cp build/icon/DocumentIcon.icns Resources/DocumentIcon.icns
echo "Updated app and document icons in Resources; run ./build.sh to update the app."
