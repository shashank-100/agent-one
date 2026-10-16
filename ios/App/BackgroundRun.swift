import BackgroundTasks
import Foundation

/// Keeps a run going when the user leaves the app, with the system's progress UI and Stop button
/// (iOS 26 continued-processing tasks). Older systems simply pause the run in the background.
@MainActor
final class BackgroundRun {
    static let shared = BackgroundRun()
    private static let prefix = "com.agentone.app.run"

    private var task: AnyObject?
    private var onExpire: (() -> Void)?
    private var registered = false

    /// Ask the system to keep this run alive. `stop` is called when the user or the system ends it.
    func begin(title: String, stop: @escaping @MainActor () -> Void) {
        guard #available(iOS 26.0, *) else { return }
        onExpire = stop
        let identifier = "\(Self.prefix).\(UUID().uuidString)"
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: "\(Self.prefix).*", using: .main) { task in
                MainActor.assumeIsolated { BackgroundRun.shared.started(task) }
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Agent One", subtitle: title)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Steps done so far, shown in the system's progress UI.
    func progress(step: Int, of total: Int, detail: String) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(total)
        task.progress.completedUnitCount = Int64(min(step, total))
        task.updateTitle("Agent One", subtitle: detail)
    }

    func end(success: Bool) {
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        self.task = nil
        onExpire = nil
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
        self.task = task
        task.expirationHandler = {
            Task { @MainActor in
                BackgroundRun.shared.onExpire?()
                BackgroundRun.shared.end(success: false)
            }
        }
    }
}
