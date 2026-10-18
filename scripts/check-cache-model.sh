#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/AppModel.swift Sources/MacEven/CacheModel.swift Sources/MacEven/ApplicationCloser.swift Tests/CacheModelChecks.swift \
    -o "$TASK_BIN/MacEvenCacheModelChecks" -lsqlite3
"$TASK_BIN/MacEvenCacheModelChecks" -AppleLanguages '(zh-Hans)'
