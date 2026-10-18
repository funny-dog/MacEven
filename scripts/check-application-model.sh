#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
TASK_HOME="$(mktemp -d "$TASK_BIN/MacEven-application-model.XXXXXX")"
# 测试 Dock 偏好域在检查进程退出后清理：进程内删除会被仍缓存该域的 cfprefsd 写回空文件。
task_cleanup_preferences() {
    for TASK_PREF in "$HOME"/Library/Preferences/local.maceven.applicationchecks.dock.*.plist; do
        [ -e "$TASK_PREF" ] || continue
        defaults delete "$(basename "$TASK_PREF" .plist)" >/dev/null 2>&1 || true
        rm -f "$TASK_PREF"
    done
}
trap 'rm -rf "$TASK_HOME"; task_cleanup_preferences' EXIT
TASK_APP="$TASK_HOME/Applications/MacEvenChecks.app"
mkdir -p "$TASK_APP/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/AppModel.swift Sources/MacEven/CacheModel.swift Sources/MacEven/ApplicationCloser.swift \
    Sources/MacEven/ApplicationRemovalModel.swift Sources/MacEven/LeftoverModel.swift Sources/MacEven/DockCleaner.swift Tests/ApplicationModelChecks.swift \
    -o "$TASK_APP/Contents/MacOS/MacEven" -lsqlite3
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.maceven.applicationchecks' "$TASK_APP/Contents/Info.plist"
codesign --force --sign - "$TASK_APP"
"$TASK_APP/Contents/MacOS/MacEven" -AppleLanguages '(zh-Hans)'
