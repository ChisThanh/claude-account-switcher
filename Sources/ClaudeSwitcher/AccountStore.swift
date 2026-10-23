import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var state = AppState()
    @Published private(set) var message: String?
    @Published private(set) var busy = false

    /// Idle accounts whose login expires within this window get refreshed.
    static let keepAliveWindow: TimeInterval = 5 * 86400

    private let dir: URL
    private var stateURL: URL { dir.appendingPathComponent("state.json") }
    private var lastSaved: AppState?
    private var savedRaw: [String: String] = [:]   // login blob last stored per account; skips keychain calls
    private var notified: [String: Date] = [:]
    private var timer: Timer?

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var active: Account? { state.activeId.flatMap(account) }
    func account(_ id: String) -> Account? { state.accounts.first { $0.id == id } }

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func tick() {
        guard !busy else { return }
        sync()
        checkHealth()
        if state.autoKeepAlive { keepAliveIfDue() }
    }

    // MARK: Sync with Claude Code

    /// Reconciles the live login (keychain + ~/.claude.json) with the store: keeps
    /// the tokens Claude Code rotated, adopts logins made with `claude auth login`,
    /// and undoes a still-running session writing an older account's tokens back.
    func sync() {
        defer { save() }
        guard let raw = Keychain.readClaudeLogin(), let blob = LoginBlob(raw: raw) else { return }
        let oa = ClaudeFiles.oauthAccount()

        if let oa, let oaId = oa["accountUuid"] as? String, oa["organizationUuid"] as? String == blob.organizationUuid {
            let isNew = account(oaId) == nil
            store(blob, for: oaId, oauthAccount: oa)
            guard let acc = account(oaId) else { return }
            if state.activeId != oaId {
                state.activeId = oaId
                try? applyEnvMode(for: acc)
                announce(isNew ? "Đã thêm tài khoản \(acc.email)" : "Claude đang dùng \(acc.email)")
            } else if state.activeUsesSetupToken, acc.loginUsable, !acc.preferSetupToken {
                try? applyEnvMode(for: acc)   // logged in again: back to the full login
            }
            return
        }

        // Keychain and ~/.claude.json disagree: a session still on an older account
        // refreshed its token. Keep those tokens, then put the active account back.
        guard let owner = ownerOf(blob) else { return }
        store(blob, for: owner.id, oauthAccount: nil)
        guard let active else { return }
        if active.id != owner.id {
            if let r = Keychain.storedLogin(active.id), Keychain.writeClaudeLogin(r) { savedRaw[active.id] = r }
            notifyOnce("stale-\(owner.id)", "Một phiên Claude cũ vẫn chạy bằng \(owner.email). Đã đặt lại \(active.email) — hãy khởi động lại phiên đó.")
        }
        try? ClaudeFiles.setOauthAccount(active.oauthAccount)
    }

    private func ownerOf(_ blob: LoginBlob) -> Account? {
        let matches = state.accounts.filter { $0.organizationUuid == blob.organizationUuid }
        return matches.count == 1 ? matches[0] : nil
    }

    private func store(_ blob: LoginBlob, for id: String, oauthAccount oa: [String: Any]?) {
        if savedRaw[id] != blob.raw {
            if Keychain.storedLogin(id) != blob.raw, !Keychain.saveLogin(id, blob.raw) {
                announce("Không lưu được login vào Keychain")
                return
            }
            savedRaw[id] = blob.raw
        }
        var acc = account(id) ?? Account(id: id, email: "", organizationUuid: blob.organizationUuid ?? "",
                                         oauthAccount: Data(), hasLogin: true, preferSetupToken: false)
        acc.hasLogin = true
        acc.refreshTokenExpiresAt = blob.refreshTokenExpiresAt
        if let s = blob.subscriptionType { acc.subscriptionType = s }
        if let oa, let data = try? JSONSerialization.data(withJSONObject: oa, options: [.sortedKeys]) {
            acc.oauthAccount = data
            acc.email = oa["emailAddress"] as? String ?? acc.email
            acc.displayName = oa["displayName"] as? String
            acc.organizationUuid = oa["organizationUuid"] as? String ?? acc.organizationUuid
            acc.organizationName = oa["organizationName"] as? String
        }
        upsert(acc)
    }

    // MARK: Switching

    @discardableResult
    func switchTo(_ id: String, quiet: Bool = false, forceLogin: Bool = false) -> Bool {
        sync()
        guard let acc = account(id) else { return false }
        if !acc.loginUsable && !acc.hasSetupToken {
            announce("\(acc.email): login đã hết hạn và chưa có token dự phòng. Hãy đăng nhập lại.")
            return false
        }
        do {
            if let raw = Keychain.storedLogin(id) {
                guard Keychain.writeClaudeLogin(raw) else {
                    announce("Không ghi được login vào Keychain")
                    return false
                }
                savedRaw[id] = raw
            }
            try ClaudeFiles.setOauthAccount(acc.oauthAccount)
            try applyEnvMode(for: acc, forceLogin: forceLogin)
        } catch {
            announce(error.localizedDescription)
            return false
        }
        state.activeId = id
        update(id) { $0.lastUsedAt = Date() }
        save()
        if !quiet {
            let mode = state.activeUsesSetupToken ? " (token dự phòng)" : ""
            announce("Đã chuyển sang \(acc.email)\(mode). Các phiên claude đang mở cần khởi động lại.")
        }
        return true
    }

    /// settings.json carries the setup-token only while the login can't be used
    /// (or the account is set to always use it).
    private func applyEnvMode(for acc: Account, forceLogin: Bool = false) throws {
        let wantSetup = !forceLogin && (acc.preferSetupToken || !acc.loginUsable)
        if wantSetup, let token = Keychain.setupToken(acc.id) {
            try ClaudeFiles.setEnvToken(token)
            state.activeUsesSetupToken = true
            return
        }
        state.activeUsesSetupToken = false
        guard let current = ClaudeFiles.envToken() else { return }
        if state.accounts.contains(where: { $0.hasSetupToken && Keychain.setupToken($0.id) == current }) {
            try ClaudeFiles.setEnvToken(nil)
        } else {
            announce("~/.claude/settings.json có \(ClaudeFiles.envKey) không do app đặt — nó đang đè lên login.")
        }
    }

    // MARK: Keep-alive

    private func checkHealth() {
        for acc in state.accounts {
            if let exp = acc.setupTokenExpiresAt, exp.daysFromNow < 30 {
                notifyOnce("setup-\(acc.id)", "Token dự phòng của \(acc.email) còn khoảng \(max(exp.daysFromNow, 0)) ngày. Hãy chạy lại claude setup-token.")
            }
            guard let exp = acc.refreshTokenExpiresAt else { continue }
            if exp <= Date() {
                if acc.id == state.activeId, !state.activeUsesSetupToken, acc.hasSetupToken {
                    try? applyEnvMode(for: acc)
                    save()
                    notifyOnce("fallback-\(acc.id)", "Login của \(acc.email) đã hết hạn — đã chuyển sang token dự phòng.")
                } else if !acc.hasSetupToken {
                    notifyOnce("expired-\(acc.id)", "Login của \(acc.email) đã hết hạn. Hãy đăng nhập lại hoặc thêm token dự phòng.")
                }
            } else if !state.autoKeepAlive, acc.id != state.activeId, exp.timeIntervalSinceNow < Self.keepAliveWindow {
                notifyOnce("soon-\(acc.id)", "Login của \(acc.email) còn \(exp.daysFromNow) ngày. Bấm Làm mới hoặc dùng tài khoản này một lần.")
            }
        }
    }

    private func keepAliveIfDue() {
        let due = state.accounts.first { acc in
            guard acc.id != state.activeId, acc.hasLogin, let exp = acc.refreshTokenExpiresAt,
                  exp > Date(), exp.timeIntervalSinceNow < Self.keepAliveWindow else { return false }
            return acc.lastKeepAliveAt.map { -$0.timeIntervalSinceNow > 20 * 3600 } ?? true
        }
        if let due { Task { await refreshLogin(due.id) } }
    }

    /// Lets Claude Code itself refresh an idle account: briefly makes it the live
    /// login, runs one tiny `claude -p`, keeps the rotated tokens, switches back.
    func refreshLogin(_ id: String) async {
        guard !busy, let acc = account(id) else { return }
        guard let claude = Self.claudePath else {
            announce("Không tìm thấy lệnh claude")
            return
        }
        busy = true
        defer { busy = false }
        let previous = state.activeId
        let before = acc.refreshTokenExpiresAt
        guard switchTo(id, quiet: true, forceLogin: true) else { return }

        var env = ProcessInfo.processInfo.environment
        for key in [ClaudeFiles.envKey, "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env[key] = nil }
        let runEnv = env
        let home = FileManager.default.homeDirectoryForCurrentUser
        let result = await Task.detached {
            Shell.run(claude, ["-p", "Reply with OK", "--model", "haiku", "--max-turns", "1", "--strict-mcp-config"],
                      env: runEnv, cwd: home, timeout: 180)
        }.value

        sync()
        update(id) { $0.lastKeepAliveAt = Date() }
        if let previous, previous != id { switchTo(previous, quiet: true) }
        save()

        if result.status == 0 {
            let after = account(id)?.refreshTokenExpiresAt
            announce("Đã làm mới \(acc.email): hạn login \(Fmt.date(before)) → \(Fmt.date(after))")
        } else {
            let why = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            announce("Làm mới \(acc.email) lỗi: \(why)")
        }
    }

    // MARK: Account actions

    func addAccount() {
        sync()
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude") }
        openInTerminal("login", "'\(claude)' auth login")
        announce("Đăng nhập tài khoản mới trong Terminal. App tự nhận khi xong (tối đa 30 giây).")
    }

    func createSetupToken() {
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude") }
        openInTerminal("setup-token", "'\(claude)' setup-token")
    }

    @discardableResult
    func saveSetupToken(_ token: String, for id: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("sk-ant-") else {
            announce("Token không đúng dạng (sk-ant-…)")
            return false
        }
        guard Keychain.saveSetupToken(id, t) else {
            announce("Không lưu được token vào Keychain")
            return false
        }
        update(id) { $0.setupTokenAddedAt = Date() }
        if id == state.activeId, let acc = account(id) { try? applyEnvMode(for: acc) }
        save()
        announce("Đã lưu token dự phòng cho \(account(id)?.email ?? "")")
        return true
    }

    func removeSetupToken(_ id: String) {
        update(id) { $0.setupTokenAddedAt = nil; $0.preferSetupToken = false }
        if id == state.activeId, let acc = account(id) { try? applyEnvMode(for: acc) }
        Keychain.delete(service: Keychain.storeService, account: "\(id).setup")
        save()
    }

    func setPreferSetupToken(_ on: Bool, for id: String) {
        update(id) { $0.preferSetupToken = on }
        if id == state.activeId, let acc = account(id) { try? applyEnvMode(for: acc) }
        save()
    }

    func setLabel(_ label: String, for id: String) {
        update(id) { $0.label = label.isEmpty ? nil : label }
        save()
    }

    func setAutoKeepAlive(_ on: Bool) {
        state.autoKeepAlive = on
        save()
    }

    func remove(_ id: String) {
        guard id != state.activeId else { return }
        Keychain.forget(id)
        savedRaw[id] = nil
        state.accounts.removeAll { $0.id == id }
        save()
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            announce("Không đổi được mở cùng macOS: \(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    func status(_ acc: Account) -> String {
        var parts: [String] = []
        if let s = acc.subscriptionType { parts.append(s.capitalized) }
        if let exp = acc.refreshTokenExpiresAt {
            parts.append(exp > Date() ? "login \(exp.daysFromNow) ngày" : "login hết hạn")
        }
        if let exp = acc.setupTokenExpiresAt {
            parts.append("dự phòng ~\(max(exp.daysFromNow, 0)) ngày")
        } else {
            parts.append("chưa có dự phòng")
        }
        if acc.id == state.activeId && state.activeUsesSetupToken { parts.append("đang dùng dự phòng") }
        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&state.accounts[i])
    }

    private func upsert(_ acc: Account) {
        if let i = state.accounts.firstIndex(where: { $0.id == acc.id }) {
            if state.accounts[i] != acc { state.accounts[i] = acc }
        } else {
            state.accounts.append(acc)
        }
    }

    private func openInTerminal(_ name: String, _ command: String) {
        let url = dir.appendingPathComponent("\(name).command")
        let script = "#!/bin/zsh\nclear\n\(command)\necho\necho 'Xong. Có thể đóng cửa sổ này.'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        NSWorkspace.shared.open(url)
    }

    private func announce(_ text: String) { message = text }

    private func notifyOnce(_ key: String, _ text: String) {
        if let last = notified[key], -last.timeIntervalSinceNow < 86400 { return }
        notified[key] = Date()
        announce(text)
        let content = UNMutableNotificationContent()
        content.title = "Claude Switcher"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(AppState.self, from: data) {
            state = s
            lastSaved = s
        }
    }

    private func save() {
        guard state != lastSaved else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
        lastSaved = state
    }
}

enum Fmt {
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: d)
    }
}
