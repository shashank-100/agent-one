// Serves Phone Harness's remote-phone protocol from this Mac, with a still screenshot standing in for
// the iPhone, so a Phone Harness client (and Hermes) can be tested against the protocol before the app
// runs on a phone. Taps and typing are printed, not performed.
// Usage: swift run phoneuse-host <screenshot.png|jpg> [port] ; token from PHONEUSE_TOKEN or generated.
import CoreGraphics
import Foundation
import ImageIO
import PhoneUseCore

struct PrintingDevice: DeviceController {
    let shot: Screenshot
    func screenshot() async throws -> Screenshot { shot }
    func tap(x: Int, y: Int) async throws { print("tap \(x),\(y)") }
    func longPress(x: Int, y: Int, seconds: Double) async throws { print("hold \(x),\(y) \(seconds)s") }
    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        print("swipe \(fromX),\(fromY) -> \(toX),\(toY) \(seconds)s")
    }
    func typeText(_ text: String) async throws { print("type \"\(text)\"") }
    func pressEnter() async throws { print("enter") }
    func pressHome() async throws { print("home") }
    func openApp(named name: String) async throws -> Bool {
        print("open \(name)")
        return true
    }
}

func load(_ path: String) -> Screenshot? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return Screenshot(jpeg: data as Data, width: image.width, height: image.height)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, let shot = load(arguments[1]) else {
    print("usage: phoneuse-host <screenshot> [port]")
    exit(2)
}
let token = ProcessInfo.processInfo.environment["PHONEUSE_TOKEN"] ?? UUID().uuidString
let server = try HarnessServer(host: HarnessHost(device: PrintingDevice(shot: shot)), token: token,
                               port: arguments.count > 2 ? UInt16(arguments[2]) ?? 0 : 0)
let port = try await server.start()
print("listening on http://127.0.0.1:\(port)  token \(token)")
setvbuf(stdout, nil, _IOLBF, 0)
while true { try await Task.sleep(for: .seconds(3600)) }
