//! Agent mode's front door: a tiny HTTP listener on 127.0.0.1:47321 (loopback only, never the network).
//! Accepts POST /event with one JSON event or a list; everything else gets a 404.

use serde_json::Value;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;
use tauri::AppHandle;

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let listener = match TcpListener::bind("127.0.0.1:47321") {
            Ok(l) => l,
            Err(e) => {
                crate::log::write(&format!("agent listener could not start: {e}"));
                return;
            }
        };
        for stream in listener.incoming().flatten() {
            serve(&app, stream);
        }
    });
}

fn serve(app: &AppHandle, mut s: TcpStream) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let request = loop {
        if let Some(r) = parse(&buf) {
            break Some(r);
        }
        match s.read(&mut chunk) {
            Ok(0) | Err(_) => break None,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
        if buf.len() > 1_000_000 {
            break None;
        }
    };
    let ok = matches!(request, Some((true, _)));
    if let Some((true, body)) = request {
        if let Ok(v) = serde_json::from_slice::<Value>(&body) {
            let events = match v {
                Value::Array(a) => a,
                other => vec![other],
            };
            for e in events.iter().filter(|e| e.is_object()) {
                crate::agent_event(app, e);
            }
        }
    }
    let reply: &[u8] = if ok {
        b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
    } else {
        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    };
    let _ = s.write_all(reply);
}

/// Waits for the headers and Content-Length bytes of body; true only for POST /event.
fn parse(data: &[u8]) -> Option<(bool, Vec<u8>)> {
    let end = data.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&data[..end]);
    let ok = head.starts_with("POST /event ");
    let len = head
        .lines()
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
        .unwrap_or(0);
    let body = &data[end + 4..];
    (body.len() >= len).then(|| (ok, body[..len].to_vec()))
}
