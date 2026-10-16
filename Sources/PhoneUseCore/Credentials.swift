import Foundation

/// A login detail the person saved: a phone number, an email, a password. The agent may type it into a field, but the
/// model never sees the value, only the name ("amazon_phone") and the site it belongs to.
public struct Credential: Codable, Sendable, Equatable {
    public var name: String
    public var site: String
    public var value: String

    public init(name: String, site: String, value: String) {
        self.name = name
        self.site = site
        self.value = value
    }
}

/// Where saved credentials live on this device. Values never leave it except as keystrokes into a field.
public protocol CredentialVault: Sendable {
    func all() async -> [Credential]
}

extension CredentialVault {
    /// What the model is told: names and sites only.
    public func catalog() async -> String {
        let items = await all()
        guard !items.isEmpty else { return "" }
        return "\n\nSaved logins you can fill with fill_credential (values are hidden from you): "
            + items.map { "\($0.name) (for \($0.site))" }.joined(separator: ", ") + "."
    }

    /// Replaces any saved value in text that goes to the model, so a filled field cannot leak it back.
    public func redact(_ text: String) async -> String {
        var out = text
        for c in await all() where c.value.count >= 3 { out = out.replacingOccurrences(of: c.value, with: "••••") }
        return out
    }
}

/// Credentials in an owner-only JSON file (`[{"name","site","value"}]`). Used by the test runner and the Mac tools.
public struct FileVault: CredentialVault {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func all() async -> [Credential] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Credential].self, from: data)) ?? []
    }

    public func save(_ items: [Credential]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

#if canImport(Security)
/// Credentials in the Keychain, one item per name; the list of names sits in a Keychain item too. Used by the app.
public struct KeychainVault: CredentialVault {
    public let service: String
    public init(service: String = "agentone.vault") { self.service = service }

    private var index: KeychainStore { KeychainStore(service: service, account: "_index") }

    public func all() async -> [Credential] {
        guard let raw = try? index.get(), let data = raw.data(using: .utf8),
              let names = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return names.compactMap { pair in
            guard pair.count == 2, let value = try? KeychainStore(service: service, account: pair[0]).get() else { return nil }
            return Credential(name: pair[0], site: pair[1], value: value)
        }
    }

    public func save(_ items: [Credential]) throws {
        let old = (try? index.get()).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([[String]].self, from: $0) } ?? []
        for pair in old where !items.contains(where: { $0.name == pair.first }) {
            try? KeychainStore(service: service, account: pair[0]).delete()
        }
        for item in items { try KeychainStore(service: service, account: item.name).set(item.value) }
        let names = items.map { [$0.name, $0.site] }
        try index.set(String(decoding: try JSONEncoder().encode(names), as: UTF8.self))
    }
}
#endif
