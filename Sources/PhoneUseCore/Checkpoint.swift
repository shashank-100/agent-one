import Foundation

struct PendingResult: Codable, Sendable, Equatable {
    let id: String
    let text: String
    let isError: Bool
}

/// Everything needed to carry a run on after the app is killed: iOS suspends and terminates
/// background apps freely, and a task is usually mid-way through another app when it happens.
public struct RunCheckpoint: Codable, Sendable, Equatable {
    public let task: String
    var messages: [JSONValue] = []
    var pending: [PendingResult] = []
    /// Tool calls chosen but not yet known to have been performed.
    var inFlight: [String] = []
    public internal(set) var step = 0
    public internal(set) var usage = TokenUsage()

    init(task: String, messages: [JSONValue] = [], pending: [PendingResult] = [], inFlight: [String] = [], step: Int = 0, usage: TokenUsage = TokenUsage()) {
        self.task = task
        self.messages = messages
        self.pending = pending
        self.inFlight = inFlight
        self.step = step
        self.usage = usage
    }
}

public protocol CheckpointStore: Sendable {
    func save(_ checkpoint: RunCheckpoint) async
    func load() async -> RunCheckpoint?
    func clear() async
}

public actor FileCheckpointStore: CheckpointStore {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func save(_ checkpoint: RunCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func load() -> RunCheckpoint? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(RunCheckpoint.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
