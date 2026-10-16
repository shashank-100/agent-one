import ActivityKit
import Foundation

/// Starts, updates and ends the run's Live Activity. Does nothing when Live Activities are off.
@MainActor
final class LiveRun {
    static let shared = LiveRun()
    private var activity: Activity<RunActivityAttributes>?

    func begin(task: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: RunActivityAttributes(task: task),
                                         content: .init(state: .init(step: 0, detail: "Starting", finished: false), staleDate: nil))
    }

    func update(step: Int, detail: String) {
        guard let activity else { return }
        // ActivityKit's Activity is not marked Sendable; it is only ever used from here, one call at a time.
        nonisolated(unsafe) let live = activity
        Task { await live.update(.init(state: .init(step: step, detail: detail, finished: false), staleDate: nil)) }
    }

    func end(_ text: String) {
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let live = activity
        Task {
            await live.end(.init(state: .init(step: 0, detail: text, finished: true), staleDate: nil), dismissalPolicy: .after(.now + 600))
        }
    }
}
