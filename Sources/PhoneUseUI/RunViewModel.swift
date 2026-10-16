import Foundation
import Observation
import PhoneUseCore

/// Drives one screen: type a task, watch the steps, answer the agent's prompts, stop it.
@MainActor
@Observable
public final class RunViewModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case running
        case done(RunOutcome)
    }

    public struct StepLine: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
    }

    /// Something the agent is waiting on the user for.
    public struct PendingPrompt: Identifiable {
        public enum Kind: Equatable, Sendable {
            case approval(action: String, target: String)
            case handOver(reason: String)
            case question(String)
        }

        public let id = UUID()
        public let kind: Kind
        fileprivate let continuation: CheckedContinuation<String?, Never>
    }

    public typealias AgentFactory = @Sendable (any UserInteraction, @escaping @Sendable (AgentProgress) -> Void) -> Agent

    public var task = ""
    /// What the user is typing in answer to the agent's question.
    public var draftReply = ""
    public private(set) var phase: Phase = .idle
    public private(set) var steps: [StepLine] = []
    public private(set) var prompt: PendingPrompt?
    public private(set) var costUSD = 0.0

    private let makeAgent: AgentFactory
    private let pricing: Pricing
    private var agent: Agent?
    private var runTask: Task<Void, Never>?

    public init(pricing: Pricing = .opus55, makeAgent: @escaping AgentFactory) {
        self.pricing = pricing
        self.makeAgent = makeAgent
    }

    public var canStart: Bool {
        phase != .running && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func start() {
        guard canStart else { return }
        steps = []
        costUSD = 0
        phase = .running
        let agent = makeAgent(self) { [weak self] progress in
            Task { @MainActor in self?.steps.append(StepLine(id: progress.step, text: progress.summary)) }
        }
        self.agent = agent
        let task = self.task
        runTask = Task {
            let result = await agent.run(task: task)
            costUSD = result.usage.estimatedCost(pricing)
            phase = .done(result.outcome)
            self.agent = nil
        }
    }

    public func stop() {
        guard phase == .running, let agent else { return }
        Task { await agent.requestStop() }
        // A prompt left open would keep the run waiting; answer it as a refusal.
        answer(nil)
    }

    /// Answers the open prompt. For approvals and hand-overs any non-nil value means yes.
    public func answer(_ value: String?) {
        guard let prompt else { return }
        self.prompt = nil
        draftReply = ""
        prompt.continuation.resume(returning: value)
    }

    /// Blocks until the run that `start()` began has ended.
    public func waitUntilDone() async {
        await runTask?.value
    }

    private func present(_ kind: PendingPrompt.Kind) async -> String? {
        await withCheckedContinuation { continuation in
            prompt = PendingPrompt(kind: kind, continuation: continuation)
        }
    }
}

extension RunViewModel: UserInteraction {
    nonisolated public func approve(action summary: String, target: String) async -> Bool {
        await present(.approval(action: summary, target: target)) != nil
    }

    nonisolated public func handOver(reason: String) async -> Bool {
        await present(.handOver(reason: reason)) != nil
    }

    nonisolated public func ask(question: String) async -> String? {
        await present(.question(question))
    }
}
