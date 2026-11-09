# Mac job: build and validate the Typesong Mac App Store edition (no upload, no submission)

For a Codex chat on the Mac (codex-oauth, gpt-6.1-terra, high). Builds the sandboxed store edition from branch
`claude/project-thread-x6zogk`, proves it runs inside the sandbox, sets up the store signing pieces through the
App Store Connect API, then makes a signed .pkg and validates it with Apple.

Hard limits:
- Do not upload the .pkg, do not run the printed upload line, do not create or edit anything in App Store Connect
  apps (no app record, no listing, no submission). Those wait for Miguel's yes.
- Never print, copy into the repo or paste anywhere the API private key (.p8), a certificate private key or a p12.
- Do not push to main. Commits go on `claude/project-thread-x6zogk` only.
- Do not touch `~/Developer/typesong-v0.1.1` (it holds the finished, unpublished DMG).
- Change only the store edition files if something fails to compile; nothing else in the app.

## 1. Get the code

```zsh
cd ~/Developer/typesong
git fetch origin claude/project-thread-x6zogk
[[ -d ~/Developer/typesong-appstore ]] || git worktree add -B appstore-build ~/Developer/typesong-appstore origin/claude/project-thread-x6zogk
cd ~/Developer/typesong-appstore
git status --short        # expect nothing
git log --oneline -1      # expect 87ab7c8 or newer ("Mac App Store edition: ...")
```

## 2. Sandboxed test build (development signature)

```zsh
scripts/appstore.sh --dev
```

Expected: `DEV OK: the store edition runs sandboxed, loads its page and fonts, and plays.` and log lines showing
`launch: edition=appstore sandboxed=true`, `selftest: page loaded` and `ticks/5s=...`. It plays a short burst of
music for about 25 seconds. If `swift build` fails, fix only the compile error in the `storeEdition` code
(Sources/Typesong/main.swift), commit with a clear message, push with `git push origin HEAD:claude/project-thread-x6zogk`,
and rerun. Also run plain `scripts/build.sh` once afterwards to prove the direct download build still compiles
(it signs with Apple Development; do not install it).

## 3. Store signing pieces (App Store Connect API, existing key)

The asc CLI is `~/Developer/asc-cli/asc` (see `asc --help`), configured in `~/.config/asc/config.json` with the
Streetside Films API key (App Manager). Read the config only for the key ID, issuer ID and the path of the
AuthKey .p8 file. Keep those three in shell variables; print only the key ID.

a. Bundle ID. `GET /v1/bundleIds?filter[identifier]=com.miguelmendoza.typesong`.
   If none exists, register it: `POST /v1/bundleIds` with identifier `com.miguelmendoza.typesong`, name
   `Typesong`, platform `MAC_OS`. If one exists with platform `IOS`, stop and report (do not delete it).

b. Apple Distribution certificate ID. `GET /v1/certificates?filter[certificateType]=DISTRIBUTION`. Match by serial
   number against the keychain's `Apple Distribution: Streetside Films LLC (2UFQBR2K68)`
   (`security find-certificate -c "Apple Distribution: Streetside Films LLC" -p | openssl x509 -noout -serial`).

c. Mac Installer Distribution certificate. Check `security find-identity -v | grep -i "installer"`.
   If there is none for team 2UFQBR2K68:
   - In a new folder `~/Developer/typesong-signing` (chmod 700, outside every repo), make a 2048 bit RSA key and a
     CSR with openssl (CN `Streetside Films LLC Installer`).
   - `POST /v1/certificates` with certificateType `MAC_INSTALLER_DISTRIBUTION` and the CSR.
   - Save the returned certificateContent as a .cer, combine with the key into a p12 under a random throwaway
     passphrase, and `security import` it into the login keychain with `-T /usr/bin/productbuild -T /usr/bin/pkgbuild`.
   - Confirm `security find-identity -v` now lists `3rd Party Mac Developer Installer: Streetside Films LLC (2UFQBR2K68)`
     (or `Mac Installer Distribution: ...`), then delete the loose key, CSR, .cer and .p12 files.
   - If the keychain import is denied or a dialog blocks it, stop and report exactly what was denied.

d. Provisioning profile. `GET /v1/profiles?filter[profileType]=MAC_APP_STORE` and look for one for this bundle ID
   with the Apple Distribution certificate from b. If none, `POST /v1/profiles` with name
   `Typesong Mac App Store`, profileType `MAC_APP_STORE`, the bundle ID from a and that certificate.
   Save its profileContent (base64 decoded) to `~/Developer/typesong-signing/Typesong_Mac_App_Store.provisionprofile`.

## 4. Store build, package and validation

```zsh
cd ~/Developer/typesong-appstore
export TYPESONG_PROFILE=~/Developer/typesong-signing/Typesong_Mac_App_Store.provisionprofile
export TYPESONG_ASC_KEY_ID=<key id from the asc config>
export TYPESONG_ASC_ISSUER=<issuer id from the asc config>
export TYPESONG_ASC_KEY_FILE=<path of the AuthKey .p8 from the asc config>
scripts/appstore.sh --check
scripts/appstore.sh 1.0
cat build/appstore/RESULT.txt
```

Expected: `--check` ends with `READY`. The build ends with `Ready: build/appstore/Typesong-1.0.pkg`. Validation most
likely reports that there is no app record yet; the script then prints
`validation=needs the app record (...)` and exits with code 3. That is the expected result today. Any other
validation error is a real problem: report Apple's full message from `build/appstore/validate.txt`.

If codesign or productbuild sits silent for over a minute, macOS is showing a keychain dialog asking to use a
signing key: choose Always Allow.

## Report back

- Step 2 result and the health log lines it printed.
- What step 3 found or created: bundle ID (existing or registered), installer certificate (existing or created),
  profile name and expiry.
- `RESULT.txt` lines, the .pkg path, and the validation outcome with Apple's exact words.
- Any commit you pushed (hash and one line).
Do not upload, do not run the printed upload line, and do not touch App Store Connect apps.
