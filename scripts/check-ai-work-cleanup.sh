#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o \
    Sources/MacEven/AppModel.swift Sources/MacEven/CacheModel.swift Sources/MacEven/ApplicationCloser.swift Sources/MacEven/ApplicationRemovalModel.swift \
    Sources/MacEven/LeftoverModel.swift Sources/MacEven/DockCleaner.swift Sources/MacEven/SmartScanModel.swift Sources/MacEven/AICleanupRows.swift Sources/MacEven/Design/*.swift \
    Tests/AIWorkCleanupChecks.swift -o "$TASK_BIN/MacEvenAIWorkCleanupChecks" -lsqlite3
"$TASK_BIN/MacEvenAIWorkCleanupChecks" -AppleLanguages '(zh-Hans)'
