#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/MoniView.app"

# Optional overrides. Defaults keep the local development build working as before.
#   MONIVIEW_VERSION / MONIVIEW_BUILD  override the bundled version strings
#   MONIVIEW_ARCH                      pass an explicit architecture (for example arm64 or x86_64)
#   MONIVIEW_ENTITLEMENTS=1            sign with Resources/MoniView.entitlements for sandbox verification
#   MONIVIEW_SIGN_IDENTITY             codesign identity; defaults to ad-hoc "-"
#   MONIVIEW_SIGN_KEYCHAIN             extra keychain holding a local stable signing identity
#   MONIVIEW_SIGN_KEYCHAIN_PASSWORD_FILE  password file used to unlock that keychain first
#   MONIVIEW_DISABLE_AI=1              compile spatial fallback without SDK 26 ML symbols
MONIVIEW_VERSION="${MONIVIEW_VERSION:-}"
MONIVIEW_BUILD="${MONIVIEW_BUILD:-}"
MONIVIEW_ARCH="${MONIVIEW_ARCH:-}"
MONIVIEW_ENTITLEMENTS="${MONIVIEW_ENTITLEMENTS:-0}"
MONIVIEW_SIGN_IDENTITY="${MONIVIEW_SIGN_IDENTITY:--}"
MONIVIEW_SIGN_KEYCHAIN="${MONIVIEW_SIGN_KEYCHAIN:-}"
MONIVIEW_SIGN_KEYCHAIN_PASSWORD_FILE="${MONIVIEW_SIGN_KEYCHAIN_PASSWORD_FILE:-$HOME/.config/moniview/signing-keychain-password}"
MONIVIEW_DISABLE_AI="${MONIVIEW_DISABLE_AI:-0}"

BUILD_ARGS=(--package-path "$PROJECT_ROOT" -c release --product MoniView)
if [[ -n "$MONIVIEW_ARCH" ]]; then BUILD_ARGS+=(--arch "$MONIVIEW_ARCH"); fi
if [[ "$MONIVIEW_DISABLE_AI" == "1" ]]; then BUILD_ARGS+=(-Xswiftc -DMONIVIEW_DISABLE_AI); fi

swift build "${BUILD_ARGS[@]}"

# Resolve the produced binary from the actual build configuration instead of assuming a path.
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/MoniView"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/MoniView"
cp "$PROJECT_ROOT/Resources/MoniView.icns" "$APP_BUNDLE/Contents/Resources/MoniView.icns"
cp "$PROJECT_ROOT/Resources/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
cp -R "$PROJECT_ROOT/Resources/en.lproj" "$PROJECT_ROOT/Resources/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Stamp the requested version so a release artifact does not depend on the checked-in plist.
if [[ -n "$MONIVIEW_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MONIVIEW_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "$MONIVIEW_BUILD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MONIVIEW_BUILD" "$APP_BUNDLE/Contents/Info.plist"
fi

SIGN_ARGS=(--force --sign "$MONIVIEW_SIGN_IDENTITY")
if [[ -n "$MONIVIEW_SIGN_KEYCHAIN" ]]; then
  if [[ -f "$MONIVIEW_SIGN_KEYCHAIN_PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(cat "$MONIVIEW_SIGN_KEYCHAIN_PASSWORD_FILE")" "$MONIVIEW_SIGN_KEYCHAIN"
  fi
  SIGN_ARGS+=(--keychain "$MONIVIEW_SIGN_KEYCHAIN")
fi
if [[ "$MONIVIEW_ENTITLEMENTS" == "1" ]]; then
  SIGN_ARGS+=(--entitlements "$PROJECT_ROOT/Resources/MoniView.entitlements" --options runtime)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# Verify the artifact instead of assuming the signing step did what was asked.
codesign --verify --strict "$APP_BUNDLE"
if [[ "$MONIVIEW_ENTITLEMENTS" == "1" ]]; then
  codesign -d --entitlements - "$APP_BUNDLE" 2>&1 | grep -q 'com.apple.security.app-sandbox' || {
    echo "error: sandbox entitlement missing from signed bundle" >&2
    exit 1
  }
fi
for resource in MoniView.icns PrivacyInfo.xcprivacy en.lproj/Localizable.strings zh-Hans.lproj/Localizable.strings; do
  [[ -e "$APP_BUNDLE/Contents/Resources/$resource" ]] || { echo "error: missing $resource" >&2; exit 1; }
done

echo "Built: $APP_BUNDLE"
echo "Architecture: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/MoniView")"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist"))"
