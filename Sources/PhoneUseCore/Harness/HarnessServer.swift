#if canImport(Network)
import Foundation
import Network

/// A small HTTP/1.1 server for `HarnessHost`. One request per connection; every request must carry
/// `Authorization: Bearer <token>`, because whoever holds the token can operate the phone.
public final class HarnessServer: @unchecked Sendable {
    private let host: HarnessHost
    private let token: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "harness-server")
    private static let maxBody = 1 << 20

    public init(host: HarnessHost, token: String, port: UInt16 = 0) throws {
        precondition(!token.isEmpty, "an empty token would let anyone on the network operate the phone")
        self.host = host
        self.token = token
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// Starts listening and returns the port once ready.
    public func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let request = Self.parse(data) {
                Task { await self.respond(to: request, on: connection) }
            } else if complete || error != nil || data.count > Self.maxBody + 16384 {
                connection.cancel()
            } else {
                self.read(connection, buffer: data)
            }
        }
    }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Nil until the whole request (headers and Content-Length body) has arrived.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, maxBody)
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        let reply: HarnessHost.Reply
        if request.headers["authorization"] != "Bearer \(token)" {
            reply = HarnessHost.Reply(status: 401, body: ["error": "RuntimeError: wrong or missing token"])
        } else {
            reply = await host.handle(method: request.method, path: request.path, body: request.body)
        }
        let body = (try? JSONEncoder().encode(reply.body)) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][reply.status] ?? "Internal Server Error"
        var response = Data("HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
#endif
