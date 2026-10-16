import Foundation
import Observation
import PhoneUseCore
import PhoneUseUI
import SwiftUI
import UIKit

struct ChatAction: Codable, Identifiable {
    var id: Int
    var text: String
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var createdAt = Date()
    var state = "done"
    var actions: [ChatAction] = []
    var preview: Data?
}

struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title = "New chat"
    var createdAt = Date()
    var updatedAt = Date()
    var target = "phone"
    var color = 0
    var revision = 1
    var messages: [ChatMessage] = []
    var working: Bool { messages.last?.state == "working" }
    var subtitle: String { working ? "Working on it…" : messages.last?.text ?? "Send a message to start" }
}

/// The thread is the entry point for every task. The display transcript is saved
/// on the phone and synced to the Mac; PiDurableKit keeps each thread's model context.
@MainActor @Observable
final class ChatWorkspace {
    struct Approval: Identifiable {
        let id = UUID()
        let text: String
        let continuation: CheckedContinuation<Bool, Never>
    }
    var threads: [ChatThread] = []
    var drafts: [UUID: String] = [:]
    var activeThread: UUID?
    var approval: Approval?
    var syncError: String?
    var storageError: String?
    var showingPhone = false
    var previewTarget = "phone"
    let phone = TestPhone()
    let browser = WebBrowserDevice()
    #if AGENTONE_DEVCONTROL
    /// This iPhone itself: other apps driven through Apple's test automation from inside the app (developer builds).
    let thisPhone = OnDeviceController()
    #endif
    private var agents: [String: PhoneAgent] = [:]
    private var activeAgent: PhoneAgent?
    private var syncTask: Task<Void, Never>?
    private let file: URL
    private let clientID: String

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("chat-threads.json")
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "phoneuse.chatClient") { clientID = id }
        else { let id = UUID().uuidString; clientID = id; defaults.set(id, forKey: "phoneuse.chatClient") }
        if FileManager.default.fileExists(atPath: file.path) {
            do { threads = try Self.decoder().decode([ChatThread].self, from: Data(contentsOf: file)) }
            catch { storageError = "Could not read saved chats: \(error.localizedDescription)" }
        }
        // A killed app has no live approval UI or active runner. Keep the transcript,
        // mark the unfinished reply honestly, and let the next message continue it.
        for t in threads.indices {
            for m in threads[t].messages.indices where threads[t].messages[m].state == "working" {
                threads[t].messages[m].state = "interrupted"
                threads[t].messages[m].text = "The app closed before this run finished. Send a message to continue."
                threads[t].revision += 1
            }
        }
        if storageError == nil { saveOnPhone() }
    }

    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    var ordered: [ChatThread] { threads.sorted { $0.updatedAt > $1.updatedAt } }
    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }

    @discardableResult func create(target: String = "phone") -> UUID {
        var chat = ChatThread(); chat.target = target; chat.color = threads.count % 5
        threads.append(chat); persist(chat.id)
        return chat.id
    }

    func send(in id: UUID, connection: ConnectionModel) {
        let text = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeThread == nil, !text.isEmpty, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let history = threads[index].messages.suffix(30).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let target = threads[index].target
        if threads[index].messages.isEmpty { threads[index].title = String(text.prefix(65)) }
        threads[index].messages.append(ChatMessage(role: "user", text: text))
        let reply = ChatMessage(role: "assistant", text: "", state: "working")
        threads[index].messages.append(reply)
        drafts[id] = ""; activeThread = id
        persist(id)

        var picked: (any DeviceController, String)?
        #if AGENTONE_DEVCONTROL
        if target == "device" { picked = (thisPhone, "device") }
        #endif
        let device: any DeviceController
        let key: String
        if let picked { (device, key) = picked }
        else if target == "web" { device = browser; key = "web" }
        else if let remote = connection.remoteDevice() { device = remote; key = "remote-\(connection.remoteURL)" }
        else { device = phone; key = "phone" }
        let agent: PhoneAgent
        if let existing = agents[key] { agent = existing }
        else {
            agent = PhoneAgent(device: device, storageName: "chat-\(key == "device" ? "device" : target == "web" ? "web" : "phone").sqlite")
            agents[key] = agent
        }
        activeAgent = agent
        BackgroundRun.shared.begin(title: text) { [weak self] in self?.stop() }
        LiveRun.shared.begin(task: text)
        Task {
            if device is TestPhone { try? await phone.waitUntilReady() }
            let ending = await agent.run(task: text, threadID: id.uuidString, history: history, onStep: { [weak self] step in
                await self?.record(step, threadID: id, replyID: reply.id)
            }, approve: { [weak self] summary, _ in
                guard let self else { return false }
                return await self.requestApproval(summary, device: device)
            })
            complete(ending, threadID: id, replyID: reply.id)
            activeThread = nil; activeAgent = nil
            let success: Bool
            if case .done = ending { success = true } else { success = false }
            BackgroundRun.shared.end(success: success)
            LiveRun.shared.end(AgentRunModel.describe(ending))
            print("AGENT_ONE_RESULT \(AgentRunModel.describe(ending))")
            if let phone = device as? TestPhone { print("AGENT_ONE_STATE \(await phone.stateJSON())") }
        }
    }

    /// A message sent while this chat's agent is working joins the run (PiDurableKit steering) instead of waiting.
    func steer(in id: UUID) {
        let text = (drafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeThread == id, !text.isEmpty, let agent = activeAgent, let index = threads.firstIndex(where: { $0.id == id }) else { return }
        let working = threads[index].messages.lastIndex(where: { $0.role == "assistant" }) ?? threads[index].messages.endIndex
        threads[index].messages.insert(ChatMessage(role: "user", text: text), at: working)
        drafts[id] = ""
        persist(id)
        Task { await agent.steer(text) }
    }

    private func record(_ step: PhoneAgent.Step, threadID: UUID, replyID: UUID) {
        guard let t = threads.firstIndex(where: { $0.id == threadID }), let m = threads[t].messages.firstIndex(where: { $0.id == replyID }) else { return }
        threads[t].messages[m].actions.append(ChatAction(id: step.number, text: step.text))
        if let data = step.screenshot, let source = UIImage(data: data) {
            let size = CGSize(width: 300, height: 300 * source.size.height / source.size.width)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            threads[t].messages[m].preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.65)
        }
        BackgroundRun.shared.progress(step: step.number, of: 40, detail: step.text)
        LiveRun.shared.update(step: step.number, detail: step.text)
        persist(threadID)
    }

    private func complete(_ ending: PhoneAgent.Ending, threadID: UUID, replyID: UUID) {
        guard let t = threads.firstIndex(where: { $0.id == threadID }), let m = threads[t].messages.firstIndex(where: { $0.id == replyID }) else { return }
        switch ending {
        case .done(let text): threads[t].messages[m].text = text; threads[t].messages[m].state = "done"
        case .failed(let text): threads[t].messages[m].text = text; threads[t].messages[m].state = "failed"
        case .stopped: threads[t].messages[m].text = "Stopped. Send another message when you’re ready."; threads[t].messages[m].state = "stopped"
        }
        persist(threadID)
    }

    private func requestApproval(_ text: String, device: any DeviceController) async -> Bool {
        #if DEBUG
        if device is TestPhone && UserDefaults.standard.bool(forKey: "autoAllow") { return true }
        #endif
        #if AGENTONE_DEVCONTROL
        // The agent may be in Safari or another app: bring Agent One forward so the Allow card is on screen, and go
        // back to that app after the answer.
        if let phone = device as? OnDeviceController, let own = Bundle.main.bundleIdentifier {
            let previous = phone.frontBundleID
            try? await phone.launch(bundleID: own)
            let allowed = await withCheckedContinuation { approval = Approval(text: text, continuation: $0) }
            if let previous, previous != own { try? await phone.launch(bundleID: previous) }
            return allowed
        }
        #endif
        return await withCheckedContinuation { approval = Approval(text: text, continuation: $0) }
    }
    /// The screen the agent is on, from its latest step, shown on the Allow card.
    var approvalPicture: Data? { threads.first { $0.id == activeThread }?.messages.last { $0.role == "assistant" }?.preview }
    func answer(_ allow: Bool) { let pending = approval; approval = nil; pending?.continuation.resume(returning: allow) }
    func stop() { answer(false); let agent = activeAgent; Task { await agent?.stop() } }

    private func saveOnPhone() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(threads).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        } catch { storageError = "Could not save chats: \(error.localizedDescription)" }
    }

    private func persist(_ id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].revision += 1; threads[index].updatedAt = Date()
        saveOnPhone()
        let chat = threads[index]
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            do {
                var request = request(path: "api/threads/\(id.uuidString)")
                request.httpMethod = "PUT"; request.httpBody = try Self.encoder().encode(chat)
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                syncError = nil
            } catch { syncError = "Saved on this iPhone. Waiting to sync with your Mac." }
        }
    }

    private func request(path: String) -> URLRequest {
        let base = URL(string: UserDefaults.standard.string(forKey: "phoneuse.bridgeURL") ?? "http://127.0.0.1:8766")!
        var request = URLRequest(url: base.appendingPathComponent(path)); request.timeoutInterval = 8
        request.setValue(clientID, forHTTPHeaderField: "x-agentone-client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func refresh() async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(path: "api/threads"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            struct Response: Decodable { var threads: [ChatThread] }
            let remote = try Self.decoder().decode(Response.self, from: data).threads
            for var chat in remote {
                guard chat.id != activeThread else { continue }
                if let i = threads.firstIndex(where: { $0.id == chat.id }) {
                    if chat.revision > threads[i].revision { threads[i] = chat }
                } else {
                    for m in chat.messages.indices where chat.messages[m].state == "working" {
                        chat.messages[m].state = "interrupted"; chat.messages[m].text = "This run was interrupted. Send a message to continue."
                    }
                    threads.append(chat)
                }
            }
            saveOnPhone(); syncError = nil
            // Flush phone-side edits made while the bridge was unavailable.
            for chat in threads where chat.revision > (remote.first { $0.id == chat.id }?.revision ?? 0) { persist(chat.id) }
        } catch { syncError = "Saved on this iPhone. Waiting to sync with your Mac." }
    }
}

/// Agent One's accent, after Muse: a soft blue for fills (your bubbles, buttons), with dark icons and text on it.
private let chatPurple = Color(red: 0.80, green: 0.898, blue: 1.0)
private let chatInk = Color(uiColor: .label)
/// Very pale grey page, white in dark mode's place of the system background.
private let chatPage = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemBackground : UIColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1) })

/// Muse-style send button: a light-blue circle with a dark arrow.
private struct SendCircle: View {
    var body: some View {
        Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(chatInk)
            .frame(width: 34, height: 34).background(chatPurple, in: Circle()).padding(4)
    }
}

/// Full-screen Allow card: what the agent wants to do, the screen it is on, and two clear choices.
private struct ApprovalCard: View {
    let text: String
    let picture: Data?
    let answer: (Bool) -> Void
    private var payment: Bool { text.hasPrefix("pay:") }
    var body: some View {
        VStack(spacing: 18) {
            Text(payment ? "Pay and place the order?" : "Allow this action?").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(payment ? "Payment: \(text.dropFirst(4).trimmingCharacters(in: .whitespaces))" : text)
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let picture, let image = UIImage(data: picture) {
                Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary)).frame(maxHeight: 380)
            }
            Spacer(minLength: 0)
            Button { answer(true) } label: { Text("Allow").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.borderedProminent).tint(chatPurple).foregroundStyle(chatInk)
            Button(role: .cancel) { answer(false) } label: { Text("Don’t allow").frame(maxWidth: .infinity) }
        }.padding(24)
    }
}

struct ChatsHome: View {
    let settings: SettingsViewModel
    let connection: ConnectionModel
    @State private var workspace = ChatWorkspace()
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var onlyWorking = false
    @State private var showSettings = false
    @State private var launched = false
    var filtered: [ChatThread] {
        workspace.ordered.filter { (!onlyWorking || $0.working) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }) }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if workspace.threads.isEmpty {
                    VStack(spacing: 18) {
                        Text("A little help, one chat away.").font(.title3.weight(.semibold))
                        Text("Start a conversation. Agent One can use your phone, keep you updated, and pick up where you left off.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Start a chat") { path.append(workspace.create()) }.buttonStyle(.borderedProminent).tint(chatPurple).foregroundStyle(chatInk)
                    }.frame(maxWidth: .infinity).padding(.vertical, 64).listRowSeparator(.hidden)
                } else {
                    ForEach(filtered) { thread in
                        NavigationLink(value: thread.id) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(thread.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(thread.updatedAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    if thread.working {
                                        HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Working on it…").font(.subheadline).foregroundStyle(.secondary) }
                                    } else { Text(thread.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                }
                            }.padding(.vertical, 6)
                        }.listRowSeparatorTint(Color(uiColor: .separator).opacity(0.5))
                    }
                }
                if let error = workspace.storageError ?? workspace.syncError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(chatPage)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
                ToolbarItem(placement: .topBarTrailing) { Button { onlyWorking.toggle() } label: { Image(systemName: onlyWorking ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }.accessibilityLabel(onlyWorking ? "Show all chats" : "Show active chats") }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    HStack { Image(systemName: "magnifyingglass"); TextField("Search chats", text: $search).accessibilityLabel("Search chats") }
                        .foregroundStyle(.secondary).padding(13).background(.thinMaterial, in: Capsule())
                    Button { path.append(workspace.create()) } label: { Image(systemName: "square.and.pencil").font(.title3).frame(width: 48, height: 48).background(.thinMaterial, in: Circle()) }
                        .accessibilityLabel("New chat")
                }.padding(.horizontal, 18).padding(.vertical, 8).background(.ultraThinMaterial)
            }
            .navigationDestination(for: UUID.self) { id in ChatDetail(workspace: workspace, threadID: id, connection: connection) }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsScreen(model: settings).navigationTitle("Settings")
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 14) {
                                NavigationLink("Saved logins") { SavedLoginsView() }
                                NavigationLink("Connected services") { ConnectedServicesView() }
                            }.padding()
                        }
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
            }
        }
        // Keep the web views attached while a chat is visible so screenshots and
        // background phone actions still render, without putting the phone above the chat.
        .background {
            if !workspace.showingPhone {
                ZStack {
                    TestPhoneView(phone: workspace.phone)
                    WebBrowserView(device: workspace.browser)
                }.frame(width: 360, height: 800).opacity(0.001).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $workspace.showingPhone) {
            NavigationStack {
                Group {
                    if workspace.previewTarget == "web" { WebBrowserView(device: workspace.browser) }
                    else { TestPhoneView(phone: workspace.phone) }
                }.navigationTitle("Phone").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { workspace.showingPhone = false } } }
            }
        }
        .tint(chatInk)
        .fullScreenCover(isPresented: Binding(get: { workspace.approval != nil }, set: { if !$0 && workspace.approval != nil { workspace.answer(false) } })) {
            ApprovalCard(text: workspace.approval?.text ?? "", picture: workspace.approvalPicture) { workspace.answer($0) }
        }
        .onOpenURL { if $0 == RunLinks.stop { workspace.stop() } }
        .task {
            guard !launched else { return }; launched = true
            await workspace.refresh()
            if let task = UserDefaults.standard.string(forKey: "task"), !task.isEmpty {
                let id = workspace.create(target: ["web", "device"].contains(UserDefaults.standard.string(forKey: "drive") ?? "") ? UserDefaults.standard.string(forKey: "drive")! : "phone")
                workspace.drafts[id] = task; path.append(id); workspace.send(in: id, connection: connection)
                // Test hook: -steer "text" -steerAfter seconds sends a second message while the run is going.
                if let steer = UserDefaults.standard.string(forKey: "steer"), !steer.isEmpty {
                    let delay = max(1, UserDefaults.standard.integer(forKey: "steerAfter"))
                    Task { try? await Task.sleep(for: .seconds(delay)); workspace.drafts[id] = steer; workspace.steer(in: id); print("AGENT_STEERED \(steer)") }
                }
            }
        }
    }
}

struct ChatDetail: View {
    @Bindable var workspace: ChatWorkspace
    let threadID: UUID
    let connection: ConnectionModel
    @State private var showConnection = false
    @FocusState private var composing: Bool
    var thread: ChatThread? { workspace.thread(threadID) }
    var draft: Binding<String> { Binding(get: { workspace.drafts[threadID] ?? "" }, set: { workspace.drafts[threadID] = $0 }) }
    private func openPhone() { workspace.previewTarget = thread?.target ?? "phone"; workspace.showingPhone = true }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let thread, thread.messages.isEmpty {
                        VStack(spacing: 16) {
                            Text("What would you like done?").font(.title3.weight(.semibold))
                            Text("Ask naturally. I’ll work through it here.").foregroundStyle(.secondary)
                            ForEach(["Open Calculator and work out 128 times 46.", "Create a note with my shopping list.", "Set my desk lamp to 30%."], id: \.self) { task in
                                Button(task) { workspace.drafts[threadID] = task; composing = true }
                                    .font(.subheadline).padding(12).frame(maxWidth: .infinity).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }.frame(maxWidth: .infinity).padding(.top, 70).padding(.horizontal, 12)
                    }
                    if let thread {
                        ForEach(thread.messages) { message in
                            ChatMessageView(message: message, showPhone: openPhone).id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 16).padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread?.revision) { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { scroll.scrollTo("bottom", anchor: .bottom) }
        }
        .background(chatPage)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Claude").font(.headline)
                    if workspace.approval != nil { Text("Waiting for your OK").font(.caption2).foregroundStyle(.secondary) }
                    else if workspace.activeThread == threadID { Text("Working on your phone…").font(.caption2).foregroundStyle(.secondary) }
                }
                    .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("View phone", systemImage: "iphone", action: openPhone)
                    Button("Connection settings", systemImage: "network") { showConnection = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Chat options")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if workspace.activeThread != nil && workspace.activeThread != threadID {
                    Text("Another chat is using the phone. You can send this when it finishes.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: openPhone) { Image(systemName: "plus").font(.title3).frame(width: 36, height: 42) }.accessibilityLabel("View phone")
                    TextField("Message", text: draft, axis: .vertical).lineLimit(1...5).focused($composing)
                        .padding(.vertical, 11).accessibilityLabel("Message")
                    if workspace.activeThread == threadID, !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Typing while the agent works redirects it without stopping the run.
                        Button {
                            composing = false; workspace.steer(in: threadID)
                        } label: { SendCircle() }.accessibilityLabel("Send to the running agent")
                    } else if workspace.activeThread == threadID {
                        Button { workspace.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.secondary).padding(8) }.accessibilityLabel("Stop agent")
                    } else {
                        Button {
                            composing = false; workspace.send(in: threadID, connection: connection)
                        } label: { SendCircle() }
                            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.activeThread != nil)
                            .accessibilityLabel("Send message")
                    }
                }.padding(.horizontal, 5).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 25))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            }.padding(.horizontal, 14).padding(.vertical, 8).background(chatPage)
        }
        .sheet(isPresented: $showConnection) { HermesView(connection: connection) }
    }
}

private struct ChatMessageView: View {
    let message: ChatMessage
    let showPhone: () -> Void
    @State private var expanded = false
    var user: Bool { message.role == "user" }
    var body: some View {
        VStack(alignment: user ? .trailing : .leading, spacing: 10) {
            Text(message.createdAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            if !message.actions.isEmpty || message.state == "working" {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        if message.state == "working" { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                        Text(message.state == "working" ? "Working on your phone" : "Used your phone")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    if let data = message.preview, let image = UIImage(data: data) {
                        Button(action: showPhone) {
                            Image(uiImage: image).resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 155).clipped()
                                .overlay(alignment: .bottomTrailing) { Image(systemName: "arrow.up.right.square").padding(9).background(.ultraThinMaterial, in: Circle()).padding(8) }
                        }.buttonStyle(.plain).clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("View phone preview")
                    }
                    if let action = message.actions.last { Text(action.text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if !message.actions.isEmpty {
                        Button { withAnimation { expanded.toggle() } } label: {
                            Label(expanded ? "Hide actions" : "Show \(message.actions.count) actions", systemImage: expanded ? "chevron.up" : "chevron.down").font(.caption)
                        }
                        if expanded {
                            ForEach(message.actions) { action in
                                HStack(alignment: .top) { Text("\(action.id)").foregroundStyle(.tertiary); Text(action.text).textSelection(.enabled) }.font(.caption)
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: 275, alignment: .leading).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            }
            if !message.text.isEmpty {
                HStack {
                    if user { Spacer(minLength: 48) }
                    Text(message.text).textSelection(.enabled).font(.body)
                        .foregroundStyle(.primary).padding(.horizontal, 14).padding(.vertical, 11)
                        .background(user ? chatPurple : Color(uiColor: .secondarySystemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: user ? 18 : 4, bottomTrailingRadius: user ? 4 : 18, topTrailingRadius: 18))
                    if !user { Spacer(minLength: 48) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }
}
