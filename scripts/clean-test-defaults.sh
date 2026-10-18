#!/bin/bash
# 删除检查程序登记的一次性偏好域（见 Tests/TestDefaultsSupport.swift）。
# 必须在检查进程退出后运行：进程内 removePersistentDomain 之后 cfprefsd 仍会写回空 plist。
# 只处理登记文件中逐行列出、且完全符合测试域格式的名字，不使用通配符。
set -uo pipefail
if [ "$#" -ne 1 ]; then echo 'Usage: bash scripts/clean-test-defaults.sh /path/to/defaults-log'; exit 1; fi
TASK_LOG="$1"
[ -f "$TASK_LOG" ] || exit 0
TASK_PREFS="$HOME/Library/Preferences"
while IFS= read -r TASK_SUITE; do
    [ -n "$TASK_SUITE" ] || continue
    if ! [[ "$TASK_SUITE" =~ ^MacEven\.(Test\.Settings|stats\.tests|WindowChecks)\.[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
        echo "跳过不符合测试偏好域格式的登记项：$TASK_SUITE" >&2
        continue
    fi
    # 先经 cfprefsd 删除域（同时清掉其缓存），再删除可能残留的 plist 文件。
    defaults delete "$TASK_SUITE" >/dev/null 2>&1 || true
    rm -f "$TASK_PREFS/$TASK_SUITE.plist"
    if [ -e "$TASK_PREFS/$TASK_SUITE.plist" ]; then echo "未能删除测试偏好域：$TASK_SUITE" >&2; fi
done < "$TASK_LOG"
rm -f "$TASK_LOG"
