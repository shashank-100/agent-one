import Foundation
import Observation
import PhoneUseCore
import SwiftUI

/// Picks the model provider and stores each provider's key in the Keychain.
@MainActor
@Observable
public final class SettingsViewModel {
    public var bridgeURL: String {
        didSet { defaults.set(bridgeURL, forKey: "phoneuse.bridgeURL") }
    }
    public var provider: ModelProvider {
        didSet { defaults.set(provider.rawValue, forKey: Self.providerKey) }
    }
    /// What the user is typing; never pre-filled with a stored secret.
    public var draft = ""
    public private(set) var message: String?
    /// Bumped on every save so views re-read which providers have a key.
    public private(set) var revision = 0

    private let settings: ModelSettings
    private let defaults: UserDefaults
    private static let providerKey = "phoneuse.provider"

    public init(settings: ModelSettings = ModelSettings(), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        bridgeURL = defaults.string(forKey: "phoneuse.bridgeURL") ?? "http://127.0.0.1:8766"
        provider = defaults.string(forKey: Self.providerKey).flatMap(ModelProvider.init(rawValue:)) ?? .claude
    }

    public func hasSecret(for provider: ModelProvider) -> Bool {
        _ = revision
        return settings.hasSecret(for: provider)
    }

    public var isReady: Bool { URL(string: bridgeURL)?.host != nil }

    public func save() {
        do {
            try settings.setSecret(draft, for: provider)
            message = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Removed." : "Saved."
            draft = ""
            revision += 1
        } catch {
            message = "Could not save: \(error)"
        }
    }

    public func client() -> any ModelClient {
        // Direct provider calls disabled. The Mac runs Claude Code with the saved token.
        // settings.client(for: provider)
        LocalModelClient(base: URL(string: bridgeURL) ?? URL(string: "http://127.0.0.1:8766")!)
    }
}

public struct SettingsScreen: View {
    @Bindable private var model: SettingsViewModel

    public init(model: SettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Claude Code on your Mac") {
                TextField("Bridge address", text: $model.bridgeURL)
                    .autocorrectionDisabled()
                Text("Use http://127.0.0.1:8766 in the simulator. On an iPhone, enter your Mac’s local network address and restart the app after changing it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Your subscription token stays on the Mac. Other model calls are disabled.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            /* Direct provider settings disabled for the personal Claude Code bridge.
            Section("Model") {
                Picker("Provider", selection: $model.provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.title + (model.hasSecret(for: provider) ? "" : " (no key)")).tag(provider)
                    }
                }
                LabeledContent("Model", value: model.provider.defaultModel)
            }
            Section {
                SecureField(model.hasSecret(for: model.provider) ? "Saved. Type to replace" : "Paste it here", text: $model.draft)
                Button(model.draft.isEmpty && model.hasSecret(for: model.provider) ? "Remove" : "Save") { model.save() }
                    .disabled(model.draft.isEmpty && !model.hasSecret(for: model.provider))
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(model.provider.secretLabel)
            } footer: {
                Text("With no key saved, the agent uses the Agent One server, which keeps the keys.")
            }
            */
        }
    }
}
