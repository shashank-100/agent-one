import Foundation

/// Talks to an OpenAI-style chat completions endpoint, such as Z.ai's GLM models.
/// The agent keeps its history in one shape (content blocks); this client translates it on the way out
/// and translates the reply back.
public struct OpenAICompatibleClient: ModelClient {
    public var apiKey: @Sendable () async throws -> String
    public var model: String
    public var endpoint: URL
    public var maxTokens: Int
    /// Only the most recent screenshots are sent as pictures; older ones become a line of text.
    /// Every step re-sends the conversation, so this bounds what each step costs.
    public var keepImages: Int
    public var coordinates: CoordinateSpace
    public var session: URLSession
    public var maxRetries: Int

    public init(
        apiKey: @escaping @Sendable () async throws -> String,
        model: String,
        endpoint: URL,
        maxTokens: Int = 4096,
        keepImages: Int = 3,
        coordinates: CoordinateSpace = .grid,
        session: URLSession = .shared,
        maxRetries: Int = 2
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.maxTokens = maxTokens
        self.keepImages = keepImages
        self.coordinates = coordinates
        self.session = session
        self.maxRetries = maxRetries
    }

    /// Z.ai's GLM models on the Coding Plan endpoint. In live tests glm-5.3-flash hit 8 of 8 targets when asked
    /// for screenshot pixels and 2 of 8 on the 0–999 grid, where it mixed the two conventions.
    public static func glm(apiKey: @escaping @Sendable () async throws -> String, model: String = "glm-5.3-flash") -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            apiKey: apiKey, model: model,
            endpoint: URL(string: "https://api.z.ai/api/coding/paas/v4/chat/completions")!, coordinates: .pixels)
    }

    public func body(system: String, tools: [JSONValue], messages: [JSONValue]) -> JSONValue {
        [
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "messages": .array([["role": "system", "content": .string(system)]] + Self.translate(messages, keepImages: keepImages)),
            "tools": .array(tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool["name"] ?? "",
                        "description": tool["description"] ?? "",
                        "parameters": tool["input_schema"] ?? ["type": "object"],
                    ],
                ]
            }),
            "tool_choice": "auto",
        ]
    }

    static func translate(_ messages: [JSONValue], keepImages: Int) -> [JSONValue] {
        let imageTotal = messages.reduce(0) { $0 + Self.images(in: $1).count }
        var imagesSeen = 0
        func picture(_ block: JSONValue) -> JSONValue {
            imagesSeen += 1
            guard imagesSeen > imageTotal - keepImages, let source = block["source"],
                  let type = source["media_type"]?.stringValue, let data = source["data"]?.stringValue else {
                return ["type": "text", "text": "(An earlier screen, not shown again.)"]
            }
            return ["type": "image_url", "image_url": ["url": .string("data:\(type);base64,\(data)")]]
        }

        var out: [JSONValue] = []
        for message in messages {
            let blocks = message["content"]?.arrayValue ?? []
            if message["role"] == "assistant" {
                let text = blocks.compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
                let calls: [JSONValue] = blocks.filter { $0["type"] == "tool_use" }.map { block in
                    let arguments = (try? JSONEncoder().encode(block["input"] ?? .object([:]))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ["id": block["id"] ?? "", "type": "function",
                            "function": ["name": block["name"] ?? "", "arguments": .string(arguments)]]
                }
                var assistant: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
                if !calls.isEmpty { assistant["tool_calls"] = .array(calls) }
                out.append(.object(assistant))
                continue
            }
            // Tool results cannot carry pictures in this format: the text goes in a tool message
            // and the screenshot follows in a user message.
            var loose: [JSONValue] = []
            for block in blocks {
                switch block["type"]?.stringValue {
                case "tool_result":
                    let inner = block["content"]?.arrayValue ?? []
                    let text = inner.compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
                    let prefix = block["is_error"] == true ? "Error: " : ""
                    out.append(["role": "tool", "tool_call_id": block["tool_use_id"] ?? "", "content": .string(prefix + text)])
                    loose += inner.filter { $0["type"] == "image" }.map(picture)
                case "image":
                    loose.append(picture(block))
                case "text":
                    loose.append(block)
                default:
                    break
                }
            }
            if !loose.isEmpty { out.append(["role": "user", "content": .array(loose)]) }
        }
        return out
    }

    private static func images(in message: JSONValue) -> [JSONValue] {
        (message["content"]?.arrayValue ?? []).flatMap { block -> [JSONValue] in
            if block["type"] == "image" { return [block] }
            if block["type"] == "tool_result" { return (block["content"]?.arrayValue ?? []).filter { $0["type"] == "image" } }
            return []
        }
    }

    public func reply(system: String, tools: [JSONValue], messages: [JSONValue]) async throws -> ModelReply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(try await apiKey())", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONEncoder().encode(body(system: system, tools: tools, messages: messages))

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return try Self.parse(data) }
                if status == 408 || status == 429 || status >= 500, attempt < maxRetries {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    attempt += 1
                    continue
                }
                let json = try? JSONDecoder().decode(JSONValue.self, from: data)
                throw ModelError(status: status, description: json?["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self))
            } catch let error as URLError where attempt < maxRetries && error.code != .cancelled {
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }

    /// Turns a chat-completions reply into the block shape the agent stores.
    static func parse(_ data: Data) throws -> ModelReply {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let choice = json["choices"]?.arrayValue?.first, let message = choice["message"] else {
            throw ModelError(status: 200, description: "the reply had no choices")
        }
        var content: [JSONValue] = []
        if let text = message["content"]?.stringValue, !text.isEmpty {
            content.append(["type": "text", "text": .string(text)])
        }
        for call in message["tool_calls"]?.arrayValue ?? [] {
            let raw = call["function"]?["arguments"]
            // Arguments arrive as a JSON string; some servers send the object itself.
            let input = raw?.stringValue.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? raw ?? .object([:])
            content.append([
                "type": "tool_use",
                "id": call["id"] ?? .string(UUID().uuidString),
                "name": call["function"]?["name"] ?? "",
                "input": input,
            ])
        }
        let finish = choice["finish_reason"]?.stringValue ?? ""
        let stop: String
        switch finish {
        case "tool_calls": stop = "tool_use"
        case "content_filter", "sensitive": stop = "refusal"
        case "length": stop = "max_tokens"
        default: stop = content.contains { $0["type"] == "tool_use" } ? "tool_use" : "end_turn"
        }
        let usage = json["usage"]
        let cached = usage?["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        return ModelReply(content: content, stopReason: stop, usage: TokenUsage(
            input: max((usage?["prompt_tokens"]?.intValue ?? 0) - cached, 0),
            output: usage?["completion_tokens"]?.intValue ?? 0, cacheRead: cached))
    }
}
