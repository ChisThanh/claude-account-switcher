import Foundation

/// Keychain access through /usr/bin/security, the same tool Claude Code uses, so
/// the existing "Claude Code-credentials" item never asks for a password prompt
/// and our own items survive rebuilding the (ad-hoc signed) app.
enum Keychain {
    static let claudeService = "Claude Code-credentials"
    static let storeService = "ClaudeSwitcher"
    static var user: String { ProcessInfo.processInfo.environment["USER"] ?? NSUserName() }

    static func read(service: String, account: String) -> String? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service, "-w"])
        guard r.status == 0 else { return nil }
        let s = r.stdout.trimmingCharacters(in: .newlines)
        return s.isEmpty ? nil : s
    }

    /// Writes via `security -i` on stdin with a hex payload, so the secret never
    /// shows up in a process list. Reads it back to confirm.
    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n"
        _ = Shell.run("/usr/bin/security", ["-i"], stdin: cmd)
        return read(service: service, account: account) == value
    }

    static func delete(service: String, account: String) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-a", account, "-s", service])
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Claude Code's live login

    static func readClaudeLogin() -> String? { read(service: claudeService, account: user) }
    static func writeClaudeLogin(_ raw: String) -> Bool { write(service: claudeService, account: user, value: raw) }

    // MARK: Our per-account store

    static func storedLogin(_ id: String) -> String? { read(service: storeService, account: "\(id).login") }
    static func saveLogin(_ id: String, _ raw: String) -> Bool { write(service: storeService, account: "\(id).login", value: raw) }
    static func setupToken(_ id: String) -> String? { read(service: storeService, account: "\(id).setup") }
    static func saveSetupToken(_ id: String, _ token: String) -> Bool { write(service: storeService, account: "\(id).setup", value: token) }

    static func forget(_ id: String) {
        delete(service: storeService, account: "\(id).login")
        delete(service: storeService, account: "\(id).setup")
    }
}
