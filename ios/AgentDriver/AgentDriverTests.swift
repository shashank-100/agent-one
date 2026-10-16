import PhoneUseCore
import XCTest

/// Runs the agent with Apple's UI test framework, so it can use any app on the phone: Safari, Settings, the
/// Amazon app. The same engine Pelican uses, started by `xcodebuild test` (simulator, or a cloud iPhone service
/// that runs XCUITests) instead of from inside the app.
///
///     TEST_RUNNER_AGENT_TASK="Search for an iPhone on Amazon in Safari and place an order" \
///       xcodebuild test -scheme AgentOne -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:AgentDriver
///
/// Nobody is at the phone during these runs, so every irreversible tap (Place order, Pay, Send) is refused and the
/// agent stops there and reports; logins and codes stop the run too. Set AGENT_ALLOW=1 only for test accounts.
final class AgentDriverTests: XCTestCase {
    @MainActor
    func testRunTask() async throws {
        // A failed tap or keystroke is the agent's problem to see and fix, not the end of the run.
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        print("AGENT_ENV \(env.keys.filter { $0.hasPrefix("AGENT") }.sorted()) vault readable: \(env["AGENT_VAULT_FILE"].map { FileManager.default.isReadableFile(atPath: $0) } ?? false)")
        let task = env["AGENT_TASK"] ?? "Open Safari, go to amazon.in and search for iPhone"
        let base = URL(string: env["AGENT_SERVER"] ?? "http://127.0.0.1:8766")!
        let device = UITestDevice()
        let user = Unattended(allow: env["AGENT_ALLOW"] == "1")
        var config = AgentConfig()
        // Claude Code uses Opus for the personal setup.
        config.pricing = .opus55
        config.maxSteps = 60
        let started = Date()
        // Saved logins for unattended runs: an owner-only JSON file on the Mac, path given by AGENT_VAULT_FILE.
        let vault = env["AGENT_VAULT_FILE"].map { FileVault(url: URL(fileURLWithPath: $0)) }
        let agent = Agent(device: device, model: LocalModelClient(base: base), user: user, vault: vault, config: config) { progress in
            print("AGENT_STEP \(progress.step) [\(Int(Date().timeIntervalSince(started)))s] \(progress.summary)")
        }
        let result = await agent.run(task: task)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("AGENT_ONE_RESULT \(result.outcome) in \(result.steps) model turns, \(Int(Date().timeIntervalSince(started)))s")
    }
}

/// Checks Agent One's own chat screen end to end: after a restart the saved thread is still listed, and a follow-up
/// sent in it continues the same conversation (the answer depends on the earlier one).
final class ChatFollowUpTests: XCTestCase {
    @MainActor
    func testFollowUpInSavedThread() throws {
        let env = ProcessInfo.processInfo.environment
        let title = env["CHAT_TITLE"] ?? "Open the Calculator"
        let followUp = env["CHAT_FOLLOW_UP"] ?? "Now multiply that result by 2. Tell me the result."
        let expect = env["CHAT_EXPECT"] ?? "288"
        let app = XCUIApplication(bundleIdentifier: "com.agentone.app")
        app.terminate()
        app.activate()   // a fresh launch: the thread list comes from saved storage
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 20), "the saved thread is listed after a restart")
        print("CHAT_CHECK thread listed after restart: \(thread.exists)")
        thread.tap()
        let field = app.textViews["Message"].exists ? app.textViews["Message"] : app.textFields["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(followUp)
        app.buttons["Send message"].tap()
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expect)).firstMatch
        let found = answer.waitForExistence(timeout: 240)
        print("CHAT_CHECK follow-up answer contains \(expect): \(found)")
        XCTAssertTrue(found)
    }
}

/// Answers for an absent person: refuse irreversible taps (unless allowed), stop at logins, skip questions.
struct Unattended: UserInteraction {
    let allow: Bool
    func approve(action summary: String, target: String) async -> Bool {
        print("AGENT_APPROVAL \(allow ? "allowed" : "refused"): \(summary)")
        return allow
    }
    func handOver(reason: String) async -> Bool { print("AGENT_HANDOVER \(reason)"); return false }
    func ask(question: String) async -> String? { print("AGENT_QUESTION \(question)"); return nil }
}

/// The phone through XCUITest's public API. Coordinates are screenshot pixels; XCUITest taps in points.
final class UITestDevice: DeviceController, ElementReader, ElementTapper, ValueSetter, @unchecked Sendable {
    private var front: XCUIApplication
    private var frontID = "com.apple.springboard"
    private var scale: CGFloat = 3

    @MainActor init() { front = XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    private static let apps: [String: String] = [
        "safari": "com.apple.mobilesafari", "settings": "com.apple.Preferences", "photos": "com.apple.mobileslideshow",
        "files": "com.apple.DocumentsApp", "messages": "com.apple.MobileSMS", "contacts": "com.apple.MobileAddressBook",
        "calendar": "com.apple.mobilecal", "maps": "com.apple.Maps", "amazon": "com.amazon.Amazon",
        "agent one": "com.agentone.app",
    ]

    /// The app actually in front, however it was opened (dock tap, link, open_app): the first known app running in
    /// the foreground, else the home screen.
    @MainActor private func refreshFront() {
        if frontID != "com.apple.springboard", front.state == .runningForeground { return }
        for id in Self.apps.values {
            let app = XCUIApplication(bundleIdentifier: id)
            if app.state == .runningForeground { front = app; frontID = id; return }
        }
        front = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        frontID = "com.apple.springboard"
    }

    /// The element that has keyboard focus in the front app, if any.
    @MainActor private func focused() -> XCUIElement? {
        let el = front.descendants(matching: .any).element(matching: NSPredicate(format: "hasKeyboardFocus == true"))
        return el.exists ? el : nil
    }

    @MainActor private func point(_ x: Int, _ y: Int) -> XCUICoordinate {
        front.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: CGFloat(x) / scale, dy: CGFloat(y) / scale))
    }

    func screenshot() async throws -> Screenshot {
        let t0 = Date()
        defer { print("AGENT_TIMING screenshot \(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }
        return try await MainActor.run {
            refreshFront()
            let image = XCUIScreen.main.screenshot().image
            scale = image.scale
            guard let jpeg = image.jpegData(compressionQuality: 0.7) else { throw DeviceUnsupported("no screenshot") }
            return Screenshot(jpeg: jpeg, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
        }
    }

    /// The front app's accessibility tree as elements in screenshot pixels. Off-screen controls are included
    /// (marked above or below), so the agent knows what exists and which way to scroll.
    func elements() async -> [ScreenElement] {
        let t0 = Date()
        defer { print("AGENT_TIMING elements \(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }
        return await MainActor.run {
            refreshFront()
            guard let root = try? front.snapshot() else { return [] }
            let screen = XCUIScreen.main.screenshot().image.size
            var on: [ScreenElement] = [], off: [ScreenElement] = []
            var seen = Set<String>()
            func visit(_ node: XCUIElementSnapshot, depth: Int) {
                guard on.count < 90, depth < 60 else { return }
                let f = node.frame
                let label = [node.label, node.title, (node.value as? String) ?? "", node.placeholderValue ?? ""]
                    .first { !$0.isEmpty }?.replacingOccurrences(of: "\n", with: " ") ?? ""
                let kind: String? = switch node.elementType {
                case .button: "button"
                case .link: "link"
                case .textField, .secureTextField, .searchField: "field"
                case .switch, .toggle: "switch"
                case .slider: "slider"
                case .pickerWheel: "picker"
                case .cell: "cell"
                case .staticText: label.count <= 80 ? "text" : nil
                default: nil
                }
                if let kind, f.width >= 4, f.height >= 4, !label.isEmpty || kind == "field" {
                    let visible = f.maxY > 0 && f.minY < screen.height && f.maxX > 0 && f.minX < screen.width
                    let place: ScreenElement.Place = visible ? .onScreen : (f.minY >= screen.height ? .below : .above)
                    let key = "\(kind)|\(label)|\(visible ? "\(Int(f.midX) / 4),\(Int(f.midY) / 4)" : "off")"
                    let interactive = kind != "text"
                    if !seen.contains(key), visible || (interactive && off.count < 40) {
                        seen.insert(key)
                        let e = ScreenElement(text: String(label.prefix(80)), x: Int(f.minX * scale), y: Int(f.minY * scale),
                                              width: Int(f.width * scale), height: Int(f.height * scale),
                                              tappable: interactive, kind: kind, place: place)
                        if visible { on.append(e) } else { off.append(e) }
                    }
                }
                for child in node.children { visit(child, depth: depth + 1) }
            }
            visit(root, depth: 0)
            return on + off
        }
    }

    /// Taps an element itself: XCTest scrolls it into view first, so the agent can act on anything on the page from
    /// one read. Found again by kind and label (the first match that exists).
    func tap(_ element: ScreenElement) async throws {
        try await MainActor.run {
            let type: XCUIElement.ElementType = switch element.kind {
            case "button": .button
            case "link": .link
            case "field": .textField
            case "switch": .switch
            case "cell": .cell
            default: .any
            }
            let query = front.descendants(matching: type).matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", element.text, element.text, element.text))
            let match = query.firstMatch
            guard match.waitForExistence(timeout: 2) else { throw DeviceUnsupported("could not find “\(element.text)” any more; read the page again") }
            match.tap()
        }
    }

    /// Sets a slider (0–100), a picker wheel (row text) or a field (full text) directly, the way a person would
    /// with the control's own behaviour rather than a guessed drag.
    func setValue(_ value: String, on element: ScreenElement) async throws {
        try await MainActor.run {
            let type: XCUIElement.ElementType = switch element.kind {
            case "slider": .slider
            case "picker": .pickerWheel
            case "field": .any
            default: .any
            }
            let target = CGPoint(x: CGFloat(element.center.x) / scale, y: CGFloat(element.center.y) / scale)
            let candidates = front.descendants(matching: type).allElementsBoundByIndex
            guard let match = candidates.first(where: { $0.exists && $0.frame.contains(target) && ($0.elementType == .slider || $0.elementType == .pickerWheel || $0.elementType == .textField || $0.elementType == .searchField || $0.elementType == .secureTextField || type != .any) }) else {
                throw DeviceUnsupported("could not find that control again; read the screen and retry")
            }
            switch match.elementType {
            case .slider:
                guard let percent = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) else {
                    throw DeviceUnsupported("a slider needs a number from 0 to 100")
                }
                match.adjust(toNormalizedSliderPosition: CGFloat(min(max(percent, 0), 100) / 100))
            case .pickerWheel:
                match.adjust(toPickerWheelValue: value)
            case .textField, .searchField, .secureTextField:
                match.tap()
                if let current = match.value as? String, !current.isEmpty, current != match.placeholderValue {
                    match.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
                }
                match.typeText(value)
            default:
                throw DeviceUnsupported("set_value works on sliders, picker wheels and text fields")
            }
        }
    }

    func tap(x: Int, y: Int) async throws {
        let t0 = Date()
        await MainActor.run { point(x, y).tap() }
        print("AGENT_TIMING tap \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    }
    func longPress(x: Int, y: Int, seconds: Double) async throws { await MainActor.run { point(x, y).press(forDuration: seconds) } }
    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        await MainActor.run { point(fromX, fromY).press(forDuration: 0.05, thenDragTo: point(toX, toY), withVelocity: .slow, thenHoldForDuration: 0) }
    }
    func typeText(_ text: String) async throws {
        try await MainActor.run {
            refreshFront()
            guard let field = focused() else { throw DeviceUnsupported("no text field has the keyboard: tap the field first") }
            field.typeText(text)
        }
    }
    func clearText() async throws {
        try await MainActor.run {
            refreshFront()
            guard let field = focused() else { throw DeviceUnsupported("no text field has the keyboard: tap the field first") }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        }
    }
    func pressEnter() async throws {
        try await MainActor.run {
            refreshFront()
            guard let field = focused() else { throw DeviceUnsupported("no text field has the keyboard") }
            field.typeText("\n")
        }
    }
    func pressHome() async throws {
        await MainActor.run {
            XCUIDevice.shared.press(.home)
            front = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            frontID = "com.apple.springboard"
        }
    }
    /// iPhone has no Back button: swipe in from the left edge.
    func pressBack() async throws {
        await MainActor.run {
            let from = front.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: front.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
    }
    func openApp(named name: String) async throws -> Bool {
        let t0 = Date()
        defer { print("AGENT_TIMING open_app \(String(format: "%.2f", Date().timeIntervalSince(t0)))s") }
        let key = name.lowercased().replacingOccurrences(of: " app", with: "").trimmingCharacters(in: .whitespaces)
        guard let id = Self.apps[key] ?? (key.contains(".") ? name : nil) else { return false }
        await MainActor.run {
            let app = XCUIApplication(bundleIdentifier: id)
            app.activate()
            front = app
            frontID = id
        }
        return true   // activate() returns once the app is up; the agent's settle check covers the rest
    }
}
