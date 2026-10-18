#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then echo 'Usage: bash scripts/check-window.sh /absolute/path/to/disposable/fixture [检查参数，如 --feature-integration / --status-resource]'; exit 1; fi
TASK_FIXTURE="$1"; shift
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
TASK_APP="$TASK_BIN/MacEvenWindowChecks.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
TASK_SOURCES=()
for TASK_SOURCE in Sources/MacEven/*.swift Sources/MacEven/Design/*.swift; do
    if [ "$(basename "$TASK_SOURCE")" != "MacEvenApp.swift" ]; then TASK_SOURCES+=("$TASK_SOURCE"); fi
done
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o "${TASK_SOURCES[@]}" Tests/TestDefaultsSupport.swift Tests/WindowChecks.swift -o "$TASK_APP/Contents/MacOS/MacEven" -lsqlite3
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.maceven.windowchecks' "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MacEven Window Checks' "$TASK_APP/Contents/Info.plist"
echo "$TASK_FIXTURE" > "$TASK_APP/Contents/Resources/fixture.txt"
codesign --force --sign - "$TASK_APP"
echo "$TASK_APP"
# 由脚本启动检查并等待退出，再删除它登记的临时偏好域（进程存活时 cfprefsd 会写回空 plist）。
TASK_DEFAULTS_LOG="$(mktemp -t maceven-window-defaults)"
export MACEVEN_TEST_DEFAULTS_LOG="$TASK_DEFAULTS_LOG"
trap 'bash scripts/clean-test-defaults.sh "$TASK_DEFAULTS_LOG"' EXIT
"$TASK_APP/Contents/MacOS/MacEven" "$@" -AppleLanguages '(zh-Hans)'
