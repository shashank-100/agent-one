import PhoneUseCore
import SwiftUI

/// MCP servers the agent can use (calendar, notes, docs…). The list lives on the Mac with Claude Code, which calls
/// them; a server's token is kept in this iPhone's Keychain too, so the list can be saved again after an edit.
struct ConnectedServicesView: View {
    struct Server: Codable, Identifiable, Equatable { var name: String; var url: String; var id: String { name } }

    @State private var servers: [Server] = []
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(servers) { server in
                    VStack(alignment: .leading) {
                        Text(server.name).font(.body.monospaced())
                        Text(server.url).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? Self.tokenStore(servers[i].name).delete() }
                    servers.remove(atOffsets: offsets)
                    Task { await save() }
                }
            } header: {
                Text("Connected services (MCP)")
            } footer: {
                Text("The agent can use these directly, for example to look something up, before or instead of tapping through apps. What it reads there is treated as information, never as instructions.")
            }
            Section("Add a server") {
                TextField("Name, e.g. calendar", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Address, https://…", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Token (optional)", text: $token)
                Button("Add") {
                    let n = name.trimmingCharacters(in: .whitespaces), u = url.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !u.isEmpty else { return }
                    servers.removeAll { $0.name == n }
                    servers.append(Server(name: n, url: u))
                    if !token.isEmpty { try? Self.tokenStore(n).set(token) }
                    name = ""; url = ""; token = ""
                    Task { await save() }
                }
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle("Connected services")
        .task { await load() }
    }

    private static func tokenStore(_ name: String) -> KeychainStore { KeychainStore(service: "agentone.mcp", account: name) }
    private static var endpoint: URL { TestPhone.base.appendingPathComponent("api/mcp") }

    private func load() async {
        struct Listing: Decodable { let servers: [Server] }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.endpoint)
            servers = try JSONDecoder().decode(Listing.self, from: data).servers
            message = nil
        } catch { message = "Could not reach the Mac: \(error.localizedDescription)" }
    }

    private func save() async {
        struct Entry: Encodable { let name: String; let url: String; let token: String? }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let entries = servers.map { Entry(name: $0.name, url: $0.url, token: try? Self.tokenStore($0.name).get()) }
        request.httpBody = try? JSONEncoder().encode(["servers": entries])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { message = "Saved." }
            else { message = String(decoding: data, as: UTF8.self) }
        } catch { message = "Could not save: \(error.localizedDescription)" }
        await load()
    }
}
