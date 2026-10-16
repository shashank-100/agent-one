import Foundation

/// The model reached through `POST /api/step`. The personal setup uses the local Claude Code bridge.
/// Credentials stay on the Mac. This protocol uses screenshot pixels.
public struct LocalModelClient: ModelClient {
    public let endpoint: URL
    public var session: URLSession
    public var maxRetries = 2

    public init(base: URL, session: URLSession = .shared) {
        self.endpoint = base.appendingPathComponent("api/step")
        self.session = session
    }

    public var coordinates: CoordinateSpace { .pixels }

    /// Legacy GLM history compaction, retained for reference. The Claude Code route does not use it.
    static func onlyNewestImage(_ messages: [JSONValue]) -> [JSONValue] {
        func strip(_ block: JSONValue) -> JSONValue {
            guard case .object(var b) = block else { return block }
            if b["type"]?.stringValue == "image" { return ["type": "text", "text": "(earlier screenshot omitted)"] }
            // Old element lists go too: only the newest list matters, and they are most of each turn's text.
            if b["type"]?.stringValue == "text", let t = b["text"]?.stringValue, let r = t.range(of: "\nElements on the page, numbered") {
                b["text"] = .string(String(t[..<r.lowerBound]) + "\n(element list of an earlier screen omitted)")
            }
            if case .array(let inner)? = b["content"] { b["content"] = .array(inner.map(strip)) }
            return .object(b)
        }
        return messages.enumerated().map { index, message in
            guard index < messages.count - 1, case .object(var m) = message, case .array(let blocks)? = m["content"] else { return message }
            m["content"] = .array(blocks.map(strip))
            return .object(m)
        }
    }

    public func reply(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "system": .string(system), "tools": .array(tools), "messages": .array(Self.onlyNewestImage(messages)),
        ]))

        var attempt = 0
        while true {
            do {
                // Test-only leak check: AGENT_CANARY lists values that must never appear in what goes to the model.
                if let canary = ProcessInfo.processInfo.environment["AGENT_CANARY"], let body = request.httpBody {
                    let text = String(decoding: body, as: UTF8.self)
                    for value in canary.split(separator: "|") where text.contains(value) { print("AGENT_LEAK a saved value was in a model request") }
                    print("AGENT_CANARY checked \(body.count) bytes")
                }
                let t0 = Date()
                let (data, response) = try await session.data(for: request)
                if ProcessInfo.processInfo.environment["AGENT_TIMING"] != nil {
                    print("AGENT_TIMING model \(String(format: "%.2f", Date().timeIntervalSince(t0)))s, \(request.httpBody?.count ?? 0) bytes sent")
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
                if status == 200, case .array(let content)? = json["content"] {
                    let usage = TokenUsage(input: json["usage"]?["input"]?.intValue ?? 0, output: json["usage"]?["output"]?.intValue ?? 0)
                    return ModelReply(content: content, stopReason: json["stop"]?.stringValue ?? "end_turn", usage: usage)
                }
                if status >= 500 || status == 429, attempt < maxRetries {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    attempt += 1
                    continue
                }
                throw ModelError(status: status, description: json["error"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self))
            } catch let error as URLError where attempt < maxRetries && error.code != .cancelled {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }
}
