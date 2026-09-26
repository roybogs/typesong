#!/usr/bin/env python3
"""Live Claude output → Typesong, word by word.

    claude -p "your prompt" --output-format stream-json --include-partial-messages --verbose | agent/claude-stream.py

Reads Claude Code's streaming JSON, prints the answer text as it arrives (so you still see it), and sends
text, thinking and tool calls to Typesong on 127.0.0.1:47321 in small batches.
"""
import json, sys, time, urllib.request

URL = "http://127.0.0.1:47321/event"

def post(events):
    if not events:
        return
    for e in events:
        if session:
            e.setdefault("session", session)
    try:
        req = urllib.request.Request(URL, data=json.dumps(events).encode(), headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=0.3).close()
    except Exception:
        pass

pending, buf, kind, last = [], "", None, time.time()
session = None   # set from the run's init message; Typesong follows the chat that last started

def flush_text():
    global buf, kind
    if buf.strip():
        pending.append({"type": kind, "text": buf})
    buf, kind = "", None

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get("type") == "system" and msg.get("session_id") and session is None:
        session = msg["session_id"]
        pending.append({"type": "prompt"})
    ev = msg.get("event") if msg.get("type") == "stream_event" else None
    if ev and ev.get("type") == "content_block_delta":
        d = ev.get("delta") or {}
        piece, k = (d.get("text"), "text") if d.get("type") == "text_delta" else (d.get("thinking"), "thinking") if d.get("type") == "thinking_delta" else (None, None)
        if piece:
            if k == "text":
                sys.stdout.write(piece); sys.stdout.flush()
            if kind and kind != k:
                flush_text()
            kind = k
            buf += piece
    elif ev and ev.get("type") == "content_block_start" and (ev.get("content_block") or {}).get("type") == "tool_use":
        flush_text()
        pending.append({"type": "tool", "tool": ev["content_block"].get("name", "tool")})
    elif msg.get("type") == "result":
        flush_text()
        pending.append({"type": "stop"})
        sys.stdout.write("\n")
    # send about 6 times a second, cutting text at word boundaries
    if time.time() - last > 0.15 or len(pending) > 4:
        if buf and kind and " " in buf:
            cut = buf.rfind(" ") + 1
            pending.append({"type": kind, "text": buf[:cut]}); buf = buf[cut:]
        post(pending); pending, last = [], time.time()

flush_text()
post(pending)
