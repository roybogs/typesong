# Mac job: build the Typesong 0.1.1 DMG (no upload)

For the Mac loop. Builds, signs, notarizes and staples the DMG from the v0.1.1 tag. Uploads and publishes
nothing, installs nothing, and changes no keychain item. Notarization takes a few minutes per submission.

```zsh
set -e
cd ~/Developer/typesong
git fetch origin claude/project-thread-x6zogk --tags
# The v0.1.1 build folder (detached at 1d184af). Make it if it is missing.
[[ -d ~/Developer/typesong-v0.1.1 ]] || git worktree add --detach ~/Developer/typesong-v0.1.1 v0.1.1
cd ~/Developer/typesong-v0.1.1
git status --short          # expect nothing, or only scripts/release.sh
git -C ~/Developer/typesong show origin/claude/project-thread-x6zogk:scripts/release.sh > scripts/release.sh
chmod +x scripts/release.sh
scripts/release.sh 0.1.1 --check
scripts/release.sh 0.1.1
cat build/release/RESULT.txt
```

**Expected:** `--check` ends with `READY` and shows `Signing: Developer ID Application: Streetside Films LLC (2UFQBR2K68)`
and a notary profile (`typesong-notary` if Miguel ever made it, else `streetside-notary`, the App Store Connect
API key profile saved Oct 8). The build ends with `Ready: build/release/Typesong-0.1.1.dmg`, both spctl lines say
`accepted` with `source=Notarized Developer ID`, and RESULT.txt shows `archs=x86_64 arm64` and the SHA-256.

**If it stops:** every stop starts with `STOP:` and says what is missing. If Apple rejects a submission, its reasons
are printed and saved to `build/release/notary-*.txt.json`. If codesign sits silent for over a minute, macOS is
showing a keychain dialog asking to let codesign use the Developer ID key: choose Always Allow.

**Report back:** the RESULT.txt lines and the path of the DMG. Do not run the printed `gh release upload` line,
edit the release, or install the build; those wait for Miguel's yes.
