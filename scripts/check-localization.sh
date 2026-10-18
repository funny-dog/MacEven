#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Tests/LocalizationChecks.swift \
    -o "$TASK_BIN/MacEvenLocalizationChecks" -lsqlite3
"$TASK_BIN/MacEvenLocalizationChecks" -AppleLanguages '(zh-Hans)'
"$TASK_BIN/MacEvenLocalizationChecks" -AppleLanguages '(en)'
"$TASK_BIN/MacEvenLocalizationChecks" -AppleLanguages '(fr)'

# Exercise the installed app layout without opening any windows.
TASK_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/maceven-localization.XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_APP="$TASK_STAGE/MacEven.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/MacEvenLocalizationChecks" "$TASK_APP/Contents/MacOS/MacEven"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
ditto "$TASK_BIN/MacEven_MacEvenCore.bundle" "$TASK_APP/Contents/Resources/MacEven_MacEvenCore.bundle"
"$TASK_APP/Contents/MacOS/MacEven" -AppleLanguages '(en)'
