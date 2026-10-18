#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/AppModel.swift Sources/MacEven/DuplicateModel.swift \
    Tests/DuplicateModelChecks.swift -o "$TASK_BIN/MacEvenDuplicateModelChecks" -lsqlite3
"$TASK_BIN/MacEvenDuplicateModelChecks" -AppleLanguages '(zh-Hans)'
