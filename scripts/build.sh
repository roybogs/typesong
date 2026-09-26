#!/bin/zsh
# Builds build/Typesong.app: compiles the Swift host, wraps the engine page, writes Info.plist, signs.
# Signing uses a stable certificate on purpose: macOS keys the Input Monitoring grant to the signature,
# so an ad-hoc signature (new hash every build) would silently drop the permission after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${TYPESONG_SIGN_IDENTITY:-Apple Development: 1mendozamiguel@gmail.com (9Y3KQJS852)}"
BUNDLE_ID="com.miguelmendoza.typesong"
VERSION="0.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="build/Typesong.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Typesong"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Typesong"

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

codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP  version ${VERSION} (${BUILD_NUMBER})  engine ${ENGINE_SHA}"
