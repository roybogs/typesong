#!/bin/zsh
# Builds, then installs to /Applications/Typesong.app.
# Refuses to replace a running Typesong, keeps the previous copy as a backup, and verifies the installed
# executable and signature match the build before reporting success.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Typesong.app"
LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

# The app itself, not a Claude Code hook (the same program run briefly with --hook).
running=0
for pid in $(pgrep -f "$DEST/Contents/MacOS/Typesong"); do
  [[ "$(ps -o args= -p "$pid")" == *--hook* ]] || running=1
done
if (( running )); then
  echo "Typesong is running. Quit it from the menu bar (Quit Typesong), then run this again." >&2
  exit 1
fi

scripts/build.sh

if [[ -d "$DEST" ]]; then
  rm -rf build/Typesong.previous.app
  ditto "$DEST" build/Typesong.previous.app
fi

rm -rf "$DEST"
if ! ditto build/Typesong.app "$DEST"; then
  echo "Copying the app failed. Restoring the previous version." >&2
  rm -rf "$DEST"
  [[ -d build/Typesong.previous.app ]] && ditto build/Typesong.previous.app "$DEST"
  exit 1
fi

BUILT_SHA="$(shasum -a 256 build/Typesong.app/Contents/MacOS/Typesong | cut -d' ' -f1)"
INSTALLED_SHA="$(shasum -a 256 "$DEST/Contents/MacOS/Typesong" | cut -d' ' -f1)"
if [[ "$BUILT_SHA" != "$INSTALLED_SHA" ]] || ! codesign --verify --strict "$DEST"; then
  echo "Installed copy does not match the build. Restoring the previous version." >&2
  rm -rf "$DEST"
  [[ -d build/Typesong.previous.app ]] && ditto build/Typesong.previous.app "$DEST"
  exit 1
fi

echo "Installed $DEST (executable ${INSTALLED_SHA:0:12})"
[[ $LAUNCH == 1 ]] && open "$DEST"
exit 0
