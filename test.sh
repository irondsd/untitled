#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache \
  Sources/NotesStore.swift Sources/LogicalLines.swift Sources/FindEngine.swift Sources/Syntax*.swift Tests/main.swift -o build/notes-tests
build/notes-tests
