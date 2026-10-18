#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o Tests/StartupItemsChecks.swift -o "$TASK_BIN/MacEvenStartupItemsChecks" -lsqlite3
"$TASK_BIN/MacEvenStartupItemsChecks" -AppleLanguages '(zh-Hans)'
