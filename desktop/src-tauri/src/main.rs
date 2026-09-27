#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
//! Typesong for Windows and Linux: a tray app that turns typing anywhere into music.
//!
//! The sound engine is the same page as the web and Mac versions (Engine/typesong.html), running in a hidden
//! WebView2 window. A global keyboard listener feeds it which key was pressed and when; nothing typed is stored,
//! logged or sent anywhere. Unlike macOS, Windows does not hide password fields from keyboard listeners, so those
//! keys play notes too, and are still never recorded.

mod agent_server;
mod hook;
#[cfg(target_os = "linux")]
mod keys_linux;
mod log;

use rdev::{EventType, Key};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent, Wry};

const STYLES: [(&str, &str); 7] = [
    ("lofi", "Lofi"), ("night", "Late night"), ("ambient", "Ambient"), ("angelic", "Ethereal"),
    ("rain", "Rainfall"), ("noise", "Noise"), ("free", "Instruments"),
];
const TRAY: &str = "typesong";

#[derive(Default)]
struct Shared {
    muted: AtomicBool,
    paused: AtomicBool,
    agent_on: AtomicBool,
    connect_error: Mutex<Option<String>>,
    listening: AtomicBool,
    clock_on: AtomicBool,
    page_ready: AtomicBool,
    selftest: AtomicBool,
    agent_events: AtomicUsize,
    style: Mutex<String>,
    scope: Mutex<String>,
    pending: Mutex<Vec<String>>,
    tip_url: Mutex<Option<String>>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--connect-claude") {
        // Same as the tray's "Connect Claude Code"; used by CI to test the settings merge.
        match hook::install() {
            Ok(()) => println!("connected: {}", hook::is_installed()),
            Err(e) => println!("connect failed: {e}"),
        }
        return;
    }
    if args.iter().any(|a| a == "--hook") {
        hook::run();
        return;
    }
    let selftest = args.iter().any(|a| a == "--selftest");
    let exit_after = args
        .iter()
        .position(|a| a == "--exit-after")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| s.parse::<u64>().ok());

    let settings = log::load_settings();
    let shared = Shared::default();
    shared.agent_on.store(settings["agentOn"].as_bool().unwrap_or(false), Relaxed);
    let scope = if settings["agentScope"].as_str() == Some("all") { "all" } else { "focus" };
    *shared.scope.lock().unwrap() = scope.to_string();
    *shared.style.lock().unwrap() = "lofi".into();
    shared.selftest.store(selftest, Relaxed);

    tauri::Builder::default()
        .manage(shared)
        .invoke_handler(tauri::generate_handler![page_message])
        .on_window_event(|window, event| {
            // Closing the window keeps the music going from the tray; the page just stops drawing.
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                js(window.app_handle(), "typesongHost.setVisible(false)");
            }
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            build_engine_window(&handle, args.iter().any(|a| a == "--show"))?;
            // A desktop without tray support (e.g. stock GNOME) must not stop the music: log it and carry on.
            let tray = build_menu(&handle).and_then(|menu| {
                TrayIconBuilder::with_id(TRAY)
                    .icon(tray_icon(&handle))
                    .tooltip("Typesong")
                    .menu(&menu)
                    .on_menu_event(|app, event| on_menu(app, event.id().as_ref()))
                    .build(app)
            });
            if let Err(e) = tray {
                log::write(&format!("tray icon unavailable, music continues without it: {e}"));
            }
            agent_server::start(handle.clone());
            start_clock(handle.clone());
            if !selftest {
                start_keyboard(handle.clone());
            }
            if let Some(secs) = exit_after {
                let h = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(secs));
                    log::write("exit-after reached");
                    h.exit(0);
                });
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Typesong failed to start");
}

// MARK: engine window

fn init_script() -> String {
    let platform = if cfg!(windows) { "windows" } else { "linux" };
    // The engine speaks the Mac host's bridge (window.webkit.messageHandlers.typesong); route it to Tauri.
    format!(
        "window.TYPESONG_HOST='mac';window.TYPESONG_PLATFORM='{platform}';\
         window.webkit={{messageHandlers:{{typesong:{{postMessage:function(m){{\
         try{{window.__TAURI_INTERNALS__.invoke('page_message',{{msg:m}});}}catch(e){{}}}}}}}}}};"
    )
}

fn build_engine_window(app: &AppHandle, show: bool) -> tauri::Result<()> {
    let init = init_script();
    let builder = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Typesong")
        .inner_size(920.0, 780.0)
        .visible(show)
        .initialization_script(&init)
        .on_page_load(|window, payload| {
            if payload.event() == PageLoadEvent::Finished {
                page_loaded(window.app_handle());
            }
        });
    // Let audio start without a click, and stop WebView2 from slowing or suspending the hidden page.
    #[cfg(windows)]
    let builder = builder.additional_browser_args(
        "--autoplay-policy=no-user-gesture-required --disable-background-timer-throttling \
         --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
         --disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection,CalculateNativeWinOcclusion",
    );
    builder.build()?;
    Ok(())
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("main")
}

fn js(app: &AppHandle, code: &str) {
    if app.state::<Shared>().page_ready.load(Relaxed) {
        if let Some(w) = window(app) {
            let _ = w.eval(code);
        }
    }
}

fn page_loaded(app: &AppHandle) {
    let st = app.state::<Shared>();
    st.page_ready.store(true, Relaxed);
    st.clock_on.store(true, Relaxed);
    js(app, &format!("typesongHost.setAgentScope('{}')", st.scope.lock().unwrap()));
    if st.muted.load(Relaxed) {
        js(app, "typesongHost.setMuted(true)"); // the app's mute wins over a freshly (re)loaded page
    }
    for e in st.pending.lock().unwrap().drain(..) {
        js(app, &e);
    }
    log::write("engine page loaded");
    if st.selftest.load(Relaxed) {
        run_selftest(app.clone());
    }
}

// The page's own timers are throttled while hidden, so the app drives its 25 ms clock. The page asks for it to
// stop ('sleep') once everything is quiet and to restart ('wake') when sound starts.
fn start_clock(app: AppHandle) {
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(25));
        let st = app.state::<Shared>();
        if st.clock_on.load(Relaxed) && st.page_ready.load(Relaxed) {
            if let Some(w) = window(&app) {
                let _ = w.eval("typesongHost.tick()");
            }
        }
    });
}

fn wake(app: &AppHandle) {
    app.state::<Shared>().clock_on.store(true, Relaxed);
}

#[tauri::command]
fn page_message(app: AppHandle, msg: Value) {
    let st = app.state::<Shared>();
    match msg["type"].as_str().unwrap_or("") {
        "state" => {
            if let Some(s) = msg["style"].as_str() {
                *st.style.lock().unwrap() = s.to_string();
            }
            // while loading, the page doesn't know the app's mute yet
            if let (true, Some(m)) = (st.page_ready.load(Relaxed), msg["muted"].as_bool()) {
                st.muted.store(m, Relaxed);
            }
            if let Some(t) = msg["tipURL"].as_str() {
                *st.tip_url.lock().unwrap() = safe_link(t).map(str::to_string);
            }
            refresh_tray(&app);
        }
        "openURL" => {
            if let Some(url) = msg["url"].as_str().and_then(safe_link) {
                open_link(url);
            }
        }
        "health" => {
            let m = &msg["music"];
            let music: Vec<String> = ["notes", "pitches", "top", "maxRun", "range", "beats", "chats", "heard"]
                .iter()
                .filter_map(|k| m.get(*k).map(|v| format!("{k}={v}")))
                .collect();
            log::write(&format!(
                "ticks/5s={} audio={} clock={} style={} listening={} paused={} agentEvents={} | {}",
                msg["ticks"],
                msg["audio"].as_str().unwrap_or("?"),
                msg["t"],
                st.style.lock().unwrap(),
                st.listening.load(Relaxed),
                st.paused.load(Relaxed),
                st.agent_events.load(Relaxed),
                music.join(" ")
            ));
        }
        "sleep" => {
            st.clock_on.store(false, Relaxed);
            log::write("asleep: audio suspended, clock stopped");
        }
        "wake" => wake(&app),
        "audioReset" => log::write(&format!("audio reset: {}", msg["reason"].as_str().unwrap_or("?"))),
        _ => {}
    }
}

/// Only plain https links leave the app.
fn safe_link(s: &str) -> Option<&str> {
    (s.starts_with("https://") && s.len() > 8 && !s.chars().any(|c| c.is_whitespace() || c == '"')).then_some(s)
}

/// Opens a link in the system browser.
fn open_link(url: &str) {
    #[cfg(windows)]
    let result = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn();
    #[cfg(not(windows))]
    let result = std::process::Command::new("xdg-open").arg(url).spawn();
    match result {
        Ok(mut child) => {
            std::thread::spawn(move || child.wait()); // reap the helper so it doesn't linger
        }
        Err(e) => log::write(&format!("could not open link: {e}")),
    }
}

// MARK: agent mode

pub(crate) fn agent_event(app: &AppHandle, event: &Value) {
    let st = app.state::<Shared>();
    if !st.agent_on.load(Relaxed) && !st.selftest.load(Relaxed) {
        return;
    }
    st.agent_events.fetch_add(1, Relaxed);
    wake(app);
    let code = format!("typesongHost.agent({event})");
    if st.page_ready.load(Relaxed) {
        js(app, &code);
    } else {
        let mut pending = st.pending.lock().unwrap();
        if pending.len() < 200 {
            pending.push(code);
        }
    }
}

// MARK: keyboard

/// Modifier keys held at the moment of a press.
#[derive(Clone, Copy, Default)]
pub(crate) struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub win: bool,
}

pub(crate) enum Press {
    Space,
    Enter,
    Back,
    Char(char),
}

/// One key press from any listener (rdev on Windows/X11, evdev on Linux).
pub(crate) fn press(app: &AppHandle, p: Press, m: Mods) {
    if matches!(p, Press::Char('m' | 'M')) && m.ctrl && m.alt && m.shift {
        let a = app.clone();
        let _ = app.run_on_main_thread(move || toggle_mute(&a));
        return;
    }
    // Shortcuts are commands, not writing (Ctrl+Alt together is AltGr on many layouts, so it still plays).
    if (m.ctrl && !m.alt) || m.win {
        return;
    }
    match p {
        Press::Space => send_key(app, " ", "space"),
        Press::Enter => send_key(app, "\n", "enter"),
        Press::Back => send_key(app, "", "back"),
        Press::Char(c) if !c.is_control() => send_key(app, &c.to_string(), "char"),
        Press::Char(_) => {}
    }
}

fn set_listening(app: &AppHandle, on: bool) {
    app.state::<Shared>().listening.store(on, Relaxed);
    let tray_app = app.clone();
    let _ = app.run_on_main_thread(move || refresh_tray(&tray_app));
}

fn start_keyboard(app: AppHandle) {
    // Linux: read the keyboard devices directly (works on Wayland and X11). Without access to /dev/input,
    // fall back to the X11 listener, which only exists on X11 sessions.
    #[cfg(target_os = "linux")]
    {
        if keys_linux::start(app.clone()) {
            return set_listening(&app, true);
        }
        let wayland = std::env::var("XDG_SESSION_TYPE").map_or(false, |t| t == "wayland");
        if wayland || std::env::var_os("DISPLAY").is_none() {
            log::write("keyboard: no access to /dev/input and no X11 session; add the user to the input group");
            return set_listening(&app, false);
        }
        log::write("keyboard: no access to /dev/input, using the X11 listener");
    }
    std::thread::spawn(move || {
        set_listening(&app, true);
        let mut held: HashMap<String, Instant> = HashMap::new();
        let listener_app = app.clone();
        if let Err(e) = rdev::listen(move |event| on_key(&listener_app, &mut held, event)) {
            log::write(&format!("keyboard listener failed: {e:?}"));
            set_listening(&app, false);
        }
    });
}

fn send_key(app: &AppHandle, ch: &str, kind: &str) {
    let st = app.state::<Shared>();
    if st.paused.load(Relaxed) || !st.page_ready.load(Relaxed) {
        return;
    }
    wake(app);
    js(app, &format!("typesongHost.key({},{})", json!(ch), json!(kind)));
}

/// A key that has been "down" this long without repeating was really released: Windows never reports releases for
/// keys held into the lock screen (Win+L, Ctrl+Alt+Del), and a stuck Win or Ctrl would silence every key after it.
const STUCK_AFTER: Duration = Duration::from_secs(10);

fn on_key(app: &AppHandle, held: &mut HashMap<String, Instant>, event: rdev::Event) {
    match event.event_type {
        EventType::KeyPress(key) => {
            let (name, now) = (format!("{key:?}"), Instant::now());
            // a key already down is auto-repeating (one note per press), unless its entry is stale
            let repeat = held.get(&name).map_or(false, |t| now.duration_since(*t) < STUCK_AFTER);
            held.insert(name, now);
            if repeat {
                return;
            }
            held.retain(|_, t| now.duration_since(*t) < STUCK_AFTER);
            let has = |names: &[&str]| names.iter().any(|n| held.contains_key(*n));
            let m = Mods {
                ctrl: has(&["ControlLeft", "ControlRight"]),
                alt: has(&["Alt", "AltGr"]),
                shift: has(&["ShiftLeft", "ShiftRight"]),
                win: has(&["MetaLeft", "MetaRight"]),
            };
            // Locking the screen hides the releases that follow: start clean.
            if (m.win && key == Key::KeyL) || (m.ctrl && m.alt && key == Key::Delete) {
                held.clear();
                return;
            }
            let p = match key {
                Key::Space => Press::Space,
                Key::Return | Key::KpReturn => Press::Enter,
                Key::Backspace | Key::Delete => Press::Back,
                Key::KeyM if m.ctrl && m.alt && m.shift => Press::Char('m'),
                _ => match event.name.as_deref().and_then(|n| n.chars().last()) {
                    Some(c) => Press::Char(c),
                    None => return,
                },
            };
            press(app, p, m);
        }
        EventType::KeyRelease(key) => {
            held.remove(&format!("{key:?}"));
        }
        _ => {}
    }
}

// MARK: tray

fn tray_icon(app: &AppHandle) -> Image<'static> {
    let st = app.state::<Shared>();
    let (muted, paused, agent, listening) =
        (st.muted.load(Relaxed), st.paused.load(Relaxed), st.agent_on.load(Relaxed), st.listening.load(Relaxed));
    // note = your typing plays · note with a sparkle = only agent music (typing paused) ·
    // mute = muted, or nothing can play · warning = typing is on but the keyboard listener isn't running
    let bytes: &'static [u8] = if muted || (paused && !agent) {
        include_bytes!("../icons/tray-mute@2x.png")
    } else if paused {
        include_bytes!("../icons/tray-agent@2x.png")
    } else if !listening && !st.selftest.load(Relaxed) {
        include_bytes!("../icons/tray-warning@2x.png")
    } else {
        include_bytes!("../icons/tray-note@2x.png")
    };
    Image::from_bytes(bytes).expect("tray icons are valid PNGs")
}

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let st = app.state::<Shared>();
    let (muted, paused, agent) = (st.muted.load(Relaxed), st.paused.load(Relaxed), st.agent_on.load(Relaxed));
    let style = st.style.lock().unwrap().clone();
    let scope = st.scope.lock().unwrap().clone();
    let title = STYLES.iter().find(|(k, _)| *k == style).map(|(_, t)| *t).unwrap_or("Lofi");
    let status = if muted {
        "Muted".to_string()
    } else if paused && !agent {
        "Paused".to_string()
    } else {
        format!("Playing · {title}")
    };

    let header = MenuItem::with_id(app, "status", status, false, None::<&str>)?;
    let mute = CheckMenuItem::with_id(app, "mute", "Mute (Ctrl+Alt+Shift+M)", true, muted, None::<&str>)?;
    let pause = CheckMenuItem::with_id(app, "pause", "Pause listening to my typing", true, paused, None::<&str>)?;
    let agent_item = CheckMenuItem::with_id(app, "agent", "Agent music for Claude Code (Beta)", true, agent, None::<&str>)?;
    let connected = hook::is_installed();
    let connect_label = match st.connect_error.lock().unwrap().clone() {
        Some(e) => format!("    Couldn't connect Claude Code: {e}"),
        None if connected => "    Claude Code is connected ✓".to_string(),
        None => "    Connect Claude Code (adds hooks to ~/.claude/settings.json)".to_string(),
    };
    let connect = MenuItem::with_id(app, "connect", connect_label, agent && !connected, None::<&str>)?;
    let focus = CheckMenuItem::with_id(app, "scope_focus", "    Only my latest chat", agent, scope == "focus", None::<&str>)?;
    let all = CheckMenuItem::with_id(app, "scope_all", "    All chats, each in its own spot", agent, scope == "all", None::<&str>)?;
    let style_items: Vec<CheckMenuItem<Wry>> = STYLES
        .iter()
        .map(|(k, t)| CheckMenuItem::with_id(app, format!("style_{k}"), *t, true, *k == style, None::<&str>))
        .collect::<tauri::Result<_>>()?;
    let style_refs: Vec<&dyn IsMenuItem<Wry>> = style_items.iter().map(|i| i as &dyn IsMenuItem<Wry>).collect();
    let styles = Submenu::with_id_and_items(app, "style", "Style", true, &style_refs)?;
    let show = MenuItem::with_id(app, "show", "Show Typesong window", true, None::<&str>)?;
    let tip = MenuItem::with_id(app, "tip", "Leave a tip ♥", true, None::<&str>)?;
    let has_tip = st.tip_url.lock().unwrap().is_some();
    let quit = MenuItem::with_id(app, "quit", "Quit Typesong", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let keyboard_hint = MenuItem::with_id(
        app,
        "keyboard_hint",
        "Keyboard is off: run  sudo usermod -aG input $USER  then log out and back in",
        false,
        None::<&str>,
    )?;
    let mut items: Vec<&dyn IsMenuItem<Wry>> = vec![&header];
    if cfg!(target_os = "linux") && !st.listening.load(Relaxed) && !st.selftest.load(Relaxed) {
        items.push(&keyboard_hint);
    }
    items.extend([&sep1 as &dyn IsMenuItem<Wry>, &mute, &pause, &agent_item, &connect, &focus, &all, &styles, &show]);
    if has_tip {
        items.push(&tip);
    }
    items.extend([&sep2 as &dyn IsMenuItem<Wry>, &quit]);
    Menu::with_items(app, &items)
}

fn refresh_tray(app: &AppHandle) {
    if let Some(tray) = app.tray_by_id(TRAY) {
        let _ = tray.set_icon(Some(tray_icon(app)));
        if let Ok(menu) = build_menu(app) {
            let _ = tray.set_menu(Some(menu));
        }
    }
}

fn save_settings(app: &AppHandle) {
    let st = app.state::<Shared>();
    log::save_settings(&json!({"agentOn": st.agent_on.load(Relaxed), "agentScope": *st.scope.lock().unwrap()}));
}

fn toggle_mute(app: &AppHandle) {
    let st = app.state::<Shared>();
    let m = !st.muted.load(Relaxed);
    st.muted.store(m, Relaxed);
    js(app, &format!("typesongHost.setMuted({m})"));
    if !m {
        // if the output device changed while muted (headphones, Bluetooth), the old audio route is gone: rebuild it
        log::write("unmuted: rebuilding audio");
        js(app, "typesongHost.resetAudio('unmute', true)");
    }
    refresh_tray(app);
}

fn on_menu(app: &AppHandle, id: &str) {
    let st = app.state::<Shared>();
    match id {
        "mute" => return toggle_mute(app),
        "pause" => {
            st.paused.fetch_xor(true, Relaxed);
        }
        "agent" => {
            st.agent_on.fetch_xor(true, Relaxed);
            save_settings(app);
        }
        "connect" => {
            *st.connect_error.lock().unwrap() = hook::install().err();
        }
        "scope_focus" | "scope_all" => {
            let scope = if id == "scope_all" { "all" } else { "focus" };
            *st.scope.lock().unwrap() = scope.into();
            js(app, &format!("typesongHost.setAgentScope('{scope}')"));
            save_settings(app);
        }
        "show" => {
            if let Some(w) = window(app) {
                let _ = w.show();
                let _ = w.set_focus();
            }
            js(app, "typesongHost.setVisible(true)");
        }
        "quit" => app.exit(0),
        "tip" => {
            if let Some(url) = st.tip_url.lock().unwrap().clone() {
                open_link(&url);
            }
        }
        _ => {
            if let Some(k) = id.strip_prefix("style_") {
                *st.style.lock().unwrap() = k.to_string();
                wake(app);
                js(app, &format!("typesongHost.setStyle('{k}')"));
            }
        }
    }
    refresh_tray(app);
}

// MARK: self-test (--selftest): no keyboard listener; feeds synthetic keys and logs engine health.

fn run_selftest(app: AppHandle) {
    std::thread::spawn(move || {
        log::write("selftest: page loaded");
        std::thread::sleep(Duration::from_millis(500));
        for ch in "Hello there, this is a test of the typing music on Windows. ".chars() {
            let kind = if ch == ' ' { "space" } else { "char" };
            send_key(&app, &ch.to_string(), kind);
            std::thread::sleep(Duration::from_millis(120));
        }
        log::write("selftest: typing done");
    });
}
