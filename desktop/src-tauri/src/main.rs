#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
//! Typesong for Windows (and later Linux): a tray app that turns typing anywhere into music.
//!
//! The sound engine is the same page as the web and Mac versions (Engine/typesong.html), running in a hidden
//! WebView2 window. A global keyboard listener feeds it which key was pressed and when; nothing typed is stored,
//! logged or sent anywhere. Unlike macOS, Windows does not hide password fields from keyboard listeners, so those
//! keys play notes too, and are still never recorded.

mod agent_server;
mod hook;
mod log;

use rdev::{EventType, Key};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed};
use std::sync::Mutex;
use std::time::Duration;
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent, Wry};

const STYLES: [(&str, &str); 7] = [
    ("lofi", "Lofi"), ("night", "Late night"), ("ambient", "Ambient"), ("angelic", "Ethereal"),
    ("rain", "Rainfall"), ("noise", "Noise"), ("free", "Free"),
];
const TRAY: &str = "typesong";

#[derive(Default)]
struct Shared {
    muted: AtomicBool,
    paused: AtomicBool,
    agent_on: AtomicBool,
    listening: AtomicBool,
    clock_on: AtomicBool,
    page_ready: AtomicBool,
    selftest: AtomicBool,
    agent_events: AtomicUsize,
    style: Mutex<String>,
    scope: Mutex<String>,
    pending: Mutex<Vec<String>>,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
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
    shared.agent_on.store(settings["agentOn"].as_bool().unwrap_or(true), Relaxed);
    *shared.scope.lock().unwrap() = settings["agentScope"].as_str().unwrap_or("focus").to_string();
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
            let menu = build_menu(&handle)?;
            TrayIconBuilder::with_id(TRAY)
                .icon(tray_icon(&handle))
                .tooltip("Typesong")
                .menu(&menu)
                .on_menu_event(|app, event| on_menu(app, event.id().as_ref()))
                .build(app)?;
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
            if let Some(m) = msg["muted"].as_bool() {
                st.muted.store(m, Relaxed);
            }
            refresh_tray(&app);
        }
        "health" => {
            let m = &msg["music"];
            let music: Vec<String> = ["notes", "pitches", "top", "maxRun", "range", "beats"]
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
        st.pending.lock().unwrap().push(code);
    }
}

// MARK: keyboard

fn start_keyboard(app: AppHandle) {
    std::thread::spawn(move || {
        app.state::<Shared>().listening.store(true, Relaxed);
        let tray_app = app.clone();
        let _ = app.run_on_main_thread(move || refresh_tray(&tray_app));
        let mut held: HashSet<String> = HashSet::new();
        let listener_app = app.clone();
        if let Err(e) = rdev::listen(move |event| on_key(&listener_app, &mut held, event)) {
            log::write(&format!("keyboard listener failed: {e:?}"));
            app.state::<Shared>().listening.store(false, Relaxed);
            let tray_app = app.clone();
            let _ = app.run_on_main_thread(move || refresh_tray(&tray_app));
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

fn on_key(app: &AppHandle, held: &mut HashSet<String>, event: rdev::Event) {
    match event.event_type {
        EventType::KeyPress(key) => {
            if !held.insert(format!("{key:?}")) {
                return; // held keys auto-repeat; one note per press
            }
            let has = |names: &[&str]| names.iter().any(|n| held.contains(*n));
            let ctrl = has(&["ControlLeft", "ControlRight"]);
            let alt = has(&["Alt", "AltGr"]);
            let shift = has(&["ShiftLeft", "ShiftRight"]);
            let win = has(&["MetaLeft", "MetaRight"]);
            if key == Key::KeyM && ctrl && alt && shift {
                let a = app.clone();
                let _ = app.run_on_main_thread(move || toggle_mute(&a));
                return;
            }
            // Shortcuts are commands, not writing (Ctrl+Alt together is AltGr on many layouts, so it still plays).
            if (ctrl && !alt) || win {
                return;
            }
            match key {
                Key::Space => send_key(app, " ", "space"),
                Key::Return | Key::KpReturn => send_key(app, "\n", "enter"),
                Key::Backspace | Key::Delete => send_key(app, "", "back"),
                _ => {
                    if let Some(c) = event.name.as_deref().and_then(|n| n.chars().last()).filter(|c| !c.is_control()) {
                        send_key(app, &c.to_string(), "char");
                    }
                }
            }
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
    let agent_item = CheckMenuItem::with_id(app, "agent", "Agent music (Claude Code)", true, agent, None::<&str>)?;
    let focus = CheckMenuItem::with_id(app, "scope_focus", "    Only my latest chat", agent, scope == "focus", None::<&str>)?;
    let all = CheckMenuItem::with_id(app, "scope_all", "    All chats, each in its own spot", agent, scope == "all", None::<&str>)?;
    let style_items: Vec<CheckMenuItem<Wry>> = STYLES
        .iter()
        .map(|(k, t)| CheckMenuItem::with_id(app, format!("style_{k}"), *t, true, *k == style, None::<&str>))
        .collect::<tauri::Result<_>>()?;
    let style_refs: Vec<&dyn IsMenuItem<Wry>> = style_items.iter().map(|i| i as &dyn IsMenuItem<Wry>).collect();
    let styles = Submenu::with_id_and_items(app, "style", "Style", true, &style_refs)?;
    let show = MenuItem::with_id(app, "show", "Show Typesong window", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Typesong", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    Menu::with_items(app, &[&header, &sep1, &mute, &pause, &agent_item, &focus, &all, &styles, &show, &sep2, &quit])
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
