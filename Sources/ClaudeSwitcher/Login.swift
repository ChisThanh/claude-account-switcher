import AppKit
import Foundation

/// `claude auth login` in the background, opened wherever the user chose.
///
/// Claude Code has two sign-in links. The one it hands to $BROWSER redirects to
/// a localhost listener, so the login completes by itself. The one it prints
/// ("If the browser didn't open, visit: …") redirects to a page that only shows
/// a code to paste back. BROWSER therefore points at a tiny script that records
/// the link instead of opening it; the printed link is only a fallback, and a
/// code from it can be sent with `submitCode`.
final class LoginProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let lock = NSLock()
    private let workDir: URL
    private var output = ""
    private var urlSent = false
    private var cancelled = false

    /// Both called on the main queue. `needsCode` is true for the fallback link.
    var onURL: ((_ url: URL, _ needsCode: Bool) -> Void)?
    var onExit: ((_ status: Int32, _ cancelled: Bool, _ output: String) -> Void)?

    init() {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSwitcher-login-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: workDir) }

    func start(claude: String, email: String?) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let urlFile = workDir.appendingPathComponent("url")
        let script = workDir.appendingPathComponent("browser.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" > \"$CLAUDE_SWITCHER_URL_FILE\"\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)

        var env = ProcessInfo.processInfo.environment
        for key in [ClaudeFiles.envKey, "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env[key] = nil }
        env["BROWSER"] = script.path
        env["CLAUDE_SWITCHER_URL_FILE"] = urlFile.path

        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["auth", "login"] + (email.map { ["--email", $0] } ?? [])
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdin   // kept open for the paste-code prompt; it must not see EOF

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
        watch(urlFile, since: Date())
    }

    /// The localhost link usually lands within half a second. If it hasn't after
    /// 5 s, fall back to the printed paste-code link.
    private func watch(_ file: URL, since start: Date) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.process.isRunning else { return }
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" {
                return self.send(url, needsCode: false)
            }
            if Date().timeIntervalSince(start) > 5 {
                self.lock.lock()
                let printed = Self.printedURL(in: self.output)
                self.lock.unlock()
                if let printed { return self.send(printed, needsCode: true) }
            }
            if Date().timeIntervalSince(start) < 60 { self.watch(file, since: start) }
        }
    }

    private func send(_ url: URL, needsCode: Bool) {
        lock.lock()
        let first = !urlSent
        urlSent = true
        lock.unlock()
        if first { DispatchQueue.main.async { self.onURL?(url, needsCode) } }
    }

    /// The code the fallback page shows, answered to "Paste code here if prompted >".
    func submitCode(_ code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, process.isRunning else { return }
        stdin.fileHandleForWriting.write(Data((clean + "\n").utf8))
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
        lock.unlock()
    }

    static func printedURL(in text: String) -> URL? {
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
        NSWorkspace.shared.urlForApplication(toOpen: probe).map(displayName) ?? L("trình duyệt", "browser")
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
