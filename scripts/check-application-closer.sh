#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --build-system native --target MacEvenCore
TASK_BIN="$(swift build --build-system native --show-bin-path)"
TASK_HOME="$(mktemp -d "$TASK_BIN/MacEven-application-closer.XXXXXX")"
trap 'rm -rf "$TASK_HOME"' EXIT

# 1. 编译专属测试子应用二进制（支持正常退出与 terminateCancel 拒绝退出）
TASK_HELPER_SRC="$TASK_HOME/DummyHelper.swift"
cat << 'EOF' > "$TASK_HELPER_SRC"
import AppKit

final class DummyDelegate: NSObject, NSApplicationDelegate {
    let stubborn = ProcessInfo.processInfo.environment["TEST_STUBBORN"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if stubborn {
            return .terminateCancel
        }
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = DummyDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
EOF

swiftc -swift-version 6 "$TASK_HELPER_SRC" -o "$TASK_HOME/DummyHelper"

# 2. 编译测试套件并打包为独立 Bundle，以便准确测试自身应用保护与独立上下文
TASK_APP="$TASK_HOME/Applications/MacEvenCloserChecks.app"
mkdir -p "$TASK_APP/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library -I "$TASK_BIN/Modules" \
    "$TASK_BIN/MacEvenCore.build/"*.o Sources/MacEven/ApplicationCloser.swift Tests/ApplicationCloserChecks.swift \
    -o "$TASK_APP/Contents/MacOS/MacEvenCloserChecks" -lsqlite3
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.maceven.closerchecks' "$TASK_APP/Contents/Info.plist"
codesign --force --sign - "$TASK_APP"

# 3. 运行完整单元检查
"$TASK_APP/Contents/MacOS/MacEvenCloserChecks" "$TASK_HOME" -AppleLanguages '(zh-Hans)'
