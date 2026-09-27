//! `Typesong.exe --hook`: the Claude Code hook, built into the app so Windows needs no Python.
//! Reads the hook's JSON from stdin, picks up assistant text written to the session transcript since the last
//! call, and POSTs small events to the running app on 127.0.0.1:47321. Prints nothing, never blocks Claude Code.

use crate::log::data_dir;
use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const MAX_TEXT: usize = 4000;
/// More new transcript than this in one call (screenshots, a long gap) is old news: skip it rather than replay it.
const MAX_READ: u64 = 8 << 20;
/// The most recent text blocks per call: the music follows what's happening now.
const MAX_EVENTS: usize = 6;

pub fn run() {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return;
    }
    let Ok(hook) = serde_json::from_str::<Value>(&input) else { return };
    let name = hook["hook_event_name"].as_str().unwrap_or("");
    let transcript = hook["transcript_path"].as_str().unwrap_or("");
    let tool = hook["tool_name"].as_str().unwrap_or("");
    let session = hook["session_id"].as_str().filter(|s| !s.is_empty()).unwrap_or(transcript).to_string();

    let mut events = match name {
        "UserPromptSubmit" => {
            new_text(transcript, true);
            prune_old();
            vec![json!({"type": "prompt"})]
        }
        "PreToolUse" => with(new_text(transcript, false), json!({"type": "tool", "tool": tool})),
        "PostToolUseFailure" => with(new_text(transcript, false), json!({"type": "tool_error", "tool": tool})),
        "PostToolUse" => {
            let mut e = new_text(transcript, false);
            if failed(&hook["tool_response"]) {
                e.push(json!({"type": "tool_error", "tool": tool}));
            }
            e
        }
        "Stop" => with(new_text(transcript, false), json!({"type": "stop"})),
        "SubagentStop" => new_text(transcript, false),
        "Notification" => vec![json!({"type": "notify"})],
        _ => vec![],
    };
    for e in events.iter_mut() {
        e["session"] = json!(session);
    }
    post(&events);
}

fn with(mut v: Vec<Value>, e: Value) -> Vec<Value> {
    v.push(e);
    v
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Number(n) => n.as_f64() != Some(0.0),
        _ => true,
    }
}

fn failed(resp: &Value) -> bool {
    resp.is_object() && ["is_error", "error", "interrupted"].iter().any(|k| truthy(&resp[*k]))
}

fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3))
}

/// Assistant text and thinking appended since the last call (whole lines only; history is skipped on first sight).
fn new_text(transcript: &str, skip: bool) -> Vec<Value> {
    let mut events = vec![];
    if transcript.is_empty() || !Path::new(transcript).exists() {
        return events;
    }
    let dir = data_dir().join("agent");
    let _ = fs::create_dir_all(&dir);
    let off_path = dir.join(format!("{:016x}.off", fnv(transcript)));
    // Parallel tool calls fire several hooks at once: take turns on this transcript, so each bit of text plays once.
    let lock = File::options().create(true).truncate(false).write(true).open(off_path.with_extension("off.lock"));
    if let Ok(l) = &lock {
        let _ = l.lock();
    }
    let Ok(meta) = fs::metadata(transcript) else { return events };
    let size = meta.len();
    let mut start = fs::read_to_string(&off_path).ok().and_then(|s| s.trim().parse::<u64>().ok()).unwrap_or(size);
    if skip || start > size || size - start > MAX_READ {
        start = size; // nothing to replay
    }
    let mut buf = Vec::new();
    if let Ok(mut f) = File::open(transcript) {
        if f.seek(SeekFrom::Start(start)).is_ok() {
            let _ = f.take(size - start).read_to_end(&mut buf);
        }
    }
    // whole lines only: leave a half-written last line for next time
    let end = buf.iter().rposition(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    let marker = b"\"assistant\"";
    for line in buf[..end].split(|&b| b == b'\n') {
        if !line.windows(marker.len()).any(|w| w == marker) {
            continue; // tool output and the like, skipped without parsing
        }
        let Ok(row) = serde_json::from_slice::<Value>(line) else { continue };
        if row["type"] != "assistant" {
            continue;
        }
        for block in row["message"]["content"].as_array().into_iter().flatten() {
            let (kind, key) = match block["type"].as_str() {
                Some("text") => ("text", "text"),
                Some("thinking") => ("thinking", "thinking"),
                _ => continue,
            };
            if let Some(t) = block[key].as_str().filter(|t| !t.is_empty()) {
                events.push(json!({"type": kind, "text": t.chars().take(MAX_TEXT).collect::<String>()}));
            }
        }
    }
    let _ = fs::write(&off_path, (start + end as u64).to_string());
    let n = events.len();
    events.split_off(n.saturating_sub(MAX_EVENTS))
}

/// Offsets for chats untouched in two weeks are dropped (with their locks), so the folder doesn't grow forever.
fn prune_old() {
    let Ok(entries) = fs::read_dir(data_dir().join("agent")) else { return };
    let cutoff = Duration::from_secs(14 * 86_400);
    for path in entries.flatten().map(|e| e.path()) {
        let old = fs::metadata(&path)
            .and_then(|m| m.modified())
            .map_or(false, |t| SystemTime::now().duration_since(t).map_or(false, |age| age > cutoff));
        if old && path.extension().map_or(false, |e| e == "off") {
            let _ = fs::remove_file(&path);
            let _ = fs::remove_file(path.with_extension("off.lock"));
        }
    }
}

fn post(events: &[Value]) {
    if events.is_empty() {
        return;
    }
    let body = Value::Array(events.to_vec()).to_string();
    let addr = "127.0.0.1:47321".parse().expect("valid address");
    let Ok(mut s) = TcpStream::connect_timeout(&addr, Duration::from_millis(300)) else { return };
    let _ = s.set_write_timeout(Some(Duration::from_millis(300)));
    let _ = s.set_read_timeout(Some(Duration::from_millis(300)));
    let req = format!(
        "POST /event HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    if s.write_all(req.as_bytes()).is_ok() {
        let mut sink = [0u8; 256];
        let _ = s.read(&mut sink);
    }
}

// MARK: setup

const EVENTS: [&str; 7] = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "SubagentStop", "Notification"];

fn settings_path() -> Option<std::path::PathBuf> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })?;
    Some(std::path::PathBuf::from(home).join(".claude").join("settings.json"))
}

/// The command Claude Code runs: this app with --hook. An AppImage runs from a temporary mount that changes
/// every launch, so point at the AppImage file itself.
pub fn command() -> Option<String> {
    let exe = std::env::var_os("APPIMAGE").map(std::path::PathBuf::from).or_else(|| std::env::current_exe().ok())?;
    Some(format!("\"{}\" --hook", exe.display()))
}

pub fn is_installed() -> bool {
    let (Some(p), Some(cmd)) = (settings_path(), command()) else { return false };
    let Ok(text) = fs::read_to_string(p) else { return false };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return false };
    EVENTS.iter().all(|e| {
        v["hooks"][*e].as_array().map_or(false, |gs| gs.iter().any(|g| g["hooks"].as_array().map_or(false, |hs| hs.iter().any(|h| h["command"].as_str() == Some(cmd.as_str())))))
    })
}

/// Adds (or refreshes) Typesong's hooks in ~/.claude/settings.json. Keeps every other setting and hook, replaces
/// only earlier Typesong entries, and saves the original file once as settings.json.before-typesong.
pub fn install() -> Result<(), String> {
    let path = settings_path().ok_or("no home folder")?;
    let cmd = command().ok_or("can't find the Typesong program")?;
    // a dotfiles symlink stays a symlink: update the file it points to
    let path: PathBuf = fs::canonicalize(&path).unwrap_or(path);
    let mut settings = json!({});
    let original = match fs::read_to_string(&path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => return Err(format!("couldn't read ~/.claude/settings.json ({e}), so it was left alone")),
    };
    if let Some(text) = original.as_deref().filter(|t| !t.trim().is_empty()) {
        settings = serde_json::from_str::<Value>(text).map_err(|_| "~/.claude/settings.json isn't valid JSON, so it was left alone")?;
        if !settings.is_object() {
            return Err("~/.claude/settings.json isn't a JSON object, so it was left alone".into());
        }
        let backup = path.with_extension("json.before-typesong");
        if !backup.exists() {
            fs::write(&backup, text).map_err(|e| e.to_string())?;
            restrict(&backup); // it may hold API keys
        }
    }
    let ours = |h: &Value| {
        let c = h["command"].as_str().unwrap_or("");
        c.contains("claude-hook.py") || c.ends_with("--hook") && c.to_lowercase().contains("typesong")
    };
    // Never guess at a shape we don't recognize: leave the file alone rather than drop someone's hooks.
    let hooks = settings.as_object_mut().unwrap().entry("hooks").or_insert_with(|| json!({}));
    if !hooks.is_object() {
        return Err("the hooks section of ~/.claude/settings.json isn't in the usual shape, so it was left alone".into());
    }
    for ev in EVENTS {
        if !hooks[ev].is_null() && !hooks[ev].is_array() {
            return Err(format!("the {ev} hooks in ~/.claude/settings.json aren't in the usual shape, so the file was left alone"));
        }
        let mut groups: Vec<Value> = hooks[ev].as_array().cloned().unwrap_or_default().into_iter().filter_map(|mut g| {
            let kept: Vec<Value> = g["hooks"].as_array().cloned().unwrap_or_default().into_iter().filter(|h| !ours(h)).collect();
            if kept.is_empty() { return None; }
            g["hooks"] = Value::Array(kept);
            Some(g)
        }).collect();
        groups.push(json!({"hooks": [{"type": "command", "command": cmd, "async": true, "timeout": 2}]}));
        hooks[ev] = Value::Array(groups);
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let permissions = fs::metadata(&path).ok().map(|m| m.permissions());
    let tmp = path.with_extension("json.typesong-tmp");
    fs::write(&tmp, serde_json::to_string_pretty(&settings).unwrap()).map_err(|e| e.to_string())?;
    if let Some(p) = permissions {
        let _ = fs::set_permissions(&tmp, p); // keep the file as private as it was
    }
    fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// Owner-only access for a file that may hold secrets (Unix; Windows user folders are private already).
fn restrict(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}
