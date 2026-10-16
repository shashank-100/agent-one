import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A small grid of grey levels: enough to tell "the screen did not change" without comparing JPEG bytes,
/// which differ between two captures of the same screen.
public struct ScreenFingerprint: Sendable, Equatable {
    public static let side = 12
    public let cells: [UInt8]

    public init(cells: [UInt8]) {
        self.cells = cells
    }

    public init?(jpeg: Data) {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        cells = pixels
        #else
        return nil
        #endif
    }

    /// Small differences (the clock ticking, a blinking cursor) still count as the same screen.
    public func isSameScreen(as other: ScreenFingerprint, tolerance: Double = 3) -> Bool {
        guard cells.count == other.cells.count, !cells.isEmpty else { return false }
        let total = zip(cells, other.cells).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(cells.count) <= tolerance
    }

    /// A protected screen (banking, DRM) captures as black.
    public var isBlack: Bool { !cells.isEmpty && cells.allSatisfy { $0 < 8 } }
}

/// Notices the agent going round in circles: the same action again on a screen that did not change.
/// Every step is a paid model call with an image, so a loop is stopped rather than left to run out the clock.
public struct LoopWatch: Sendable {
    public enum Verdict: Equatable, Sendable { case fine, note, stop }

    public let noteAt: Int
    public let stopAt: Int
    public private(set) var streak = 0
    private var lastFingerprint: ScreenFingerprint?
    private var lastAction: AgentAction?

    public init(noteAt: Int = 3, stopAt: Int = 6) {
        self.noteAt = noteAt
        self.stopAt = stopAt
    }

    /// `fingerprint` is the screen the model saw when it chose `action`.
    public mutating func step(fingerprint: ScreenFingerprint?, action: AgentAction) -> Verdict {
        defer {
            lastFingerprint = fingerprint
            lastAction = action
        }
        guard !action.isPauseOrEnd, let fingerprint, let lastFingerprint, let lastAction,
              Self.sameAction(lastAction, action), fingerprint.isSameScreen(as: lastFingerprint) else {
            streak = 1
            return .fine
        }
        streak += 1
        if streak >= stopAt { return .stop }
        return streak >= noteAt ? .note : .fine
    }

    /// Taps a few grid units apart are the same tap.
    static func sameAction(_ a: AgentAction, _ b: AgentAction) -> Bool {
        func near(_ p: GridPoint, _ q: GridPoint) -> Bool { abs(p.x - q.x) <= 15 && abs(p.y - q.y) <= 15 }
        switch (a, b) {
        case (.tap(let p, _, _), .tap(let q, _, _)), (.longPress(let p, _), .longPress(let q, _)):
            return near(p, q)
        case (.swipe(let p1, let p2), .swipe(let q1, let q2)):
            return near(p1, q1) && near(p2, q2)
        default:
            return a == b
        }
    }
}
