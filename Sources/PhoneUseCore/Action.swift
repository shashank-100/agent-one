import Foundation

/// How the model expresses positions on the screenshot.
public enum CoordinateSpace: String, Sendable {
    /// A 0–999 grid laid over the screenshot, whatever its size.
    case grid
    /// Pixels of the screenshot as sent, with its size stated in each turn.
    case pixels
}

/// A point as the model gave it. What the numbers mean depends on the `CoordinateSpace` in use.
public struct GridPoint: Equatable, Sendable {
    public static let gridSize = 1000
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// Pixel position in a screenshot of the given size, clamped to the screen.
    public func pixels(width: Int, height: Int, space: CoordinateSpace = .grid) -> (x: Int, y: Int) {
        var px = x, py = y
        if space == .grid {
            px = Int((Double(x) * Double(width) / Double(Self.gridSize)).rounded())
            py = Int((Double(y) * Double(height) / Double(Self.gridSize)).rounded())
        }
        return (min(max(px, 0), max(width - 1, 0)), min(max(py, 0), max(height - 1, 0)))
    }
}

public enum ScrollDirection: String, Sendable, CaseIterable {
    case up, down, left, right
}

/// One thing the agent can do per turn. Each case is one tool the model can call.
public enum AgentAction: Equatable, Sendable {
    case tap(GridPoint, target: String, irreversible: Bool)
    case longPress(GridPoint, target: String)
    case swipe(from: GridPoint, to: GridPoint)
    case scroll(ScrollDirection)
    case typeText(String, field: String, at: GridPoint?, clear: Bool)
    case pressEnter
    case openApp(String)
    case goHome
    case goBack
    case wait(seconds: Int)
    /// Logins, passwords, codes, Face ID, payment screens: the user does it, then the agent carries on.
    case handOver(reason: String)
    case askUser(question: String)
    case finish(success: Bool, answer: String)
    /// Sets a listed control's value directly: a slider (0–100), a picker wheel's row, a text field.
    case setValue(element: Int, value: String)

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Builds an action from a tool call. Throws with a message the model can read and correct.
    public init(toolName: String, input: JSONValue) throws {
        func string(_ key: String) throws -> String {
            guard let v = input[key]?.stringValue else { throw ParseError(description: "\(toolName): missing string \"\(key)\"") }
            return v
        }
        func point(_ xKey: String, _ yKey: String) throws -> GridPoint {
            guard let x = input[xKey]?.intValue, let y = input[yKey]?.intValue else {
                throw ParseError(description: "\(toolName): missing coordinates \"\(xKey)\", \"\(yKey)\"")
            }
            return GridPoint(x: x, y: y)
        }
        switch toolName {
        case "tap":
            self = .tap(try point("x", "y"), target: try string("target"), irreversible: input["irreversible"]?.boolValue ?? false)
        case "long_press":
            self = .longPress(try point("x", "y"), target: try string("target"))
        case "swipe":
            self = .swipe(from: try point("from_x", "from_y"), to: try point("to_x", "to_y"))
        case "scroll":
            guard let d = ScrollDirection(rawValue: try string("direction")) else {
                throw ParseError(description: "scroll: direction must be up, down, left or right")
            }
            self = .scroll(d)
        case "type_text":
            let at: GridPoint? = (input["x"]?.intValue).flatMap { x in input["y"]?.intValue.map { GridPoint(x: x, y: $0) } }
            self = .typeText(try string("text"), field: try string("field"), at: at, clear: input["clear"]?.boolValue ?? false)
        case "press_enter":
            self = .pressEnter
        case "open_app":
            self = .openApp(try string("name"))
        case "go_home":
            self = .goHome
        case "go_back":
            self = .goBack
        case "wait":
            self = .wait(seconds: min(max(input["seconds"]?.intValue ?? 2, 1), 10))
        case "hand_over":
            self = .handOver(reason: try string("reason"))
        case "ask_user":
            self = .askUser(question: try string("question"))
        case "set_value":
            guard let n = input["element"]?.intValue, n > 0 else { throw ParseError(description: "set_value: give the element's number from the list") }
            self = .setValue(element: n, value: try string("value"))
        case "finish":
            guard let ok = input["success"]?.boolValue else { throw ParseError(description: "finish: missing boolean \"success\"") }
            self = .finish(success: ok, answer: try string("answer"))
        default:
            throw ParseError(description: "unknown tool \"\(toolName)\"")
        }
    }

    /// One line for the progress display and the trace.
    public var summary: String {
        func quoted(_ s: String) -> String { s.isEmpty ? "" : " “\(s.prefix(40))”" }
        switch self {
        case .tap(_, let target, _): return "tap" + quoted(target)
        case .longPress(_, let target): return "hold" + quoted(target)
        case .swipe: return "swipe"
        case .scroll(let d): return "scroll \(d.rawValue)"
        case .typeText(_, let field, _, _): return "type into" + (field.isEmpty ? " field" : quoted(field))
        case .pressEnter: return "enter"
        case .openApp(let name): return "open \(name.prefix(40))"
        case .goHome: return "home"
        case .goBack: return "back"
        case .wait(let s): return "wait \(s)s"
        case .handOver: return "your turn"
        case .askUser: return "question for you"
        case .finish(let ok, _): return ok ? "done" : "could not finish"
        case .setValue(let n, let value): return "set \(n) to “\(value.prefix(30))”"
        }
    }

    /// Actions after which the next one needs a fresh look at the screen.
    var changesScreen: Bool {
        switch self {
        case .typeText, .wait, .handOver, .askUser, .finish: return false
        default: return true
        }
    }

    /// Actions that pause or end the run; they never count toward being stuck.
    var isPauseOrEnd: Bool {
        switch self {
        case .handOver, .askUser, .finish: return true
        default: return false
        }
    }
}

extension AgentAction {
    /// Tool definitions sent to the model. `strict` keeps the arguments schema-valid.
    public static let toolDefinitions = toolDefinitions(for: .grid)

    public static func toolDefinitions(for space: CoordinateSpace) -> [JSONValue] {
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue] = [:]) -> JSONValue {
            [
                "name": .string(name),
                "description": .string(description),
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(properties.keys.sorted().map(JSONValue.string)),
                    "additionalProperties": false,
                ],
            ]
        }
        func str(_ d: String) -> JSONValue { ["type": "string", "description": .string(d)] }
        func coord(_ d: String) -> JSONValue { ["type": "integer", "description": .string(d)] }
        let unit = space == .grid ? "on the 0–999 grid" : "in pixels of the screenshot"
        let x = coord("Horizontal position \(unit), 0 at the left edge")
        let y = coord("Vertical position \(unit), 0 at the top edge")
        let element: JSONValue = ["type": "integer", "description": "The element's number in the list on screen; the tap lands on its centre. 0 if it is not in the list: then x and y are used."]
        return [
            tool("tap", "Tap once on a listed element, or at a point on the screen.", [
                "element": element, "x": x, "y": y,
                "target": str("The text on the thing you tap, exactly as written, or a short description"),
                "irreversible": ["type": "boolean", "description": "True if this tap sends, posts, pays, orders, books, approves, cancels or deletes something. False for switches and settings that can be switched back."],
            ]),
            tool("long_press", "Press and hold a listed element, or a point.", ["element": element, "x": x, "y": y, "target": str("What is under the finger")]),
            tool("swipe", "Drag a finger from one point to another (a slider, a carousel, back from the left edge).", [
                "from_x": x, "from_y": y, "to_x": x, "to_y": y,
            ]),
            tool("scroll", "Scroll the content about half a screen. \"down\" reveals what is further down the page.", [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
            ]),
            tool("type_text", "Type into a text field. It taps the field first (its element number, or x,y), then types. Set clear to true to replace what the field already holds.", [
                "element": element, "x": x, "y": y, "text": str("The text to type"), "field": str("What the field is"),
                "clear": ["type": "boolean", "description": "True to replace the field's current text"],
            ]),
            tool("press_enter", "Press the Return / Search key on the keyboard."),
            tool("fill_credential", "Type a saved login (phone number, email or password) into a field. You give its name; the phone types the value, which you never see.", [
                "element": ["type": "integer", "description": "The field's number in the list (0 if it already has the keyboard)"],
                "name": str("The saved login's name, as listed"),
                "clear": ["type": "boolean", "description": "True to replace what the field holds"],
            ]),
            tool("look", "Get a screenshot of the screen with the next turn, when the element list is not enough to decide."),
            tool("set_value", "Set a listed slider, picker wheel or text field to a value in one step, instead of dragging or typing.", [
                "element": ["type": "integer", "description": "The control's number in the list"],
                "value": str("For a slider: 0 to 100 (percent). For a picker wheel: the row's text exactly as shown, e.g. \"07\". For a field: the full text."),
            ]),
            tool("open_app", "Open an installed app by its name.", ["name": str("The app's name as shown on the home screen")]),
            tool("go_home", "Go to the home screen."),
            tool("go_back", "Go back to the previous screen."),
            tool("wait", "Wait for the screen to finish loading.", ["seconds": ["type": "integer", "description": "1 to 10"]]),
            tool("hand_over", "Give the phone to the user for a login, password, verification code, captcha, Face ID or payment authorisation. They do it and you carry on.", [
                "reason": str("What the user needs to do"),
            ]),
            tool("ask_user", "Ask the user something only they know. The task pauses until they answer.", ["question": str("The question")]),
            tool("finish", "End the task.", [
                "success": ["type": "boolean", "description": "True if the task was completed"],
                "answer": str("The result: what was done or found, or why it could not be done"),
            ]),
        ]
    }
}
