import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// A phone reached over Phone Harness's remote-phone protocol (`GET /ops`, `POST /op`): the MobileGym
/// bridge today, the iPhone app later. Coordinates are pixels of the phone's screenshot.
public struct RemoteDevice: DeviceController {
    public let baseURL: URL
    public let token: String
    public var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public struct RemoteError: Error, CustomStringConvertible {
        public let description: String
    }

    func op(_ name: String, _ kw: JSONValue = [:], timeout: TimeInterval = 60) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent("op"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["op": .string(name), "kw": kw]))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard status == 200 else {
            let message = json["error"]?.stringValue ?? "HTTP \(status)"
            if json["unsupported"] == true { throw DeviceUnsupported(message) }
            throw RemoteError(description: message)
        }
        return json["result"] ?? .null
    }

    public func screenshot() async throws -> Screenshot {
        let result = try await op("screen.capture")
        guard let b64 = result["png_b64"]?.stringValue, let png = Data(base64Encoded: b64) else {
            throw RemoteError(description: "the phone sent no screenshot")
        }
        return try Self.jpeg(fromPNG: png)
    }

    public func tap(x: Int, y: Int) async throws { _ = try await op("input.tap", ["x": .int(x), "y": .int(y)]) }

    public func longPress(x: Int, y: Int, seconds: Double) async throws {
        _ = try await op("input.press", ["x": .int(x), "y": .int(y), "duration": .double(seconds)])
    }

    public func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        _ = try await op("input.drag", ["x1": .int(fromX), "y1": .int(fromY), "x2": .int(toX), "y2": .int(toY),
                                        "duration": .double(seconds), "steps": 14])
    }

    public func typeText(_ text: String) async throws {
        _ = try await op("input.text", ["s": .string(text), "delay": .double(0.03), "keystrokes": false])
    }

    public func pressEnter() async throws { _ = try await op("input.keys", ["combo": "enter"]) }
    public func clearText() async throws { _ = try await op("input.text", ["s": "", "clear": true]) }
    public func pressHome() async throws { _ = try await op("nav.home") }
    public func pressBack() async throws { _ = try await op("nav.back") }

    public func openApp(named name: String) async throws -> Bool {
        do {
            _ = try await op("apps.launch", ["name": .string(name)], timeout: 90)
            return true
        } catch let error as RemoteError where error.description.contains("no installed app") {
            return false
        }
    }

    /// The agent and its fingerprinting work on JPEG; the protocol carries PNG.
    static func jpeg(fromPNG png: Data) throws -> Screenshot {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RemoteError(description: "unreadable screenshot") }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw RemoteError(description: "could not encode JPEG")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RemoteError(description: "could not encode JPEG") }
        return Screenshot(jpeg: out as Data, width: image.width, height: image.height)
        #else
        throw RemoteError(description: "no image codec on this platform")
        #endif
    }
}
