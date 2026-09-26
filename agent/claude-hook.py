#!/usr/bin/env python3
"""Claude Code hook → Typesong agent mode.

Register this one script (async) for UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop
and Notification.
Each call reads the hook's JSON from stdin, picks up any assistant text written to the session transcript since
the last call, and POSTs small events to Typesong on 127.0.0.1:47321. It never prints anything (some hook
outputs are fed back to the model) and always exits 0 quickly, so it can't slow down or block Claude Code.
"""
import json, os, sys, hashlib, urllib.request

URL = "http://127.0.0.1:47321/event"
STATE = os.path.expanduser("~/Library/Caches/Typesong/agent")
MAX_TEXT = 4000

def post(events):
    if not events:
        return
    try:
        req = urllib.request.Request(URL, data=json.dumps(events).encode(), headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req, timeout=0.3).close()
    except Exception:
        pass  # Typesong not running, or agent mode off: stay silent

def offset_file(transcript):
    return os.path.join(STATE, hashlib.sha1(transcript.encode()).hexdigest()[:16] + ".off")

def new_text(transcript, skip=False):
    """Assistant text/thinking appended to the transcript since the last call (whole lines only)."""
    if not transcript or not os.path.exists(transcript):
        return []
    os.makedirs(STATE, exist_ok=True)
    off_path = offset_file(transcript)
    size = os.path.getsize(transcript)
    try:
        start = int(open(off_path).read().strip())
    except Exception:
        start = size  # first sighting of this session: don't replay history
    if skip or start > size:
        start = size
    events = []
    with open(transcript, "rb") as f:
        f.seek(start)
        chunk = f.read(size - start)
    end = chunk.rfind(b"\n") + 1  # leave a half-written last line for next time
    for line in chunk[:end].splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("type") != "assistant":
            continue
        for block in (row.get("message") or {}).get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text"):
                events.append({"type": "text", "text": block["text"][:MAX_TEXT]})
            elif block.get("type") == "thinking" and block.get("thinking"):
                events.append({"type": "thinking", "text": block["thinking"][:MAX_TEXT]})
    with open(off_path, "w") as f:
        f.write(str(start + end))
    return events

def failed(response):
    if isinstance(response, dict):
        return bool(response.get("is_error") or response.get("error") or response.get("interrupted"))
    return False

def tag(events, session):
    for e in events:
        e["session"] = session
    return events

def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        return
    name = hook.get("hook_event_name", "")
    session = hook.get("session_id") or hook.get("transcript_path", "")   # which chat this is, so Typesong can follow one
    transcript = hook.get("transcript_path", "")
    tool = hook.get("tool_name", "")
    if name == "UserPromptSubmit":
        new_text(transcript, skip=True)
        post(tag([{"type": "prompt"}], session))
    elif name == "PreToolUse":
        post(tag(new_text(transcript) + [{"type": "tool", "tool": tool}], session))
    elif name == "PostToolUseFailure":
        post(tag(new_text(transcript) + [{"type": "tool_error", "tool": tool}], session))
    elif name == "PostToolUse":
        post(tag(new_text(transcript) + ([{"type": "tool_error", "tool": tool}] if failed(hook.get("tool_response")) else []), session))
    elif name in ("Stop", "SubagentStop"):
        post(tag(new_text(transcript) + ([{"type": "stop"}] if name == "Stop" else []), session))
    elif name == "Notification":
        post(tag([{"type": "notify"}], session))

if __name__ == "__main__":
    try:
        main()
    finally:
        sys.exit(0)
