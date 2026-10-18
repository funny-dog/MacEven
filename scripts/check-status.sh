#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
# 检查程序把创建的临时偏好域登记到这里，脚本退出时（含失败）逐个删除残留 plist。
TASK_DEFAULTS_LOG="$(mktemp -t maceven-test-defaults)"
export MACEVEN_TEST_DEFAULTS_LOG="$TASK_DEFAULTS_LOG"
trap 'bash scripts/clean-test-defaults.sh "$TASK_DEFAULTS_LOG"' EXIT
for TASK_CHECK in Hardware HardwareHistory; do
    swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o "Tests/${TASK_CHECK}Checks.swift" -o "$TASK_BIN/MacEven${TASK_CHECK}Checks" -lsqlite3
    "$TASK_BIN/MacEven${TASK_CHECK}Checks" -AppleLanguages '(zh-Hans)'
done
swiftc -swift-version 6 -parse-as-library Sources/MacEvenCore/Localization.swift Sources/MacEvenCore/SMCReader.swift Tests/SMCChecks.swift -o "$TASK_BIN/MacEvenSMCChecks"
"$TASK_BIN/MacEvenSMCChecks" -AppleLanguages '(zh-Hans)'
swiftc -swift-version 6 -parse-as-library Sources/MacEvenCore/Localization.swift Sources/MacEvenCore/Models.swift Sources/MacEvenCore/ScanIssue.swift Sources/MacEvenCore/SystemMonitor.swift Tests/ProcessStatusChecks.swift -o "$TASK_BIN/MacEvenProcessStatusChecks"
TASK_CHILD="$TASK_BIN/MacEvenProcessStatusChild.app"
mkdir -p "$TASK_CHILD/Contents/MacOS"
cp "$TASK_BIN/MacEvenProcessStatusChecks" "$TASK_CHILD/Contents/MacOS/MacEvenProcessStatusChecks"
cat > "$TASK_CHILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacEvenProcessStatusChecks</string>
<key>CFBundleIdentifier</key><string>local.maceven.process-status-child</string>
<key>CFBundleName</key><string>MacEven 专属退出测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$TASK_CHILD"
"$TASK_BIN/MacEvenProcessStatusChecks" -AppleLanguages '(zh-Hans)'
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/StatusSettings.swift Sources/MacEven/SystemTools.swift Tests/TestDefaultsSupport.swift Tests/StatusToolsChecks.swift -o "$TASK_BIN/MacEvenStatusToolsChecks" -lsqlite3
"$TASK_BIN/MacEvenStatusToolsChecks" -AppleLanguages '(zh-Hans)'
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/OperationStats.swift Tests/TestDefaultsSupport.swift Tests/OperationStatsChecks.swift -o "$TASK_BIN/MacEvenOperationStatsChecks" -lsqlite3
"$TASK_BIN/MacEvenOperationStatsChecks" -AppleLanguages '(zh-Hans)'
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/OperationJournal.swift Sources/MacEven/ProtectionModel.swift Tests/OperationJournalChecks.swift -o "$TASK_BIN/MacEvenOperationJournalChecks" -lsqlite3
"$TASK_BIN/MacEvenOperationJournalChecks" -AppleLanguages '(zh-Hans)'
