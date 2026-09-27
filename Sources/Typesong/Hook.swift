import Foundation

// `Typesong --hook`: the Claude Code hook, built into the app so agent music needs no Python or repo checkout.
// Reads the hook's JSON from stdin, picks up assistant text written to the session transcript since the last call,
// and POSTs small events to 127.0.0.1:47321. Prints nothing (some hook output
// is fed back to the model) and always exits 0 quickly, so it can't slow down or block Claude Code.
enum Hook {
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "SubagentStop", "Notification"]
    private static let maxText = 4000
    private static let maxRead = 8 << 20   // 8 MB per call: past that (huge tool output, a long gap), skip to the recent part
    private static let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Typesong/agent")

    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] { handle(hook) }
        exit(0)
    }

    private static func handle(_ hook: [String: Any]) {
        let name = hook["hook_event_name"] as? String ?? ""
        let transcript = hook["transcript_path"] as? String ?? ""
        let session = (hook["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? transcript
        let tool = hook["tool_name"] as? String ?? ""
        var out: [[String: Any]] = []
        switch name {
        case "UserPromptSubmit":
            _ = newText(transcript, skip: true); out = [["type": "prompt"]]
            pruneOld()
        case "PreToolUse":
            out = newText(transcript) + [["type": "tool", "tool": tool]]
        case "PostToolUseFailure":
            out = newText(transcript) + [["type": "tool_error", "tool": tool]]
        case "PostToolUse":
            out = newText(transcript) + (failed(hook["tool_response"]) ? [["type": "tool_error", "tool": tool]] : [])
        case "Stop", "SubagentStop":
            out = newText(transcript) + (name == "Stop" ? [["type": "stop"]] : [])
        case "Notification":
            out = [["type": "notify"]]
        default: return
        }
        post(out.map { var e = $0; e["session"] = session; return e })
    }

    private static func failed(_ r: Any?) -> Bool {
        guard let d = r as? [String: Any] else { return false }
        for k in ["is_error", "error", "interrupted"] {
            if let b = d[k] as? Bool { if b { return true } } else if let v = d[k], !(v is NSNull) { if let s = v as? String, s.isEmpty { continue }; return true }
        }
        return false
    }

    // Assistant text/thinking appended to the transcript since the last call (whole lines only).
    private static func newText(_ transcript: String, skip: Bool = false) -> [[String: Any]] {
        let fm = FileManager.default
        guard !transcript.isEmpty, fm.fileExists(atPath: transcript) else { return [] }
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let offURL = stateDir.appendingPathComponent(String(format: "%016llx", fnv(transcript)) + ".off")
        // Parallel tool calls fire several hooks at once: take turns on this transcript, so each bit of text plays once.
        let lock = open(offURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

        guard let size = ((try? fm.attributesOfItem(atPath: transcript))?[.size] as? NSNumber)?.intValue else { return [] }
        var start = (try? String(contentsOf: offURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? size   // first sighting: don't replay history
        if skip || start > size || start < 0 { start = size }
        let skipped = size - start > maxRead
        if skipped { start = size - maxRead }
        guard let fh = FileHandle(forReadingAtPath: transcript) else { return [] }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(start))
        let chunk = (try? fh.read(upToCount: size - start)) ?? Data()
        // whole lines only: leave a half-written last line for next time, and after a skip drop the partial first one
        let end = chunk.lastIndex(of: 0x0A).map { chunk.index(after: $0) } ?? chunk.startIndex
        let begin = skipped ? (chunk.firstIndex(of: 0x0A).map { chunk.index(after: $0) } ?? end) : chunk.startIndex
        var events: [[String: Any]] = []
        let marker = Data("\"assistant\"".utf8)
        for line in chunk[begin..<max(begin, end)].split(separator: 0x0A) where line.range(of: marker) != nil {   // skip tool output cheaply
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  row["type"] as? String == "assistant",
                  let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty {
                    events.append(["type": "text", "text": String(t.prefix(maxText))])
                } else if block["type"] as? String == "thinking", let t = block["thinking"] as? String, !t.isEmpty {
                    events.append(["type": "thinking", "text": String(t.prefix(maxText))])
                }
            }
        }
        try? String(start + chunk.distance(from: chunk.startIndex, to: end)).write(to: offURL, atomically: true, encoding: .utf8)
        return events
    }

    // Offsets for chats untouched in two weeks are dropped (with their locks), so the folder doesn't grow forever.
    private static func pruneOld() {
        let fm = FileManager.default, cutoff = Date().addingTimeInterval(-14 * 86_400)
        guard let files = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.pathExtension == "off" {
            guard let when = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, when < cutoff else { continue }
            try? fm.removeItem(at: f)
            try? fm.removeItem(at: URL(fileURLWithPath: f.path + ".lock"))
        }
    }

    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    private static func post(_ events: [[String: Any]]) {
        guard !events.isEmpty, let body = try? JSONSerialization.data(withJSONObject: events),
              let url = URL(string: "http://127.0.0.1:47321/event") else { return }
        var req = URLRequest(url: url, timeoutInterval: 0.3)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 0.5)   // Typesong not running or agent music off: stay silent
    }

    // MARK: Setup

    // Adds (or refreshes) Typesong's hooks in ~/.claude/settings.json, pointing at this app. Keeps every other
    // setting and hook; replaces only earlier Typesong entries. Backs the original file up first (once).
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")

    static func install(command: String, at url: URL = settingsURL) throws -> URL {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()   // a dotfiles symlink stays a symlink: update the file it points to
        var settings: [String: Any] = [:]
        var original: Data?
        do { original = try Data(contentsOf: target) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile {}
        catch { throw failure("Couldn't read ~/.claude/settings.json (\(error.localizedDescription)), so it was left alone.") }
        if let data = original, !data.isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw failure("~/.claude/settings.json isn't valid JSON, so it was left alone.")
            }
            settings = obj
            let backup = target.appendingPathExtension("before-typesong")   // the file as it was before Typesong ever touched it
            if !fm.fileExists(atPath: backup.path) {
                try data.write(to: backup)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)   // it may hold API keys
            }
        }
        // Never guess at a shape we don't recognize: leave the file alone rather than drop someone's hooks.
        var hooks: [String: Any] = [:]
        if let h = settings["hooks"] {
            guard let dict = h as? [String: Any] else { throw failure("The hooks section of ~/.claude/settings.json isn't in the usual shape, so it was left alone.") }
            hooks = dict
        }
        let ours: (Any) -> Bool = { h in
            let c = (h as? [String: Any])?["command"] as? String ?? ""
            // earlier Typesong entries, including the Python hook from early builds
            return c.contains("claude-hook.py") || c.contains("Typesong --hook") || c.hasSuffix("/Typesong\" --hook")
        }
        for ev in events {
            var existing: [[String: Any]] = []
            if let list = hooks[ev] {
                guard let groups = list as? [[String: Any]] else { throw failure("The \(ev) hooks in ~/.claude/settings.json aren't in the usual shape, so the file was left alone.") }
                existing = groups
            }
            var groups = existing.compactMap { g -> [String: Any]? in
                var g = g
                let kept = (g["hooks"] as? [Any] ?? []).filter { !ours($0) }
                if kept.isEmpty { return nil }
                g["hooks"] = kept
                return g
            }
            groups.append(["hooks": [["type": "command", "command": command, "async": true, "timeout": 2]]])
            hooks[ev] = groups
        }
        settings["hooks"] = hooks
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }   // keep the file as private as it was
        return target
    }

    static func isInstalled(command: String, at url: URL = settingsURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let hooks = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            (hooks[ev] as? [[String: Any]] ?? []).contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Typesong", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
