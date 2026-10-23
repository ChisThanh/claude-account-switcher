import AppKit
import Foundation
import ServiceManagement
import UserNotifications

struct Banner: Equatable {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let text: String
}

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var state = AppState()
    @Published private(set) var banner: Banner?
    @Published private(set) var busy = false
    /// Set while `claude auth login` runs in Terminal; cleared when the new login shows up.
    @Published private(set) var addingSince: Date?
    /// claude processes that were running at the last switch and still hold the old account.
    @Published private(set) var staleSessions: Set<Int32> = []

    /// Idle accounts whose login expires within this window get refreshed.
    static let keepAliveWindow: TimeInterval = 5 * 86400

    private let dir: URL
    private var stateURL: URL { dir.appendingPathComponent("state.json") }
    private var lastSaved: AppState?
    private var savedRaw: [String: String] = [:]   // login blob last stored per account; skips keychain calls
    private var notified: [String: Date] = [:]
    private var lastHealthCheck = Date.distantPast
    private var lastLiveRaw: String?
    private var liveRawChangedAt = Date.distantPast
    private var addingBaseline: String?
    private var addingEmail: String?
    private var timer: Timer?

    /// True when no state file existed at startup.
    private(set) var isFirstLaunch = false

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        isFirstLaunch = lastSaved == nil
        recoverHalfSavedSetupTokens()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        tick()
        // 5 s keeps "add account" and the restart hint responsive; the heavier
        // health and keep-alive checks run once a minute inside tick().
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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

    func tick(force: Bool = false) {
        guard !busy else { return }
        sync()
        if !staleSessions.isEmpty { staleSessions.formIntersection(Self.runningClaudePids()) }
        if let since = addingSince, -since.timeIntervalSinceNow > 15 * 60 { addingSince = nil }
        guard force || -lastHealthCheck.timeIntervalSinceNow >= 60 else { return }
        lastHealthCheck = Date()
        checkHealth()
        if state.autoKeepAlive { keepAliveIfDue() }
    }

    /// Terminal (`~/.local/share/claude/versions/…`) and IDE-extension
    /// (`…/native-binary/claude`) Claude Code processes.
    static func runningClaudePids() -> Set<Int32> {
        let r = Shell.run("/bin/ps", ["-axo", "pid=,comm="])
        var pids = Set<Int32>()
        for line in r.stdout.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let comm = parts[1]
            if comm.contains("/.local/share/claude/versions/") || comm.hasSuffix("/native-binary/claude") {
                pids.insert(pid)
            }
        }
        return pids
    }

    // MARK: Sync with Claude Code

    /// Reconciles the live login (keychain + ~/.claude.json) with the store: keeps
    /// the tokens Claude Code rotated, adopts logins made with `claude auth login`,
    /// and undoes a still-running session writing an older account's tokens back.
    func sync() {
        defer { save() }
        guard let raw = Keychain.readClaudeLogin(), let blob = LoginBlob(raw: raw) else { return }
        if raw != lastLiveRaw {
            if lastLiveRaw != nil { liveRawChangedAt = Date() }
            lastLiveRaw = raw
        }
        let oa = ClaudeFiles.oauthAccount()

        if let oa, let oaId = oa["accountUuid"] as? String, describesSameLogin(blob, oa) {
            let isNew = account(oaId) == nil
            store(blob, for: oaId, oauthAccount: oa)
            guard let acc = account(oaId) else { return }
            // A fresh login has no organizationUuid yet; a routine refresh does.
            if addingSince != nil, raw != addingBaseline, isNew || blob.organizationUuid == nil {
                finishAdding(acc, isNew: isNew)
            }
            if state.activeId != oaId {
                state.activeId = oaId
                try? applyEnvMode(for: acc)
                announce(isNew ? "Đã thêm \(acc.email) và đang dùng tài khoản này." : "Claude đang dùng \(acc.email).",
                         kind: .success)
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

    /// Token refreshes carry the organization, so it must match. A fresh
    /// `claude auth login` writes the keychain without it and updates
    /// ~/.claude.json a moment later; until the profile there is at least as
    /// new as the keychain change it may still describe the previous account.
    private func describesSameLogin(_ blob: LoginBlob, _ oa: [String: Any]) -> Bool {
        if let org = blob.organizationUuid { return org == oa["organizationUuid"] as? String }
        guard let ms = oa["profileFetchedAt"] as? NSNumber else { return liveRawChangedAt == .distantPast }
        return Date(timeIntervalSince1970: ms.doubleValue / 1000) >= liveRawChangedAt.addingTimeInterval(-15)
    }

    private func finishAdding(_ acc: Account, isNew: Bool) {
        let relogin = addingEmail?.caseInsensitiveCompare(acc.email) == .orderedSame
        addingSince = nil
        addingEmail = nil
        if isNew {
            announce("Đã thêm \(acc.email) và đang dùng tài khoản này.", kind: .success)
        } else if relogin {
            announce("Đã đăng nhập lại \(acc.email).", kind: .success)
        } else {
            announce("Bạn vừa đăng nhập lại \(acc.email) — tài khoản này đã có. Trình duyệt đang tự dùng tài khoản claude.ai cũ. Để thêm tài khoản khác: đăng xuất claude.ai trên trình duyệt (hoặc mở link trong Terminal bằng cửa sổ ẩn danh), rồi bấm Thêm tài khoản lần nữa.",
                     kind: .warning)
        }
    }

    private func ownerOf(_ blob: LoginBlob) -> Account? {
        let matches = state.accounts.filter { $0.organizationUuid == blob.organizationUuid }
        return matches.count == 1 ? matches[0] : nil
    }

    private func store(_ blob: LoginBlob, for id: String, oauthAccount oa: [String: Any]?) {
        if savedRaw[id] != blob.raw {
            if Keychain.storedLogin(id) != blob.raw, !Keychain.saveLogin(id, blob.raw) {
                announce("Không lưu được login vào Keychain", kind: .error)
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
            announce("\(acc.email): login đã hết hạn và chưa có token dự phòng. Hãy đăng nhập lại.", kind: .error)
            return false
        }
        do {
            if let raw = Keychain.storedLogin(id) {
                guard Keychain.writeClaudeLogin(raw) else {
                    announce("Không ghi được login vào Keychain", kind: .error)
                    return false
                }
                savedRaw[id] = raw
            }
            try ClaudeFiles.setOauthAccount(acc.oauthAccount)
            try applyEnvMode(for: acc, forceLogin: forceLogin)
        } catch {
            announce(error.localizedDescription, kind: .error)
            return false
        }
        state.activeId = id
        update(id) { $0.lastUsedAt = Date() }
        save()
        if !quiet {
            staleSessions = Self.runningClaudePids()
            let mode = state.activeUsesSetupToken ? " bằng token dự phòng" : ""
            announce("Đã chuyển sang \(acc.title)\(mode).", kind: .success)
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
            announce("~/.claude/settings.json có \(ClaudeFiles.envKey) không do app đặt — nó đang đè lên login.", kind: .error)
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
            announce("Không tìm thấy lệnh claude", kind: .error)
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
            announce("Đã làm mới \(acc.email): hạn login \(Fmt.date(before)) → \(Fmt.date(after))", kind: .success)
        } else {
            let why = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            announce("Làm mới \(acc.email) lỗi: \(why)", kind: .error)
        }
    }

    // MARK: Account actions

    /// Runs `claude auth login` in Terminal; with an email it pre-fills the page
    /// (used to log an expired account back in).
    func addAccount(email: String? = nil) {
        sync()
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude", kind: .error) }
        var command = """
            echo 'Trình duyệt sẽ mở trang đăng nhập Claude.'
            echo 'Nếu nó tự dùng tài khoản claude.ai đang đăng nhập sẵn mà bạn muốn tài khoản KHÁC:'
            echo '  copy link bên dưới và mở trong cửa sổ ẩn danh (Cmd+Shift+N), hoặc đăng xuất claude.ai trước.'
            echo
            '\(claude)' auth login
            """
        if let email { command += " --email '\(email.replacingOccurrences(of: "'", with: ""))'" }
        openInTerminal("login", command)
        addingBaseline = Keychain.readClaudeLogin()
        addingEmail = email
        addingSince = Date()
    }

    func cancelAdding() {
        addingSince = nil
        addingEmail = nil
    }

    /// A `claude setup-token` token the user just copied, if the clipboard holds one.
    func clipboardSetupToken() -> String? {
        NSPasteboard.general.string(forType: .string).flatMap(Self.cleanSetupToken)
    }

    /// `claude setup-token` prints the token wrapped across lines, so a copy from
    /// Terminal carries a newline and indent in the middle. Tokens never contain
    /// whitespace: drop all of it, then require the token's shape.
    static func cleanSetupToken(_ text: String) -> String? {
        let t = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard t.hasPrefix("sk-ant-oat"), t.count >= 40,
              t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        return t
    }

    /// Before tokens were cleaned, a pasted token with a line break was written to
    /// the keychain but reported as failed. `security -w` prints such a value as
    /// hex; decode it, clean it and keep it.
    private func recoverHalfSavedSetupTokens() {
        for acc in state.accounts where !acc.hasSetupToken {
            guard var stored = Keychain.setupToken(acc.id) else { continue }
            if stored.count % 2 == 0, stored.allSatisfy(\.isHexDigit) {
                var bytes = [UInt8]()
                var i = stored.startIndex
                while i < stored.endIndex {
                    let j = stored.index(i, offsetBy: 2)
                    bytes.append(UInt8(stored[i..<j], radix: 16) ?? 0)
                    i = j
                }
                stored = String(decoding: bytes, as: UTF8.self)
            }
            guard let token = Self.cleanSetupToken(stored), Keychain.saveSetupToken(acc.id, token) else { continue }
            update(acc.id) { $0.setupTokenAddedAt = Date() }
            announce("Đã khôi phục token dự phòng đã dán cho \(acc.email).", kind: .success)
        }
    }

    func createSetupToken() {
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude", kind: .error) }
        openInTerminal("setup-token", "'\(claude)' setup-token")
    }

    @discardableResult
    func saveSetupToken(_ token: String, for id: String) -> Bool {
        guard let t = Self.cleanSetupToken(token) else {
            announce("Đây không phải token của claude setup-token. Token bắt đầu bằng sk-ant-oat01-, chỉ gồm chữ, số, - và _.", kind: .error)
            return false
        }
        guard Keychain.saveSetupToken(id, t) else {
            announce("Không lưu được token vào Keychain", kind: .error)
            return false
        }
        update(id) { $0.setupTokenAddedAt = Date() }
        if id == state.activeId, let acc = account(id) { try? applyEnvMode(for: acc) }
        save()
        announce("Đã lưu token dự phòng cho \(account(id)?.email ?? "")", kind: .success)
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
            announce("Không đổi được mở cùng macOS: \(error.localizedDescription)", kind: .error)
        }
        objectWillChange.send()
    }

    enum HealthLevel { case good, soon, backup, expired }

    /// One plain-language line per account, the same in the menu and the window.
    func health(_ acc: Account) -> (level: HealthLevel, text: String) {
        let usingBackup = acc.id == state.activeId && state.activeUsesSetupToken
        if usingBackup && acc.loginUsable { return (.backup, "Đang dùng token dự phòng") }
        if !acc.loginUsable {
            return acc.hasSetupToken
                ? (.backup, "Login hết hạn · đang có token dự phòng")
                : (.expired, "Hết hạn · cần đăng nhập lại")
        }
        guard let exp = acc.refreshTokenExpiresAt else { return (.good, "Đăng nhập tốt") }
        let days = max(exp.daysFromNow, 0)
        if exp.timeIntervalSinceNow < Self.keepAliveWindow {
            if acc.id == state.activeId { return (.soon, "Còn \(days) ngày · tự gia hạn khi đang dùng") }
            return (.soon, state.autoKeepAlive ? "Còn \(days) ngày · app sắp tự làm mới" : "Còn \(days) ngày · nên bấm Làm mới")
        }
        return (.good, "Đăng nhập tốt · còn \(days) ngày")
    }

    func backupText(_ acc: Account) -> String {
        guard let exp = acc.setupTokenExpiresAt else { return "Chưa có token dự phòng" }
        return "Token dự phòng còn ~\(max(exp.daysFromNow, 0)) ngày"
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

    /// Shows a banner in the menu and the window; it goes away on its own unless it's an error.
    private func announce(_ text: String, kind: Banner.Kind = .info) {
        let b = Banner(kind: kind, text: text)
        banner = b
        guard kind != .error else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if self?.banner == b { self?.banner = nil }
        }
    }

    func dismissBanner() { banner = nil }

    private func notifyOnce(_ key: String, _ text: String) {
        if let last = notified[key], -last.timeIntervalSinceNow < 86400 { return }
        notified[key] = Date()
        announce(text, kind: .warning)
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
