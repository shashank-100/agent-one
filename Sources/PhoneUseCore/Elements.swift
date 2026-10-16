import Foundation

/// A thing on screen the agent can name by number: its text, kind and box in screenshot pixels. Phones that can
/// list their screen (a web page's elements, an app's accessibility tree) give the agent these, so it taps a named
/// control instead of guessing a point from the picture. (The idea comes from macos-harness's numbered app state.)
public struct ScreenElement: Sendable, Equatable {
    public enum Place: Sendable, Equatable { case onScreen, above, below }

    public let text: String
    /// "button", "link", "field", "switch", "slider", "picker", "cell", "text"… Empty when unknown.
    public let kind: String
    public let x: Int, y: Int, width: Int, height: Int
    public let tappable: Bool
    public let place: Place

    public init(text: String, x: Int, y: Int, width: Int, height: Int, tappable: Bool, kind: String = "", place: Place = .onScreen) {
        self.text = text
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.tappable = tappable
        self.place = place
    }

    public var center: (x: Int, y: Int) { (x + width / 2, y + height / 2) }
}

/// Phones that can list what is on screen.
public protocol ElementReader: Sendable {
    func elements() async -> [ScreenElement]
}

/// Phones that can act on an element itself (not just its point), so an off-screen one is scrolled into view first.
public protocol ElementTapper: Sendable {
    func tap(_ element: ScreenElement) async throws
}

/// Phones that can set a control's value directly: a slider's position, a picker wheel's row, a field's text.
public protocol ValueSetter: Sendable {
    func setValue(_ value: String, on element: ScreenElement) async throws
}

/// The list the model was last shown: every element on the page, numbered from 1, with off-screen ones marked
/// above or below. When nothing changed, the model gets one line instead of the list again.
public struct ElementList: Sendable {
    public private(set) var shown: [ScreenElement] = []
    private var numbered: [ScreenElement] = []

    public init() {}

    /// The text for this turn: the full list, a note that it is unchanged, or nothing when the phone lists nothing.
    public mutating func describe(_ elements: [ScreenElement]) -> String {
        guard !elements.isEmpty else { shown = []; numbered = []; return "" }
        if !shown.isEmpty, elements == shown {
            return "\nElements on the page: unchanged since the last list (same numbers)."
        }
        shown = elements
        // Every element is numbered, on screen or not: tapping an off-screen number brings it into view and taps it,
        // so the agent acts on the whole page from one read instead of scrolling to look for things.
        numbered = elements
        let lines = elements.enumerated().map { i, e in
            let place = e.place == .onScreen ? "" : (e.place == .below ? " (below the screen; tapping it scrolls to it)" : " (above the screen; tapping it scrolls to it)")
            return "\(i + 1) \(e.tappable ? "•" : "-") \(Self.label(e))\(place)"
        }
        return "\nElements on the page, numbered (• can be tapped), including those off screen:\n" + lines.joined(separator: "\n")
    }

    /// The numbered element, or nil.
    public func element(_ number: Int) -> ScreenElement? {
        number >= 1 && number <= numbered.count ? numbered[number - 1] : nil
    }

    private static func label(_ e: ScreenElement) -> String {
        (e.kind.isEmpty ? "" : e.kind + " ") + "\"\(e.text.prefix(70))\""
    }
}
