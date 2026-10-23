import AppKit
import Foundation

/// `claude auth login` in the background. BROWSER points at a no-op, so Claude
/// Code opens nothing itself; the sign-in link is read from its output and opened
/// wherever the user chose. The process waits for the browser's localhost
/// callback and exits once the login is saved.
final class LoginProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var output = ""
    private var urlSent = false
    private var cancelled = false

    /// Both called on the main queue.
    var onURL: ((URL) -> Void)?
    var onExit: ((_ status: Int32, _ cancelled: Bool, _ output: String) -> Void)?

    func start(claude: String, email: String?) throws {
        var env = ProcessInfo.processInfo.environment
        for key in [ClaudeFiles.envKey, "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env[key] = nil }
        env["BROWSER"] = "/usr/bin/true"

        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdin   // kept open: it offers a paste-code prompt and must not see EOF

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            let text = self.output, wasCancelled = self.cancelled
            self.lock.unlock()
            DispatchQueue.main.async { self.onExit?(p.terminationStatus, wasCancelled, text) }
        }
        try process.run()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ chunk: String) {
        lock.lock()
        output += chunk
        if output.count > 20_000 { output = String(output.suffix(10_000)) }
        let found = urlSent ? nil : Self.signInURL(in: output)
        if found != nil { urlSent = true }
        lock.unlock()
        if let found { DispatchQueue.main.async { self.onURL?(found) } }
    }

    static func signInURL(in text: String) -> URL? {
        guard let r = text.range(of: #"https://\S*oauth/authorize\S*"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }
}

/// Opening the sign-in link in the normal browser or a private window.
enum LoginBrowser {
    struct App: Identifiable, Equatable {
        let url: URL
        let name: String
        let privateArgs: [String]
        var id: String { url.path }
    }

    /// Command-line switches that open a private window, by bundle id.
    private static func privateArgs(_ bundleID: String) -> [String]? {
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
             "com.brave.Browser", "com.brave.Browser.beta", "com.vivaldi.Vivaldi",
             "org.chromium.Chromium", "com.thebrowser.Browser":
            return ["--incognito"]
        case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta":
            return ["--inprivate"]
        case "com.operasoftware.Opera":
            return ["--private"]
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen":
            return ["-private-window"]
        default:
            return nil   // Safari has no switch for it
        }
    }

    private static let probe = URL(string: "https://claude.ai")!

    static var defaultBrowserName: String {
        NSWorkspace.shared.urlForApplication(toOpen: probe).map(displayName) ?? "trình duyệt"
    }

    /// Browsers that can open a private window, the default one first.
    static func privateCapable() -> [App] {
        let ws = NSWorkspace.shared
        var urls = ws.urlsForApplications(toOpen: probe)
        if let def = ws.urlForApplication(toOpen: probe) {
            urls.removeAll { $0 == def }
            urls.insert(def, at: 0)
        }
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, let args = privateArgs(id), seen.insert(id).inserted else { return nil }
            return App(url: url, name: displayName(url), privateArgs: args)
        }
    }

    static func openNormal(_ link: URL) {
        NSWorkspace.shared.open(link)
    }

    static func openPrivate(_ link: URL, in app: App) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", app.url.path, "--args"] + app.privateArgs + [link.absoluteString]
        try? p.run()
    }

    static func copy(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    private static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

enum LoginOpenMode: Equatable {
    case normal
    case privateWindow(LoginBrowser.App)
    case copyOnly
}
