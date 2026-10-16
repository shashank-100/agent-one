import Foundation

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func += (l: inout TokenUsage, r: TokenUsage) {
        l.input += r.input
        l.output += r.output
        l.cacheRead += r.cacheRead
        l.cacheWrite += r.cacheWrite
    }
}

/// US dollars per million tokens.
public struct Pricing: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Claude Opus 5.5 list prices. The cache-write rate is assumed to be 1.25× input, the usual
    /// five-minute rate; check it against the pricing page before relying on the totals.
    public static let opus55 = Pricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)
}

extension TokenUsage {
    public func estimatedCost(_ pricing: Pricing) -> Double {
        (Double(input) * pricing.input + Double(output) * pricing.output
            + Double(cacheRead) * pricing.cacheRead + Double(cacheWrite) * pricing.cacheWrite) / 1_000_000
    }
}

public struct ModelReply: Sendable {
    /// The assistant content exactly as returned. It is appended to the history unchanged:
    /// thinking blocks are only valid in an unedited conversation.
    public let content: [JSONValue]
    public let stopReason: String
    public let usage: TokenUsage

    public init(content: [JSONValue], stopReason: String, usage: TokenUsage = TokenUsage()) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
            return ToolCall(id: id, name: name, input: block["input"] ?? .object([:]))
        }
    }

    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
    }
}

public protocol ModelClient: Sendable {
    /// The coordinate convention this model follows reliably.
    var coordinates: CoordinateSpace { get }
    func reply(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelReply
}

extension ModelClient {
    public var coordinates: CoordinateSpace { .grid }
}

/// How a request to the Claude API is authenticated.
public enum ClaudeCredential: Sendable, Equatable {
    /// An API key from the Claude Console (`sk-ant-api…`), sent as `x-api-key`.
    case apiKey(String)
    /// An OAuth access token, sent as a bearer token.
    case authToken(String)
}

public struct ModelError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let description: String
}

/// Calls the Claude Messages API directly over HTTPS. There is no official Swift SDK.
public struct AnthropicClient: ModelClient {
    public var credential: @Sendable () async throws -> ClaudeCredential
    public var model: String
    public var effort: String
    public var maxTokens: Int
    public var endpoint: URL
    public var session: URLSession
    public var maxRetries: Int

    public init(apiKey: @escaping @Sendable () async throws -> String, model: String = "claude-opus-5-5", effort: String = "medium") {
        self.init(credential: { .apiKey(try await apiKey()) }, model: model, effort: effort)
    }

    public init(
        credential: @escaping @Sendable () async throws -> ClaudeCredential,
        model: String = "claude-opus-5-5",
        effort: String = "medium",
        maxTokens: Int = 16000,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared,
        maxRetries: Int = 2
    ) {
        self.credential = credential
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.session = session
        self.maxRetries = maxRetries
    }

    /// The request body. This model rejects a forced `tool_choice`, so one call per turn comes from
    /// `auto` with parallel calls off, plus the system prompt's instruction.
    public func body(system: String, tools: [JSONValue], messages: [JSONValue]) -> JSONValue {
        [
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "system": [["type": "text", "text": .string(system)]],
            "tools": .array(tools),
            "tool_choice": ["type": "auto", "disable_parallel_tool_use": true],
            "output_config": ["effort": .string(effort)],
            // A safety decline is re-run on Anthropic's recommended fallback model inside the same call.
            "fallbacks": "default",
            // Caches the growing prefix (tools, system, earlier turns) so each step re-reads it cheaply.
            "cache_control": ["type": "ephemeral"],
            "messages": .array(messages),
        ]
    }

    public func reply(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        for (field, value) in Self.authHeaders(try await credential()) { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONEncoder().encode(body(system: system, tools: tools, messages: messages))

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return try Self.parse(data) }
                let retryable = status == 408 || status == 409 || status == 429 || status >= 500
                if retryable, attempt < maxRetries {
                    let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                    try await Task.sleep(for: .seconds(min(header ?? pow(2, Double(attempt)), 30)))
                    attempt += 1
                    continue
                }
                throw ModelError(status: status, description: Self.errorMessage(data) ?? "HTTP \(status)")
            } catch let error as URLError where attempt < maxRetries && error.code != .cancelled {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }

    static func authHeaders(_ credential: ClaudeCredential) -> [String: String] {
        let fallback = "server-side-fallback-2026-07-01"
        switch credential {
        case .apiKey(let key):
            return ["x-api-key": key, "anthropic-beta": fallback]
        case .authToken(let token):
            return ["authorization": "Bearer \(token)", "anthropic-beta": "\(fallback),oauth-2025-04-20"]
        }
    }

    static func parse(_ data: Data) throws -> ModelReply {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        let usage = json["usage"]
        return ModelReply(
            content: json["content"]?.arrayValue ?? [],
            stopReason: json["stop_reason"]?.stringValue ?? "",
            usage: TokenUsage(
                input: usage?["input_tokens"]?.intValue ?? 0,
                output: usage?["output_tokens"]?.intValue ?? 0,
                cacheRead: usage?["cache_read_input_tokens"]?.intValue ?? 0,
                cacheWrite: usage?["cache_creation_input_tokens"]?.intValue ?? 0
            )
        )
    }

    static func errorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["message"]?.stringValue
    }
}
