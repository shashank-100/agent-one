import Foundation

public struct AgentConfig: Sendable {
    public var maxSteps = 40
    public var maxDuration: Duration = .seconds(15 * 60)
    /// Cap on tokens across the run, counting cached reads. Every step re-sends the conversation.
    public var maxTotalTokens = 3_000_000
    /// Cap on the estimated spend for one run, in US dollars.
    public var maxCostUSD = 3.0
    public var pricing = Pricing.opus55
    /// Pause after an action so animations and loading finish before the next screenshot.
    public var settle: Duration = .milliseconds(300)
    public var installedApps: [String] = []
    /// Overrides the model client's own coordinate convention.
    public var coordinates: CoordinateSpace?

    public init() {}
}

public enum RunOutcome: Equatable, Sendable {
    case finished(success: Bool, answer: String)
    case stopped(reason: String)
}

public struct RunResult: Sendable {
    public let outcome: RunOutcome
    public let steps: Int
    public let usage: TokenUsage
    /// True when the primary model failed and the backup finished the run.
    public var usedBackup = false
}

public struct AgentProgress: Sendable {
    public let step: Int
    public let summary: String
}

/// The loop: screenshot to the model, one action back, perform it, repeat.
public actor Agent {
    private let device: any DeviceController
    private let model: any ModelClient
    private let backup: (any ModelClient)?
    private var usedBackup = false
    private let user: any UserInteraction
    /// Saved logins the agent may type without the model ever seeing them.
    private let vault: (any CredentialVault)?
    private let trace: (any TraceSink)?
    private let checkpoints: (any CheckpointStore)?
    private let riskGuard: RiskGuard
    private let config: AgentConfig
    private let onProgress: (@Sendable (AgentProgress) -> Void)?
    private var stopReason: String?

    public init(
        device: any DeviceController,
        model: any ModelClient,
        backup: (any ModelClient)? = nil,
        user: any UserInteraction,
        trace: (any TraceSink)? = nil,
        vault: (any CredentialVault)? = nil,
        checkpoints: (any CheckpointStore)? = nil,
        riskGuard: RiskGuard = RiskGuard(),
        config: AgentConfig = AgentConfig(),
        onProgress: (@Sendable (AgentProgress) -> Void)? = nil
    ) {
        self.device = device
        self.model = model
        self.backup = backup
        self.user = user
        self.vault = vault
        self.trace = trace
        self.checkpoints = checkpoints
        self.riskGuard = riskGuard
        self.config = config
        self.onProgress = onProgress
    }

    /// Takes effect before the next step; an action already in flight completes.
    public func requestStop(reason: String = "stopped by the user") {
        stopReason = reason
    }

    private enum Performed {
        case carryOn(String, isError: Bool = false)
        case end(RunOutcome)
    }

    public func run(task: String) async -> RunResult {
        await loop(RunCheckpoint(task: task))
    }

    /// Continues a run that was cut short (the app was killed or suspended). Returns nil when there is nothing to resume.
    public func resume() async -> RunResult? {
        guard var state = await checkpoints?.load() else { return nil }
        if !state.inFlight.isEmpty {
            // The app died between choosing an action and recording its result.
            state.pending = state.inFlight.map {
                PendingResult(id: $0, text: "The app was interrupted during this action, so it may or may not have happened. Check the screen before repeating it.", isError: false)
            }
            state.inFlight = []
        }
        return await loop(state)
    }

    private func loop(_ state: RunCheckpoint) async -> RunResult {
        stopReason = nil
        let task = state.task
        usedBackup = false
        var active: any ModelClient = model
        var space = config.coordinates ?? model.coordinates
        let saved = await vault?.catalog() ?? ""
        var system = Prompt.system(installedApps: config.installedApps, space: space) + saved
        let clock = ContinuousClock()
        let started = clock.now
        var messages = state.messages
        var pending = state.pending
        var watch = LoopWatch()
        var usage = state.usage
        var misses = 0
        var step = state.step
        var elementList = ElementList()
        // macos-harness's rule: read the text, open the picture only when the text is not enough. The screenshot
        // goes to the model on the first turn, after an error, when nothing is listed, or when it asks (look).
        var wantImage = true
        var justFilled = false

        while step < config.maxSteps {
            if let stopReason { return await end(.stopped(reason: stopReason), step: step, usage: usage) }
            if clock.now - started > config.maxDuration { return await end(.stopped(reason: "time limit reached"), step: step, usage: usage) }
            if usage.total > config.maxTotalTokens { return await end(.stopped(reason: "token limit reached"), step: step, usage: usage) }
            if usage.estimatedCost(config.pricing) > config.maxCostUSD { return await end(.stopped(reason: "spend limit reached"), step: step, usage: usage) }
            step += 1

            let shot: Screenshot
            do { shot = try await device.screenshot() } catch {
                return await end(.stopped(reason: "could not capture the screen: \(error)"), step: step, usage: usage)
            }
            let fingerprint = ScreenFingerprint(jpeg: shot.jpeg)
            let protected = fingerprint?.isBlack == true
                ? " The screenshot is black, which means a protected screen: use hand_over, or go back." : ""
            let isFirst = messages.isEmpty
            var listed = ""
            if let reader = device as? any ElementReader {
                listed = elementList.describe(await reader.elements())
                if let vault { listed = await vault.redact(listed) }
            }
            // Right after a saved login was typed, no screenshot goes out: the field may show the value.
            // A saved login visible on screen (shown as •••• in the list) means no picture may go out at all.
            let secretVisible = listed.contains("••••")
            let sendImage = !justFilled && !secretVisible && (wantImage || isFirst || listed.isEmpty || !protected.isEmpty || pending.contains(where: \.isError))
            justFilled = false
            let note = sendImage ? "" : " (No screenshot this turn: the element list above is the screen. Call look if you need to see it.)"
            func turn(_ space: CoordinateSpace) -> JSONValue {
                Self.userMessage(task: isFirst ? task : nil, pending: pending,
                                 screen: Prompt.screenLine(shot, space: space) + protected + listed + note, jpeg: sendImage ? shot.jpeg : nil)
            }
            wantImage = false
            messages.append(turn(space))

            var reply: ModelReply
            do { reply = try await active.reply(system: system, tools: AgentAction.toolDefinitions(for: space), messages: messages) } catch {
                guard let backup, !usedBackup else {
                    return await end(.stopped(reason: "model call failed: \(error)"), step: step, usage: usage)
                }
                // The primary is down or refusing calls (not a content refusal): the backup takes over for the rest of
                // the run. The unanswered turn is rebuilt in the backup's coordinate convention; earlier turns stay as they are.
                usedBackup = true
                active = backup
                space = config.coordinates ?? backup.coordinates
                system = Prompt.system(installedApps: config.installedApps, space: space) + saved
                messages.removeLast()
                messages.append(turn(space))
                onProgress?(AgentProgress(step: step, summary: "switched to the backup model"))
                do { reply = try await active.reply(system: system, tools: AgentAction.toolDefinitions(for: space), messages: messages) } catch {
                    return await end(.stopped(reason: "model call failed on both models: \(error)"), step: step, usage: usage)
                }
            }
            pending = []
            usage += reply.usage
            // Appended unchanged: the history is append-only so the model's thinking blocks stay valid.
            messages.append(["role": "assistant", "content": .array(reply.content)])
            if reply.stopReason == "refusal" { return await end(.stopped(reason: "the model declined this task"), step: step, usage: usage) }

            let calls = reply.toolCalls
            guard let call = calls.first else {
                misses += 1
                await trace?.record(step: step, screenshot: shot.jpeg, modelText: reply.text, action: "(no action)", result: "")
                if misses >= 3 { return await end(.stopped(reason: "the model stopped choosing actions"), step: step, usage: usage) }
                continue
            }
            misses = 0
            // Several actions per reply, in order (macos-harness: "chain the steps you are sure of; one call costs less
            // than three"). The chain stops at a failure, a refusal, or once the screen has changed and the next action
            // would need the new screen: only typing, Return, wait and look may follow a screen-changing action.
            var results: [PendingResult] = []
            var stopChain = false
            var screenChanged = false
            for call in calls {
                if stopChain || (screenChanged && !["type_text", "press_enter", "wait", "look"].contains(call.name)) {
                    results.append(PendingResult(id: call.id, text: "Not performed: the screen changed first. Read the new list and decide again.", isError: false))
                    stopChain = true
                    continue
                }
                if call.name == "fill_credential" {
                    let name = call.input["name"]?.stringValue ?? ""
                    guard let credential = await vault?.all().first(where: { $0.name == name }) else {
                        results.append(PendingResult(id: call.id, text: "There is no saved login called \"\(name)\". Use hand_over so the user types it.", isError: true))
                        stopChain = true
                        continue
                    }
                    do {
                        if let n = call.input["element"]?.intValue, n > 0 {
                            guard let element = elementList.element(n) else { throw AgentAction.ParseError(description: "There is no element \(n) on this screen.") }
                            if let tapper = device as? any ElementTapper, element.place != .onScreen { try await tapper.tap(element) }
                            else { try await device.tap(x: element.center.x, y: element.center.y) }
                            try await Task.sleep(for: .milliseconds(300))
                        }
                        if call.input["clear"]?.boolValue == true { try? await device.clearText() }
                        // The value goes straight to the keyboard; nothing about it is written to the conversation.
                        try await device.typeText(credential.value)
                        onProgress?(AgentProgress(step: step, summary: "fill saved login “\(name)”"))
                        results.append(PendingResult(id: call.id, text: "Filled the saved login \(name) (value hidden).", isError: false))
                        justFilled = true
                    } catch {
                        results.append(PendingResult(id: call.id, text: "The action failed: \(error)", isError: true))
                        stopChain = true
                    }
                    continue
                }
                if call.name == "look" {
                    if listed.contains("••••") {
                        results.append(PendingResult(id: call.id, text: "No screenshot while a saved login is visible on screen; use the element list.", isError: false))
                        continue
                    }
                    wantImage = true
                    results.append(PendingResult(id: call.id, text: "Here is the screenshot.", isError: false))
                    continue
                }
                // Tap on an off-screen element: the phone scrolls it into view and taps it in one action.
                if call.name == "tap", let tapper = device as? any ElementTapper,
                   let n = call.input["element"]?.intValue, n > 0, let element = elementList.element(n), element.place != .onScreen {
                    let target = call.input["target"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? element.text
                    if riskGuard.needsApproval(target: target, flaggedIrreversible: call.input["irreversible"]?.boolValue ?? false),
                       await !user.approve(action: "tap “\(target)”", target: target) {
                        results.append(PendingResult(id: call.id, text: "The user refused this tap. Do not try another way: call finish with success false and say what was left undone.", isError: false))
                        stopChain = true
                        continue
                    }
                    onProgress?(AgentProgress(step: step, summary: "tap “\(target.prefix(40))” (scrolled into view)"))
                    do { try await tapper.tap(element); results.append(PendingResult(id: call.id, text: "Scrolled to it and tapped.", isError: false)) }
                    catch { results.append(PendingResult(id: call.id, text: "The action failed: \(error)", isError: true)); stopChain = true }
                    screenChanged = true
                    continue
                }
                let action: AgentAction
                do {
                    let input = try Self.resolveElement(call.input, list: elementList, shot: shot, space: space)
                    action = try AgentAction(toolName: call.name, input: input)
                } catch {
                    results.append(PendingResult(id: call.id, text: "\(error)", isError: true))
                    await trace?.record(step: step, screenshot: shot.jpeg, modelText: reply.text, action: call.name, result: "\(error)")
                    stopChain = true
                    continue
                }

                let verdict = watch.step(fingerprint: fingerprint, action: action)
                if verdict == .stop {
                    let reason = "stuck: the same action \(watch.streak) times on a screen that did not change (\(action.summary))"
                    await trace?.record(step: step, screenshot: shot.jpeg, modelText: reply.text, action: action.summary, result: reason)
                    return await end(.stopped(reason: reason), step: step, usage: usage)
                }

                onProgress?(AgentProgress(step: step, summary: action.summary))
                // Saved before acting: if the app dies mid-action, the resumed run knows the outcome is uncertain.
                await checkpoints?.save(RunCheckpoint(task: task, messages: messages, pending: results, inFlight: calls.map(\.id), step: step, usage: usage))
                let performed = await perform(action, on: shot, space: space, list: elementList)
                switch performed {
                case .end(let outcome):
                    let text: String
                    if case .finished(_, let answer) = outcome { text = answer } else { text = "stopped" }
                    await trace?.record(step: step, screenshot: shot.jpeg, modelText: reply.text, action: action.summary, result: text)
                    return await end(outcome, step: step, usage: usage)
                case .carryOn(var text, let isError):
                    if verdict == .note {
                        text += " This is the same action on an unchanged screen for the \(watch.streak)th time; it is not working. Try something else."
                    }
                    await trace?.record(step: step, screenshot: shot.jpeg, modelText: reply.text, action: action.summary, result: text)
                    results.append(PendingResult(id: call.id, text: text, isError: isError))
                    if isError || text.hasPrefix("The user refused") { stopChain = true }
                }
                if !action.isPauseOrEnd, action.changesScreen { screenChanged = true; await settle() }
            }
            pending = results
            await checkpoints?.save(RunCheckpoint(task: task, messages: messages, pending: pending, inFlight: [], step: step, usage: usage))
        }
        return await end(.stopped(reason: "step limit reached"), step: step, usage: usage)
    }

    /// Waits until the screen stops changing: a short pause, then quick looks until two match (about 3 s at most),
    /// so the model never sees a half-loaded screen and never has to call `wait` itself.
    private func settle() async {
        try? await Task.sleep(for: config.settle)
        var last = (try? await device.screenshot()).flatMap { ScreenFingerprint(jpeg: $0.jpeg) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(250))
            let next = (try? await device.screenshot()).flatMap { ScreenFingerprint(jpeg: $0.jpeg) }
            if let a = last, let b = next, a.isSameScreen(as: b) { return }
            last = next
        }
    }

    /// An `element` number in a tool call becomes that element's centre, in the coordinates the model uses.
    /// 0 or no number leaves x and y as given.
    static func resolveElement(_ input: JSONValue, list: ElementList, shot: Screenshot, space: CoordinateSpace) throws -> JSONValue {
        guard case .object(var fields) = input, let number = fields["element"]?.intValue, number > 0 else { return input }
        guard let element = list.element(number) else {
            throw AgentAction.ParseError(description: "There is no element \(number) in the list on this screen. Use a number from the newest list, or x and y.")
        }
        let c = element.center
        let (x, y) = space == .grid
            ? (c.x * (GridPoint.gridSize - 1) / max(shot.width, 1), c.y * (GridPoint.gridSize - 1) / max(shot.height, 1))
            : (c.x, c.y)
        fields["x"] = .int(x)
        fields["y"] = .int(y)
        if (fields["target"]?.stringValue ?? "").isEmpty { fields["target"] = .string(element.text) }
        if (fields["field"]?.stringValue ?? "").isEmpty, fields["text"] != nil { fields["field"] = .string(element.text) }
        return .object(fields)
    }

    private func end(_ outcome: RunOutcome, step: Int, usage: TokenUsage) async -> RunResult {
        await checkpoints?.clear()
        var result = RunResult(outcome: outcome, steps: step, usage: usage)
        result.usedBackup = usedBackup
        return result
    }

    private func perform(_ action: AgentAction, on shot: Screenshot, space: CoordinateSpace, list: ElementList) async -> Performed {
        do {
            switch action {
            case .tap(let point, let target, let irreversible):
                if riskGuard.needsApproval(target: target, flaggedIrreversible: irreversible) {
                    guard await user.approve(action: action.summary, target: target) else {
                        return .carryOn("The user refused this tap. Do not try another way: call finish with success false and say what was left undone.")
                    }
                }
                let p = point.pixels(width: shot.width, height: shot.height, space: space)
                try await device.tap(x: p.x, y: p.y)
                return .carryOn("Tapped.")
            case .longPress(let point, _):
                let p = point.pixels(width: shot.width, height: shot.height, space: space)
                try await device.longPress(x: p.x, y: p.y, seconds: 0.8)
                return .carryOn("Held.")
            case .swipe(let from, let to):
                let a = from.pixels(width: shot.width, height: shot.height, space: space)
                let b = to.pixels(width: shot.width, height: shot.height, space: space)
                try await device.swipe(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y, seconds: 0.35)
                return .carryOn("Swiped.")
            case .scroll(let direction):
                // The finger moves the opposite way to the content: scrolling down drags upward.
                let (w, h) = (shot.width, shot.height)
                let (cx, cy) = (w / 2, h / 2)
                let (dx, dy) = (w * 3 / 10, h / 5)
                let ends: (Int, Int, Int, Int)
                switch direction {
                case .down: ends = (cx, cy + dy, cx, cy - dy)
                case .up: ends = (cx, cy - dy, cx, cy + dy)
                case .right: ends = (cx + dx, cy, cx - dx, cy)
                case .left: ends = (cx - dx, cy, cx + dx, cy)
                }
                try await device.swipe(fromX: ends.0, fromY: ends.1, toX: ends.2, toY: ends.3, seconds: 0.35)
                return .carryOn("Scrolled \(direction.rawValue).")
            case .typeText(let text, _, let at, let clear):
                if let at {
                    let p = at.pixels(width: shot.width, height: shot.height, space: space)
                    try await device.tap(x: p.x, y: p.y)
                    try? await Task.sleep(for: .milliseconds(350))
                }
                if clear { try await device.clearText() }
                if await device.focusedFieldIsSecure() {
                    return .carryOn("This is a password field. Use hand_over so the user types it.", isError: true)
                }
                try await device.typeText(text)
                return .carryOn("Typed.")
            case .pressEnter:
                try await device.pressEnter()
                return .carryOn("Pressed Return.")
            case .openApp(let name):
                return try await device.openApp(named: name)
                    ? .carryOn("Opened \(name).")
                    : .carryOn("No installed app matches \"\(name)\".", isError: true)
            case .goHome:
                try await device.pressHome()
                return .carryOn("On the home screen.")
            case .goBack:
                try await device.pressBack()
                return .carryOn("Went back.")
            case .wait(let seconds):
                try? await Task.sleep(for: .seconds(seconds))
                return .carryOn("Waited \(seconds) seconds.")
            case .handOver(let reason):
                return await user.handOver(reason: reason)
                    ? .carryOn("The user has done their part. Carry on.")
                    : .end(.stopped(reason: "stopped by the user during a hand-over"))
            case .askUser(let question):
                if let answer = await user.ask(question: question) {
                    return .carryOn("The user answered: \(answer)")
                }
                return .carryOn("The user did not answer.")
            case .finish(let success, let answer):
                return .end(.finished(success: success, answer: answer))
            case .setValue(let number, let value):
                guard let element = list.element(number) else {
                    return .carryOn("There is no element \(number) on this screen.", isError: true)
                }
                guard let setter = device as? any ValueSetter else {
                    return .carryOn("This phone cannot set values directly. Use swipe for sliders and wheels, or type_text for fields.", isError: true)
                }
                try await setter.setValue(value, on: element)
                return .carryOn("Set to \(value).")
            }
        } catch {
            return .carryOn("The action failed: \(error)", isError: true)
        }
    }

    private static func userMessage(task: String?, pending: [PendingResult], screen: String, jpeg: Data?) -> JSONValue {
        let image: JSONValue? = jpeg.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": .string($0.base64EncodedString())]]
        }
        func text(_ s: String) -> JSONValue { ["type": "text", "text": .string(s)] }
        var blocks: [JSONValue] = []
        if let task {
            blocks = [text(Prompt.firstTurn(task: task) + screen)] + (image.map { [$0] } ?? [])
        } else if pending.isEmpty {
            blocks = [text("Reply with one or more tool calls. " + screen)] + (image.map { [$0] } ?? [])
        } else {
            // The new screenshot rides in the last result so tool results stay first in the message.
            for (index, item) in pending.enumerated() {
                let last = index == pending.count - 1
                var content: [JSONValue] = [text(last ? item.text + " " + screen : item.text)]
                if last, let image { content.append(image) }
                var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(item.id), "content": .array(content)]
                if item.isError { block["is_error"] = true }
                blocks.append(.object(block))
            }
        }
        return ["role": "user", "content": .array(blocks)]
    }
}
