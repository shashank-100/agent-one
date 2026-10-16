import Observation
import PhoneUseCore
import SwiftUI

/// One run of the PiDurableKit agent: the task, the steps as they happen, the person's Allow, the result.
@MainActor
@Observable
final class AgentRunModel {
    struct Ask: Identifiable { let id = UUID(); let summary: String; let answer: CheckedContinuation<Bool, Never> }

    var task = ""
    private(set) var running = false
    private(set) var steps: [PhoneAgent.Step] = []
    private(set) var result: PhoneAgent.Ending?
    var ask: Ask?

    let agent: PhoneAgent
    private let device: any DeviceController
    init(device: any DeviceController) {
        self.device = device
        agent = PhoneAgent(device: device)
    }

    /// Debug launch flags for unattended runs in the simulator, on the test phone only:
    /// `-autoAllow YES` allows irreversible taps; every run prints the test phone's state for grading.
    private var autoAllow: Bool {
        #if DEBUG
        device is TestPhone && UserDefaults.standard.bool(forKey: "autoAllow")
        #else
        false   // never in shipped builds
        #endif
    }

    func start() {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !running else { return }
        running = true
        steps = []
        result = nil
        BackgroundRun.shared.begin(title: task) { [weak self] in self?.stop() }
        LiveRun.shared.begin(task: task)
        Task {
            let ending = await agent.run(task: task, onStep: { step in
                Task { @MainActor [weak self] in
                    self?.steps.append(step)
                    BackgroundRun.shared.progress(step: step.number, of: 40, detail: step.text)
                    LiveRun.shared.update(step: step.number, detail: step.text)
                }
            }, approve: { [weak self] summary, _ in
                if await self?.autoAllow == true { return true }
                return await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        guard let self else { return continuation.resume(returning: false) }
                        self.ask = Ask(summary: summary, answer: continuation)
                    }
                }
            })
            result = ending
            running = false
            if case .done = ending { BackgroundRun.shared.end(success: true) } else { BackgroundRun.shared.end(success: false) }
            LiveRun.shared.end(Self.describe(ending))
            print("AGENT_ONE_RESULT \(Self.describe(ending))")
            if let phone = device as? TestPhone { print("AGENT_ONE_STATE \(await phone.stateJSON())") }
        }
    }

    func stop() { Task { await agent.stop() } }

    func answer(_ yes: Bool) {
        ask?.answer.resume(returning: yes)
        ask = nil
    }

    static func describe(_ ending: PhoneAgent.Ending) -> String {
        switch ending {
        case .done(let text): "Done: \(text)"
        case .failed(let text): "Could not finish: \(text)"
        case .stopped: "Stopped."
        }
    }
}

struct AgentRunView: View {
    @Bindable var model: AgentRunModel

    var body: some View {
        List {
            Section {
                TextField("What should the agent do?", text: $model.task, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(model.running)
                HStack {
                    Button(model.running ? "Running…" : "Run") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.running || model.task.isEmpty)
                    if model.running { Button("Stop", role: .destructive) { model.stop() } }
                }
            }
            if !model.steps.isEmpty {
                Section("Steps") {
                    ForEach(model.steps, id: \.number) { step in
                        Text("\(step.number). \(step.text)").font(.footnote.monospaced())
                    }
                }
            }
            if let result = model.result {
                Section("Result") { Text(AgentRunModel.describe(result)) }
            }
        }
        .alert("Allow this tap?", isPresented: Binding(get: { model.ask != nil }, set: { if !$0 { model.answer(false) } })) {
            Button("Allow") { model.answer(true) }
            Button("Don't allow", role: .cancel) { model.answer(false) }
        } message: {
            Text(model.ask?.summary ?? "")
        }
    }
}
