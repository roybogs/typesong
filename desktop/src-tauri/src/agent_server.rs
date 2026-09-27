//! Agent mode's front door: a tiny HTTP listener on 127.0.0.1:47321 (loopback only, never the network).
//! Accepts POST /event with one JSON event or a list. Web pages in a browser can reach 127.0.0.1 too, so a request
//! from one (it carries an Origin header, and can't send application/json without asking first) is refused, as is
//! anything malformed, oversized or slow.

use serde_json::{json, Map, Value};
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tauri::AppHandle;

const PORT: u16 = 47321;
const MAX_BODY: usize = 1_000_000;
const MAX_HEADER: usize = 16 * 1024;
const MAX_EVENTS: usize = 100;
const MAX_CONNECTIONS: usize = 16;

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        // The port can be busy for a moment (a previous copy still closing): keep trying.
        let mut failures = 0u32;
        let listener = loop {
            match TcpListener::bind(("127.0.0.1", PORT)) {
                Ok(l) => break l,
                Err(e) => {
                    failures += 1;
                    if failures == 1 {
                        crate::log::write(&format!("agent listener could not start: {e}; retrying every 3 s"));
                    }
                    std::thread::sleep(Duration::from_secs(3));
                }
            }
        };
        if failures > 0 {
            crate::log::write("agent listener running");
        }
        let open = Arc::new(AtomicUsize::new(0));
        for stream in listener.incoming().flatten() {
            if open.load(SeqCst) >= MAX_CONNECTIONS {
                continue; // dropping the stream closes it
            }
            open.fetch_add(1, SeqCst);
            let (app, open) = (app.clone(), open.clone());
            std::thread::spawn(move || {
                serve(&app, stream);
                open.fetch_sub(1, SeqCst);
            });
        }
    });
}

enum Parsed {
    Incomplete,
    Rejected(&'static str),
    Accepted(Vec<u8>),
}

fn serve(app: &AppHandle, mut s: TcpStream) {
    let deadline = Instant::now() + Duration::from_secs(3); // a client that stalls gives its slot back
    let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(1)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let outcome = loop {
        match parse(&buf) {
            Parsed::Incomplete => {}
            done => break done,
        }
        if Instant::now() > deadline {
            return;
        }
        match s.read(&mut chunk) {
            Ok(0) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
            Err(_) => return,
        }
    };
    let status = match outcome {
        Parsed::Accepted(body) => {
            if let Ok(v) = serde_json::from_slice::<Value>(&body) {
                let events = match v {
                    Value::Array(a) => a,
                    other => vec![other],
                };
                for e in events.iter().take(MAX_EVENTS).filter_map(clean) {
                    crate::agent_event(app, &e);
                }
            }
            "204 No Content"
        }
        Parsed::Rejected(status) => status,
        Parsed::Incomplete => return,
    };
    let length = if status.starts_with("204") { "" } else { "Content-Length: 0\r\n" }; // a 204 has no body
    let _ = s.write_all(format!("HTTP/1.1 {status}\r\n{length}Connection: close\r\n\r\n").as_bytes());
}

/// Waits for the headers and Content-Length bytes of body. Only POST /event with a JSON body, from a tool on this
/// machine rather than a web page, is accepted.
fn parse(data: &[u8]) -> Parsed {
    let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if data.len() > MAX_HEADER { Parsed::Rejected("431 Request Header Fields Too Large") } else { Parsed::Incomplete };
    };
    let head = String::from_utf8_lossy(&data[..end]);
    let header = |name: &str| {
        head.split("\r\n")
            .skip(1)
            .filter_map(|l| l.split_once(':'))
            .find(|(k, _)| k.trim().eq_ignore_ascii_case(name))
            .map(|(_, v)| v.trim().to_ascii_lowercase())
    };
    if !head.starts_with("POST /event ") {
        return Parsed::Rejected("404 Not Found");
    }
    if header("origin").is_some() {
        return Parsed::Rejected("403 Forbidden"); // sent by a web page
    }
    if let Some(host) = header("host") {
        if !["127.0.0.1", "127.0.0.1:47321", "localhost", "localhost:47321"].contains(&host.as_str()) {
            return Parsed::Rejected("403 Forbidden"); // DNS rebinding
        }
    }
    if !header("content-type").map_or(false, |t| t.starts_with("application/json")) {
        return Parsed::Rejected("415 Unsupported Media Type");
    }
    let len = match header("content-length").as_deref().unwrap_or("0").parse::<usize>() {
        Ok(n) if n <= MAX_BODY => n,
        _ => return Parsed::Rejected("413 Content Too Large"),
    };
    let body = &data[end + 4..];
    if body.len() < len {
        return Parsed::Incomplete;
    }
    Parsed::Accepted(body[..len].to_vec())
}

/// Only the fields the page uses, as strings of a sane length.
fn clean(e: &Value) -> Option<Value> {
    let kind = e.get("type")?.as_str().filter(|t| !t.is_empty())?;
    let mut out = Map::new();
    out.insert("type".into(), json!(kind.chars().take(32).collect::<String>()));
    for (key, max) in [("session", 200), ("text", 20_000), ("tool", 100)] {
        if let Some(v) = e.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()) {
            out.insert(key.into(), json!(v.chars().take(max).collect::<String>()));
        }
    }
    Some(Value::Object(out))
}
