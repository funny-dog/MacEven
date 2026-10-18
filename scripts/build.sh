#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"

TASK_BUILD_ONLY=0
TASK_PACKAGE=0
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--build-only" ]; then
        TASK_BUILD_ONLY=1
    elif [ "$#" -eq 1 ] && [ "$1" = "--package" ]; then
        TASK_PACKAGE=1
    else
        echo "未知参数: $*" >&2
        echo "用法: $0 [--build-only|--package]" >&2
        exit 1
    fi
fi

swift build --build-system native -c release --product MacEven
TASK_BIN="$(swift build --build-system native -c release --show-bin-path)"
TASK_APP="$TASK_ROOT/dist/MacEven.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN/MacEven" "$TASK_APP/Contents/MacOS/MacEven"
cp Resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$TASK_APP/Contents/Resources/AppIcon.icns"
ditto "$TASK_BIN/MacEven_MacEvenCore.bundle" "$TASK_APP/Contents/Resources/MacEven_MacEvenCore.bundle"
plutil -lint "$TASK_APP/Contents/Info.plist"
# 图标文件必须与 Info.plist 声明一致，否则安装后 Dock 与 Finder 显示默认图标
[ "$(plutil -extract CFBundleIconFile raw "$TASK_APP/Contents/Info.plist")" = AppIcon ]
[ -s "$TASK_APP/Contents/Resources/AppIcon.icns" ]

SIGN_IDENTITY_NAME="${MACEVEN_SIGN_IDENTITY:-MacEven Self-Signed}"
identities="$(security find-identity -p codesigning ${MACEVEN_KEYCHAIN:+"$MACEVEN_KEYCHAIN"} 2>/dev/null || true)"
if [[ "$identities" == *"\"$SIGN_IDENTITY_NAME\""* ]]; then
    SIGN_IDENTITY="$SIGN_IDENTITY_NAME"
    echo "使用证书签名：$SIGN_IDENTITY"
    if [ -n "${MACEVEN_KEYCHAIN:-}" ]; then
        codesign -s "$SIGN_IDENTITY" --keychain "$MACEVEN_KEYCHAIN" --force -o runtime --entitlements "$TASK_ROOT/Resources/MacEven.entitlements" "$TASK_APP"
    else
        codesign -s "$SIGN_IDENTITY" --force -o runtime --entitlements "$TASK_ROOT/Resources/MacEven.entitlements" "$TASK_APP"
    fi
else
    SIGN_IDENTITY="-"
    echo "警告：未找到签名证书「${SIGN_IDENTITY_NAME}」，退回 ad-hoc 签名" >&2
    codesign --force --sign - "$TASK_APP"
fi

codesign --verify --strict "$TASK_APP"

if [ "$SIGN_IDENTITY" != "-" ]; then
    sig_info="$(codesign -dv "$TASK_APP" 2>&1)"
    if [[ "$sig_info" != *"flags="*"runtime"* ]]; then
        echo "错误：$TASK_APP 未启用 Hardened Runtime" >&2
        exit 1
    fi
fi

if [ "$TASK_BUILD_ONLY" -eq 1 ]; then
    echo "$TASK_APP"
    exit 0
fi

if [ "$TASK_PACKAGE" -eq 1 ]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw "$TASK_APP/Contents/Info.plist")"
    STAGE_DIR="$TASK_ROOT/build/dmg-stage"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    ditto "$TASK_APP" "$STAGE_DIR/MacEven.app"
    ln -shf /Applications "$STAGE_DIR/Applications"

    mkdir -p "$TASK_ROOT/build"
    rm -f "$TASK_ROOT/build/MacEven-$VERSION.dmg" "$TASK_ROOT/MacEven.dmg" "$TASK_ROOT/build/MacEven-v$VERSION.zip" "$TASK_ROOT/MacEven-v$VERSION.zip" "$TASK_ROOT/build/MacEven-v$VERSION.zip.sha256" "$TASK_ROOT/MacEven-v$VERSION.zip.sha256"

    hdiutil create -volname "MacEven" -srcfolder "$STAGE_DIR" -ov -format UDZO "$TASK_ROOT/build/MacEven-$VERSION.dmg"
    cp "$TASK_ROOT/build/MacEven-$VERSION.dmg" "$TASK_ROOT/MacEven.dmg"

    (cd "$STAGE_DIR" && zip -ry "$TASK_ROOT/build/MacEven-v$VERSION.zip" MacEven.app)
    cp "$TASK_ROOT/build/MacEven-v$VERSION.zip" "$TASK_ROOT/MacEven-v$VERSION.zip"

    (cd "$TASK_ROOT" && shasum -a 256 "MacEven-v$VERSION.zip" > "MacEven-v$VERSION.zip.sha256")
    cp "$TASK_ROOT/MacEven-v$VERSION.zip.sha256" "$TASK_ROOT/build/MacEven-v$VERSION.zip.sha256"

    echo "=== 构建与打包完成！==="
    echo "DMG 产物: $TASK_ROOT/MacEven.dmg (及 build/MacEven-$VERSION.dmg)"
    echo "ZIP 产物: $TASK_ROOT/MacEven-v$VERSION.zip"
    echo "SHA256:  $TASK_ROOT/MacEven-v$VERSION.zip.sha256"
    exit 0
fi

# 让 LaunchServices / 访达重新读取已安装包的图标与 Info.plist；check-install.sh 会替换成假的同名函数。
lsregister() { /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister "$@"; }

TASK_INSTALLED="/Applications/MacEven.app"
TASK_INSTALL_DIR="$(dirname "$TASK_INSTALLED")"
TASK_STAGE="$(mktemp -d "$TASK_INSTALL_DIR/.MacEven-install.XXXXXX")"
TASK_SUCCESS=0
TASK_REOPEN=0
TASK_REPLACED=0
cleanup() {
    local status=$?
    if [ "$TASK_SUCCESS" -ne 1 ] && [ -d "$TASK_STAGE/previous.app" ]; then
        if [ -e "$TASK_INSTALLED" ]; then
            if ! mv "$TASK_INSTALLED" "$TASK_STAGE/failed.app"; then
                echo "无法恢复安装，旧版保留在 $TASK_STAGE/previous.app" >&2
                return "$status"
            fi
        fi
        if ! mv "$TASK_STAGE/previous.app" "$TASK_INSTALLED"; then
            echo "无法恢复安装，旧版保留在 $TASK_STAGE/previous.app" >&2
            return "$status"
        fi
        if [ "$TASK_REOPEN" -eq 1 ]; then open "$TASK_INSTALLED" || true; fi
    elif [ "$TASK_SUCCESS" -ne 1 ] && [ "$TASK_REPLACED" -eq 1 ]; then
        if ! mv "$TASK_INSTALLED" "$TASK_STAGE/failed.app"; then
            echo "无法撤回失败的首次安装：$TASK_INSTALLED" >&2
            return "$status"
        fi
    fi
    rm -rf "$TASK_STAGE"
}
trap cleanup EXIT

ditto "$TASK_APP" "$TASK_STAGE/MacEven.app"
# ditto 保留 dist 包目录的旧修改时间；访达按包的修改时间判断图标缓存是否过期，所以安装时刷新它。
touch "$TASK_STAGE/MacEven.app"
codesign --verify --strict "$TASK_STAGE/MacEven.app"
if [ -L "$TASK_INSTALLED" ] || { [ -e "$TASK_INSTALLED" ] && [ ! -d "$TASK_INSTALLED" ]; }; then
    echo "安装目标必须是实际 App 目录：$TASK_INSTALLED" >&2
    exit 1
fi
TASK_PIDS="$(ps -axo pid=,comm= | awk -v path="$TASK_INSTALLED/Contents/MacOS/MacEven" '$2 == path {print $1}')"
if [ -n "$TASK_PIDS" ]; then
    TASK_REOPEN=1
    for TASK_PID in $TASK_PIDS; do
        if ! kill -TERM "$TASK_PID" 2>/dev/null && kill -0 "$TASK_PID" 2>/dev/null; then
            echo "无法通知 MacEven 退出，保留现有安装。" >&2
            exit 1
        fi
        TASK_WAIT=0
        while kill -0 "$TASK_PID" 2>/dev/null; do
            if [ "$TASK_WAIT" -ge 150 ]; then
                echo "MacEven 未完成退出，保留现有安装，请稍后重试。" >&2
                exit 1
            fi
            sleep 0.2
            TASK_WAIT=$((TASK_WAIT + 1))
        done
    done
fi
if [ -d "$TASK_INSTALLED" ]; then mv "$TASK_INSTALLED" "$TASK_STAGE/previous.app"; fi
mv "$TASK_STAGE/MacEven.app" "$TASK_INSTALLED"
TASK_REPLACED=1
codesign --verify --strict "$TASK_INSTALLED"
diff -qr "$TASK_APP" "$TASK_INSTALLED"
lsregister -f "$TASK_INSTALLED" >/dev/null 2>&1 || true
if [ "$TASK_REOPEN" -eq 1 ]; then open "$TASK_INSTALLED"; fi
TASK_SUCCESS=1
echo "已构建并安装：$TASK_INSTALLED"
echo "构建产物：$TASK_APP"
