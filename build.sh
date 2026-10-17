#!/bin/bash
# Usage: ./build.sh [--install] [--run]
#   --install  also copy the app into /Applications (or $INSTALL_DIR)
#   --run      open the built app, or the installed copy with --install
set -euo pipefail
cd "$(dirname "$0")"
install=false run=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --run) run=true ;;
    *) echo "Unknown option: $arg (use --install and/or --run)" >&2; exit 2 ;;
  esac
done
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
cp Resources/DocumentIcon.icns build/untitled.app/Contents/Resources/DocumentIcon.icns
codesign --force --sign - build/untitled.app
# Resource replacements do not update the outer bundle's timestamp on their own.
# Let Finder notice the new icon after an incremental build.
touch build/untitled.app
echo "Built: $(pwd)/build/untitled.app"
app=build/untitled.app

if $install; then
  dir="${INSTALL_DIR:-/Applications}"
  target="$dir/untitled.app"
  # Never replace a bundle that is running, or a different app that happens to share the name.
  if pgrep -f "^$target/Contents/MacOS/untitled" >/dev/null; then
    echo "Quit the installed untitled before reinstalling: $target is running." >&2; exit 1
  fi
  if [ -e "$target" ] && [ "$(defaults read "$target/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "local.untitled.editor" ]; then
    echo "Not replacing $target: it is not this app." >&2; exit 1
  fi
  # Copy beside the old version first, so a failed copy leaves the installed app intact.
  rm -rf "$target.installing"
  ditto build/untitled.app "$target.installing"
  rm -rf "$target"
  mv "$target.installing" "$target"
  echo "Installed: $target"
  if pgrep -f "^$(pwd)/build/untitled.app/Contents/MacOS/untitled" >/dev/null; then
    echo "Note: the local build is still running. Quit it before opening the installed copy; both edit the same notes." >&2
  fi
  app="$target"
fi

if $run; then open "$app"; fi
