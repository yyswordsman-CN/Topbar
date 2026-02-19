#!/bin/bash
# build.sh — Topbar 编译脚本
# 支持两种模式：
#   ./build.sh         仅编译
#   ./build.sh --run   编译后立即运行

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Topbar.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Topbar"

echo "=== Topbar Build ==="

# 优先使用 xcodebuild（如果有 Xcode）
if command -v xcodebuild &>/dev/null && [ -f "$PROJECT_DIR/Topbar.xcodeproj/project.pbxproj" ]; then
    echo "[xcodebuild] 使用 Xcode 编译..."

    # 先重新生成项目（如果有 xcodegen）
    if command -v xcodegen &>/dev/null; then
        (cd "$PROJECT_DIR" && xcodegen generate 2>&1 | head -3)
    fi

    xcodebuild \
        -project "$PROJECT_DIR/Topbar.xcodeproj" \
        -scheme Topbar \
        -configuration Debug \
        build 2>&1 | tail -3

    # 获取编译产物路径
    BUILT_DIR=$(xcodebuild -project "$PROJECT_DIR/Topbar.xcodeproj" -scheme Topbar -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 ' BUILT_PRODUCTS_DIR' | awk '{print $3}')

    if [ "$1" = "--run" ] 2>/dev/null; then
        pkill -x Topbar 2>/dev/null || true
        sleep 0.3
        open "$BUILT_DIR/Topbar.app"
        echo "[OK] 已启动 (Xcode build)"
    fi

else
    # Fallback: 使用 swiftc 直接编译
    echo "[swiftc] Fallback 编译..."

    SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    swiftc \
        -target arm64-apple-macosx14.0 \
        -sdk "$SDK_PATH" \
        -framework SwiftUI \
        -framework AppKit \
        -framework ServiceManagement \
        -parse-as-library \
        -O \
        -o "$EXECUTABLE" \
        "$PROJECT_DIR/Topbar/TopbarApp.swift" \
        "$PROJECT_DIR/Topbar/NotchOverlayManager.swift" \
        "$PROJECT_DIR/Topbar/MenuBarScanner.swift"

    cp "$PROJECT_DIR/Topbar/Info.plist" "$APP_BUNDLE/Contents/"

    if [ "$1" = "--run" ] 2>/dev/null; then
        pkill -x Topbar 2>/dev/null || true
        sleep 0.3
        open "$APP_BUNDLE"
        echo "[OK] 已启动 (swiftc build)"
    fi
fi

echo "=== Done ==="
