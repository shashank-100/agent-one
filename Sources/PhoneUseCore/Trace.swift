import Foundation

/// One step of a run, as recorded.
public struct TraceStep: Codable, Sendable, Equatable {
    public let step: Int
    public let screenshot: String?
    public let modelText: String
    public let action: String
    public let result: String
}

public protocol TraceSink: Sendable {
    func record(step: Int, screenshot: Data?, modelText: String, action: String, result: String) async
}

/// Writes each step's screenshot and a line of JSON to a directory. Traces hold pictures of the user's
/// apps, so the directory stays on the device.
public actor FileTraceRecorder: TraceSink {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func record(step: Int, screenshot: Data?, modelText: String, action: String, result: String) {
        var name: String?
        if let screenshot {
            let file = String(format: "step-%03d.jpg", step)
            if (try? screenshot.write(to: directory.appendingPathComponent(file))) != nil { name = file }
        }
        let entry = TraceStep(step: step, screenshot: name, modelText: modelText, action: action, result: result)
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        let log = directory.appendingPathComponent("steps.jsonl")
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: log)
        }
    }
}
