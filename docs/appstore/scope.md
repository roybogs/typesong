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

## Build and upload (scriptable, scripts/appstore.sh to write)

1. Register the bundle ID for Mac App Store and make a "Mac App Store" provisioning profile (API key can do this).
2. Build universal with an entitlements file (app-sandbox, network.server), embed the profile, sign with
   "Apple Distribution: Streetside Films LLC (2UFQBR2K68)" (already in the keychain).
3. productbuild a .pkg signed with a "Mac Installer Distribution" certificate (likely missing; one click in Xcode).
4. Upload with the existing App Store Connect API key (App Manager role can upload builds).

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
