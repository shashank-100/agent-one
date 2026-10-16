import Foundation

public struct Screenshot: Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }
}

/// The hands and eyes on the phone. Coordinates are pixels in the space of the latest screenshot.
/// The on-device implementation (touch synthesis through the test framework) lives in the app target.
public protocol DeviceController: Sendable {
    func screenshot() async throws -> Screenshot
    func tap(x: Int, y: Int) async throws
    func longPress(x: Int, y: Int, seconds: Double) async throws
    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws
    func typeText(_ text: String) async throws
    func pressEnter() async throws
    func pressHome() async throws
    /// The system Back action. Phones without one throw `DeviceUnsupported`.
    func pressBack() async throws
    /// Returns false when no installed app matches the name.
    func openApp(named name: String) async throws -> Bool
    /// True when the focused field is a password field. Controllers that cannot tell return false.
    func focusedFieldIsSecure() async -> Bool
}

public struct DeviceUnsupported: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension DeviceController {
    public func focusedFieldIsSecure() async -> Bool { false }
    public func pressBack() async throws { throw DeviceUnsupported("this phone has no Back action; use the back control on screen") }
    /// Empties the focused text field. Phones without a way to do it throw `DeviceUnsupported`.
    public func clearText() async throws { throw DeviceUnsupported("this phone cannot clear a field") }
}

/// Everything that needs the person: approvals, hand-overs and questions.
public protocol UserInteraction: Sendable {
    /// Asked before an irreversible tap. `target` is the label under the finger.
    func approve(action summary: String, target: String) async -> Bool
    /// The user does something themselves (login, code, Face ID). Returns false to stop the run.
    func handOver(reason: String) async -> Bool
    /// Returns nil when the user declines to answer.
    func ask(question: String) async -> String?
}

