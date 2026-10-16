import Foundation

/// One task to run repeatedly. `verify` checks the real outcome; without it, success is the model's own claim.
public struct EvalTask: Sendable {
    public let name: String
    public let prompt: String
    public let verify: (@Sendable () async -> Bool)?
    /// Puts the phone back to a known state before each run.
    public let reset: (@Sendable () async -> Void)?

    public init(name: String, prompt: String, verify: (@Sendable () async -> Bool)? = nil, reset: (@Sendable () async -> Void)? = nil) {
        self.name = name
        self.prompt = prompt
        self.verify = verify
        self.reset = reset
    }
}

public struct EvalReport: Sendable, Equatable {
    public let name: String
    public let runs: Int
    public let successes: Int
    public let averageSteps: Double
    public let averageCostUSD: Double
    /// Why each failed run ended.
    public let failures: [String]

    public var successRate: Double { runs == 0 ? 0 : Double(successes) / Double(runs) }
}

/// Runs each task several times. One run of a phone agent proves little; the rate over repeats is the number that matters.
public func evaluate(
    _ tasks: [EvalTask], runsPerTask: Int, pricing: Pricing = .opus55, makeAgent: @Sendable () async -> Agent
) async -> [EvalReport] {
    var reports: [EvalReport] = []
    for task in tasks {
        var successes = 0, steps = 0, cost = 0.0
        var failures: [String] = []
        for _ in 0..<runsPerTask {
            await task.reset?()
            let result = await makeAgent().run(task: task.prompt)
            steps += result.steps
            cost += result.usage.estimatedCost(pricing)
            switch result.outcome {
            case .finished(true, _):
                if let verify = task.verify, await !verify() {
                    failures.append("reported success, but the check failed")
                } else {
                    successes += 1
                }
            case .finished(false, let answer): failures.append(answer)
            case .stopped(let reason): failures.append(reason)
            }
        }
        let n = Double(max(runsPerTask, 1))
        reports.append(EvalReport(
            name: task.name, runs: runsPerTask, successes: successes,
            averageSteps: Double(steps) / n, averageCostUSD: cost / n, failures: failures))
    }
    return reports
}
