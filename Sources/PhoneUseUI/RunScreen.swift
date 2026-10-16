import PhoneUseCore
import SwiftUI

public struct RunScreen: View {
    @Bindable private var model: RunViewModel

    public init(model: RunViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What should I do on this phone?", text: $model.task, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .disabled(model.phase == .running)

            HStack {
                if model.phase == .running {
                    Button("Stop", role: .destructive) { model.stop() }
                        .buttonStyle(.borderedProminent)
                    ProgressView()
                } else {
                    Button("Start") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                }
                Spacer()
                if model.costUSD > 0 {
                    Text(model.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if case .done(let outcome) = model.phase {
                OutcomeView(outcome: outcome)
            }

            List(model.steps) { step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(step.id)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    Text(step.text)
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .sheet(item: Binding(get: { model.prompt }, set: { if $0 == nil { model.answer(nil) } })) { prompt in
            PromptSheet(kind: prompt.kind, reply: $model.draftReply) { model.answer($0) }
            .presentationDetents([.medium])
        }
    }
}

private struct OutcomeView: View {
    let outcome: RunOutcome

    var body: some View {
        switch outcome {
        case .finished(let success, let answer):
            Label(answer, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .orange)
        case .stopped(let reason):
            Label("Stopped: \(reason)", systemImage: "stop.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PromptSheet: View {
    let kind: RunViewModel.PendingPrompt.Kind
    @Binding var reply: String
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch kind {
            case .approval(let action, let target):
                Text("Allow this?").font(.headline)
                Text(target.isEmpty ? action : "Tap “\(target)”")
                HStack {
                    Button("Don't allow", role: .cancel) { answer(nil) }
                    Spacer()
                    Button("Allow") { answer("yes") }.buttonStyle(.borderedProminent)
                }
            case .handOver(let reason):
                Text("Your turn").font(.headline)
                Text(reason)
                HStack {
                    Button("Stop the task", role: .destructive) { answer(nil) }
                    Spacer()
                    Button("Done, carry on") { answer("yes") }.buttonStyle(.borderedProminent)
                }
            case .question(let question):
                Text(question).font(.headline)
                TextField("Answer", text: $reply).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Skip", role: .cancel) { answer(nil) }
                    Spacer()
                    Button("Send") { answer(reply) }.buttonStyle(.borderedProminent).disabled(reply.isEmpty)
                }
            }
        }
        .padding()
    }
}
