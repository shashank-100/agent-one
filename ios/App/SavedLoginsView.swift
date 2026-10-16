import PhoneUseCore
import SwiftUI

/// Logins the agent may type for the person. Stored in this iPhone's Keychain; the model only sees each name.
struct SavedLoginsView: View {
    @State private var items: [Credential] = []
    @State private var name = ""
    @State private var site = ""
    @State private var value = ""
    @State private var message: String?
    private let vault = KeychainVault()

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.name) { item in
                    VStack(alignment: .leading) {
                        Text(item.name).font(.body.monospaced())
                        Text("\(item.site) · ••••").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                    save()
                }
            } header: {
                Text("Saved logins")
            } footer: {
                Text("The agent can type these into login fields. The AI model only ever sees the name, never the value. One-time codes are always left to you.")
            }
            Section("Add") {
                TextField("Name, e.g. amazon_phone", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Site, e.g. amazon.in", text: $site).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Value", text: $value)
                Button("Save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !value.isEmpty else { return }
                    items.removeAll { $0.name == n }
                    items.append(Credential(name: n, site: site.trimmingCharacters(in: .whitespaces), value: value))
                    name = ""; site = ""; value = ""
                    save()
                }
                .disabled(name.isEmpty || value.isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Saved logins")
        .task { items = await vault.all() }
    }

    private func save() {
        do { try vault.save(items); message = "Saved on this iPhone." } catch { message = "Could not save: \(error)" }
    }
}
