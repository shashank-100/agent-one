import Foundation
import PhoneUseCore
import PiDurableKit
import UIKit

/// The agent on PiDurableKit (Finn Voorhees, CC0): the phone's actions are its tools, approvals are a hook, and each
/// task is its own conversation with its own context, like Pelican's profiles. Runs are durable: a task the system
/// kills picks up again on the next launch. The model runs through the local Claude Code bridge on the Mac.
actor PhoneAgent {
    static let provider: ProviderID = "agentone"
    static let model = ModelRef(provider: provider, modelId: "agent-one")

    /// What the screen shows the person while a run goes on.
    struct Step: Sendable { let number: Int; let text: String; var screenshot: Data? = nil }
    enum Ending: Sendable { case done(String), failed(String), stopped }

    /// Asked before a tap that sends, pays, approves, cancels or deletes. Set by the UI.
    typealias Approver = @Sendable (_ summary: String, _ target: String) async -> Bool

    private let device: any DeviceController
    private let storageName: String
    private var harness: Harness?
    private var models: Models?
    private var current: Conversation?
    private var steps = 0
    /// Set when the person allows the payment step; covers placing that order in this run.
    private(set) var paymentAllowed = false
    private func allowPayment() { paymentAllowed = true }
    private var ending: Ending?
    private var onStep: (@Sendable (Step) async -> Void)?
    private var approve: Approver?
    private var lastLabel = "", lastScreen: ScreenFingerprint?, streak = 0
    private var shown: [ScreenElement] = []
    private var wantImage = false
    /// In-app the list comes from reading the screenshot's text, so icon-only buttons are missing from it.
    private var textOnlyList: Bool {
        #if AGENTONE_DEVCONTROL
        device is OnDeviceController
        #else
        false
        #endif
    }
    private var lastListHadSecret = false
    private var started = Date()

    init(device: any DeviceController, storageName: String = "agent.sqlite") {
        self.device = device
        self.storageName = storageName
    }

    func run(task: String, threadID: String? = nil, history: String = "", onStep: @escaping @Sendable (Step) async -> Void, approve: @escaping Approver) async -> Ending {
        self.onStep = onStep
        self.approve = approve
        steps = 0
        paymentAllowed = false
        ending = nil
        started = Date()
        lastLabel = ""; lastScreen = nil; streak = 0; shown = []
        do {
            let harness = try await openHarness()
            let (shot, list) = try await observe()
            let key = threadID.map { "phoneuse.conversation.\(storageName).\($0)" }
            let savedID = key.map { UserDefaults.standard.integer(forKey: $0) } ?? 0
            let restored = savedID > 0 ? try await harness.conversation(ConversationID(savedID)) : nil
            let conversation: Conversation
            if let restored { conversation = restored }
            else {
                conversation = try await harness.createConversation(agent: AgentChange(model: try await chooseModel(), extensions: .only(phoneExtension())))
                if let key { UserDefaults.standard.set(conversation.id.rawValue, forKey: key) }
            }
            current = conversation
            let context = restored == nil && !history.isEmpty ? "Previous messages in this chat, for context:\n\(history)\n\n" : ""
            let submission = try await conversation.submit([
                .text("\(context)Task: \(task)\n\n\(Self.sizeLine(shot))\(list)"),
                .image(ImageContent(data: shot.jpeg, mimeType: "image/jpeg")),
            ])
            _ = try await submission.wait()
        } catch is CancellationError {
            return .stopped
        } catch {
            return ending ?? .failed("The run stopped: \(error.localizedDescription)")
        }
        return ending ?? .failed("The model stopped without finishing.")
    }

    /// Adds the person's message to the running task; the model reads it before its next step.
    func steer(_ text: String) async {
        _ = try? await current?.submit("Message from the user while you work (it changes or adds to the task): \(text)", whenBusy: .steer)
    }

    func stop() async {
        ending = .stopped
        try? await current?.abort()
    }

    private func openHarness() async throws -> Harness {
        if let harness { return harness }
        let models = Models(credentials: InMemoryCredentialStore())  // keys are set per run from our own Keychain store; nothing to persist here
        // The local bridge speaks the OpenAI chat API and runs Claude Code; no token ships in the app.
        try await models.register(CustomProvider(
            id: Self.provider, name: "Agent One", baseURL: TestPhone.base.appendingPathComponent("v1"),
            api: .openAICompletions, apiKey: "none",
            models: [.init(id: "agent-one", input: ["text", "image"], contextWindow: 128_000, maxTokens: 4096,
                           compat: ["supportsDeveloperRole": false, "supportsStore": false])]))
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Several tool calls in one reply run one after another, in order (tap a field, type, Return).
        let opened = try await Harness.open(.sqlite(at: folder.appendingPathComponent(storageName)), models: models,
                                            extensions: [phoneExtension()], settings: Settings(toolExecution: .sequential))
        // pi-durable resumes unfinished work when storage opens. A run cut off by a crash or a kill must not carry on
        // by itself next to a new one (twice it reached a checkout page in parallel), so every conversation is stopped
        // here; the chat shows it as interrupted and the next message continues from its history.
        var cursor: Cursor?
        repeat {
            let page = try await opened.conversations(limit: 100, after: cursor)
            for record in page.items { try? await opened.conversation(record.id)?.abort() }
            cursor = page.next
        } while cursor != nil
        harness = opened
        self.models = models
        return opened
    }

    /// The local bridge runs the actual Claude Code CLI. No direct provider or API-key route is used.
    private func chooseModel() async throws -> ModelRef {
        /* Direct provider selection disabled: always use the local Claude Code bridge.
        guard let models else { return Self.model }
        let saved = ModelSettings()
        let chosen = UserDefaults.standard.string(forKey: "phoneuse.provider").flatMap(ModelProvider.init(rawValue:)) ?? .claude
        if chosen == .claude, let key = saved.secret(for: .claude), key.hasPrefix("sk-ant-api") {
            try await models.setAPIKey(key, for: .anthropic)
            return .anthropic(ModelProvider.claude.defaultModel)
        }
        // GLM disabled.
//         if chosen == .glm, let key = saved.secret(for: .glm), !key.isEmpty {
//             try await models.register(CustomProvider(
//                 id: "zai", name: "Z.ai", baseURL: URL(string: "https://api.z.ai/api/coding/paas/v4")!, api: .openAICompletions,
//                 apiKey: key, models: [.init(id: ModelProvider.glm.defaultModel, input: ["text", "image"], contextWindow: 128_000, maxTokens: 4096,
//                                             compat: ["supportsDeveloperRole": false, "supportsStore": false])]))
//             return ModelRef(provider: "zai", modelId: ModelProvider.glm.defaultModel)
//         }
        */
        return Self.model
    }

    // MARK: - Tools

    private struct Point: Decodable, Sendable { var element: Int?; var x: Int?; var y: Int?; var target: String?; var irreversible: Bool? }
    private struct SwipeArgs: Decodable, Sendable { var from_x: Int; var from_y: Int; var to_x: Int; var to_y: Int }
    private struct ScrollArgs: Decodable, Sendable { var direction: String }
    private struct TypeArgs: Decodable, Sendable { var element: Int?; var x: Int?; var y: Int?; var text: String; var field: String?; var clear: Bool? }
    private struct AppArgs: Decodable, Sendable { var name: String }
    private struct MapsSearchArgs: Decodable, Sendable { var query: String; var near: String? }
    private struct MapsRouteArgs: Decodable, Sendable { var from: String; var to: String; var mode: String? }

    /// Opens shortcuts://run-shortcut, the public way for an app to run a shortcut; iOS then shows the Shortcuts app.
    @MainActor private static func runShortcut(_ name: String) async throws {
        var url = URLComponents(string: "shortcuts://run-shortcut")!
        url.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let link = url.url, await UIApplication.shared.open(link) else {
            throw PhoneAgentError("Shortcuts could not be opened to run \"\(name)\".")
        }
    }
    private struct FillArgs: Decodable, Sendable { var element: Int?; var name: String; var clear: Bool? }
    /// Saved logins (iPhone Keychain). The agent types them; the model only ever sees their names.
    private let vault = KeychainVault()
    private struct WaitArgs: Decodable, Sendable { var seconds: Int? }
    private struct FinishArgs: Decodable, Sendable { var success: Bool; var answer: String }
    private struct ReasonArgs: Decodable, Sendable { var reason: String }

    nonisolated private func phoneExtension() -> Extension {
        let x = JSONSchema.integer("Horizontal position in pixels of the screenshot, 0 at the left edge")
        let y = JSONSchema.integer("Vertical position in pixels of the screenshot, 0 at the top edge")
        let element = JSONSchema.integer("The element's number in the list; the tap lands on its centre. Leave out to use x and y.").optional
        return Extension("phone") {
            PromptSection("phone", tag: false, text: Prompt.system(installedApps: [], space: .pixels))
            PromptSection("saved-logins", tag: false) { _ in await self.vault.catalog() }
            PromptSection("elements", tag: false, text: "Each turn may list the elements on screen with numbers. To tap, hold or type into something in the list, give its number in \"element\" instead of x and y. Use x and y only for things not in the list. When the list is unchanged, the numbers from the last list still hold.")
            Tool("tap", description: "Tap once on an element from the list, or at a point.", parameters: .object([
                "element": element, "x": x.optional, "y": y.optional, "target": .string("The text on the thing you tap, exactly as written"),
                "irreversible": .boolean("True if this tap sends, posts, pays, orders, books, approves, cancels or deletes something"),
            ])) { (a: Point, _) in
                let p = try await self.point(a.element, a.x, a.y)
                return try await self.act("tap \"\(a.target ?? "")\" @ \(p.x),\(p.y)") { try await $0.tap(x: p.x, y: p.y) }
            }
            Tool("long_press", description: "Press and hold an element or a point.", parameters: .object(["element": element, "x": x.optional, "y": y.optional, "target": .string("What is under the finger").optional])) { (a: Point, _) in
                let p = try await self.point(a.element, a.x, a.y)
                return try await self.act("long_press @ \(p.x),\(p.y)") { try await $0.longPress(x: p.x, y: p.y, seconds: 0.8) }
            }
            Tool("swipe", description: "Drag slowly from one point to another without momentum. For sliders and picker wheels.", parameters: .object([
                "from_x": x, "from_y": y, "to_x": x, "to_y": y,
            ])) { (a: SwipeArgs, _) in
                try await self.act("swipe") { try await $0.swipe(fromX: a.from_x, fromY: a.from_y, toX: a.to_x, toY: a.to_y, seconds: 0.45) }
            }
            Tool("scroll", description: "Scroll the content about half a screen. \"down\" reveals what is further down.", parameters: .object([
                "direction": .string(enum: ["up", "down", "left", "right"]),
            ])) { (a: ScrollArgs, _) in
                try await self.act("scroll \(a.direction)") { device in
                    let (fy, ty, fx, tx): (Int, Int, Int, Int) = switch a.direction {
                    case "up": (900, 1600, 540, 540)
                    case "left": (1200, 1200, 240, 840)
                    case "right": (1200, 1200, 840, 240)
                    default: (1600, 900, 540, 540)
                    }
                    try await device.swipe(fromX: fx, fromY: fy, toX: tx, toY: ty, seconds: 0.5)
                }
            }
            Tool("type_text", description: "Type into a text field. Give the field's position and it taps the field first. Set clear to replace what it holds.", parameters: .object([
                "element": element, "x": x.optional, "y": y.optional, "text": .string("The text to type"), "field": .string("What the field is").optional,
                "clear": .boolean("True to replace the field's current text").optional,
            ])) { (a: TypeArgs, _) in
                let p: (x: Int, y: Int)? = (a.element != nil || a.x != nil) ? try await self.point(a.element, a.x, a.y) : nil
                return try await self.act("type_text \"\(a.text)\"") { device in
                    if let p { try await device.tap(x: p.x, y: p.y); try await Task.sleep(for: .milliseconds(300)) }
                    if await device.focusedFieldIsSecure() { throw PhoneAgentError("This is a password field. Use hand_over so the user types it.") }
                    if a.clear == true { try await device.clearText() }
                    try await device.typeText(a.text)
                }
            }
            Tool("fill_credential", description: "Type a saved login (phone number, email or password) into a field. You give its name; the phone types the value, which you never see.", parameters: .object([
                "element": JSONSchema.integer("The field's number in the list; leave out if it already has the keyboard").optional,
                "name": .string("The saved login's name, as listed"),
                "clear": JSONSchema.boolean("True to replace what the field holds").optional,
            ])) { (a: FillArgs, _) in
                try await self.fill(a.name, element: a.element, clear: a.clear ?? false)
            }
            Tool("look", description: "Get a screenshot of the screen now, when the element list is not enough to decide.") { _ in
                try await self.look()
            }
            Tool("press_enter", description: "Press the Return / Search key.") { _ in try await self.act("press_enter") { try await $0.pressEnter() } }
            Tool("open_app", description: "Open an installed app by its name.", parameters: .object(["name": .string("The app's name")])) { (a: AppArgs, _) in
                try await self.act("open_app \"\(a.name)\"") { device in
                    if try await !device.openApp(named: a.name) { throw PhoneAgentError("No installed app matches \"\(a.name)\".") }
                }
            }
            Tool("run_shortcut", description: "Run one of the user's Shortcuts by its exact name (as in the Shortcuts app). Faster than doing the same steps by hand; the result shows on the next screen.", parameters: .object(["name": .string("The shortcut's name")])) { (a: AppArgs, _) in
                try await self.act("run_shortcut \"\(a.name)\"") { _ in try await Self.runShortcut(a.name) }
            }
            Tool("maps_search", description: "Find places with Apple Maps (restaurants, shops, addresses), answered directly without opening the Maps app. Give near to search around a place.", parameters: .object([
                "query": .string("What to look for, e.g. \"pharmacy\" or \"Blue Tokai coffee\""), "near": .string("A place or address to search around").optional,
            ])) { (a: MapsSearchArgs, _) in
                do { return ToolResult.text(try await MapsTools.search(a.query, near: a.near)) } catch { return ToolResult.error("Maps: \(error)") }
            }
            Tool("maps_directions", description: "Travel time, distance and route between two places with Apple Maps, without opening the Maps app.", parameters: .object([
                "from": .string("Start place or address"), "to": .string("Destination place or address"), "mode": .string("driving, walking or transit").optional,
            ])) { (a: MapsRouteArgs, _) in
                do { return ToolResult.text(try await MapsTools.directions(from: a.from, to: a.to, mode: a.mode)) } catch { return ToolResult.error("Maps: \(error)") }
            }
            Tool("go_home", description: "Go to the home screen.") { _ in try await self.act("go_home") { try await $0.pressHome() } }
            Tool("go_back", description: "Go back to the previous screen.") { _ in try await self.act("go_back") { try await $0.pressBack() } }
            Tool("wait", description: "Wait for the screen to finish loading.", parameters: .object(["seconds": .integer("1 to 10").optional])) { (a: WaitArgs, _) in
                try await self.act("wait") { _ in try await Task.sleep(for: .seconds(min(10, max(1, a.seconds ?? 2)))) }
            }
            Tool("hand_over", description: "Give the phone to the user for a login, password, code or payment authorisation.", parameters: .object([
                "reason": .string("What the user needs to do"),
            ])) { (a: ReasonArgs, _) in
                await self.finish(.failed("Needs you: \(a.reason)"))
                return ToolResult.text("Handed to the user.").terminating()
            }
            Tool("finish", description: "End the task.", parameters: .object([
                "success": .boolean("True if the task was completed"), "answer": .string("What was done or found, or why it could not be done"),
            ])) { (a: FinishArgs, _) in
                await self.finish(a.success ? .done(a.answer) : .failed(a.answer))
                return ToolResult.text("Finished.").terminating()
            }
            // Approvals: the person allows each irreversible tap before it happens.
            Hook.beforeTool { call, _ in
                guard call.name == "tap" else { return .allow }
                let target = call.arguments["target"]?.stringValue ?? ""
                let flagged = call.arguments["irreversible"]?.boolValue ?? false
                let guardRail = RiskGuard()
                let refused = ToolDecision.block("The user refused this tap. Do not look for another way; call finish with success false.")
                // Buying is allowed once, at the payment step; placing the order after that goes ahead without asking.
                if guardRail.isPaymentStep(target) {
                    if await self.paymentAllowed { return .allow }
                    guard await self.askApproval("pay: \"\(target)\"", target: target) else { return refused }
                    await self.allowPayment()
                    return .allow
                }
                guard guardRail.needsApproval(target: target, flaggedIrreversible: flagged) else { return .allow }
                if guardRail.placesOrder(target), await self.paymentAllowed { return .allow }
                return await self.askApproval("tap \"\(target)\"", target: target) ? .allow : refused
            }
        }
    }

    /// Performs one action, then returns the next screenshot so the model sees the result.
    private func act(_ label: String, _ action: @Sendable (any DeviceController) async throws -> Void) async throws -> ToolResult {
        steps += 1
        if steps > 40 { ending = .failed("Stopped at the step limit."); return ToolResult.text("Step limit reached.").terminating() }
        var note = "Done."
        var isError = false
        let t0 = Date()
        do { try await action(device) } catch { note = "That did not work: \(error.localizedDescription)"; isError = true }
        let t1 = Date()
        let (shot, list) = try await observe()
        print(String(format: "AGENT_STEP %d [%.0fs] %@ (act %.1fs, observe %.1fs)", steps, Date().timeIntervalSince(started), label, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
        // Never a picture (to the model, or as a preview saved in the thread) while a saved login is visible on
        // screen, which the redacted list shows as ••••.
        lastListHadSecret = list.contains("••••") || (list.contains("unchanged") && lastListHadSecret)
        await onStep?(Step(number: steps, text: isError ? "\(label) — \(note)" : label, screenshot: lastListHadSecret ? nil : shot.jpeg))
        // Stuck: the same action on an unchanged screen. Warn at 3 in a row, stop at 6.
        let screen = ScreenFingerprint(jpeg: shot.jpeg)
        if label == lastLabel, let screen, let lastScreen, screen.isSameScreen(as: lastScreen) { streak += 1 } else { streak = 1 }
        lastLabel = label; lastScreen = screen
        if streak >= 6 { ending = .failed("Stopped: the same action kept failing."); return ToolResult.text(note).terminating() }
        if streak >= 3 { note += " This is the same action on an unchanged screen again; it is not working. Try something else." }
        // Text first, picture on demand (macos-harness): the image goes back only after an error, when nothing is
        // listed, or when the model asked with look.
        let withImage = !lastListHadSecret && (isError || list.isEmpty || wantImage)
        wantImage = false
        var output: [ContentBlock] = [.text("\(note)\n\(Self.sizeLine(shot))\(list)" + (withImage ? "" : textOnlyList ? "\n(No screenshot: this list is only the text read off the screen; icons and pictures are not in it. Call look to see the screen.)" : "\n(No screenshot: the element list is the screen. Call look to see it.)"))]
        if withImage { output.append(.image(ImageContent(data: shot.jpeg, mimeType: "image/jpeg"))) }
        return ToolResult(output: output, isError: isError)
    }

    /// Waits until the screen stops changing (up to ~2.5 s), then returns it with the element list. The list is
    /// sent in full only when it changed, as macOS Harness does, to keep each step small.
    private func observe() async throws -> (Screenshot, String) {
        try await Task.sleep(for: .milliseconds(400))
        var shot = try await device.screenshot()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(450))
            let next = try await device.screenshot()
            let same = ScreenFingerprint(jpeg: next.jpeg).flatMap { a in ScreenFingerprint(jpeg: shot.jpeg).map { a.isSameScreen(as: $0) } } ?? false
            shot = next
            if same { break }
        }
        guard let reader = device as? any ElementReader else { return (shot, "") }
        let elements = await reader.elements()
        if !shown.isEmpty, elements == shown { return (shot, "\nElements on screen: unchanged since the last list (same numbers).") }
        shown = elements
        let lines = elements.enumerated().map { i, e in "\(i + 1) \(e.tappable ? "•" : "-") \"\(e.text)\" [x=\(e.x) y=\(e.y) w=\(e.width) h=\(e.height)]" }
        // A field that holds a saved login must not show its value to the model.
        return (shot, await vault.redact("\nElements on screen, numbered (• can be tapped):\n" + lines.joined(separator: "\n")))
    }

    /// The point to act on: the centre of a listed element, or the given pixels.
    private func point(_ element: Int?, _ x: Int?, _ y: Int?) throws -> (x: Int, y: Int) {
        if let element, element > 0 {
            guard element <= shown.count else { throw PhoneAgentError("There is no element \(element) in the list on this screen.") }
            return shown[element - 1].center
        }
        guard let x, let y else { throw PhoneAgentError("Give an element number, or x and y.") }
        return (x, y)
    }

    /// Types a saved login into a field. Nothing about the value goes into the conversation, and no screenshot follows.
    private func fill(_ name: String, element: Int?, clear: Bool) async throws -> ToolResult {
        guard let credential = await vault.all().first(where: { $0.name == name }) else {
            return ToolResult.error("There is no saved login called \"\(name)\". Use hand_over so the user types it.")
        }
        if let element {
            let p = try point(element, nil, nil)
            try await device.tap(x: p.x, y: p.y)
            try await Task.sleep(for: .milliseconds(300))
        }
        if clear { try? await device.clearText() }
        try await device.typeText(credential.value)
        steps += 1
        // No screenshot with this step: it would show the field, and steps are saved to the chat thread.
        await onStep?(Step(number: steps, text: "fill saved login “\(name)”", screenshot: nil))
        return ToolResult.text("Filled the saved login \(name) (value hidden).")
    }

    private func look() async throws -> ToolResult {
        if lastListHadSecret { return ToolResult.text("No screenshot while a saved login is visible on screen; use the element list.") }
        let shot = try await device.screenshot()
        return ToolResult(output: [.text(Self.sizeLine(shot)), .image(ImageContent(data: shot.jpeg, mimeType: "image/jpeg"))])
    }

    private func finish(_ value: Ending) { ending = value }
    private func askApproval(_ summary: String, target: String) async -> Bool { await approve?(summary, target) ?? false }

    private static func sizeLine(_ shot: Screenshot) -> String {
        "The screenshot is \(shot.width) pixels wide and \(shot.height) pixels high."
    }
}

struct PhoneAgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
