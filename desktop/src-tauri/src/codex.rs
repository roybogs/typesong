//! Codex (the CLI, the IDE extension and the desktop app) writes each session live to
//! ~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl. Following those files lets Codex play with no setup and no change to
//! Codex's own settings. Only what the music uses is read: a turn starting and ending, tool calls, and reply and
//! reasoning-summary text. Nothing is stored or sent anywhere.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering::Relaxed;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

/// A bigger backlog is old news: skip it rather than replay it.
const MAX_READ: u64 = 8 << 20;
/// The newest text blocks per read, so the music follows what's happening now.
const MAX_TEXT: usize = 6;
/// Files that changed within this long are checked every second.
const HOT_FOR: Duration = Duration::from_secs(600);
/// Lines worth parsing; tool output (often large) is skipped without decoding it.
const MARKERS: [&[u8]; 7] = [
    b"\"task_started\"", b"\"task_complete\"", b"\"turn_aborted\"", b"\"function_call\"",
    b"\"custom_tool_call\"", b"\"reasoning\"", b"\"output_text\"",
];

pub fn root() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("CODEX_HOME").filter(|h| !h.is_empty()) {
        return Some(PathBuf::from(home).join("sessions"));
    }
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })?;
    Some(PathBuf::from(home).join(".codex").join("sessions"))
}

pub fn available() -> bool {
    root().map_or(false, |r| r.is_dir())
}

#[derive(Default)]
struct Watch {
    offsets: HashMap<PathBuf, u64>, // file → bytes already handled
    carry: HashMap<PathBuf, Vec<u8>>, // file → a half-written last line, finished next time
    hot: HashMap<PathBuf, Instant>, // files that changed lately
}

/// Follows Codex's session files while agent music is on; turning it off forgets them, so turning it back on
/// doesn't replay what happened in between.
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let mut watch: Option<Watch> = None;
        let mut appeared = false; // the sessions folder showed up while agent music was on: its files are all new
        let mut ticks = 0u64;
        loop {
            std::thread::sleep(Duration::from_secs(1));
            let st = app.state::<crate::Shared>();
            if !st.agent_on.load(Relaxed) && !st.selftest.load(Relaxed) {
                (watch, appeared) = (None, false);
                continue;
            }
            let Some(root) = root() else { continue };
            if !root.is_dir() {
                (watch, appeared) = (None, true);
                continue;
            }
            let w = watch.get_or_insert_with(|| {
                let mut w = Watch::default();
                scan_all(&root, &mut w, !appeared);
                w
            });
            ticks += 1;
            if ticks % 30 == 0 {
                scan_all(&root, w, false);
            } else {
                scan_recent(&root, w);
            }
            step(&app, w);
        }
    });
}

/// Files already there when the watch starts are only measured, so old sessions aren't replayed; a file that
/// appears later is a new session and is read from its start.
fn scan_all(root: &Path, w: &mut Watch, initial: bool) {
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let path = e.path();
            if e.file_type().map_or(false, |t| t.is_dir()) {
                dirs.push(path);
            } else if path.extension().map_or(false, |x| x == "jsonl") {
                note(w, path, initial);
            }
        }
    }
}

/// Between full scans, new sessions only need a look at the recent days' folders. Codex names them by local date;
/// the UTC days around now cover every time zone's today and yesterday.
fn scan_recent(root: &Path, w: &mut Watch) {
    let today = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() / 86_400) as i64;
    for day in today - 2..=today + 1 {
        let (y, m, d) = crate::log::civil_from_days(day);
        let Ok(entries) = fs::read_dir(root.join(format!("{y:04}")).join(format!("{m:02}")).join(format!("{d:02}"))) else { continue };
        for path in entries.flatten().map(|e| e.path()) {
            if path.extension().map_or(false, |x| x == "jsonl") && !w.offsets.contains_key(&path) {
                note(w, path, false);
            }
        }
    }
}

fn note(w: &mut Watch, path: PathBuf, initial: bool) {
    let size = fs::metadata(&path).map_or(0, |m| m.len());
    let off = *w.offsets.entry(path.clone()).or_insert(if initial { size } else { 0 });
    if size > off {
        w.hot.insert(path, Instant::now());
    }
}

fn step(app: &AppHandle, w: &mut Watch) {
    let now = Instant::now();
    let paths: Vec<PathBuf> = w.hot.keys().cloned().collect();
    for path in paths {
        let size = fs::metadata(&path).map_or(0, |m| m.len());
        let mut off = w.offsets.get(&path).copied().unwrap_or(size);
        if size < off {
            off = size; // replaced or cut short: start over from here
            w.carry.remove(&path);
        }
        if size > off {
            if size - off > MAX_READ {
                w.carry.remove(&path);
            } else {
                read(app, w, &path, off, size);
            }
            off = size;
            w.hot.insert(path.clone(), now);
        } else if w.hot.get(&path).map_or(false, |t| now.duration_since(*t) > HOT_FOR) {
            w.hot.remove(&path);
        }
        w.offsets.insert(path, off);
    }
}

fn read(app: &AppHandle, w: &mut Watch, path: &Path, from: u64, to: u64) {
    let mut data = w.carry.remove(path).unwrap_or_default();
    if let Ok(mut f) = File::open(path) {
        if f.seek(SeekFrom::Start(from)).is_ok() {
            let _ = f.take(to - from).read_to_end(&mut data);
        }
    }
    let Some(last) = data.iter().rposition(|&b| b == b'\n') else {
        if data.len() as u64 <= MAX_READ {
            w.carry.insert(path.to_path_buf(), data); // one enormous line is output, not music
        }
        return;
    };
    if last + 1 < data.len() {
        w.carry.insert(path.to_path_buf(), data[last + 1..].to_vec());
    }
    let mut events = vec![];
    for line in data[..last].split(|&b| b == b'\n') {
        if !MARKERS.iter().any(|m| line.windows(m.len()).any(|x| x == *m)) {
            continue;
        }
        let Ok(row) = serde_json::from_slice::<Value>(line) else { continue };
        events.extend(events_of(&row));
    }
    let session = format!("codex:{}", session_id(path));
    for mut e in newest_text(events, MAX_TEXT) {
        e["session"] = json!(session);
        crate::agent_event(app, &e);
    }
}

/// One session-file line → the events the music plays.
fn events_of(row: &Value) -> Vec<Value> {
    let p = &row["payload"];
    match (row["type"].as_str().unwrap_or(""), p["type"].as_str().unwrap_or("")) {
        ("event_msg", "task_started") => vec![json!({"type": "prompt"})],
        ("event_msg", "task_complete") | ("event_msg", "turn_aborted") => vec![json!({"type": "stop"})],
        ("response_item", "function_call") | ("response_item", "custom_tool_call") => {
            vec![json!({"type": "tool", "tool": tool_name(p["name"].as_str().unwrap_or("tool"), p["namespace"].as_str())})]
        }
        ("response_item", "message") if p["role"] == "assistant" => text_blocks(&p["content"], Some("output_text"), "text"),
        ("response_item", "reasoning") => text_blocks(&p["summary"], None, "thinking"),
        _ => vec![],
    }
}

fn text_blocks(items: &Value, only: Option<&str>, kind: &str) -> Vec<Value> {
    items
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| only.map_or(true, |t| c["type"] == t))
        .filter_map(|c| c["text"].as_str().filter(|t| !t.is_empty()))
        .map(|t| json!({"type": kind, "text": t.chars().take(4000).collect::<String>()}))
        .collect()
}

/// Codex's tool names, in the words the music's accents listen for (commands, edits, reads, web).
fn tool_name(name: &str, namespace: Option<&str>) -> String {
    match name {
        "exec" | "exec_command" | "shell" | "local_shell" => "Bash".into(),
        "apply_patch" => "Edit".into(),
        "view_image" | "read_file" => "Read".into(),
        "web_search" | "search" => "WebSearch".into(),
        _ => match namespace.filter(|n| !n.is_empty() && *n != "functions") {
            Some(ns) => format!("{}.{}", ns.strip_prefix("mcp__").unwrap_or(ns), name),
            None => name.into(),
        },
    }
}

/// Turn and tool events all play; of the text, only the newest few blocks do.
fn newest_text(events: Vec<Value>, keep: usize) -> Vec<Value> {
    let is_text = |e: &Value| e["type"] == "text" || e["type"] == "thinking";
    let mut drop = events.iter().filter(|e| is_text(e)).count().saturating_sub(keep);
    events
        .into_iter()
        .filter(|e| {
            if drop > 0 && is_text(e) {
                drop -= 1;
                false
            } else {
                true
            }
        })
        .collect()
}

/// rollout-2026-09-27T14-44-17-01a0e4d3-71a7-7a73-a7e9-8acad82783f4.jsonl → the session's id
fn session_id(path: &Path) -> String {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let skip = stem.chars().count().saturating_sub(36);
    stem.chars().skip(skip).collect()
}
