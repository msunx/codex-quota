#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
MODULE_CACHE="$BUILD_DIR/module-cache"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/Codex Quota.app"
EXPECTED_APP_PATH="$PROJECT_DIR/dist/Codex Quota.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
ICONSET_PATH="$BUILD_DIR/AppIcon.iconset"
ICON_PATH="$RESOURCES_PATH/AppIcon.icns"
ICON_GENERATOR="$BUILD_DIR/generate-icon"

if [[ "$APP_PATH" != "$EXPECTED_APP_PATH" ]]; then
    print -u2 "拒绝清理意外路径：$APP_PATH"
    exit 1
fi

if [[ ! -x /usr/bin/clang ]]; then
    print -u2 "未找到 Apple Clang。请运行：xcode-select --install"
    exit 1
fi

/bin/rm -rf "$APP_PATH" "$ICONSET_PATH"
/bin/mkdir -p "$MACOS_PATH" "$RESOURCES_PATH" "$MODULE_CACHE" "$ICONSET_PATH"

/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Os \
    -DNDEBUG \
    -Wall \
    -Wextra \
    -I "$PROJECT_DIR/Sources/CodexQuota" \
    "$PROJECT_DIR"/Sources/CodexQuota/*.m \
    -framework Cocoa \
    -framework QuartzCore \
    -framework Network \
    -framework Security \
    -framework ServiceManagement \
    -lsqlite3 \
    -o "$MACOS_PATH/CodexQuota"

/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -Os \
    -DNDEBUG \
    -Wall \
    -Wextra \
    "$PROJECT_DIR/Sources/HistoryBridge/main.m" \
    -framework Foundation \
    -o "$MACOS_PATH/CodexQuotaHistoryBridge"

/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"

/usr/bin/clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    "$PROJECT_DIR/scripts/generate_icon.m" \
    -framework Cocoa \
    -o "$ICON_GENERATOR"

"$ICON_GENERATOR" "$ICONSET_PATH" "$ICON_PATH"

/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

print "已生成：$APP_PATH"
print "无需完整 Xcode，也无需升级 macOS。"
