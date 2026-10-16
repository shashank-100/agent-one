import PhoneUseCore
import SwiftUI
import UIKit
import WebKit

/// A real website inside the app, driven by the agent like a phone: taps land on the element under the point,
/// typing goes into the focused field, scrolling moves the page. This is how the agent shops on amazon.in
/// without the Amazon app or any device control: the person logs in themselves (the agent hands the phone
/// over for logins, OTPs and card prompts) and allows the final Place order.
final class WebBrowserDevice: DeviceController, ElementReader, @unchecked Sendable {
    static let sites: [String: String] = [
        "amazon": "https://www.amazon.in", "google": "https://www.google.com", "flipkart": "https://www.flipkart.com",
        "youtube": "https://m.youtube.com", "wikipedia": "https://en.m.wikipedia.org",
    ]

    @MainActor let webView: WKWebView
    /// The page is drawn at this many screenshot pixels per CSS pixel.
    let scale = 3.0

    @MainActor init(start: URL = URL(string: "https://www.amazon.in")!) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps the person's login between runs
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = nil
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: start))
    }

    struct BrowserError: LocalizedError { let message: String; var errorDescription: String? { message } }

    @MainActor private func js(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }
    private func main<T: Sendable>(_ work: @MainActor @Sendable (WebBrowserDevice) async throws -> T) async throws -> T {
        try await work(self)
    }
    @MainActor fileprivate func run(_ body: String) async throws { _ = try await js(body) }
    @MainActor fileprivate func text(_ body: String) async throws -> String? { try await js(body) as? String }
    @MainActor fileprivate func flag(_ body: String) async throws -> Bool { try await js(body) as? Bool ?? false }

    private func css(_ v: Int) -> Double { Double(v) / scale }

    func screenshot() async throws -> Screenshot {
        try await main { device -> Screenshot in
            let bounds = device.webView.bounds
            let image = try await device.webView.takeSnapshot(configuration: nil)
            let size = CGSize(width: bounds.width * device.scale, height: bounds.height * device.scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return Screenshot(jpeg: jpeg, width: Int(size.width), height: Int(size.height))
        }
    }

    /// A click as a finger would make it: pointer and mouse events on the element under the point, then focus.
    func tap(x: Int, y: Int) async throws {
        try await main { try await $0.run("""
        const x = \(css(x)), y = \(css(y)), el = document.elementFromPoint(x, y);
        if (!el) return;
        const o = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
        for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup"]) el.dispatchEvent(new (t.startsWith("pointer") ? PointerEvent : MouseEvent)(t, o));
        const f = el.closest("input, textarea, select, [contenteditable='true']");
        if (f) f.focus(); else el.click();
        """) }
        try await Task.sleep(for: .milliseconds(300))
    }

    func longPress(x: Int, y: Int, seconds: Double) async throws { try await tap(x: x, y: y) }

    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        try await main { try await $0.run("window.scrollBy({ left: \(css(fromX - toX)), top: \(css(fromY - toY)), behavior: 'instant' })") }
    }

    /// Sets the value the way frameworks notice (React and others listen for the native setter plus input events).
    func typeText(_ text: String) async throws { try await type(text, clear: false) }
    func clearText() async throws { try await type("", clear: true) }

    private func type(_ text: String, clear: Bool) async throws {
        let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let ok = try await main { try await $0.flag("""
        const el = document.activeElement;
        if (!el || !("value" in el)) return false;
        const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const set = Object.getOwnPropertyDescriptor(proto, "value").set;
        set.call(el, (\(clear) ? "" : el.value) + \(literal));
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return true
        """) }
        if !ok { throw BrowserError(message: "No text field is focused; tap the field first.") }
    }

    func pressEnter() async throws {
        try await main { try await $0.run("""
        const el = document.activeElement || document.body;
        for (const t of ["keydown", "keypress", "keyup"]) el.dispatchEvent(new KeyboardEvent(t, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
        if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        """) }
        try await Task.sleep(for: .seconds(1))
    }

    func pressHome() async throws { try await open(URL(string: "https://www.amazon.in")!) }
    func pressBack() async throws { try await main { device in _ = await MainActor.run { device.webView.goBack() } } }

    /// "Apps" here are websites: open_app "Amazon" opens amazon.in; a URL opens that URL.
    func openApp(named name: String) async throws -> Bool {
        let key = name.lowercased().replacingOccurrences(of: " app", with: "").trimmingCharacters(in: .whitespaces)
        if let site = Self.sites[key] ?? Self.sites.first(where: { key.contains($0.key) })?.value, let url = URL(string: site) {
            try await open(url); return true
        }
        if let url = URL(string: name.hasPrefix("http") ? name : "https://\(name)"), name.contains(".") { try await open(url); return true }
        return false
    }

    func open(_ url: URL) async throws {
        try await main { device in _ = await MainActor.run { device.webView.load(URLRequest(url: url)) } }
        try await Task.sleep(for: .seconds(2))
    }

    func focusedFieldIsSecure() async -> Bool {
        (try? await main { try await $0.flag("return document.activeElement?.type === 'password'") }) ?? false
    }

    /// The same numbered element list as the test phone, in this page's coordinates.
    func elements() async -> [ScreenElement] {
        let width = await MainActor.run { webView.bounds.width }, height = await MainActor.run { webView.bounds.height }
        let script = TestPhone.elementScript.replacingOccurrences(of: "360", with: "\(Int(width))").replacingOccurrences(of: "800", with: "\(Int(height))")
        guard let json = try? await main({ try await $0.text(script) }), let data = json.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: JSONScalar]].self, from: data) else { return [] }
        return rows.compactMap { r in
            guard case .string(let t)? = r["t"], case .number(let x)? = r["x"], case .number(let y)? = r["y"],
                  case .number(let w)? = r["w"], case .number(let h)? = r["h"], case .bool(let i)? = r["i"] else { return nil }
            return ScreenElement(text: t, x: Int(x * scale), y: Int(y * scale), width: Int(w * scale), height: Int(h * scale), tappable: i)
        }
    }
}

/// The browser, shown full width so the person can log in and watch.
struct WebBrowserView: UIViewRepresentable {
    let device: WebBrowserDevice
    func makeUIView(context: Context) -> WKWebView { device.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
