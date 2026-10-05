#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/MoniView.app"

swift build --package-path "$PROJECT_ROOT" -c release --product MoniView

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$PROJECT_ROOT/.build/release/MoniView" "$APP_BUNDLE/Contents/MacOS/MoniView"
cp "$PROJECT_ROOT/Resources/MoniView.icns" "$APP_BUNDLE/Contents/Resources/MoniView.icns"
cp "$PROJECT_ROOT/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R "$PROJECT_ROOT/Resources/en.lproj" "$PROJECT_ROOT/Resources/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
