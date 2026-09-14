#!/bin/bash
#
# 从「已发布的 gemstone-swift」构建一个可在 iOS 模拟器里运行的 App
#
# 用法: ./build.sh [模拟器名]          默认 "iPhone 17"
#
# 为什么不用 Xcode 工程：
#   这个 demo 的目的是验证**已发布制品**能被下游真实消费。手工 swiftc 的好处是
#   每一步（取包 → 编 module → 链接 → 装包）都显式可见，出问题能精确定位到哪一环。
#   真实项目当然用 Xcode 工程 + SPM 依赖，见 README。
#
set -euo pipefail

cd "$(dirname "$0")"

SIM_NAME="${1:-iPhone 17}"
BUNDLE_ID="com.example.gemiosdemo"
TARGET="arm64-apple-ios17.0-simulator"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }

# ── 1. 取已发布的包 ────────────────────────────────────────
step "解析 gemstone-swift（下载 XCFramework 并校验 checksum）"
swift package resolve

XCF=".build/artifacts/gemstone-swift/GemstoneFFI/GemstoneFFI.xcframework/ios-arm64-simulator"
GEN=".build/checkouts/gemstone-swift/Sources/Gemstone/Gemstone.swift"

[ -d "$XCF" ] || { echo "error: 找不到模拟器切片 $XCF" >&2; exit 1; }
[ -f "$GEN" ] || { echo "error: 找不到 Gemstone.swift" >&2; exit 1; }
info "切片: $XCF"
info "绑定: $(wc -l < "$GEN") 行"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
rm -rf build && mkdir -p build

# ── 2. Gemstone 编成独立 module ────────────────────────────
# 🔴 必须单独编：和 App.swift 一起编的话两者会并进同一个 module，
#    App 里的 `import Gemstone` 会报 "no such module"。
#
# -I "$XCF/Headers" 就够了 —— module.modulemap 和 GemstoneFFI.h 同目录，
# clang 会自动发现。实测不需要 -Xcc -fmodule-map-file，也不需要 -Xcc -isysroot。
step "编译 Gemstone module"
swiftc -target "$TARGET" -sdk "$SDK" \
    -module-name Gemstone \
    -emit-module -emit-module-path build/Gemstone.swiftmodule \
    -emit-library -static -o build/libGemstoneSwift.a \
    -I "$XCF/Headers" \
    "$GEN"
info "libGemstoneSwift.a $(du -h build/libGemstoneSwift.a | cut -f1)"

# ── 3. 编 App ──────────────────────────────────────────────
# ⚠️ 这一步会出一条 clang warning: using sysroot for 'MacOSX' but targeting 'iPhone'。
#    已确认无害：换任何 -Xcc 组合都照样出现，且产物的 LC_BUILD_VERSION 是
#    platform IOSSIMULATOR / minos 17.0，链接的也全是 iOS 框架。
#    是 swiftc 内部调用链接器驱动时带出来的，与本脚本的参数无关。
step "编译 App 并链接"
swiftc -target "$TARGET" -sdk "$SDK" -parse-as-library \
    -I build -I "$XCF/Headers" \
    -L build -lGemstoneSwift \
    -L "$XCF" -lgemstone \
    App.swift -o build/GemIOSDemo
info "可执行文件 $(du -h build/GemIOSDemo | cut -f1)"

# 自检：确认不是误编成 macOS 产物
vtool -show-build-version build/GemIOSDemo 2>/dev/null | grep -q "IOSSIMULATOR" \
    || { echo "error: 产物平台不是 IOSSIMULATOR" >&2; exit 1; }
info "平台自检通过（IOSSIMULATOR）"

# ── 4. 组 .app bundle ──────────────────────────────────────
step "组装 .app bundle"
APP="build/GemIOSDemo.app"
mkdir -p "$APP"
cp build/GemIOSDemo "$APP/"
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GemIOSDemo</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>GemIOSDemo</string>
    <key>CFBundleDisplayName</key><string>Gem iOS Demo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.114.10</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>17.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
    <key>UILaunchScreen</key><dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
EOF
plutil -lint "$APP/Info.plist" >/dev/null
info "bundle $(du -sh "$APP" | cut -f1)"

# ── 5. 装进模拟器并启动 ────────────────────────────────────
# 🔴 必须写 ${SIM_NAME}：全角「）」会被 bash 当成变量名的一部分，
#    在 set -u 下直接报 unbound variable。中文括号紧跟变量时都要显式界定。
step "安装并启动（${SIM_NAME}）"
UDID=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || { echo "error: 找不到模拟器「$SIM_NAME」" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
open -a Simulator

xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

printf '\n\033[32m✅ 已启动\033[0m  截图: xcrun simctl io %s screenshot /tmp/s.png\n' "$UDID"
