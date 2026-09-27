import Foundation
import Network

// Agent mode's front door: a tiny HTTP listener on 127.0.0.1:47321 (loopback only, never the network).
// Claude Code hooks and the stream adapter POST small JSON events to /event; each is handed to the page.
// Events carry agent output text for the melody. It is played and dropped, never stored.
// Web pages in a browser can reach 127.0.0.1 too, so a request from one (it carries an Origin header, and can't
// send application/json without asking first) is refused, as is anything malformed, oversized or slow.
final class AgentServer {
    static let port: NWEndpoint.Port = 47321
    private static let maxBody = 1_000_000, maxHeader = 16_384, maxEvents = 100, maxConnections = 16
    private var listener: NWListener?
    private var wanted = false, failures = 0   // keep trying while agent music is on: the port can be busy for a moment
    private var openConnections = 0
    private let onEvent: ([String: Any]) -> Void

    init(onEvent: @escaping ([String: Any]) -> Void) { self.onEvent = onEvent }

    func start() {
        wanted = true
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            HealthLog.write("agent listener could not start")
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.failures > 0 { HealthLog.write("agent listener running again") }
                self.failures = 0
            case .failed(let error):
                self.failures += 1
                if self.failures == 1 { HealthLog.write("agent listener stopped: \(error) (is port \(Self.port) in use?); retrying every 3 s") }
                l?.cancel()
                if self.listener === l { self.listener = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.wanted == true { self?.start() } }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: .main)
        listener = l
    }

    func stop() { wanted = false; listener?.cancel(); listener = nil }

    private func serve(_ conn: NWConnection) {
        guard openConnections < Self.maxConnections else { conn.cancel(); return }
        openConnections += 1
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            openConnections -= 1
            conn.cancel()
        }
        func reply(_ status: String) {
            let length = status.hasPrefix("204") ? "" : "Content-Length: 0\r\n"   // a 204 has no body, so no length
            let head = "HTTP/1.1 \(status)\r\n\(length)Connection: close\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in finish() })
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }   // a client that stalls gives its slot back
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
                guard !finished else { return }
                if let data { buffer.append(data) }
                switch Self.parse(buffer) {
                case .incomplete:
                    if done || error != nil { finish() } else { readMore() }
                case .rejected(let status):
                    reply(status)
                case .accepted(let body):
                    if let json = try? JSONSerialization.jsonObject(with: body) {
                        let list = (json as? [Any]) ?? [json]
                        list.prefix(Self.maxEvents).compactMap(Self.clean).forEach { self?.onEvent($0) }
                    }
                    reply("204 No Content")
                }
            }
        }
        readMore()
    }

    private enum Request { case incomplete, rejected(String), accepted(Data) }

    // Minimal HTTP: wait for the headers and Content-Length bytes of body. Only POST /event with a JSON body, from
    // a tool on this machine rather than a web page, is accepted.
    private static func parse(_ data: Data) -> Request {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeader ? .rejected("431 Request Header Fields Too Large") : .incomplete
        }
        let lines = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard lines.first?.hasPrefix("POST /event ") == true else { return .rejected("404 Not Found") }
        if headers["origin"] != nil { return .rejected("403 Forbidden") }                       // sent by a web page
        if let host = headers["host"]?.lowercased(),
           !["127.0.0.1", "127.0.0.1:\(port)", "localhost", "localhost:\(port)"].contains(host) {
            return .rejected("403 Forbidden")                                                    // DNS rebinding
        }
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .rejected("415 Unsupported Media Type")
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBody).contains(length) else {
            return .rejected("413 Content Too Large")
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        return .accepted(data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    // Only the fields the page uses, as strings of a sane length.
    private static func clean(_ item: Any) -> [String: Any]? {
        guard let e = item as? [String: Any], let type = e["type"] as? String, !type.isEmpty else { return nil }
        var out: [String: Any] = ["type": String(type.prefix(32))]
        for (key, max) in [("session", 200), ("text", 20_000), ("tool", 100)] {
            if let v = e[key] as? String, !v.isEmpty { out[key] = String(v.prefix(max)) }
        }
        return out
    }
}
