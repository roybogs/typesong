import Foundation
import Network

// Agent mode's front door: a tiny HTTP listener on 127.0.0.1:47321 (loopback only, never the network).
// Claude Code hooks and the stream adapter POST small JSON events to /event; each is handed to the page.
// Events carry agent output text for the melody. It is played and dropped, never stored.
final class AgentServer {
    static let port: NWEndpoint.Port = 47321
    private var listener: NWListener?
    private let onEvent: ([String: Any]) -> Void

    init(onEvent: @escaping ([String: Any]) -> Void) { self.onEvent = onEvent }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            NSLog("Typesong: agent listener could not start (port \(Self.port) busy?)")
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.start(queue: .main)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    if request.ok, let json = try? JSONSerialization.jsonObject(with: request.body) {
                        let events = (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]]
                        events.forEach { self?.onEvent($0) }
                    }
                    let reply = request.ok ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                                           : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                } else if done || error != nil || buffer.count > 1_000_000 {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    // Minimal HTTP: wait for the headers and Content-Length bytes of body; accept only POST /event.
    private static func parse(_ data: Data) -> (ok: Bool, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let ok = lines.first?.hasPrefix("POST /event ") ?? false
        let length = lines.lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "content-length" ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return (ok, data[bodyStart..<(bodyStart + length)])
    }
}
