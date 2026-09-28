import Foundation

// Codex (the CLI, the IDE extension and the desktop app) writes each session live to
// ~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl. Following those files lets Codex play with no setup and no change to
// Codex's own settings. Only what the music uses is read: a turn starting and ending, tool calls, and reply and
// reasoning-summary text. Nothing is stored or sent anywhere.
final class CodexWatcher {
    private let root: URL
    private let onEvent: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "Typesong.codex")   // file work stays off the main thread
    private var timer: DispatchSourceTimer?
    private var offsets: [String: Int] = [:]   // file → bytes already handled
    private var carry: [String: Data] = [:]    // file → a half-written last line, finished next time
    private var hot: [String: Date] = [:]      // files that changed lately: checked every second
    private var ticks = 0
    private static let maxRead = 8 << 20   // a bigger backlog is old news: skip it rather than replay it
    private static let maxText = 6         // the newest text blocks per read, so the music follows what's happening now
    private static let hotFor: TimeInterval = 600

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
         onEvent: @escaping ([String: Any]) -> Void) {
        self.root = root
        self.onEvent = onEvent
    }

    var available: Bool { FileManager.default.fileExists(atPath: root.path) }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            scanAll(initial: true)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.step() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            offsets = [:]; carry = [:]; hot = [:]
        }
    }

    // Files already there when the watch starts are only measured, so old sessions aren't replayed; a file that
    // appears later is a new session and is read from its start.
    private func scanAll(initial: Bool) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in files where url.pathExtension == "jsonl" {
            note(url, initial: initial)
        }
    }

    // Between full scans, new sessions only need a look at the last two days' folders.
    private func scanRecentDays() {
        let cal = Calendar.current
        for daysAgo in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            where url.pathExtension == "jsonl" && offsets[url.path] == nil {
                note(url, initial: false)
            }
        }
    }

    private func note(_ url: URL, initial: Bool) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let path = url.path
        if offsets[path] == nil { offsets[path] = initial ? size : 0 }
        if size > offsets[path, default: 0] { hot[path] = Date() }
    }

    private func step() {
        ticks += 1
        if ticks % 30 == 0 { scanAll(initial: false) } else { scanRecentDays() }
        let now = Date()
        for (path, since) in hot {
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            var off = offsets[path] ?? size
            if size < off { off = size; carry[path] = nil }   // replaced or cut short: start over from here
            if size > off {
                if size - off > Self.maxRead { carry[path] = nil } else { read(path, from: off, to: size) }
                off = size
                hot[path] = now
            } else if now.timeIntervalSince(since) > Self.hotFor {
                hot[path] = nil
            }
            offsets[path] = off
        }
    }

    private func read(_ path: String, from: Int, to: Int) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(from))
        var data = carry[path] ?? Data()
        data.append((try? fh.read(upToCount: to - from)) ?? Data())
        guard let last = data.lastIndex(of: 0x0A) else {
            carry[path] = data.count > Self.maxRead ? nil : data   // one enormous line is output, not music
            return
        }
        carry[path] = last + 1 < data.count ? Data(data[(last + 1)...]) : nil
        var events: [[String: Any]] = []
        for line in data[..<last].split(separator: 0x0A) where Self.markers.contains(where: { line.range(of: $0) != nil }) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            events += Self.events(row)
        }
        let session = "codex:" + Self.sessionID(path)
        for e in Self.newestText(events, keep: Self.maxText) {
            var e = e
            e["session"] = session
            DispatchQueue.main.async { self.onEvent(e) }
        }
    }

    // Lines worth parsing; tool output (often large) is skipped without decoding it.
    private static let markers = ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\"", "\"function_call\"",
                                  "\"custom_tool_call\"", "\"reasoning\"", "\"output_text\""].map { Data($0.utf8) }

    // One session-file line → the events the music plays.
    static func events(_ row: [String: Any]) -> [[String: Any]] {
        guard let p = row["payload"] as? [String: Any], let kind = p["type"] as? String else { return [] }
        switch (row["type"] as? String, kind) {
        case ("event_msg"?, "task_started"):
            return [["type": "prompt"]]
        case ("event_msg"?, "task_complete"), ("event_msg"?, "turn_aborted"):
            return [["type": "stop"]]
        case ("response_item"?, "function_call"), ("response_item"?, "custom_tool_call"):
            return [["type": "tool", "tool": toolName(p["name"] as? String ?? "tool", namespace: p["namespace"] as? String)]]
        case ("response_item"?, "message") where p["role"] as? String == "assistant":
            return (p["content"] as? [[String: Any]] ?? []).compactMap { c in
                guard c["type"] as? String == "output_text", let t = c["text"] as? String, !t.isEmpty else { return nil }
                return ["type": "text", "text": String(t.prefix(4000))]
            }
        case ("response_item"?, "reasoning"):
            return (p["summary"] as? [[String: Any]] ?? []).compactMap { s in
                guard let t = s["text"] as? String, !t.isEmpty else { return nil }
                return ["type": "thinking", "text": String(t.prefix(4000))]
            }
        default:
            return []
        }
    }

    // Codex's tool names, in the words the music's accents listen for (commands, edits, reads, web).
    static func toolName(_ name: String, namespace: String?) -> String {
        switch name {
        case "exec", "exec_command", "shell", "local_shell": return "Bash"
        case "apply_patch": return "Edit"
        case "view_image", "read_file": return "Read"
        case "web_search", "search": return "WebSearch"
        default:
            guard let ns = namespace, !ns.isEmpty, ns != "functions" else { return name }
            return (ns.hasPrefix("mcp__") ? String(ns.dropFirst(5)) : ns) + "." + name
        }
    }

    // Turn and tool events all play; of the text, only the newest few blocks do.
    static func newestText(_ events: [[String: Any]], keep: Int) -> [[String: Any]] {
        let isText = { (e: [String: Any]) in e["type"] as? String == "text" || e["type"] as? String == "thinking" }
        var drop = events.filter(isText).count - keep
        return events.filter { e in
            guard drop > 0, isText(e) else { return true }
            drop -= 1
            return false
        }
    }

    // rollout-2026-09-27T14-44-17-01a0e4d3-71a7-7a73-a7e9-8acad82783f4.jsonl → the session's id
    static func sessionID(_ path: String) -> String {
        String(((path as NSString).lastPathComponent as NSString).deletingPathExtension.suffix(36))
    }
}
