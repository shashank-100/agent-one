import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
#if canImport(Vision)
import Vision
#endif

/// Answers Phone Harness's remote-phone protocol for the phone this app runs on, so Hermes (or any
/// Phone Harness client) can drive the iPhone directly: no Mac, no iPhone Mirroring.
///
///     GET  /ops                       -> {"ops": [...]}
///     POST /op  {"op": ..., "kw": {}} -> {"result": ...}
///     errors                          -> {"error": "...", "unsupported": true?}
///
/// Coordinates are pixels of the screenshot, as on Phone Harness's Android backend: bounds are
/// {x: 0, y: 0, w, h}, taps and text boxes use the same space.
public actor HarnessHost {
    public struct Reply: Sendable, Equatable {
        public let status: Int
        public let body: JSONValue
    }

    private let device: any DeviceController
    private var lastSize: (w: Int, h: Int)?

    public init(device: any DeviceController) {
        self.device = device
    }

    public static let supportedOps = [
        "screen.capture", "screen.bounds", "screen.require", "screen.text", "screen.text_pixels",
        "input.tap", "input.press", "input.drag", "input.scroll", "input.keys", "input.text",
        "nav.home", "nav.back", "apps.launch", "session.state", "session.require",
    ]

    public func handle(method: String, path: String, body: Data) async -> Reply {
        switch (method, path) {
        case ("GET", "/ops"):
            return Reply(status: 200, body: ["ops": .array(Self.supportedOps.map(JSONValue.string))])
        case ("POST", "/op"):
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let op = request["op"]?.stringValue else {
                return Reply(status: 400, body: ["error": "RuntimeError: the body must be {\"op\": ..., \"kw\": {...}}"])
            }
            let kw = request["kw"] ?? .object([:])
            guard Self.supportedOps.contains(op) else {
                return Reply(status: 400, body: ["error": .string("this iPhone cannot \(op)"), "unsupported": true])
            }
            do {
                return Reply(status: 200, body: ["result": try await perform(op, kw)])
            } catch let error as Unsupported {
                return Reply(status: 400, body: ["error": .string(error.message), "unsupported": true])
            } catch {
                return Reply(status: 500, body: ["error": .string("RuntimeError: \(error)")])
            }
        default:
            return Reply(status: 404, body: ["error": "RuntimeError: no such endpoint"])
        }
    }

    struct Unsupported: Error {
        let message: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func perform(_ op: String, _ kw: JSONValue) async throws -> JSONValue {
        func number(_ key: String, _ fallback: Double? = nil) throws -> Double {
            switch kw[key] {
            case .int(let i): return Double(i)
            case .double(let d): return d
            default:
                if let fallback { return fallback }
                throw Failure(description: "\(op) needs \(key)")
            }
        }
        func int(_ key: String, _ fallback: Double? = nil) throws -> Int { Int(try number(key, fallback).rounded()) }

        switch op {
        case "screen.capture":
            let shot = try await device.screenshot()
            lastSize = (shot.width, shot.height)
            return ["png_b64": .string(try Self.png(from: shot).base64EncodedString()), "bounds": bounds(shot.width, shot.height)]
        case "screen.bounds", "screen.require", "session.require":
            let size = try await knownSize()
            return bounds(size.w, size.h)
        case "screen.text", "screen.text_pixels":
            let shot = try await device.screenshot()
            lastSize = (shot.width, shot.height)
            return .array(try Self.recognizeText(in: shot, minConfidence: try number("min_confidence", 0.3)))
        case "input.tap":
            try await device.tap(x: try int("x"), y: try int("y"))
            return .null
        case "input.press":
            try await device.longPress(x: try int("x"), y: try int("y"), seconds: try number("duration", 0.8))
            return .null
        case "input.drag":
            try await device.swipe(fromX: try int("x1"), fromY: try int("y1"), toX: try int("x2"), toY: try int("y2"),
                                   seconds: try number("duration", 0.35))
            return .null
        case "input.scroll":
            // Content space: +dy reveals what is above, so the finger travels dy pixels down, centred on (x, y).
            let x = try number("x"), y = try number("y"), dy = try number("dy", 0), dx = try number("dx", 0)
            let steps = try number("steps", 6)
            try await device.swipe(fromX: Int(x - dx / 2), fromY: Int(y - dy / 2), toX: Int(x + dx / 2), toY: Int(y + dy / 2),
                                   seconds: 0.25 + 0.05 * steps)
            return .null
        case "input.keys":
            let combo = kw["combo"]?.stringValue?.lowercased() ?? ""
            guard ["enter", "return"].contains(combo) else { throw Unsupported(message: "this iPhone has no key \(combo)") }
            try await device.pressEnter()
            return .null
        case "input.text":
            guard let text = kw["s"]?.stringValue else { throw Failure(description: "input.text needs s") }
            try await device.typeText(text)
            return .null
        case "nav.home":
            try await device.pressHome()
            return .null
        case "nav.back":
            do { try await device.pressBack() } catch let e as DeviceUnsupported { throw Unsupported(message: e.description) }
            return .null
        case "apps.launch":
            guard let name = kw["name"]?.stringValue else { throw Failure(description: "apps.launch needs name") }
            guard try await device.openApp(named: name) else { throw Failure(description: "no installed app matches '\(name)'") }
            return .string(name)
        case "session.state":
            return "ready"
        default:
            throw Unsupported(message: "this iPhone cannot \(op)")
        }
    }

    private func knownSize() async throws -> (w: Int, h: Int) {
        if let lastSize { return lastSize }
        let shot = try await device.screenshot()
        lastSize = (shot.width, shot.height)
        return (shot.width, shot.height)
    }

    private func bounds(_ w: Int, _ h: Int) -> JSONValue {
        ["x": 0, "y": 0, "w": .int(w), "h": .int(h), "id": "iphone"]
    }

    static func png(from shot: Screenshot) throws -> Data {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(shot.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "unreadable screenshot") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "could not encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "could not encode PNG") }
        return data as Data
        #else
        throw Unsupported(message: "no image codec on this platform")
        #endif
    }

    /// On-device OCR, in the screenshot's pixel space with a top-left origin, as Phone Harness expects.
    static func recognizeText(in shot: Screenshot, minConfidence: Double) throws -> [JSONValue] {
        #if canImport(Vision) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(shot.jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(description: "unreadable screenshot") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let (w, h) = (Double(image.width), Double(image.height))
        return (request.results ?? []).compactMap { observation -> JSONValue? in
            guard let best = observation.topCandidates(1).first, Double(best.confidence) >= minConfidence else { return nil }
            let box = observation.boundingBox   // normalised, bottom-left origin
            return [
                "text": .string(best.string), "confidence": .double(Double(best.confidence)), "source": "pixels",
                "x": .int(Int(box.minX * w)), "y": .int(Int((1 - box.maxY) * h)),
                "w": .int(Int(box.width * w)), "h": .int(Int(box.height * h)),
            ]
        }
        #else
        throw Unsupported(message: "no text recognition on this platform")
        #endif
    }
}
