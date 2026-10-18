#!/bin/bash
# 重新生成 Resources/AppIcon.icns 和预览图；图标源是 scripts/make-icon.swift。
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_WORK="$(mktemp -d "${TMPDIR:-/tmp}/maceven-icon.XXXXXX")"
trap 'rm -rf "$TASK_WORK"' EXIT
mkdir -p docs/design/app-icon
swift scripts/make-icon.swift "$TASK_WORK/AppIcon.iconset" docs/design/app-icon/AppIcon-1024.png
iconutil -c icns "$TASK_WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "已更新 Resources/AppIcon.icns"
