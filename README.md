# Typesong for Mac

A menu-bar app that turns your typing, anywhere on the Mac, into music.

- `Engine/typesong.html` is the sound engine. It is the same page as the web version
  (https://claude.ai/artifact/7JqjnEYEf86okLBHxtwvFw). Change sounds there, then rebuild.
- `Sources/Typesong/main.swift` is the host: menu bar, a listen-only keyboard event tap, and a WKWebView
  that runs the engine. Only which key and when crosses into the page. Nothing typed is stored or logged.

## Build and install

```bash
scripts/install.sh
```

Quit Typesong from its menu first; the installer refuses to replace a running copy. It keeps the previous
version in `build/Typesong.previous.app` and checks the installed executable and signature against the build.

## Things that matter

- **Signing is pinned** to the Apple Development certificate. macOS ties the Input Monitoring grant to the
  signature; an ad-hoc build would lose the permission on every rebuild.
- **The app drives the page's clock.** macOS throttles a hidden page's timers to once a second, which breaks
  the beat, rain and leveling. The host calls `typesongHost.tick()` every 25 ms instead.
- **Password fields are never heard.** macOS secure input hides those keystrokes from event taps.
- `~/Library/Logs/Typesong/health.log` records engine health only (tick rate, audio state), never keys.
  `Typesong --selftest` feeds synthetic keys with no window and no permission prompt; expect `ticks/5s≈200`.

## Agent mode

Claude Code's activity plays the instrument. Toggle it from the menu bar: **Agent music (Claude Code)**.

- The app listens on `127.0.0.1:47321` (loopback only) for `POST /event` JSON; anything else gets a 404.
- `agent/claude-hook.py` is registered (async, 2 s timeout) in `~/.claude/settings.json` for UserPromptSubmit,
  PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop and Notification. It reads new assistant
  text from the session transcript and sends it with each event. It prints nothing and always exits 0.
- `agent/claude-stream.py` plays headless runs word by word as they stream:
  `claude -p "…" --output-format stream-json --include-partial-messages --verbose | agent/claude-stream.py`
- Mapping: words play like typing (thinking slower and sparser); each tool plays a motif spelled from its
  name plus an accent (commands = kick, edits = snare, reads = low tone, web = question-mark accent,
  subagents = chord); failures = a low tone and snare; needs-you = chord and two notes; finished = chord.

## Windows (and later Linux): `desktop/`

A Tauri app that runs the same engine in a hidden WebView2 window, with a global keyboard listener, tray menu,
the same agent door on `127.0.0.1:47321`, and hook mode built in (`Typesong.exe --hook`, no Python needed).

- Built and self-tested on GitHub Actions (`.github/workflows/windows.yml`): the installer is uploaded as the
  `Typesong-Windows-installer` artifact of each run.
- Unlike macOS, Windows does not hide password fields from keyboard listeners: those keys play notes too, and are
  still never recorded.
- Claude Code hook on Windows: register `"C:\\Users\\<you>\\AppData\\Local\\Typesong\\typesong.exe" --hook` for the
  same seven events as the Mac (see Agent mode above).
- Icons are drawn with plain paths (`desktop/art/draw-icons.swift`) since Apple's symbols can't ship on Windows.
