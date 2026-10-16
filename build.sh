#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/untitled.app/Contents/MacOS build/untitled.app/Contents/Resources build/module-cache
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macosx13.0" \
  Sources/*.swift -o build/untitled.app/Contents/MacOS/untitled \
  -framework AppKit -framework UniformTypeIdentifiers
cp Info.plist build/untitled.app/Contents/Info.plist
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns build/untitled.app/Contents/Resources/AppIcon.icns
fi
codesign --force --sign - build/untitled.app
echo "Built: $(pwd)/build/untitled.app"
if [ "${1:-}" = "--run" ]; then open build/untitled.app; fi
