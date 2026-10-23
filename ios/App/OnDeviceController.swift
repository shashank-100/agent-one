// Only in developer builds (internal TestFlight): uses private test-framework classes, which the App Store rejects.
#if AGENTONE_DEVCONTROL
import Foundation
import PhoneUseCore
import UIKit
import Vision

/// Drives the iPhone itself, the way Pelican does: Apple's UI test framework is loaded into this app at run time and,
/// once automation mode is on (the system asks for the passcode once per session), synthesizes touches and typing in
/// any app, takes screenshots and reads the accessibility tree. The test-manager session that has to exist first is
/// opened by the tunnel layer (`DeviceSession`), through the phone's own developer services over a loopback VPN.
///
/// Written from the publicly documented technique (TouchSynthesis's write-up, WebDriverAgent's use of the same
/// classes); no code copied. Everything goes through the Objective-C runtime, so nothing links against XCTest.
/// Coordinates in and out are screenshot pixels; XCTest works in points.
final class OnDeviceController: DeviceController, ElementReader, @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private let scale: CGFloat
    private let screenSize: CGSize
    private var loaded = false

    @MainActor init() {
        scale = UIScreen.main.scale
        screenSize = UIScreen.main.bounds.size
    }

    // MARK: - Setup

    /// Loads the test frameworks from the mounted developer disk image.
    func load() throws {
        guard !loaded else { return }
        var paths = [
            "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
            "/Developer/Library/Frameworks/XCTest.framework/XCTest",
            "/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
            "/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
        ]
        // In the simulator the frameworks live in Xcode's simulator platform on the Mac; its path is passed in.
        if let root = UserDefaults.standard.string(forKey: "xctestRoot") {
            paths += ["\(root)/Frameworks/XCTest.framework/XCTest", "\(root)/Frameworks/XCUIAutomation.framework/XCUIAutomation",
                      "\(root)/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"]
        }
        var any = false
        for path in paths where dlopen(path, RTLD_NOW) != nil { any = true }
        // XCTest creates its observation center on first use, and only allows that on the main thread.
        onMain { _ = (NSClassFromString("XCTestObservationCenter") as? NSObject.Type)?.perform(NSSelectorFromString("sharedTestObservationCenter")) }
        guard any, NSClassFromString("XCSynthesizedEventRecord") != nil else {
            throw Failure("The test framework is not available. Mount the developer disk image (LocalDevVPN) and try again.")
        }
        loaded = true
    }

    /// Turns on automation mode. iOS shows its passcode prompt; afterwards "Automation Running" is on screen.
    func enableAutomation() throws {
        try load()
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject else {
            throw Failure("No test-manager session. Start it from the Control tab first.")
        }
        let sel = NSSelectorFromString("enableAutomationModeWithError:")
        guard session.responds(to: sel) else { throw Failure("This iOS version does not offer automation mode.") }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
        var error: NSError?
        let ok = unsafeBitCast(class_getMethodImplementation(type(of: session), sel), to: Fn.self)(session, sel, &error)
        if !ok { throw Failure(error?.localizedDescription ?? "Automation mode was not enabled.") }
    }

    /// Debug probe: can this app drive other apps? Loads XCTest, tries automation mode, taps a point, and reports
    /// each stage on stdout. Launch with `-controlProbe YES -xctestRoot <…/iPhoneSimulator.platform/Developer/Library>`.
    func probe(tapAt point: (x: Int, y: Int)) async -> String {
        var out: [String] = []
        do { try load(); out.append("load: ok") } catch { return "load: \(error.localizedDescription)" }
        for name in ["XCTRunnerDaemonSession", "XCSynthesizedEventRecord", "XCPointerEventPath", "XCUIDevice", "XCUIScreen", "XCUIApplication"] {
            out.append("\(name): \(NSClassFromString(name) != nil ? "yes" : "no")")
        }
        do { try enableAutomation(); out.append("automation: enabled") } catch { out.append("automation: \(error.localizedDescription)") }
        do { try await pressHome(); out.append("home: pressed") } catch { out.append("home: \(error.localizedDescription)") }
        try? await Task.sleep(for: .seconds(2))
        do { try await tap(x: point.x, y: point.y); out.append("tap: sent") } catch { out.append("tap: \(error.localizedDescription)") }
        // Which accessibility entry points exist in-process (for reading the element tree without XCUIApplication)?
        func methods(_ cls: AnyClass?, _ filter: [String]) -> [String] {
            guard let cls else { return [] }
            var count: UInt32 = 0
            var names: [String] = []
            for c in [cls, object_getClass(cls)].compactMap({ $0 }) {
                guard let list = class_copyMethodList(c, &count) else { continue }
                for i in 0..<Int(count) {
                    let n = NSStringFromSelector(method_getName(list[i]))
                    if filter.contains(where: { n.localizedCaseInsensitiveContains($0) }) { names.append(n) }
                }
                free(list)
            }
            return names.sorted()
        }
        let words = ["snapshot", "activeApplication", "elementAt", "attributes", "systemApplication"]
        out.append("XCAXClient_iOS: " + methods(NSClassFromString("XCAXClient_iOS"), words).joined(separator: ", "))
        if let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
           let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject,
           session.responds(to: NSSelectorFromString("daemonProxy")),
           let proxy = session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject {
            out.append("daemonProxy (\(type(of: proxy))): " + methods(type(of: proxy), words).joined(separator: ", "))
        }
        out.append("XCTestManager_ManagerInterface protocol: " + {
            guard let proto = objc_getProtocol("XCTestManager_ManagerInterface") else { return "missing" }
            var count: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(proto, true, true, &count) else { return "none" }
            defer { free(list) }
            return (0..<Int(count)).compactMap { i in list[i].name.map(NSStringFromSelector) }.filter { n in words.contains(where: { n.localizedCaseInsensitiveContains($0) }) }.sorted().joined(separator: ", ")
        }())
        do { let s = try await screenshot(); out.append("screenshot: \(s.width)x\(s.height)") } catch { out.append("screenshot: \(error.localizedDescription)") }
        let started = Date()
        let found = await elements()
        out.append("text elements: \(found.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: " + found.prefix(20).map { "\($0.text)@\($0.center.x),\($0.center.y)" }.joined(separator: " | "))
        return out.joined(separator: "\n")
    }

    private var ready = false
    private var frontID: String?
    private var lastImage: CGImage?
    /// Loads the test framework and turns automation on the first time the agent needs the phone.
    private func ensureReady() throws {
        guard !ready else { return }
        try enableAutomation()
        ready = true
    }

    /// Step-by-step check of reading the front app's accessibility tree through the test daemon (no XCUIApplication,
    /// no in-app accessibility privileges needed: testmanagerd does the reading).
    private func axProbe() -> String {
        var out: [String] = []
        guard let elementClass = NSClassFromString("XCAccessibilityElement") else { return "ax: no XCAccessibilityElement" }
        var count: UInt32 = 0
        if let meta = object_getClass(elementClass), let list = class_copyMethodList(meta, &count) {
            out.append("XCAccessibilityElement class methods: " + (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted().joined(separator: ", "))
            free(list)
        }
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject,
              let proxy = session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject else { return out.joined(separator: "\n") + "\nax: no daemon proxy" }
        let cls = elementClass as! NSObject.Type
        guard let deviceSel = ["deviceElement", "systemWideElement", "systemWide"].first(where: { cls.responds(to: NSSelectorFromString($0)) }),
              let device = cls.perform(NSSelectorFromString(deviceSel))?.takeUnretainedValue() as? NSObject else {
            return out.joined(separator: "\n") + "\nax: no device element constructor"
        }
        out.append("device element via \(deviceSel)")
        func fetch(_ attributes: [String], _ element: NSObject) -> NSDictionary? {
            let sel = NSSelectorFromString("_XCT_fetchAttributes:forElement:reply:")
            typealias Reply = @convention(block) (NSDictionary?, NSError?) -> Void
            typealias Fn = @convention(c) (NSObject, Selector, NSArray, NSObject, Reply) -> Void
            let done = DispatchSemaphore(value: 0)
            var result: NSDictionary?
            let reply: Reply = { dict, error in
                result = dict
                if let error { out.append("  error: \(error.localizedDescription)") }
                done.signal()
            }
            unsafeBitCast(class_getMethodImplementation(type(of: proxy), sel), to: Fn.self)(proxy, sel, attributes as NSArray, element, reply)
            if done.wait(timeout: .now() + 30) == .timedOut { out.append("  no reply in 30 s for \(attributes)") }
            return result
        }
        // A test runner asks the daemon to load accessibility before reading any tree.
        var count2: UInt32 = 0
        var axCalls: [String] = []
        if let list = class_copyMethodList(type(of: proxy), &count2) {
            axCalls = (0..<Int(count2)).map { NSStringFromSelector(method_getName(list[$0])) }.filter { $0.localizedCaseInsensitiveContains("ccessibility") }
            free(list)
        }
        out.append("daemon accessibility calls: \(axCalls.sorted())")
        if let load = axCalls.first(where: { $0.hasPrefix("_XCT_loadAccessibilityWithTimeout:") }) {
            typealias LoadReply = @convention(block) (Bool, NSError?) -> Void
            typealias LoadFn = @convention(c) (NSObject, Selector, Double, LoadReply) -> Void
            let loaded = DispatchSemaphore(value: 0)
            var ok = false
            let r: LoadReply = { b, e in ok = b; if let e { out.append("  load error: \(e.localizedDescription)") }; loaded.signal() }
            let sel = NSSelectorFromString(load)
            unsafeBitCast(class_getMethodImplementation(type(of: proxy), sel), to: LoadFn.self)(proxy, sel, 30, r)
            out.append("load accessibility: \(loaded.wait(timeout: .now() + 35) == .timedOut ? "no reply" : (ok ? "ok" : "false"))")
        }
        let sys = fetch(["XC_kAXXCAttributeSystemAppApplication"], device)
        out.append("device → system app: \(sys.map { "\($0)".prefix(300) } ?? "nil")")
        if let systemApp = sys?.allValues.first as? NSObject {
            let apps = fetch(["XC_kAXXCAttributeFocusedApplications", "XC_kAXXCAttributeRunningApplications"], systemApp)
            out.append("system app → focused/running: \(apps.map { "\($0)".prefix(500) } ?? "nil")")
        }
        return out.joined(separator: "\n")
    }

    /// The other route to the tree: ask testmanagerd which element is under a point (that names the front app's
    /// process), then for a snapshot of that app. Neither call needs XCUIApplication or the system-app attribute
    /// that times out in `axProbe`.
    private func snapshotProbe(at point: CGPoint) -> String {
        var out: [String] = []
        func note(_ line: String) { out.append(line); print("SNAPSHOT_PROBE \(line)") }
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject,
              let proxy = session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject else { return "snapshot: no daemon proxy" }

        typealias ElementReply = @convention(block) (NSObject?, NSError?) -> Void
        typealias AtPoint = @convention(c) (NSObject, Selector, CGPoint, ElementReply) -> Void
        var hit: NSObject?
        let gotHit = DispatchSemaphore(value: 0)
        let atPoint = NSSelectorFromString("_XCT_requestElementAtPoint:reply:")
        let onHit: ElementReply = { element, error in
            print("SNAPSHOT_PROBE reply: \(element.map { NSStringFromClass(type(of: $0)) } ?? "nil") error \(error?.localizedDescription ?? "none")")
            hit = element
            if let error { note("element at point error: \(error.localizedDescription)") }
            gotHit.signal()
        }
        note("asking for the element at \(point)")
        // The proxy call itself can block until the daemon answers, so it runs off this thread and the wait below times out.
        Thread.detachNewThread { unsafeBitCast(class_getMethodImplementation(type(of: proxy), atPoint), to: AtPoint.self)(proxy, atPoint, point, onHit) }
        if gotHit.wait(timeout: .now() + 20) == .timedOut { return (out + ["element at point: no reply in 20 s"]).joined(separator: "\n") }
        guard let hit else { return (out + ["element at point: nil"]).joined(separator: "\n") }
        note("got an element; reading its process id")
        let pid = (hit.value(forKey: "processIdentifier") as? NSNumber)?.int32Value ?? 0
        note("element at \(point): pid \(pid)")

        guard let elementClass = NSClassFromString("XCAccessibilityElement") as? NSObject.Type,
              elementClass.responds(to: NSSelectorFromString("elementWithProcessIdentifier:")) else { return (out + ["no elementWithProcessIdentifier:"]).joined(separator: "\n") }
        typealias ForPID = @convention(c) (AnyClass, Selector, Int32) -> NSObject?
        let forPID = NSSelectorFromString("elementWithProcessIdentifier:")
        guard let app = unsafeBitCast(method_getImplementation(class_getClassMethod(elementClass, forPID)!), to: ForPID.self)(elementClass, forPID, pid) else {
            return (out + ["app element: nil"]).joined(separator: "\n")
        }

        // Parameters a UI test would send (max depth, children limits); an empty dictionary when the client has none.
        var parameters: NSDictionary = [:]
        if let client = (NSClassFromString("XCAXClient_iOS") as? NSObject.Type)?.perform(NSSelectorFromString("sharedClient"))?.takeUnretainedValue() as? NSObject,
           client.responds(to: NSSelectorFromString("defaultParameters")),
           let p = client.perform(NSSelectorFromString("defaultParameters"))?.takeUnretainedValue() as? NSDictionary { parameters = p }
        note("parameters: \(parameters)")

        typealias SnapshotReply = @convention(block) (NSObject?, NSError?) -> Void
        typealias Snapshot = @convention(c) (NSObject, Selector, NSObject, NSArray?, NSDictionary, SnapshotReply) -> Void
        let request = NSSelectorFromString("_XCT_requestSnapshotForElement:attributes:parameters:reply:")
        let attributes = ["XC_kAXXCAttributeLabel", "XC_kAXXCAttributeTitle", "XC_kAXXCAttributeValue", "XC_kAXXCAttributeFrame",
                          "XC_kAXXCAttributeElementType", "XC_kAXXCAttributeIdentifier", "XC_kAXXCAttributeIsEnabled", "XC_kAXXCAttributeTraits"] as NSArray
        for (name, attrs) in [("named attributes", attributes as NSArray?), ("no attributes", nil)] {
            let started = Date()
            var snapshot: NSObject?
            let got = DispatchSemaphore(value: 0)
            let onSnapshot: SnapshotReply = { s, error in
                snapshot = s
                if let error { note("snapshot (\(name)) error: \(error.localizedDescription)") }
                got.signal()
            }
            note("asking for a snapshot (\(name))")
            Thread.detachNewThread { unsafeBitCast(class_getMethodImplementation(type(of: proxy), request), to: Snapshot.self)(proxy, request, app, attrs, parameters, onSnapshot) }
            if got.wait(timeout: .now() + 30) == .timedOut { note("snapshot (\(name)): no reply in 30 s"); continue }
            guard let snapshot else { note("snapshot (\(name)): nil"); continue }
            note("snapshot (\(name)) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(type(of: snapshot))")
            if let dict = snapshot.perform(NSSelectorFromString("dictionaryRepresentation"))?.takeUnretainedValue() as? [String: Any] {
                var found: [ScreenElement] = []
                walk(dict, into: &found)
                note("  \(found.count) elements: " + found.prefix(15).map { "\($0.text)\($0.tappable ? "*" : "")" }.joined(separator: " | "))
            } else {
                note("  keys: \(String(describing: snapshot).prefix(300))")
            }
            break
        }
        return out.joined(separator: "\n")
    }

    // MARK: - DeviceController

    func tap(x: Int, y: Int) async throws {
        try ensureReady()
        // Time and place of each touch, for drawing a tap marker on a recording afterwards (local/tap-marker.py).
        print(String(format: "AGENT_TAP %.3f %d %d", Date().timeIntervalSince1970, x, y))
        let p = point(x, y)
        let path = try makePath(at: p, offset: 0)
        send(path, "liftUpAtOffset:", 0.1)
        try synthesize([path], name: "tap", lasting: 0.1)
    }

    func longPress(x: Int, y: Int, seconds: Double) async throws {
        try ensureReady()
        let path = try makePath(at: point(x, y), offset: 0)
        send(path, "liftUpAtOffset:", seconds)
        try synthesize([path], name: "long press", lasting: seconds)
    }

    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        try ensureReady()
        let a = point(fromX, fromY), b = point(toX, toY)
        let path = try makePath(at: a, offset: 0)
        let steps = 12
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            move(path, to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), at: seconds * t)
        }
        send(path, "liftUpAtOffset:", seconds + 0.05)
        try synthesize([path], name: "swipe", lasting: seconds)
    }

    func typeText(_ text: String) async throws {
        try ensureReady()
        guard let cls = NSClassFromString("XCPointerEventPath") as? NSObject.Type else { throw Failure("XCTest is not loaded.") }
        let alloc = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        guard let path = alloc.perform(NSSelectorFromString("initForTextInput"))?.takeUnretainedValue() as? NSObject else {
            throw Failure("Typing is not available.")
        }
        let sel = NSSelectorFromString("typeText:atOffset:typingSpeed:shouldRedact:")
        typealias Fn = @convention(c) (NSObject, Selector, NSString, Double, UInt, Bool) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: path), sel), to: Fn.self)(path, sel, text as NSString, 0, 30, false)
        try synthesize([path], name: "type", lasting: Double(text.count) * 0.05)
    }

    func clearText() async throws {
        // Select-all is not reliable across apps; delete keystrokes clear any field.
        try await typeText(String(repeating: "\u{8}", count: 120))
    }

    func pressEnter() async throws { try await typeText("\n") }

    func pressHome() async throws {
        try ensureReady()
        // Home is HID consumer page 0x0C, usage 0x40 (Menu), sent straight to testmanagerd; XCUIDevice's
        // pressButton: waits ~5 s for a reply the daemon never sends to this app.
        if let eventClass = NSClassFromString("XCDeviceEvent"), let proxy = daemonProxy() {
            typealias Make = @convention(c) (AnyClass, Selector, UInt32, UInt32, Double) -> NSObject?
            let make = NSSelectorFromString("deviceEventWithPage:usage:duration:")
            if let method = class_getClassMethod(eventClass, make),
               let event = unsafeBitCast(method_getImplementation(method), to: Make.self)(eventClass, make, 0x0C, 0x40, 0.05) {
                fireAndForget(proxy, "_XCT_performDeviceEvent:completion:", event)
                try await Task.sleep(for: .milliseconds(400))
                return
            }
        }
        guard let device = sharedDevice() else { throw Failure("XCTest is not loaded.") }
        let sel = NSSelectorFromString("pressButton:")
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: device), sel), to: Fn.self)(device, sel, 1)
    }

    /// iPhone has no Back button: swipe in from the left edge, which goes back in most apps.
    func pressBack() async throws {
        let h = Int(screenSize.height * scale)
        try await swipe(fromX: 2, fromY: h / 2, toX: Int(screenSize.width * scale * 0.7), toY: h / 2, seconds: 0.3)
    }

    func openApp(named name: String) async throws -> Bool {
        try ensureReady()
        // XCUIApplication is unavailable in-app, so the launch goes to testmanagerd by bundle id. An app not in the
        // list is opened the long way (go_home, then the icon or Search).
        guard let id = Self.bundleID(for: name), daemonProxy() != nil else {
            throw DeviceUnsupported("\(name) is not in the app list: use go_home, then tap its icon or search for it")
        }
        try await launch(bundleID: id)
        return true
    }

    /// The app the agent last opened (nil until it opens one).
    var frontBundleID: String? { frontID }

    /// Brings an app to the front by bundle id, through testmanagerd (see openApp).
    func launch(bundleID id: String) async throws {
        guard let proxy = daemonProxy() else { throw Failure("XCTest is not loaded.") }
        typealias Launch = @convention(c) (NSObject, Selector, NSString, NSArray, NSDictionary, @convention(block) (NSError?) -> Void) -> Void
        let sel = NSSelectorFromString("_XCT_launchApplicationWithBundleID:arguments:environment:completion:")
        let ignore: @convention(block) (NSError?) -> Void = { _ in }
        Thread.detachNewThread { unsafeBitCast(class_getMethodImplementation(type(of: proxy), sel), to: Launch.self)(proxy, sel, id as NSString, [] as NSArray, [:] as NSDictionary, ignore) }
        frontID = id
        try await Task.sleep(for: .milliseconds(1200))
    }

    func screenshot() async throws -> Screenshot {
        try ensureReady()
        guard let screenClass = NSClassFromString("XCUIScreen") as? NSObject.Type,
              let screen = screenClass.perform(NSSelectorFromString("mainScreen"))?.takeUnretainedValue() as? NSObject,
              let shot = screen.perform(NSSelectorFromString("screenshot"))?.takeUnretainedValue() as? NSObject,
              let image = shot.perform(NSSelectorFromString("image"))?.takeUnretainedValue() as? UIImage,
              let jpeg = image.jpegData(compressionQuality: 0.7) else { throw Failure("No screenshot.") }
        lastImage = image.cgImage
        return Screenshot(jpeg: jpeg, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
    }

    // MARK: - Accessibility tree → numbered elements

    /// The text on the last screenshot, as numbered elements: each line Vision reads becomes one tappable element
    /// with its box in screenshot pixels. In-app there is no accessibility tree (testmanagerd does not answer this
    /// app's snapshot requests on the simulator; see notes/in-app-control-findings.md), so text is the next best
    /// thing: the agent taps "Settings" or "Add to Cart" by number. Icon-only buttons still need a look at the picture.
    func elements() async -> [ScreenElement] {
        guard let image = lastImage, !UserDefaults.standard.bool(forKey: "noTextElements") else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        let w = Double(image.width), h = Double(image.height)
        let found = (request.results ?? []).compactMap { observation -> ScreenElement? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            let box = observation.boundingBox  // normalised, origin at the bottom left
            return ScreenElement(text: String(text.prefix(60)), x: Int(box.minX * w), y: Int((1 - box.maxY) * h),
                                 width: max(1, Int(box.width * w)), height: max(1, Int(box.height * h)), tappable: true)
        }
        return Array(found.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.prefix(90))
    }

    private func walk(_ node: [String: Any], into out: inout [ScreenElement]) {
        let label = (node["label"] as? String) ?? (node["title"] as? String) ?? (node["value"] as? String) ?? ""
        let type = (node["elementType"] as? Int) ?? 0
        // Button 9, cell 75, text field 49, secure field 50, switch 40, link 39, tab 17, search field 51
        let tappable = [9, 75, 49, 50, 40, 39, 17, 51, 38].contains(type)
        if let frame = node["frame"] as? [String: Any],
           let x = frame["X"] as? Double, let y = frame["Y"] as? Double,
           let w = frame["Width"] as? Double, let h = frame["Height"] as? Double,
           w >= 4, h >= 4, !label.isEmpty || tappable,
           x + w > 0, y + h > 0, x < Double(screenSize.width), y < Double(screenSize.height) {
            let k = Double(scale)
            out.append(ScreenElement(text: String(label.prefix(60)), x: Int(x * k), y: Int(y * k), width: Int(w * k), height: Int(h * k), tappable: tappable))
        }
        for child in (node["children"] as? [[String: Any]]) ?? [] { walk(child, into: &out) }
    }

    // MARK: - Event plumbing

    private func point(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale) }

    private func makePath(at p: CGPoint, offset: Double) throws -> NSObject {
        guard let cls = NSClassFromString("XCPointerEventPath") as? NSObject.Type else { throw Failure("XCTest is not loaded.") }
        let alloc = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        let sel = NSSelectorFromString("initForTouchAtPoint:offset:")
        typealias Fn = @convention(c) (NSObject, Selector, CGPoint, Double) -> NSObject?
        guard let path = unsafeBitCast(class_getMethodImplementation(type(of: alloc), sel), to: Fn.self)(alloc, sel, p, offset) else {
            throw Failure("Could not build a touch.")
        }
        return path
    }

    private func move(_ path: NSObject, to p: CGPoint, at offset: Double) {
        let sel = NSSelectorFromString("moveToPoint:atOffset:")
        typealias Fn = @convention(c) (NSObject, Selector, CGPoint, Double) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: path), sel), to: Fn.self)(path, sel, p, offset)
    }

    private func send(_ path: NSObject, _ selector: String, _ offset: Double) {
        let sel = NSSelectorFromString(selector)
        typealias Fn = @convention(c) (NSObject, Selector, Double) -> Void
        unsafeBitCast(class_getMethodImplementation(type(of: path), sel), to: Fn.self)(path, sel, offset)
    }

    private func synthesize(_ paths: [NSObject], name: String, lasting seconds: Double) throws {
        guard let cls = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type else { throw Failure("XCTest is not loaded.") }
        let alloc = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        let initSel = NSSelectorFromString("initWithName:interfaceOrientation:")
        typealias Init = @convention(c) (NSObject, Selector, NSString, Int) -> NSObject?
        guard let record = unsafeBitCast(class_getMethodImplementation(type(of: alloc), initSel), to: Init.self)(alloc, initSel, name as NSString, 1) else {
            throw Failure("Could not build the event.")
        }
        for path in paths { _ = record.perform(NSSelectorFromString("addPointerEventPath:"), with: path) }
        if deliverDirectly(record, lasting: seconds) { return }
        guard callWithError(record, "synthesizeWithError:", returnsBool: true) != nil else { throw Failure("The phone did not accept the \(name).") }
    }

    /// Hands the event straight to testmanagerd without waiting for its reply. In-app the daemon delivers the touch
    /// but never answers (not on the main thread, not on any other), so `synthesizeWithError:` sat out a ~5 s timeout
    /// on every touch. The next screen read shows whether the touch landed. False only when there is no daemon session.
    private func deliverDirectly(_ record: NSObject, lasting seconds: Double) -> Bool {
        guard let proxy = daemonProxy() else { return false }
        fireAndForget(proxy, "_XCT_synthesizeEvent:completion:", record)
        // Long enough for the event itself (a tap lasts 0.1 s) to play out before the screen is read.
        Thread.sleep(forTimeInterval: min(max(seconds, 0.1), 10) + 0.15)
        return true
    }

    private func daemonProxy() -> NSObject? {
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") as? NSObject.Type,
              let session = sessionClass.perform(NSSelectorFromString("sharedSession"))?.takeUnretainedValue() as? NSObject else { return nil }
        return session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject
    }

    /// Calls a daemon method shaped `_XCT_…:(id)argument completion:(block)` and does not wait: in-app the daemon
    /// acts but never replies, and the call can block until that reply, so it runs on its own thread.
    private func fireAndForget(_ proxy: NSObject, _ selector: String, _ argument: NSObject) {
        let sel = NSSelectorFromString(selector)
        typealias Completion = @convention(block) (NSError?) -> Void
        typealias Fn = @convention(c) (NSObject, Selector, NSObject, Completion) -> Void
        let ignore: Completion = { _ in }
        Thread.detachNewThread { unsafeBitCast(class_getMethodImplementation(type(of: proxy), sel), to: Fn.self)(proxy, sel, argument, ignore) }
    }

    /// Calls `selector` taking an `NSError**`; returns the result object (or the receiver for BOOL methods) or nil.
    @discardableResult
    private func callWithError(_ object: NSObject, _ selector: String, returnsBool: Bool = false) -> NSObject? {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel) else { return nil }
        var error: NSError?
        let imp = class_getMethodImplementation(type(of: object), sel)
        if returnsBool {
            typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
            return unsafeBitCast(imp, to: Fn.self)(object, sel, &error) ? object : nil
        }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> Unmanaged<NSObject>?
        return unsafeBitCast(imp, to: Fn.self)(object, sel, &error)?.takeUnretainedValue()
    }

    private func sharedDevice() -> NSObject? {
        (NSClassFromString("XCUIDevice") as? NSObject.Type)?.perform(NSSelectorFromString("sharedDevice"))?.takeUnretainedValue() as? NSObject
    }

    /// XCUIApplication and its snapshots must be used on the main thread.
    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private func application(_ bundleID: String) -> NSObject? {
        onMain { makeApplication(bundleID) }
    }

    private func makeApplication(_ bundleID: String) -> NSObject? {
        guard let cls = NSClassFromString("XCUIApplication") as? NSObject.Type else { return nil }
        let alloc = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        return alloc.perform(NSSelectorFromString("initWithBundleIdentifier:"), with: bundleID)?.takeUnretainedValue() as? NSObject
    }

    /// The app in front: the last one the agent opened if it is still in the foreground, else the first known app
    /// running in the foreground, else the home screen. (XCUIApplication.state 4 = running in the foreground.)
    private func frontApplication() -> NSObject? {
        func foreground(_ id: String) -> NSObject? {
            guard let app = application(id) else { return nil }
            let sel = NSSelectorFromString("state")
            guard app.responds(to: sel) else { return nil }
            typealias Fn = @convention(c) (NSObject, Selector) -> UInt
            return unsafeBitCast(class_getMethodImplementation(type(of: app), sel), to: Fn.self)(app, sel) == 4 ? app : nil
        }
        if let id = frontID, let app = foreground(id) { return app }
        for id in Set(Self.knownIDs) { if let app = foreground(id) { frontID = id; return app } }
        return application("com.apple.springboard")
    }

    /// App names the agent uses → bundle identifiers. Unknown names fall back to SpringBoard search in the agent.
    static var knownIDs: [String] {
        ["com.apple.Preferences", "com.apple.mobilesafari", "com.apple.mobileslideshow", "com.apple.DocumentsApp", "com.apple.MobileSMS",
         "com.apple.mobilemail", "com.apple.mobilecal", "com.apple.mobiletimer", "com.apple.mobilenotes", "com.apple.Maps",
         "com.apple.MobileAddressBook", "com.amazon.Amazon", "net.whatsapp.WhatsApp"]
    }

    static func bundleID(for name: String) -> String? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let known: [String: String] = [
            "settings": "com.apple.Preferences", "photos": "com.apple.mobileslideshow", "files": "com.apple.DocumentsApp",
            "messages": "com.apple.MobileSMS", "mail": "com.apple.mobilemail", "safari": "com.apple.mobilesafari",
            "calendar": "com.apple.mobilecal", "clock": "com.apple.mobiletimer", "notes": "com.apple.mobilenotes",
            "calculator": "com.apple.calculator", "maps": "com.apple.Maps", "phone": "com.apple.mobilephone",
            "contacts": "com.apple.MobileAddressBook", "camera": "com.apple.camera", "app store": "com.apple.AppStore",
            "whatsapp": "net.whatsapp.WhatsApp", "gmail": "com.google.Gmail", "chrome": "com.google.chrome.ios",
            "spotify": "com.spotify.client", "instagram": "com.burbn.instagram", "telegram": "ph.telegra.Telegraph",
        ]
        return known[key] ?? (key.contains(".") ? name : nil) ?? installedApps()[key]
    }

    /// Every installed app, display name (lower case) → bundle id, read once from LaunchServices' private
    /// LSApplicationWorkspace (developer builds only, like the rest of this file).
    static func installedApps() -> [String: String] {
        if let cached = installed { return cached }
        var map: [String: String] = [:]
        if let ws = (NSClassFromString("LSApplicationWorkspace") as? NSObject.Type)?.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject,
           let apps = ws.perform(NSSelectorFromString("allApplications"))?.takeUnretainedValue() as? [NSObject] {
            for app in apps {
                guard let id = app.perform(NSSelectorFromString("bundleIdentifier"))?.takeUnretainedValue() as? String,
                      let name = app.perform(NSSelectorFromString("localizedName"))?.takeUnretainedValue() as? String else { continue }
                map[name.lowercased()] = id
            }
        }
        installed = map
        return map
    }
    nonisolated(unsafe) private static var installed: [String: String]?
}

#endif
