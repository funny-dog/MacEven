#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_BIN="$(swift build --build-system native --show-bin-path)"
mkdir -p "$TASK_BIN"
swiftc -swift-version 6 -parse-as-library Sources/MacEvenCore/Localization.swift Sources/MacEvenCore/Models.swift Sources/MacEvenCore/ScanIssue.swift \
    Sources/MacEvenCore/SystemMonitor.swift Tests/ProcessBoundsChecks.swift \
    -o "$TASK_BIN/MacEvenProcessBoundsChecks" -framework SystemConfiguration
"$TASK_BIN/MacEvenProcessBoundsChecks" -AppleLanguages '(zh-Hans)'
