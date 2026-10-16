// Sends one saved screenshot and a task to the real model and prints the action it chooses.
// Usage: ANTHROPIC_API_KEY=... swift run phoneuse-probe <screenshot.png|jpg> "task"   (or ANTHROPIC_AUTH_TOKEN)
// Optional: PHONEUSE_MODEL to pick the model id.
import CoreGraphics
import Foundation
import ImageIO
import PhoneUseCore

struct StillDevice: DeviceController {
    let shot: Screenshot

    func screenshot() async throws -> Screenshot { shot }
    func tap(x: Int, y: Int) async throws { print("  -> would tap pixel \(x),\(y) of \(shot.width)x\(shot.height)") }
    func longPress(x: Int, y: Int, seconds: Double) async throws { print("  -> would hold at \(x),\(y)") }
    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        print("  -> would swipe \(fromX),\(fromY) to \(toX),\(toY)")
    }
    func typeText(_ text: String) async throws { print("  -> would type \"\(text)\"") }
    func pressEnter() async throws { print("  -> would press Return") }
    func pressHome() async throws { print("  -> would go home") }
    func openApp(named name: String) async throws -> Bool {
        print("  -> would open \(name)")
        return true
    }
}

struct ConsoleUser: UserInteraction {
    func approve(action summary: String, target: String) async -> Bool {
        print("  (approval would be asked for: \(target))")
        return true
    }
    func handOver(reason: String) async -> Bool {
        print("  (hand-over: \(reason))")
        return false
    }
    func ask(question: String) async -> String? {
        print("  (question: \(question))")
        return nil
    }
}

func loadScreenshot(_ path: String) -> Screenshot? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return Screenshot(jpeg: data as Data, width: image.width, height: image.height)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: phoneuse-probe <screenshot> \"task\"")
    exit(2)
}
let environment = ProcessInfo.processInfo.environment
/* Direct provider calls disabled; use the local Claude Code bridge.
let model: any ModelClient
var pricing: Pricing?
// GLM disabled.
// if let key = environment["GLM_API_KEY"], !key.isEmpty {
//     model = OpenAICompatibleClient.glm(apiKey: { key }, model: environment["PHONEUSE_MODEL"] ?? "glm-5.3-flash")
// } else
if let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty {
    model = AnthropicClient(apiKey: { key }, model: environment["PHONEUSE_MODEL"] ?? "claude-opus-5-5")
    pricing = .opus55
} else if let token = environment["ANTHROPIC_AUTH_TOKEN"], !token.isEmpty {
    model = AnthropicClient(credential: { .authToken(token) }, model: environment["PHONEUSE_MODEL"] ?? "claude-opus-5-5")
    pricing = .opus55
} else {
    print("Set ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN first.")
    exit(2)
}
*/
let model: any ModelClient = LocalModelClient(base: URL(string: environment["AGENTONE_BRIDGE_URL"] ?? "http://127.0.0.1:8766")!)
let pricing: Pricing? = .opus55
guard let shot = loadScreenshot(arguments[1]) else {
    print("Could not read an image from \(arguments[1])")
    exit(2)
}

var config = AgentConfig()
config.maxSteps = 1
config.coordinates = environment["PHONEUSE_COORDS"].flatMap(CoordinateSpace.init(rawValue:))
config.settle = .zero
let agent = Agent(
    device: StillDevice(shot: shot), model: model, user: ConsoleUser(), config: config,
    onProgress: { print("step \($0.step): \($0.summary)") })
let result = await agent.run(task: arguments[2])
print("outcome: \(result.outcome)")
print("tokens: \(result.usage.input) in, \(result.usage.output) out, \(result.usage.cacheRead) cached")
if let pricing { print("estimated cost $\(String(format: "%.4f", result.usage.estimatedCost(pricing)))") }
