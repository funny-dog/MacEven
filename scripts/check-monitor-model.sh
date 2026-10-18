#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/MonitorModel.swift \
    Tests/MonitorModelChecks.swift -o "$TASK_BIN/MacEvenMonitorModelChecks" -lsqlite3 -framework SystemConfiguration
"$TASK_BIN/MacEvenMonitorModelChecks" -AppleLanguages '(zh-Hans)'
