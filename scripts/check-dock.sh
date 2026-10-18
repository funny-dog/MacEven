#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 测试 Dock 偏好域在检查进程退出后清理：进程内删除会被仍缓存该域的 cfprefsd 写回空文件。
task_cleanup_preferences() {
    for TASK_PREF in "$HOME"/Library/Preferences/local.maceven.dockchecks.*.plist; do
        [ -e "$TASK_PREF" ] || continue
        defaults delete "$(basename "$TASK_PREF" .plist)" >/dev/null 2>&1 || true
        rm -f "$TASK_PREF"
    done
}
trap task_cleanup_preferences EXIT
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/DockCleaner.swift Tests/DockChecks.swift -o "$TASK_BIN/MacEvenDockChecks" -lsqlite3
"$TASK_BIN/MacEvenDockChecks" -AppleLanguages '(zh-Hans)'
