# Typesong on the Mac App Store: scope (Nov 9)

Verdict: feasible, as a second channel beside the free notarized DMG. The core feature (hearing which key was
pressed) already uses the one keyboard API Apple supports in sandboxed apps: a listen-only CGEventTap behind the
Input Monitoring permission (CGRequestListenEventAccess). Apple's DTS confirms sandboxed apps can use Input
Monitoring with CGEventTap, and Klack, a paid "sound on every keystroke" Mac app, is on the Mac App Store.

The DMG needs no App Store review. Notarization (already passed) is the only Apple check for direct downloads.

## What has to change in the app (Mac App Store build only)

| Today | In the sandbox | Change |
|---|---|---|
| Listen-only key tap, Input Monitoring | Allowed | None |
| Agent port on 127.0.0.1:47321 | Needs network.server entitlement | Add entitlement |
| Fonts from Google Fonts | Needs network.client | Bundle the three fonts in the app instead (also cleaner for privacy review) |
| Connect Claude Code writes ~/.claude/settings.json | Blocked outside the container | Leave agent music out of the store build (default), or ask the user to pick the file once (open panel + bookmark) |
| Codex watcher reads ~/.codex/sessions | Blocked | Same as above |
| "Leave a tip" menu item and Ko-fi link | Guideline 3.1.1: no outside payment links | Remove from the store build (or add an in-app tip later) |
| Health log in ~/Library/Logs/Typesong | Goes to the app container | None |
| No Info.plist category, no encryption key | Required by App Store Connect | Add LSApplicationCategoryType and ITSAppUsesNonExemptEncryption = NO |

Default: a store edition with typing music only. Agent music stays in the free DMG, where it already works.
That keeps the review simple: no writing other apps' settings, no reading other apps' folders.

## Build and upload (scripts/appstore.sh, written Nov 9)

The store edition is the same source built with `TYPESONG_APPSTORE=1`: compiled with `-DAPPSTORE` (no tip link,
no agent music, no hook mode), fonts bundled from `Engine/fonts` (OFL), sandbox entitlements from
`scripts/Typesong-AppStore.entitlements` (app-sandbox and network.client only), Info.plist category Music and
`ITSAppUsesNonExemptEncryption` false. The direct download build is unchanged.

1. `scripts/appstore.sh --dev`: sandboxed development build, runs the self-test inside the sandbox and checks the
   container's health log for `edition=appstore sandboxed=true`, the page load and engine ticks.
2. Register the bundle ID for macOS and make a Mac App Store provisioning profile (the API key can do both).
3. `TYPESONG_PROFILE=... TYPESONG_ASC_KEY_ID=... TYPESONG_ASC_ISSUER=... scripts/appstore.sh 1.0`: universal build
   signed with Apple Distribution, profile embedded, .pkg signed with the Mac Installer Distribution certificate,
   validated with `altool --validate-app`. Validation reports the missing app record until the app exists in
   App Store Connect. Nothing is uploaded; the upload command is printed for after a yes.

## Only Miguel (or me in his Chrome, on his yes)

- Create the app record in App Store Connect. Apple's API cannot create app records.
- Approve the listing: name, subtitle, description, screenshots, category, price Free.
- Privacy policy URL: required. A short page on the Typesong GitHub Pages site would do; publishing it needs a yes.
- Age rating questionnaire (all "None", so 4+) and App Privacy answers ("Data Not Collected").
- Press Submit for Review. Review usually takes a day or two; expect questions about keyboard monitoring, so the
  review notes should explain it hears only which key and when, never text, and that macOS hides password fields.

## Review risks

- Keyboard monitoring: the main question a reviewer will ask. Mitigation: listen-only tap, clear purpose string
  in the first-run prompt, the privacy section above in the review notes, Klack as precedent.
- Tip link: certain rejection if left in.
- GPL-3.0: Miguel wrote all of it, so he can publish under the store's terms. Outside contributions would need a
  contributor agreement before they could ship in the store build.
- Minimum functionality: a menu bar app with seven styles and a settings window is well past the bar.

## Effort

About a day of agent work (store build flags in the app, entitlements, scripts/appstore.sh, bundled fonts), one
Mac job to build and upload, plus Miguel's listing review and screenshots.
