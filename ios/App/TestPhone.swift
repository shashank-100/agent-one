import PhoneUseCore
import SwiftUI
import UIKit
import WebKit

/// The MobileGym test phone from the local bridge, running inside the app in a web view, as a
/// `DeviceController`. Until the on-device control layer exists, this is what the agent drives here:
/// the same Swift agent, real model calls through Claude Code on the Mac, real taps on the simulated phone.
/// The phone is 360×800 CSS pixels; screenshots are 1080×2400, so 3 screenshot pixels = 1 CSS pixel.
final class TestPhone: DeviceController, @unchecked Sendable {
    static var base: URL {
        URL(string: UserDefaults.standard.string(forKey: "phoneuse.bridgeURL") ?? "http://127.0.0.1:8766") ?? URL(string: "http://127.0.0.1:8766")!
    }
    static let scale = 3.0

    @MainActor let webView: WKWebView
    @MainActor fileprivate var apps: [String: String] = [:]

    @MainActor init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 800), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        webView.load(URLRequest(url: Self.base))
    }

    struct PhoneError: Error, CustomStringConvertible { let description: String }

    @MainActor private func js(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    @MainActor fileprivate func run(_ body: String) async throws { _ = try await js(body) }
    @MainActor fileprivate func flag(_ body: String) async throws -> Bool { try await js(body) as? Bool ?? false }
    @MainActor fileprivate func text(_ body: String) async throws -> String? { try await js(body) as? String }

    /// Runs `work` on the main actor, where the web view lives.
    private func main<T: Sendable>(_ work: @MainActor @Sendable (TestPhone) async throws -> T) async throws -> T {
        try await work(self)
    }

    @MainActor func waitUntilReady() async throws {
        for _ in 0..<60 {
            if (try? await js("return !!(window.__SIM_INPUT__ && window.__OS__)")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        if apps.isEmpty {
            let (data, _) = try await URLSession.shared.data(from: Self.base.appendingPathComponent("demo/apps.json"))
            apps = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        _ = try await js("const s = __SIM__.getState(); return true")
    }

    func screenshot() async throws -> Screenshot {
        try await main { phone -> Screenshot in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 360, height: 800)
            let image = try await phone.webView.takeSnapshot(configuration: config)
            let size = CGSize(width: 1080, height: 2400)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.75) { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            return Screenshot(jpeg: jpeg, width: 1080, height: 2400)
        }
    }

    private func css(_ v: Int) -> Double { Double(v) / Self.scale }

    // A real finger focuses the text field it lands on; the simulator's tap does not, so do it here.
    func tap(x: Int, y: Int) async throws {
        try await main { phone in
            try await phone.run("""
            const x = \(css(x)), y = \(css(y));
            __SIM_INPUT__.tap(x, y);
            const el = document.elementFromPoint(x, y);
            const f = el && (el.closest("input, textarea, [contenteditable='true']") || el.closest("label")?.querySelector("input, textarea"));
            if (f && document.activeElement !== f) f.focus({ preventScroll: true });
            return true
            """)
        }
    }

    func longPress(x: Int, y: Int, seconds: Double) async throws {
        try await main { phone in
            try await phone.run("await __SIM_INPUT__.longPress(\(css(x)), \(css(y)), \(Int(seconds * 1000))); return true")
        }
    }

    func swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, seconds: Double) async throws {
        try await main { phone in
            try await phone.run("""
            await __SIM_INPUT__.swipe({ x: \(fromX), y: \(fromY) }, { x: \(toX), y: \(toY) },
              { coords: "physical", dpr: \(Self.scale), ms: \(Int(seconds * 1000)), inertia: false }); return true
            """)
        }
    }

    func typeText(_ text: String) async throws { try await type(text, clear: false) }
    func clearText() async throws { try await type("", clear: true) }

    private func type(_ text: String, clear: Bool) async throws {
        let literal = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        let ok = try await main { phone in
            try await phone.text("try { await __SIM_INPUT__.type(\(literal), { clear: \(clear) }); return true } catch (e) { return String(e.message || e) }")
        }
        if let message = ok { throw PhoneError(description: "nothing to type into: tap a text field first (\(message))") }
    }

    func pressEnter() async throws {
        try await main { phone in
            try await phone.run("""
            const el = document.activeElement || document.body;
            for (const type of ["keydown", "keypress", "keyup"])
              el.dispatchEvent(new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
            return true
            """)
        }
    }

    func pressHome() async throws { try await main { try await $0.run("__OS__.goHome(); return true") } }
    func pressBack() async throws { try await main { try await $0.run("__OS__.handleBack(); return true") } }

    func openApp(named name: String) async throws -> Bool {
        try await main { phone -> Bool in
            var want = name.lowercased().trimmingCharacters(in: .whitespaces)
            if want.hasSuffix(" app") { want = String(want.dropLast(4)) }
            guard let id = phone.apps[want] ?? phone.apps.first(where: { $0.key.contains(want) || want.contains($0.key) })?.value else { return false }
            let literal = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
            try await phone.run("__OS__.launchApp(\(literal)); return true")
            try await Task.sleep(for: .milliseconds(600))
            return true
        }
    }

    func focusedFieldIsSecure() async -> Bool {
        (try? await main { try await $0.flag("return document.activeElement?.type === 'password'") }) ?? false
    }
}

/// A thing on screen the agent can name by number: its text and its box in screenshot pixels.
struct ScreenElement: Sendable, Equatable {
    let text: String
    let x: Int, y: Int, width: Int, height: Int
    let tappable: Bool
    var center: (x: Int, y: Int) { (x + width / 2, y + height / 2) }
}

/// Phones that can list what is on screen (the test phone's page; on a device, the accessibility tree).
protocol ElementReader: Sendable {
    func elements() async -> [ScreenElement]
}

extension TestPhone: ElementReader {
    /// Same rules as the browser agent: visible, on top (not under the keyboard or a sheet), with text or tappable.
    func elements() async -> [ScreenElement] {
        let json = try? await main { try await $0.text(Self.elementScript) }
        guard let data = json?.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[String: JSONScalar]].self, from: data) else { return [] }
        return rows.compactMap { r in
            guard case .string(let t)? = r["t"], case .number(let x)? = r["x"], case .number(let y)? = r["y"],
                  case .number(let w)? = r["w"], case .number(let h)? = r["h"], case .bool(let i)? = r["i"] else { return nil }
            let k = Self.scale
            return ScreenElement(text: t, x: Int(x * k), y: Int(y * k), width: Int(w * k), height: Int(h * k), tappable: i)
        }
    }

    /// The page's state, for grading a run from what the phone holds rather than what the model says.
    func stateJSON() async -> String {
        (try? await main { try await $0.text("return JSON.stringify(__SIM__.getState())") }) ?? "{}"
    }

    static let elementScript = #"""
    const out = [], seen = new Set();
    const onTop = (el, r) => {
      const l = Math.max(r.left, 0), rt = Math.min(r.right, 360), t = Math.max(r.top, 0), b = Math.min(r.bottom, 800), cx = (l + rt) / 2;
      for (const y of [(t + b) / 2, t + 3, b - 3]) { const hit = document.elementFromPoint(cx, y); if (hit && (hit === el || el.contains(hit) || hit.contains(el))) return true; }
      return false;
    };
    const sel = "[data-trigger],[data-action],button,a,input,textarea,[role=button],[role=switch],[role=tab],[contenteditable=true]";
    for (const el of document.querySelectorAll(sel + ",span,p,div,h1,h2,h3,label")) {
      const r = el.getBoundingClientRect();
      if (r.width < 6 || r.height < 6 || r.bottom <= 0 || r.right <= 0 || r.top >= 800 || r.left >= 360) continue;
      const st = getComputedStyle(el);
      if (st.visibility === "hidden" || st.display === "none" || Number(st.opacity) === 0 || !onTop(el, r)) continue;
      const i = el.matches(sel);
      let t = el.matches("input,textarea") ? (el.value || el.placeholder || el.getAttribute("aria-label") || "")
        : i ? (el.getAttribute("aria-label") || el.innerText || "") : Array.from(el.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join(" ");
      t = t.replace(/\s+/g, " ").trim().slice(0, 60);
      if (el.matches("[role=switch]")) t += ` (switch ${el.getAttribute("aria-checked") === "true" ? "on" : "off"})`;
      if (!t && !i) continue;
      const key = t + [r.left, r.top, r.width, r.height].map(Math.round).join(",");
      if (seen.has(key)) continue; seen.add(key);
      out.push({ t, x: r.left, y: r.top, w: r.width, h: r.height, i });
    }
    out.sort((a, b) => a.y - b.y || a.x - b.x);
    return JSON.stringify(out.slice(0, 90));
    """#
}

/// A JSON number, string or bool, for decoding the element rows.
enum JSONScalar: Decodable, Sendable {
    case number(Double), string(String), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }
}

/// Shows the test phone at its real proportions, scaled to fit.
struct TestPhoneView: UIViewRepresentable {
    let phone: TestPhone

    func makeUIView(context: Context) -> PhoneHost { PhoneHost(webView: phone.webView) }
    func updateUIView(_ host: PhoneHost, context: Context) {}

    final class PhoneHost: UIView {
        let webView: WKWebView
        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            clipsToBounds = true
            addSubview(webView)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let s = min(bounds.width / 360, bounds.height / 800)
            guard s.isFinite, s > 0 else { return }
            webView.transform = CGAffineTransform(scaleX: s, y: s)
            webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
