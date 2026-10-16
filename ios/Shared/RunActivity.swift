import ActivityKit
import Foundation

/// The Live Activity of a run: shown on the Lock Screen and in the Dynamic Island while the agent works.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: Int
        var detail: String
        var finished: Bool
    }
    var task: String
}

/// Tapping Stop on the Live Activity opens this URL in the app, which stops the run.
enum RunLinks {
    static let stop = URL(string: "agentone://stop")!
}
