#if canImport(Security)
import Foundation

/// Which model the agent talks to, with each provider's secret kept in the Keychain.
public enum ModelProvider: String, Sendable, CaseIterable, Identifiable {
    // case glm // GLM disabled.
    case claude

    public var id: String { rawValue }

    public var title: String {
        switch self {
//         case .glm: return "GLM (Z.ai)"
        case .claude: return "Claude"
        }
    }

    public var defaultModel: String {
        switch self {
//         case .glm: return "glm-5.3-flash"
        case .claude: return "claude-opus-5-5"
        }
    }

    public var secretLabel: String {
        switch self {
//         case .glm: return "Z.ai API key"
        case .claude: return "Claude API key (sk-ant-api…)"
        }
    }
}

public struct ModelSettings: Sendable {
    public let service: String

    public init(service: String = "phone-use") {
        self.service = service
    }

    private func keychain(_ provider: ModelProvider) -> KeychainStore {
        KeychainStore(service: service, account: "\(provider.rawValue)-secret")
    }

    public func secret(for provider: ModelProvider) -> String? {
        (try? keychain(provider).get()) ?? nil
    }

    /// An empty value removes the stored secret.
    public func setSecret(_ value: String, for provider: ModelProvider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try keychain(provider).delete() } else { try keychain(provider).set(trimmed) }
    }

    public func hasSecret(for provider: ModelProvider) -> Bool {
        secret(for: provider) != nil
    }

    /// A Console API key starts `sk-ant-api`; anything else for Claude is treated as an OAuth access token.
    public static func claudeCredential(from secret: String) -> ClaudeCredential {
        secret.hasPrefix("sk-ant-api") ? .apiKey(secret) : .authToken(secret)
    }

    public struct MissingSecret: Error, CustomStringConvertible {
        public let provider: ModelProvider
        public var description: String { "No \(provider.secretLabel) is saved." }
    }

    /// Claude only; GLM fallback is disabled.
    public func primaryAndBackup() -> (primary: (any ModelClient)?, backup: (any ModelClient)?) {
        /* Direct provider selection disabled.
        let order: [ModelProvider] = [.claude /*, .glm */]
        let ready = order.filter(hasSecret(for:)).map { client(for: $0) }
        return (ready.first, ready.dropFirst().first)
        */
        return (client(for: .claude), nil)
    }

    /// The client for a provider. The secret is read from the Keychain on every request, so a changed key takes effect at once.
    public func client(for provider: ModelProvider, model: String? = nil) -> any ModelClient {
        /* Direct provider calls disabled.
        let read: @Sendable () throws -> String = {
            guard let secret = self.secret(for: provider) else { throw MissingSecret(provider: provider) }
            return secret
        }
        switch provider {
        // case .glm:
        //     return OpenAICompatibleClient.glm(apiKey: { try read() }, model: model ?? provider.defaultModel)
        case .claude:
            return AnthropicClient(credential: { Self.claudeCredential(from: try read()) }, model: model ?? provider.defaultModel)
        }
        */
        let base = UserDefaults.standard.string(forKey: "phoneuse.bridgeURL") ?? "http://127.0.0.1:8766"
        return LocalModelClient(base: URL(string: base) ?? URL(string: "http://127.0.0.1:8766")!)
    }
}
#endif
