import PhoneUseCore
import PhoneUseUI
import SwiftUI

@main
struct AgentOneApp: App {
    private let settings = SettingsViewModel()
    private let connection = ConnectionModel()

    var body: some Scene {
        WindowGroup {
            RootView(settings: settings, connection: connection)
                #if AGENTONE_DEVCONTROL
                .task {
                    guard UserDefaults.standard.bool(forKey: "controlProbe") else { return }
                    let x = UserDefaults.standard.integer(forKey: "probeX"), y = UserDefaults.standard.integer(forKey: "probeY")
                    let report = await OnDeviceController().probe(tapAt: (x, y))
                    print("CONTROL_PROBE\n\(report)\nCONTROL_PROBE_END")
                }
                #endif
        }
    }
}

struct RootView: View {
    let settings: SettingsViewModel
    let connection: ConnectionModel

    var body: some View {
        ChatsHome(settings: settings, connection: connection)
    }
}

/// The task screen. The agent runs on PiDurableKit and drives the test phone (MobileGym served by the local bridge,
/// inside the app) until the on-device control layer exists, or a phone reached over the remote-phone protocol when
/// an address is set on the Hermes tab. Claude Code runs on the Mac; no token is stored on the phone.
struct RunTab: View {
    let settings: SettingsViewModel
    let connection: ConnectionModel
    @State private var phone = TestPhone()
    @State private var browser = WebBrowserDevice()
    /// What the agent drives: the test phone, or real websites (amazon.in) in the built-in browser.
    @AppStorage("target") private var target = "phone"
    @State private var model: AgentRunModel?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Drive", selection: $target) {
                    Text("Test phone").tag("phone")
                    Text("Web").tag("web")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if target == "web" {
                    WebBrowserView(device: browser)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                } else if connection.remoteDevice() == nil {
                    TestPhoneView(phone: phone)
                        .frame(height: 300)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                }
                if let model { AgentRunView(model: model) }
            }
            .navigationTitle("Agent One")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: rebuild)
        .onChange(of: connection.remoteURL) { rebuild() }
        .onChange(of: target) { rebuild() }
        // Stop from the Live Activity.
        .onOpenURL { url in if url == RunLinks.stop { model?.stop() } }
    }

    private func rebuild() {
        let remote = connection.remoteDevice()
        if UserDefaults.standard.string(forKey: "drive") == "web" { target = "web" }   // `-drive web` on launch
        let device: any DeviceController
        if target == "web" { device = browser } else if let remote { device = remote } else { device = phone }
        let model = AgentRunModel(device: device)
        self.model = model
        let phone = phone
        Task {
            if target != "web", remote == nil { try? await phone.waitUntilReady() }
            // `-task "…"` on launch starts a run at once (used to drive the app from the simulator).
            if let task = UserDefaults.standard.string(forKey: "task"), !task.isEmpty {
                model.task = task
                model.start()
            }
        }
    }
}
