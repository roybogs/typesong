#!/bin/zsh
# Builds build/Typesong.app: compiles the Swift host, wraps the engine page, writes Info.plist, signs.
# Signing uses a stable certificate on purpose: macOS keys the Input Monitoring grant to the signature,
# so an ad-hoc signature (new hash every build) would silently drop the permission after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

# Uses TYPESONG_SIGN_IDENTITY if set, else the first "Apple Development" certificate in your keychain,
# else an ad-hoc signature (fine for trying it out; macOS will ask for Input Monitoring again after each rebuild).
IDENTITY="${TYPESONG_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
BUNDLE_ID="com.miguelmendoza.typesong"
VERSION="${TYPESONG_VERSION:-0.1.1}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="build/Typesong.app"

# TYPESONG_UNIVERSAL=1 (set by release.sh) builds one binary for both Apple Silicon and Intel Macs.
ARCHS=(--arch arm64)
[[ "${TYPESONG_UNIVERSAL:-0}" == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Typesong"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Typesong"
cp desktop/src-tauri/icons/icon.icns "$APP/Contents/Resources/AppIcon.icns"   # same logo as Windows/Linux

# The engine is the same page as the web version; give it a real document shell and charset.
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<style>html,body{margin:0}</style>\n</head>\n<body>\n'
  cat Engine/typesong.html
  printf '\n</body>\n</html>\n'
} > "$APP/Contents/Resources/index.html"
ENGINE_SHA="$(shasum -a 256 Engine/typesong.html | cut -c1-12)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Typesong</string>
  <key>CFBundleDisplayName</key><string>Typesong</string>
  <key>CFBundleExecutable</key><string>Typesong</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>TypesongEngineSHA</key><string>${ENGINE_SHA}</string>
</dict>
</plist>
PLIST

# Release builds need a secure timestamp for notarization (TYPESONG_TIMESTAMP=1, set by release.sh).
codesign --force --options runtime ${TYPESONG_TIMESTAMP:+--timestamp} --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP  version ${VERSION} (${BUILD_NUMBER})  engine ${ENGINE_SHA}  for $(lipo -archs "$APP/Contents/MacOS/Typesong")"
