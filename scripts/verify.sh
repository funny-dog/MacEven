#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_MODE="fast"
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--fast" ]; then
        TASK_MODE="fast"
    elif [ "$#" -eq 1 ] && [ "$1" = "--full" ]; then
        TASK_MODE="full"
    else
        echo "未知参数: $*" >&2
        echo "用法: $0 [--fast|--full]" >&2
        exit 1
    fi
elif [ -n "${MACEVEN_VERIFY_MODE:-}" ]; then
    if [ "$MACEVEN_VERIFY_MODE" = "full" ]; then
        TASK_MODE="full"
    elif [ "$MACEVEN_VERIFY_MODE" = "fast" ]; then
        TASK_MODE="fast"
    else
        echo "未知 MACEVEN_VERIFY_MODE: $MACEVEN_VERIFY_MODE" >&2
        echo "合法取值: fast | full" >&2
        exit 1
    fi
fi

if [ "$TASK_MODE" = "fast" ]; then
    echo "=== [MacEven Verify] 运行 fast 模式（轻量探针，本地开发与常规交付） ==="
    PROBE_FILES=5000
    PROBE_ROUNDS=1
    DUP_ROUNDS=1
else
    echo "=== [MacEven Verify] 运行 full 模式（10万级真实文件全量压力探针，远程发布） ==="
    PROBE_FILES=100000
    PROBE_ROUNDS=5
    DUP_ROUNDS=3
fi

bash scripts/check-localization.sh
swift run --build-system native MacEvenChecks -AppleLanguages '(zh-Hans)'
bash scripts/check-model.sh
bash scripts/check-disk-layout.sh
bash scripts/check-popover-layout.sh
bash scripts/check-treemap.sh
bash scripts/check-developer-cleanup.sh
bash scripts/check-developer-cleanup-model.sh
bash scripts/check-application-closer.sh
bash scripts/check-cache-model.sh
bash scripts/check-application-model.sh
bash scripts/check-dock.sh
bash scripts/check-smart-scan.sh
bash scripts/check-ai-work-cleanup.sh
bash scripts/check-cleanup-layout.sh
bash scripts/check-sidebar-collapse.sh
bash scripts/check-software.sh
bash scripts/check-software-model.sh
bash scripts/check-startup-items.sh
bash scripts/check-duplicate-model.sh
bash scripts/check-install.sh
swift run --build-system native -c release MacEvenProbe --files "$PROBE_FILES" --rounds "$PROBE_ROUNDS"
swift run --build-system native -c release MacEvenDuplicateProbe --files "$PROBE_FILES" --rounds "$DUP_ROUNDS"
swift run --build-system native MacEvenMonitorChecks -AppleLanguages '(zh-Hans)'
bash scripts/check-monitor-model.sh
bash scripts/check-process.sh
bash scripts/check-status.sh
bash scripts/build.sh --build-only

