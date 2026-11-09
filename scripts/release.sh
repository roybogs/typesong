#!/bin/zsh
# Builds a release others can open: one binary for Apple Silicon and Intel, signed with Developer ID,
# notarized by Apple, stapled, packed in a DMG.
#   scripts/release.sh 0.1.1           build, sign, notarize, staple, package
#   scripts/release.sh 0.1.1 --check   only check that everything needed is in place, build nothing
# Needs, once:
#   1. Full Xcode, selected with xcode-select.
#   2. A "Developer ID Application" certificate in the keychain (Streetside Films LLC has one).
#   3. A notarytool keychain profile. The first that works is used: $TYPESONG_NOTARY_PROFILE, then
#      "typesong-notary", then "streetside-notary" (the Streetside Films App Store Connect API key profile,
#      which needs no Apple ID password). To make a Typesong-only profile instead:
#        xcrun notarytool store-credentials typesong-notary --apple-id <you> --team-id <team>
#      Nothing secret is stored in this repo.
# The source must be the commit tagged v<version>, so the DMG matches the release it is attached to.
# TYPESONG_ALLOW_UNTAGGED=1 skips that check for a test build.
# Nothing is uploaded or published; the last line prints the upload command for you to run.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--check], e.g. 0.1.1}"
CHECK_ONLY=0; [[ "${2:-}" == "--check" ]] && CHECK_ONLY=1
TAG="v$VERSION"
fail() { echo "STOP: $*" >&2; exit 1; }

echo "==> Checking what a release needs"

# One binary for both chips needs full Xcode; the Command Line Tools alone can't build two architectures at once.
[[ "$(xcode-select -p 2>/dev/null)" == *Xcode*.app* ]] || fail "Full Xcode is needed (App Store), then: sudo xcode-select -s /Applications/Xcode.app"
echo "    Xcode:    $(xcode-select -p)"

# The app's own code must be exactly the tagged commit. Only scripts/release.sh may differ (a newer copy of it).
TAGGED="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
HEAD_SHA="$(git rev-parse HEAD)"
if [[ "${TYPESONG_ALLOW_UNTAGGED:-0}" != 1 ]]; then
  [[ -n "$TAGGED" ]] || fail "There is no tag $TAG here. Run: git fetch --tags"
  [[ "$HEAD_SHA" == "$TAGGED" ]] || fail "This checkout is at ${HEAD_SHA:0:7}, but $TAG is ${TAGGED:0:7}. Run: git checkout $TAG"
  git diff --quiet HEAD -- Sources Engine Package.swift scripts/build.sh desktop/src-tauri/icons \
    || fail "The app's source differs from $TAG (git status shows what). A release must be built from the tag as is."
  echo "    Source:   $TAG (${HEAD_SHA:0:7}), unmodified"
else
  echo "    Source:   ${HEAD_SHA:0:7} (untagged test build)"
fi

# Signing identity: an explicit Developer ID, else the first one in the keychain.
IDENTITY="${TYPESONG_SIGN_IDENTITY:-}"
[[ "$IDENTITY" == "Developer ID Application:"* ]] || IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || fail "No 'Developer ID Application' certificate in the keychain. Create one at developer.apple.com, Certificates, then rerun."
echo "    Signing:  $IDENTITY"

# Notary profile: the first one Apple accepts.
PROFILE=""
for p in ${TYPESONG_NOTARY_PROFILE:-} typesong-notary streetside-notary; do
  if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then PROFILE="$p"; break; fi
done
[[ -n "$PROFILE" ]] || fail "No working notary profile (tried ${TYPESONG_NOTARY_PROFILE:+$TYPESONG_NOTARY_PROFILE, }typesong-notary, streetside-notary). Make one with: xcrun notarytool store-credentials typesong-notary --apple-id <you> --team-id <team>"
echo "    Notary:   keychain profile \"$PROFILE\""

if (( CHECK_ONLY )); then echo "READY: everything needed for $TAG is in place. Run without --check to build."; exit 0; fi

OUT="build/release"; APP="build/Typesong.app"; DMG="$OUT/Typesong-$VERSION.dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

# Submits a file and waits; on rejection prints Apple's reasons before stopping.
notarize() {
  local file="$1" log="$2" id
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait | tee "$log" || true
  if ! grep -q "status: Accepted" "$log"; then
    id="$(sed -n 's/^ *id: *\([0-9a-f-]*\).*/\1/p' "$log" | head -1)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$log.json" >/dev/null 2>&1 && cat "$log.json" >&2
    fail "Apple rejected $(basename "$file"). Its reasons are above and in $log.json"
  fi
}

echo "==> Building $VERSION for Apple Silicon and Intel"
TYPESONG_SIGN_IDENTITY="$IDENTITY" TYPESONG_TIMESTAMP=1 TYPESONG_VERSION="$VERSION" TYPESONG_UNIVERSAL=1 scripts/build.sh
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Typesong")"
[[ "$ARCHS" == *x86_64* ]] || fail "The build is missing the Intel half."
[[ "$ARCHS" == *arm64* ]] || fail "The build is missing the Apple Silicon half."
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail "The app's version is not $VERSION."
[[ "$(codesign -dvv "$APP" 2>&1)" == *flags=*runtime* ]] || fail "The app was signed without the hardened runtime."

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip" "$OUT/notary-app.txt"
xcrun stapler staple "$APP"
rm "$OUT/app.zip"

echo "==> Packing the DMG"
STAGE="$(mktemp -d)"; ditto "$APP" "$STAGE/Typesong.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Typesong" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the DMG"
notarize "$DMG" "$OUT/notary-dmg.txt"
xcrun stapler staple "$DMG"

echo "==> Checking it the way a stranger's Mac will"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tee "$OUT/spctl-app.txt" || true
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tee "$OUT/spctl-dmg.txt" || true
grep -q "accepted" "$OUT/spctl-app.txt" || fail "Gatekeeper does not accept the app."
grep -q "accepted" "$OUT/spctl-dmg.txt" || fail "Gatekeeper does not accept the DMG."
xcrun stapler validate "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")

{
  echo "version=$VERSION source=${HEAD_SHA:0:7} archs=$ARCHS"
  echo "signed=$IDENTITY notary_profile=$PROFILE"
  echo "app=$(head -1 "$OUT/spctl-app.txt")"
  echo "dmg=$(head -1 "$OUT/spctl-dmg.txt")"
  echo "sha256=$(cut -d' ' -f1 "$DMG.sha256") size=$(stat -f %z "$DMG")"
} | tee "$OUT/RESULT.txt"
echo "Ready: $DMG"
echo "To publish it (needs a yes first): gh release upload $TAG \"$DMG\" \"$DMG.sha256\" --repo roybogs/typesong"
