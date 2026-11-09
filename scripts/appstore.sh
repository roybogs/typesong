#!/bin/zsh
# Builds the Mac App Store edition of Typesong: sandboxed, no tip link, no agent music, fonts bundled.
#   scripts/appstore.sh --check   check that everything a store build needs is in place, build nothing
#   scripts/appstore.sh --dev     sandboxed test build signed for development, then runs the self-test
#                                 inside the sandbox and reads its health log (the store build itself can't
#                                 run outside the store, so this is how the sandbox is proven)
#   scripts/appstore.sh 1.0       store build: Apple Distribution signature, provisioning profile embedded,
#                                 signed installer package, validated with App Store Connect
# Needs:
#   1. Full Xcode, selected with xcode-select.
#   2. An "Apple Distribution" certificate (signs the app) and a "3rd Party Mac Developer Installer"
#      (Mac Installer Distribution) certificate (signs the .pkg), both for team Streetside Films LLC.
#   3. TYPESONG_PROFILE: path to a Mac App Store provisioning profile for com.miguelmendoza.typesong.
#   4. To validate: an App Store Connect API key. TYPESONG_ASC_KEY_ID and TYPESONG_ASC_ISSUER, and the
#      AuthKey_<id>.p8 file at TYPESONG_ASC_KEY_FILE or in ~/.appstoreconnect/private_keys or ~/private_keys.
#      Nothing secret is stored in this repo.
# Validation fails with "no suitable application records" until the app exists in App Store Connect;
# the script says so plainly and stops there. Nothing is uploaded or submitted: the last line prints
# the upload command for you to run.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:?usage: scripts/appstore.sh --check | --dev | <version>, e.g. 1.0}"
BUNDLE_ID="com.miguelmendoza.typesong"
APP="build/Typesong.app"
OUT="build/appstore"
BASE_ENT="scripts/Typesong-AppStore.entitlements"
fail() { echo "STOP: $*" >&2; exit 1; }
pick() { print -r -- "$1" | sed -n "s/.*\"\\($2: [^\"]*\\)\".*/\\1/p" | head -1; }

echo "==> Checking what a store build needs"
[[ "$(xcode-select -p 2>/dev/null)" == *Xcode*.app* ]] || fail "Full Xcode is needed (App Store), then: sudo xcode-select -s /Applications/Xcode.app"
echo "    Xcode:      $(xcode-select -p)"
CODESIGN_IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
ALL_IDS="$(security find-identity -v 2>/dev/null || true)"   # installer certificates are not code signing identities

# ---------- --dev: sandboxed development build plus a self-test inside the sandbox ----------
if [[ "$MODE" == --dev ]]; then
  DEV_ID="${TYPESONG_SIGN_IDENTITY:-$(pick "$CODESIGN_IDS" "Apple Development")}"
  [[ -n "$DEV_ID" ]] || fail "No 'Apple Development' certificate in the keychain."
  echo "    Signing:    $DEV_ID (development, sandbox on)"
  echo "==> Building the store edition for this Mac"
  TYPESONG_APPSTORE=1 TYPESONG_SIGN_IDENTITY="$DEV_ID" TYPESONG_ENTITLEMENTS="$BASE_ENT" \
    TYPESONG_VERSION="${TYPESONG_VERSION:-1.0}" scripts/build.sh
  ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  [[ "$ENTS" == *com.apple.security.app-sandbox* ]] || fail "The app was signed without the sandbox entitlement."
  [[ -f "$APP/Contents/Resources/fonts/fonts.css" ]] || fail "The fonts are not in the app."

  LOG="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Logs/Typesong/health.log"
  BEFORE=0; [[ -f "$LOG" ]] && BEFORE="$(wc -l < "$LOG" | tr -d ' ')"
  echo "==> Running the self-test inside the sandbox (25 seconds, plays a little music)"
  "$APP/Contents/MacOS/Typesong" --selftest >/dev/null 2>&1 &
  PID=$!
  sleep 25
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  [[ -f "$LOG" ]] || fail "No health log in the sandbox container ($LOG). The app did not start sandboxed."
  NEW="$(tail -n +$((BEFORE + 1)) "$LOG")"
  print -r -- "$NEW" | sed 's/^/    log: /' | tail -12
  [[ "$NEW" == *"launch: edition=appstore sandboxed=true"* ]] || fail "The app did not report edition=appstore sandboxed=true."
  [[ "$NEW" == *"selftest: page loaded"* ]] || fail "The engine page did not load inside the sandbox."
  [[ "$NEW" == *"ticks/5s="* ]] || fail "The engine never reported its health inside the sandbox."
  echo "DEV OK: the store edition runs sandboxed, loads its page and fonts, and plays."
  exit 0
fi

# ---------- store build (and --check) ----------
CHECK_ONLY=0
if [[ "$MODE" == --check ]]; then CHECK_ONLY=1; VERSION="${TYPESONG_VERSION:-1.0}"; else VERSION="$MODE"; fi
[[ "$VERSION" == [0-9]* ]] || fail "The version should look like 1.0, not '$VERSION'."

SRC_SHA="$(git rev-parse HEAD)"
if [[ "${TYPESONG_ALLOW_DIRTY:-0}" != 1 ]]; then
  git diff --quiet HEAD -- Sources Engine Package.swift scripts desktop/src-tauri/icons \
    || fail "The source has uncommitted changes (git status shows what). Commit them, or TYPESONG_ALLOW_DIRTY=1 for a test build."
fi
echo "    Source:     ${SRC_SHA:0:7} ($(git rev-parse --abbrev-ref HEAD))"

APP_ID="${TYPESONG_STORE_IDENTITY:-$(pick "$CODESIGN_IDS" "Apple Distribution")}"
[[ -n "$APP_ID" ]] || APP_ID="$(pick "$CODESIGN_IDS" "3rd Party Mac Developer Application")"
[[ -n "$APP_ID" ]] || fail "No 'Apple Distribution' certificate in the keychain."
echo "    App cert:   $APP_ID"

INST_ID="${TYPESONG_INSTALLER_IDENTITY:-$(pick "$ALL_IDS" "3rd Party Mac Developer Installer")}"
[[ -n "$INST_ID" ]] || INST_ID="$(pick "$ALL_IDS" "Mac Installer Distribution")"
[[ -n "$INST_ID" ]] || fail "No Mac Installer Distribution ('3rd Party Mac Developer Installer') certificate in the keychain. Create one (certificate type MAC_INSTALLER_DISTRIBUTION) and import it."
echo "    Pkg cert:   $INST_ID"

PROFILE="${TYPESONG_PROFILE:-}"
[[ -n "$PROFILE" && -f "$PROFILE" ]] || fail "Set TYPESONG_PROFILE to a Mac App Store provisioning profile for $BUNDLE_ID."
PROFILE_PLIST="$(mktemp)"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null || fail "Can't read the provisioning profile $PROFILE."
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PROFILE_PLIST" 2>/dev/null || true; }
TEAM="$(pb TeamIdentifier:0)"
[[ -n "$TEAM" ]] || fail "The provisioning profile has no team."
[[ "$(pb Entitlements:com.apple.application-identifier)" == "$TEAM.$BUNDLE_ID" ]] \
  || fail "The provisioning profile is for $(pb Entitlements:com.apple.application-identifier), not $TEAM.$BUNDLE_ID."
[[ -z "$(pb ProvisionedDevices)" ]] || fail "That is a development profile (it lists devices). A Mac App Store profile is needed."
[[ "$(pb Platform)" == *OSX* ]] || fail "That provisioning profile is not for macOS."
echo "    Profile:    $(pb Name) (team $TEAM, expires $(pb ExpirationDate))"

KEY_ID="${TYPESONG_ASC_KEY_ID:-}"; ISSUER="${TYPESONG_ASC_ISSUER:-}"
[[ -n "$KEY_ID" && -n "$ISSUER" ]] || fail "Set TYPESONG_ASC_KEY_ID and TYPESONG_ASC_ISSUER (App Store Connect API key) to validate."
KEY_FILE="${TYPESONG_ASC_KEY_FILE:-}"
if [[ -z "$KEY_FILE" ]]; then
  for d in "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys" "$HOME/.private_keys"; do
    [[ -f "$d/AuthKey_$KEY_ID.p8" ]] && { KEY_FILE="$d/AuthKey_$KEY_ID.p8"; break; }
  done
fi
[[ -n "$KEY_FILE" && -f "$KEY_FILE" ]] || fail "No AuthKey_$KEY_ID.p8 found. Set TYPESONG_ASC_KEY_FILE to its path."
echo "    API key:    $KEY_ID (file found, not printed)"

if (( CHECK_ONLY )); then echo "READY: everything a store build of $VERSION needs is in place. Run: scripts/appstore.sh $VERSION"; exit 0; fi

rm -rf "$OUT"; mkdir -p "$OUT"
ENT="$OUT/app.entitlements"
cp "$BASE_ENT" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"

echo "==> Building the store edition $VERSION for Apple Silicon and Intel"
TYPESONG_APPSTORE=1 TYPESONG_UNIVERSAL=1 TYPESONG_TIMESTAMP=1 TYPESONG_VERSION="$VERSION" \
  TYPESONG_SIGN_IDENTITY="$APP_ID" TYPESONG_ENTITLEMENTS="$ENT" TYPESONG_PROFILE="$PROFILE" scripts/build.sh

echo "==> Checking the app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Typesong")"
[[ "$ARCHS" == *x86_64* && "$ARCHS" == *arm64* ]] || fail "The build is not universal ($ARCHS)."
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail "The app's version is not $VERSION."
[[ "$(plutil -extract LSApplicationCategoryType raw "$APP/Contents/Info.plist")" == public.app-category.music ]] || fail "The app has no store category."
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || fail "The provisioning profile is not embedded."
[[ -f "$APP/Contents/Resources/fonts/fonts.css" ]] || fail "The fonts are not in the app."
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
for k in com.apple.security.app-sandbox com.apple.security.network.client com.apple.application-identifier; do
  [[ "$ENTS" == *"$k"* ]] || fail "The app was signed without $k."
done
for k in com.apple.security.network.server com.apple.security.files com.apple.security.temporary-exception; do
  [[ "$ENTS" != *"$k"* ]] || fail "The app asks for $k, which the store edition must not."
done
codesign --verify --deep --strict "$APP" || fail "The app's signature does not verify."

echo "==> Packing the installer package"
PKG="$OUT/Typesong-$VERSION.pkg"
productbuild --component "$APP" /Applications --sign "$INST_ID" "$PKG"
pkgutil --check-signature "$PKG" | tee "$OUT/pkg-signature.txt"
grep -qi "Status: signed" "$OUT/pkg-signature.txt" || fail "The package is not signed."

echo "==> Validating with App Store Connect (nothing is uploaded)"
KEYDIR="$(mktemp -d)"; ln -s "$KEY_FILE" "$KEYDIR/AuthKey_$KEY_ID.p8"
API_PRIVATE_KEYS_DIR="$KEYDIR" xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$KEY_ID" --apiIssuer "$ISSUER" \
  > "$OUT/validate.txt" 2>&1 || true
rm -rf "$KEYDIR"
cat "$OUT/validate.txt"
if grep -qi "no errors validating" "$OUT/validate.txt"; then
  VALID="passed"
elif grep -qi "no suitable application records\|application record" "$OUT/validate.txt"; then
  VALID="needs the app record (create Typesong in App Store Connect, then rerun)"
else
  fail "App Store Connect found problems with the package. They are above and in $OUT/validate.txt"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$PKG")" | tee "$(basename "$PKG").sha256")
{
  echo "version=$VERSION source=${SRC_SHA:0:7} archs=$ARCHS"
  echo "app_signed=$APP_ID"
  echo "pkg_signed=$INST_ID"
  echo "profile=$(pb Name)"
  echo "validation=$VALID"
  echo "sha256=$(cut -d' ' -f1 "$PKG.sha256") size=$(stat -f %z "$PKG")"
} | tee "$OUT/RESULT.txt"
rm -f "$PROFILE_PLIST"
echo "Ready: $PKG"
echo "To upload it (needs a yes first): API_PRIVATE_KEYS_DIR=<folder with AuthKey_$KEY_ID.p8> xcrun altool --upload-app -f \"$PKG\" -t macos --apiKey $KEY_ID --apiIssuer <issuer>"
[[ "$VALID" == passed ]] || exit 3
