// Runs the agent on a real phone endpoint: the MobileGym bridge now, the iPhone app later.
//   swift run phoneuse-run --device http://127.0.0.1:8765 --token <t> [--approve yes|no] [--steps 30] "task"
// Model: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN. GLM is disabled.
import Foundation
import PhoneUseCore

struct Options {
    var device = "http://127.0.0.1:8765"
    var token = ""
    var approve: Bool? = nil
    var steps = 30
    var task = ""
    var traces = FileManager.default.currentDirectoryPath + "/traces"
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--device": o.device = args.isEmpty ? o.device : args.removeFirst()
        case "--token": o.token = args.isEmpty ? "" : args.removeFirst()
        case "--approve": o.approve = (args.isEmpty ? "no" : args.removeFirst()) == "yes"
        case "--steps": o.steps = Int(args.isEmpty ? "" : args.removeFirst()) ?? o.steps
        case "--traces": o.traces = args.isEmpty ? o.traces : args.removeFirst()
        default: o.task = o.task.isEmpty ? a : o.task + " " + a
        }
    }
    return o
}

/// Asks in the terminal. Without a terminal, `--approve` decides; with neither, the answer is no.
struct TerminalUser: UserInteraction {
    let approveAll: Bool?

    func line(_ prompt: String) -> String? {
        print(prompt, terminator: " ")
        fflush(stdout)
        return isatty(STDIN_FILENO) != 0 ? readLine() : nil
    }

    func approve(action summary: String, target: String) async -> Bool {
        if let approveAll {
            print("  approval: \(summary) → \(approveAll ? "allowed (--approve yes)" : "refused (--approve no)")")
            return approveAll
        }
        return line("  Allow \(summary)? [y/N]")?.lowercased().hasPrefix("y") ?? false
    }

    func handOver(reason: String) async -> Bool {
        print("  hand-over: \(reason)")
        return line("  Done? [y/N]")?.lowercased().hasPrefix("y") ?? false
    }

    func ask(question: String) async -> String? {
        line("  question: \(question)\n  answer:")
    }
}

let o = parse()
guard !o.task.isEmpty, let url = URL(string: o.device) else {
    print("usage: phoneuse-run --device <url> --token <token> [--approve yes|no] [--steps N] \"task\"")
    exit(2)
}
let env = ProcessInfo.processInfo.environment
/* Direct provider calls disabled; use the local Claude Code bridge.
var clients: [any ModelClient] = []
if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { clients.append(AnthropicClient(apiKey: { k })) }
else if let t = env["ANTHROPIC_AUTH_TOKEN"], !t.isEmpty { clients.append(AnthropicClient(credential: { .authToken(t) })) }
// GLM disabled.
// if let k = env["GLM_API_KEY"], !k.isEmpty { clients.append(OpenAICompatibleClient.glm(apiKey: { k }, model: env["PHONEUSE_GLM_MODEL"] ?? "glm-5.3-flash")) }
guard let primary = clients.first else {
    print("Set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN.")
    exit(2)
}
*/
let primary: any ModelClient = LocalModelClient(base: URL(string: env["AGENTONE_BRIDGE_URL"] ?? "http://127.0.0.1:8766")!)

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let traceDir = URL(fileURLWithPath: o.traces).appendingPathComponent(stamp)
var config = AgentConfig()
config.maxSteps = o.steps
config.maxCostUSD = 5
let agent = Agent(
    device: RemoteDevice(baseURL: url, token: o.token), model: primary, backup: nil,
    user: TerminalUser(approveAll: o.approve), trace: try? FileTraceRecorder(directory: traceDir), config: config,
    onProgress: { print("step \($0.step): \($0.summary)") })

print("task: \(o.task)")
let started = Date()
let result = await agent.run(task: o.task)
print("outcome: \(result.outcome)")
print("steps: \(result.steps), \(Int(Date().timeIntervalSince(started)))s, tokens in \(result.usage.input) out \(result.usage.output) cached \(result.usage.cacheRead)\(result.usedBackup ? ", finished on the backup model" : "")")
print("trace: \(traceDir.path)")
