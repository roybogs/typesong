//! Linux keyboard input read straight from the keyboard devices (/dev/input, via evdev). This works on both
//! Wayland and X11, where Wayland blocks the usual global listeners. It needs read access to /dev/input: the user
//! must be in the `input` group (`sudo usermod -aG input $USER`, then log out and back in).
//! Keys are mapped with a US layout: other layouts still play, just from the US positions.

use crate::{press, Mods, Press};
use evdev::{Device, InputEventKind, Key};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::AppHandle;

/// Starts one reader thread per keyboard. Returns false when no keyboard could be opened (usually permissions).
pub fn start(app: AppHandle) -> bool {
    let open: Arc<Mutex<HashSet<PathBuf>>> = Arc::default();
    let n = open_new(&app, &open);
    if n == 0 {
        return false;
    }
    crate::log::write(&format!("keyboard: reading {n} keyboard device(s) via evdev"));
    // Keyboards come and go (Bluetooth sleep, a USB replug): look for new ones every few seconds.
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_secs(3));
        let n = open_new(&app, &open);
        if n > 0 {
            crate::log::write(&format!("keyboard: {n} keyboard device(s) connected"));
        }
    });
    true
}

fn is_keyboard(d: &Device) -> bool {
    d.supported_keys()
        .map_or(false, |k| k.contains(Key::KEY_A) && k.contains(Key::KEY_SPACE) && k.contains(Key::KEY_ENTER))
}

/// Opens the keyboards not already being read. Each gets its own reader thread, which lets go of the device when it
/// disappears, so the next scan picks it up again once it's back.
fn open_new(app: &AppHandle, open: &Arc<Mutex<HashSet<PathBuf>>>) -> usize {
    let Ok(entries) = std::fs::read_dir("/dev/input") else { return 0 };
    let mut count = 0;
    for path in entries.flatten().map(|e| e.path()) {
        let is_event = path.file_name().and_then(|n| n.to_str()).map_or(false, |n| n.starts_with("event"));
        if !is_event || open.lock().unwrap().contains(&path) {
            continue;
        }
        let Ok(dev) = Device::open(&path) else { continue };
        if !is_keyboard(&dev) {
            continue;
        }
        open.lock().unwrap().insert(path.clone());
        count += 1;
        let (app, open) = (app.clone(), open.clone());
        std::thread::spawn(move || {
            read(&app, dev);
            open.lock().unwrap().remove(&path);
        });
    }
    count
}

fn read(app: &AppHandle, mut dev: Device) {
    let mut m = Mods::default();
    while let Ok(events) = dev.fetch_events() {
        for ev in events {
            let InputEventKind::Key(k) = ev.kind() else { continue };
            // value 1 = press, 0 = release, 2 = auto-repeat (ignored: one note per press)
            let (down, up) = (ev.value() == 1, ev.value() == 0);
            if !down && !up {
                continue;
            }
            match k {
                Key::KEY_LEFTCTRL | Key::KEY_RIGHTCTRL => m.ctrl = down,
                Key::KEY_LEFTALT | Key::KEY_RIGHTALT => m.alt = down,
                Key::KEY_LEFTSHIFT | Key::KEY_RIGHTSHIFT => m.shift = down,
                Key::KEY_LEFTMETA | Key::KEY_RIGHTMETA => m.win = down,
                _ if down => {
                    let p = match k {
                        Key::KEY_SPACE => Some(Press::Space),
                        Key::KEY_ENTER | Key::KEY_KPENTER => Some(Press::Enter),
                        Key::KEY_BACKSPACE | Key::KEY_DELETE => Some(Press::Back),
                        _ => us_char(k, m.shift).map(Press::Char),
                    };
                    if let Some(p) = p {
                        press(app, p, m);
                    }
                }
                _ => {}
            }
        }
    }
}

fn us_char(k: Key, shift: bool) -> Option<char> {
    const TABLE: [(Key, char, char); 47] = [
        (Key::KEY_A, 'a', 'A'), (Key::KEY_B, 'b', 'B'), (Key::KEY_C, 'c', 'C'), (Key::KEY_D, 'd', 'D'),
        (Key::KEY_E, 'e', 'E'), (Key::KEY_F, 'f', 'F'), (Key::KEY_G, 'g', 'G'), (Key::KEY_H, 'h', 'H'),
        (Key::KEY_I, 'i', 'I'), (Key::KEY_J, 'j', 'J'), (Key::KEY_K, 'k', 'K'), (Key::KEY_L, 'l', 'L'),
        (Key::KEY_M, 'm', 'M'), (Key::KEY_N, 'n', 'N'), (Key::KEY_O, 'o', 'O'), (Key::KEY_P, 'p', 'P'),
        (Key::KEY_Q, 'q', 'Q'), (Key::KEY_R, 'r', 'R'), (Key::KEY_S, 's', 'S'), (Key::KEY_T, 't', 'T'),
        (Key::KEY_U, 'u', 'U'), (Key::KEY_V, 'v', 'V'), (Key::KEY_W, 'w', 'W'), (Key::KEY_X, 'x', 'X'),
        (Key::KEY_Y, 'y', 'Y'), (Key::KEY_Z, 'z', 'Z'),
        (Key::KEY_1, '1', '!'), (Key::KEY_2, '2', '@'), (Key::KEY_3, '3', '#'), (Key::KEY_4, '4', '$'),
        (Key::KEY_5, '5', '%'), (Key::KEY_6, '6', '^'), (Key::KEY_7, '7', '&'), (Key::KEY_8, '8', '*'),
        (Key::KEY_9, '9', '('), (Key::KEY_0, '0', ')'),
        (Key::KEY_MINUS, '-', '_'), (Key::KEY_EQUAL, '=', '+'), (Key::KEY_LEFTBRACE, '[', '{'),
        (Key::KEY_RIGHTBRACE, ']', '}'), (Key::KEY_SEMICOLON, ';', ':'), (Key::KEY_APOSTROPHE, '\'', '"'),
        (Key::KEY_GRAVE, '`', '~'), (Key::KEY_BACKSLASH, '\\', '|'), (Key::KEY_COMMA, ',', '<'),
        (Key::KEY_DOT, '.', '>'), (Key::KEY_SLASH, '/', '?'),
    ];
    TABLE.iter().find(|(key, _, _)| *key == k).map(|(_, lower, upper)| if shift { *upper } else { *lower })
}
