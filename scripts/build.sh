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
# TYPESONG_APPSTORE=1 (set by appstore.sh) builds the Mac App Store edition: compiled with -DAPPSTORE (no tip
# link, no agent music), fonts bundled instead of loaded from Google, sandbox entitlements, store Info.plist keys.
STORE="${TYPESONG_APPSTORE:-0}"
SWIFT_FLAGS=()
[[ "$STORE" == 1 ]] && SWIFT_FLAGS=(-Xswiftc -DAPPSTORE --build-path .build/appstore)
swift build -c release "${ARCHS[@]}" "${SWIFT_FLAGS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" "${SWIFT_FLAGS[@]}" --show-bin-path)/Typesong"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Typesong"
cp desktop/src-tauri/icons/icon.icns "$APP/Contents/Resources/AppIcon.icns"   # same logo as Windows/Linux

# The engine is the same page as the web version; give it a real document shell and charset.
# The store edition loads its fonts from the app itself (Engine/fonts, OFL licensed), so it makes no web requests.
FONT_LINK=""
if [[ "$STORE" == 1 ]]; then
  cp -R Engine/fonts "$APP/Contents/Resources/fonts"
  FONT_LINK='<link rel="stylesheet" href="fonts/fonts.css">\n'
fi
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n'"$FONT_LINK"'<style>html,body{margin:0}</style>\n</head>\n<body>\n'
  if [[ "$STORE" == 1 ]]; then grep -v 'fonts.googleapis.com' Engine/typesong.html; else cat Engine/typesong.html; fi
  printf '\n</body>\n</html>\n'
} > "$APP/Contents/Resources/index.html"
if [[ "$STORE" == 1 ]] && grep -q 'googleapis\|gstatic' "$APP/Contents/Resources/index.html"; then
  echo "STOP: the store edition's page still points at Google Fonts." >&2; exit 1
fi
ENGINE_SHA="$(shasum -a 256 Engine/typesong.html | cut -c1-12)"

STORE_KEYS=""
if [[ "$STORE" == 1 ]]; then
  STORE_KEYS='  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Streetside Films LLC</string>'
fi

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
${STORE_KEYS}
</dict>
</plist>
PLIST

# The store edition carries its provisioning profile (TYPESONG_PROFILE) and sandbox entitlements
# (TYPESONG_ENTITLEMENTS); both are passed in by appstore.sh.
[[ -n "${TYPESONG_PROFILE:-}" ]] && cp "$TYPESONG_PROFILE" "$APP/Contents/embedded.provisionprofile"
ENT_ARGS=()
[[ -n "${TYPESONG_ENTITLEMENTS:-}" ]] && ENT_ARGS=(--entitlements "$TYPESONG_ENTITLEMENTS")

# Release builds need a secure timestamp for notarization (TYPESONG_TIMESTAMP=1, set by release.sh).
codesign --force --options runtime ${TYPESONG_TIMESTAMP:+--timestamp} "${ENT_ARGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP  version ${VERSION} (${BUILD_NUMBER})  engine ${ENGINE_SHA}  for $(lipo -archs "$APP/Contents/MacOS/Typesong")"
