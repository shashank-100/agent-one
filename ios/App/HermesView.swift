import Observation
import PhoneUseCore
import SwiftUI

/// Where the agent's hands are, and the server that lets Hermes drive this iPhone.
@MainActor
@Observable
final class ConnectionModel {
    var remoteURL: String = UserDefaults.standard.string(forKey: "remoteURL") ?? "" {
        didSet { UserDefaults.standard.set(remoteURL, forKey: "remoteURL") }
    }
    var remoteToken: String = ""
    private(set) var serverPort: UInt16?
    private(set) var serverToken = ""
    private(set) var serverError: String?
    private var server: HarnessServer?

    func remoteDevice() -> RemoteDevice? {
        guard let url = URL(string: remoteURL), url.scheme != nil, !remoteToken.isEmpty else { return nil }
        return RemoteDevice(baseURL: url, token: remoteToken)
    }

    /// Serves the remote-phone protocol from this iPhone. The taps need the on-device control layer;
    /// until it exists, the server answers with the device it has.
    func startServer(device: any DeviceController) async {
        stopServer()
        do {
            let token = UUID().uuidString
            let s = try HarnessServer(host: HarnessHost(device: device), token: token, port: 8790)
            serverPort = try await s.start()
            serverToken = token
            server = s
            serverError = nil
        } catch {
            serverError = "\(error)"
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        serverPort = nil
    }
}

struct HermesView: View {
    @Bindable var connection: ConnectionModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Phone to drive") {
                    TextField("https://…", text: $connection.remoteURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Token", text: $connection.remoteToken)
                    Text("The agent drives the phone at this address over the remote-phone protocol, for example the hosted test phone's bridge.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Let Hermes drive this iPhone") {
                    if let port = connection.serverPort {
                        LabeledContent("Port", value: "\(port)")
                        LabeledContent("Token") { Text(connection.serverToken).font(.footnote.monospaced()).textSelection(.enabled) }
                        Button("Stop", role: .destructive) { connection.stopServer() }
                    } else {
                        Text("Needs the on-device control layer, which is not in this build yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = connection.serverError { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Hermes")
        }
    }
}
