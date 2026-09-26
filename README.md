# Typesong

**Turns your typing into music.** Every key plays a note tuned to the chord underneath, the spacebar keeps the
beat, and your speed sets the energy. Stop typing and it settles.

Typesong lives in your menu bar (or system tray) and plays along with whatever you type, in any app.
It's free, and it stays free.

https://github.com/user-attachments/assets/ed112963-0f5a-4fe1-963c-dc349358643a

*Sound on: every note in this video is Typesong itself, playing the keys you see typed.*

## Sounds

Seven styles: **Lofi**, **Late night**, **Ambient** (bells, glass or hum), **Ethereal**, **Rainfall**,
**Noise** (white, pink, brown or deep brown) and **Instruments** (piano, guitar, kalimba or synth).

## Download

Signed builds for Mac, Windows and Linux are on the way. Until then, build it from source (below).

## Privacy

Typesong only needs to know *which* key was pressed and *when*, to pick a note. Nothing you type is recorded,
stored or sent anywhere. The only thing it downloads is its fonts (from Google Fonts), and the only connection it
accepts is from your own machine (`127.0.0.1`), for agent music.

- **macOS** hides password fields from keyboard listeners entirely, so those keystrokes never reach Typesong.
- **Windows and Linux** don't do that: keys in password fields play notes too. They're still never recorded.
- A small health log (tick rate, audio state, note-pitch counts; never keys or text) is kept locally:
  `~/Library/Logs/Typesong/health.log` on Mac, `%LOCALAPPDATA%\Typesong` on Windows, `~/.local/share/Typesong` on Linux.

## Agent music for Claude Code (Beta)

Typesong can also play what [Claude Code](https://claude.com/claude-code) is doing: words it writes play like
typing, each tool it runs gets a short motif, and a chord tells you when it's done.

Turn on **Agent music for Claude Code (Beta)** in the menu, then choose **Connect Claude Code**. That adds
Typesong's hooks to `~/.claude/settings.json` (your other settings are kept, and the original file is saved as
`settings.json.before-typesong`). New Claude Code chats will play; chats already open need a restart.

Headless runs can play word by word as they stream:

```bash
claude -p "…" --output-format stream-json --include-partial-messages --verbose | agent/claude-stream.py
```

## Build from source

### Mac (macOS 14+, Apple Silicon)

```bash
scripts/install.sh
```

Builds `build/Typesong.app`, installs it to `/Applications` and opens it. macOS will ask for **Input
Monitoring** permission the first time. Quit Typesong from its menu before reinstalling.

Signing: the build uses your first "Apple Development" certificate if you have one, so the permission survives
rebuilds. Without one it signs ad hoc, and macOS asks for the permission again after each rebuild.
`scripts/release.sh <version>` makes a notarized DMG (needs a Developer ID certificate).

### Windows and Linux

A [Tauri](https://tauri.app) app in `desktop/` that runs the same engine. Needs Rust and Node.js 20+.

```bash
desktop/scripts/prepare-engine.sh
cd desktop && npx @tauri-apps/cli@2 build
```

GitHub Actions builds and self-tests both on every push (`.github/workflows/`); the Windows installer and the
Linux `.deb` / AppImage are attached to each run.

Linux notes:
- **Keyboard:** read from `/dev/input`, which works on Wayland and X11 but needs the `input` group:
  `sudo usermod -aG input $USER`, then log out and back in. Without it Typesong falls back to an X11-only
  listener, and the tray menu says what to do. Keys map with a US layout.
- **Tray:** needs AppIndicator support (built into Ubuntu, Mint and KDE; stock GNOME needs the AppIndicator extension).

## How it works

- `Engine/typesong.html` is the whole sound engine (Web Audio), one page shared by every platform.
- `Sources/Typesong/` is the Mac host: menu bar, a listen-only keyboard event tap, and a hidden WKWebView running
  the engine. Only the key and its timing cross into the page.
- `desktop/` is the Windows/Linux host (Tauri, Rust): a global keyboard listener, tray menu and hidden webview.
- **The app drives the page's clock.** Hidden webviews throttle timers to about once a second, which would break
  the beat, so the host calls `typesongHost.tick()` every 25 ms, and lets the audio sleep after 7 s of quiet.
- **Agent music** listens on `127.0.0.1:47321` for `POST /event` JSON (anything else gets a 404). The Claude Code
  hook is the app itself run as `Typesong --hook`: it reads the hook's JSON, picks up new assistant text from
  the session transcript, and posts small events. It prints nothing and always exits 0, so it can't block Claude Code.
- `Typesong --selftest` feeds synthetic keys with no window and no permission prompt, and logs engine health.

## Support

Typesong is free. If it makes your day nicer, you can [leave a tip on Ko-fi](https://ko-fi.com/typesong).

## License

[GPL-3.0](LICENSE). You're free to use, study, change and share Typesong. If you distribute a version of it,
modified or not, you must share its full source under the same license.
