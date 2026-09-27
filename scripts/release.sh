#!/bin/zsh
# Builds a release others can open: one binary for Apple Silicon and Intel, signed with Developer ID,
# notarized by Apple, stapled, packed in a DMG.
#   scripts/release.sh 1.0.0
# Needs, once:
#   1. A "Developer ID Application" certificate in your keychain (Apple Developer Program → Certificates).
#   2. Notary credentials saved under the profile name "typesong-notary":
#        xcrun notarytool store-credentials typesong-notary --apple-id <you> --team-id <team>
#      (it prompts for an app-specific password from account.apple.com; nothing is stored in this repo)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.0.0}"
PROFILE="${TYPESONG_NOTARY_PROFILE:-typesong-notary}"
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate in the keychain. Create one at developer.apple.com → Certificates, then rerun." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "Notary profile '$PROFILE' not found or not working. Run: xcrun notarytool store-credentials $PROFILE --apple-id <you> --team-id <team>" >&2; exit 1; }

OUT="build/release"; APP="build/Typesong.app"; DMG="$OUT/Typesong-$VERSION.dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Building $VERSION, signed as: $IDENTITY"
TYPESONG_SIGN_IDENTITY="$IDENTITY" TYPESONG_TIMESTAMP=1 TYPESONG_VERSION="$VERSION" TYPESONG_UNIVERSAL=1 scripts/build.sh
lipo -archs "$APP/Contents/MacOS/Typesong" | grep -q x86_64 || { echo "The build is missing the Intel half." >&2; exit 1; }

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-app.txt"
grep -q "status: Accepted" "$OUT/notary-app.txt" || { echo "Apple rejected the app. Details: xcrun notarytool log <id> --keychain-profile $PROFILE" >&2; exit 1; }
xcrun stapler staple "$APP"
rm "$OUT/app.zip"

echo "==> Packing the DMG"
STAGE="$(mktemp -d)"; ditto "$APP" "$STAGE/Typesong.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Typesong" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-dmg.txt"
grep -q "status: Accepted" "$OUT/notary-dmg.txt" || { echo "Apple rejected the DMG." >&2; exit 1; }
xcrun stapler staple "$DMG"

echo "==> Checking it the way a stranger's Mac will"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Ready: $DMG"
