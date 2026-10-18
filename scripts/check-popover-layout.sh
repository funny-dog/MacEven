#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
TASK_SOURCES=()
for TASK_SOURCE in Sources/MacEven/*.swift Sources/MacEven/Design/*.swift; do
    if [ "$(basename "$TASK_SOURCE")" != "MacEvenApp.swift" ]; then TASK_SOURCES+=("$TASK_SOURCE"); fi
done
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o "${TASK_SOURCES[@]}" Tests/TestDefaultsSupport.swift Tests/PopoverLayoutChecks.swift \
    -o "$TASK_BIN/MacEvenPopoverLayoutChecks" -lsqlite3
TASK_DEFAULTS_LOG="$(mktemp -t maceven-popover-defaults)"
export MACEVEN_TEST_DEFAULTS_LOG="$TASK_DEFAULTS_LOG"
trap 'bash scripts/clean-test-defaults.sh "$TASK_DEFAULTS_LOG"' EXIT
"$TASK_BIN/MacEvenPopoverLayoutChecks" -AppleLanguages '(zh-Hans)'
"$TASK_BIN/MacEvenPopoverLayoutChecks" -AppleLanguages '(en)'
