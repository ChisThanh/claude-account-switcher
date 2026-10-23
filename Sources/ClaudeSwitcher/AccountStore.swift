import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

struct Banner: Equatable {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let text: String
}

/// Keychain (/usr/bin/security), ps and the 120 KB ~/.claude.json are 10–20 ms
/// each; they run here, never on the main thread.
private func io<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

private func ioThrowing(_ work: @escaping @Sendable () throws -> Void) async throws {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

private struct LiveRead: Sendable {
    let raw: String?
    let configMTime: Date?
    let oauthAccount: Data?
}

@MainActor
@Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var state = AppState()
    private(set) var banner: Banner?
    private(set) var busy = false
    /// Set while a `claude auth login` is pending; cleared when the new login shows up.
    private(set) var addingSince: Date?
    /// claude processes that were running at the last switch and still hold the old account.
    private(set) var staleSessions: Set<Int32> = []
    /// Accounts whose usage is being read right now.
    private(set) var usageLoading: Set<String> = []
    /// The sign-in link of the login running in the background, once it printed it.
    private(set) var loginURL: URL?
    /// True when only the paste-code link was available, so the page shows a code.
    private(set) var loginNeedsCode = false
    @ObservationIgnored private var loginProcess: LoginProcess?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// True when no state file existed at startup.
    private(set) var isFirstLaunch = false

    /// Idle accounts whose login expires within this window get refreshed.
    static let keepAliveWindow: TimeInterval = 5 * 86400
    /// `/usage` costs ~6 s of CPU, so with nothing on screen it runs this rarely.
    static let idleUsageInterval: TimeInterval = 15 * 60

    private let dir: URL
    private var stateURL: URL { dir.appendingPathComponent("state.json") }
    private static let saveQueue = DispatchQueue(label: "ClaudeSwitcher.save", qos: .utility)

    @ObservationIgnored private var lastSaved: AppState?
    @ObservationIgnored private var savedRaw: [String: String] = [:]   // login blob last stored per account
    @ObservationIgnored private var setupTokens: [String: String] = [:] // keychain cache, saves a `security` call each
    @ObservationIgnored private var notified: [String: Date] = [:]
    @ObservationIgnored private var lastHealthCheck = Date.distantPast
    @ObservationIgnored private var lastSync = Date.distantPast
    @ObservationIgnored private var lastLiveRaw: String?
    @ObservationIgnored private var liveRawChangedAt = Date.distantPast
    @ObservationIgnored private var configMTime: Date?
    @ObservationIgnored private var cachedOauthAccount: Data?
    @ObservationIgnored private var addingBaseline: String?
    @ObservationIgnored private var addingEmail: String?
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?

    private init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        isFirstLaunch = lastSaved == nil
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t

        Task {
            await serial { await self.recoverHalfSavedSetupTokens() }
            tick(force: true)
        }
    }

    var active: Account? { state.activeId.flatMap(account) }
    func account(_ id: String) -> Account? { state.accounts.first { $0.id == id } }

    nonisolated static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Scheduling

    /// Runs store operations one at a time. They await keychain and file IO off
    /// the main thread and must not interleave (a tick's sync inside a switch).
    /// Operations already inside `serial` call the `…Locked` functions directly.
    private func serial<T: Sendable>(_ op: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            return await op()
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    /// The panel and the window report while they are on screen; syncing is fast
    /// then (and while a login is pending), lazy otherwise.
    func viewAppeared() {
        visibleViews += 1
        tick(force: true)
        refreshActiveUsage(maxAge: 60)
    }

    func viewDisappeared() { visibleViews = max(0, visibleViews - 1) }

    func tick(force: Bool = false) {
        guard !ticking, !busy else { return }
        let fast = visibleViews > 0 || addingSince != nil || !staleSessions.isEmpty
        guard force || -lastSync.timeIntervalSinceNow >= (fast ? 2.5 : 15) else { return }
        ticking = true
        Task {
            await serial { await self.tickLocked(force: force) }
            ticking = false
        }
    }

    private func tickLocked(force: Bool) async {
        lastSync = Date()
        await syncLocked()
        if !staleSessions.isEmpty {
            let alive = await io { Self.runningClaudePids() }
            let still = staleSessions.intersection(alive)
            if still != staleSessions { staleSessions = still }
        }
        if let since = addingSince, -since.timeIntervalSinceNow > 15 * 60 { cancelAdding() }
        refreshActiveUsage(maxAge: visibleViews > 0 ? 180 : Self.idleUsageInterval)
        guard force || -lastHealthCheck.timeIntervalSinceNow >= 60 else { return }
        lastHealthCheck = Date()
        await checkHealthLocked()
        if state.autoKeepAlive { keepAliveIfDue() }
    }

    /// Terminal (`~/.local/share/claude/versions/…`) and IDE-extension
    /// (`…/native-binary/claude`) Claude Code processes.
    nonisolated static func runningClaudePids() -> Set<Int32> {
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

    private func readLive() async -> (raw: String?, oauthAccount: [String: Any]?) {
        let mtime = configMTime, cached = cachedOauthAccount
        let live = await io {
            let raw = Keychain.readClaudeLogin()
            let oa = ClaudeFiles.oauthAccountData(cachedMTime: mtime, cached: cached)
            return LiveRead(raw: raw, configMTime: oa.mtime, oauthAccount: oa.data)
        }
        configMTime = live.configMTime
        cachedOauthAccount = live.oauthAccount
        let oa = live.oauthAccount.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return (live.raw, oa)
    }

    /// Reconciles the live login (keychain + ~/.claude.json) with the store: keeps
    /// the tokens Claude Code rotated, adopts logins made with `claude auth login`,
    /// and undoes a still-running session writing an older account's tokens back.
    private func syncLocked() async {
        defer { save() }
        let live = await readLive()
        guard let raw = live.raw, let blob = LoginBlob(raw: raw) else { return }
        if raw != lastLiveRaw {
            if lastLiveRaw != nil { liveRawChangedAt = Date() }
            lastLiveRaw = raw
        }

        if let oa = live.oauthAccount, let oaId = oa["accountUuid"] as? String, describesSameLogin(blob, oa) {
            let isNew = account(oaId) == nil
            await storeLogin(blob, for: oaId, oauthAccount: oa)
            guard let acc = account(oaId) else { return }
            // A fresh login has no organizationUuid yet; a routine refresh does.
            if addingSince != nil, raw != addingBaseline, isNew || blob.organizationUuid == nil {
                finishAdding(acc, isNew: isNew)
            }
            if state.activeId != oaId {
                state.activeId = oaId
                try? await applyEnvMode(for: acc)
                if !isNew { announce("Claude đang dùng \(acc.email).", kind: .success) }
            } else if state.activeUsesSetupToken, acc.loginUsable, !acc.preferSetupToken {
                try? await applyEnvMode(for: acc)   // logged in again: back to the full login
            }
            return
        }

        // Keychain and ~/.claude.json disagree: a session still on an older account
        // refreshed its token. Keep those tokens, then put the active account back.
        guard let owner = ownerOf(blob) else { return }
        await storeLogin(blob, for: owner.id, oauthAccount: nil)
        guard let active else { return }
        if active.id != owner.id {
            let id = active.id
            let written = await io { Keychain.storedLogin(id).flatMap { Keychain.writeClaudeLogin($0) ? $0 : nil } }
            if let written {
                savedRaw[id] = written
                lastLiveRaw = written
            }
            notifyOnce("stale-\(owner.id)", "Một phiên Claude cũ vẫn chạy bằng \(owner.email). Đã đặt lại \(active.email) — hãy khởi động lại phiên đó.")
        }
        let data = active.oauthAccount
        _ = await io { try? ClaudeFiles.setOauthAccount(data) }
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
        clearAddingState()
        if isNew {
            announce("Đã thêm \(acc.email) và đang dùng tài khoản này.", kind: .success)
        } else if relogin {
            announce("Đã đăng nhập lại \(acc.email).", kind: .success)
        } else {
            announce("Bạn vừa đăng nhập lại \(acc.email) — tài khoản này đã có. Trình duyệt chính đang đăng nhập sẵn tài khoản này. Để thêm tài khoản khác: bấm Thêm tài khoản và chọn Cửa sổ ẩn danh.",
                     kind: .warning)
        }
    }

    private func ownerOf(_ blob: LoginBlob) -> Account? {
        let matches = state.accounts.filter { $0.organizationUuid == blob.organizationUuid }
        return matches.count == 1 ? matches[0] : nil
    }

    private func storeLogin(_ blob: LoginBlob, for id: String, oauthAccount oa: [String: Any]?) async {
        var renewed = false
        if savedRaw[id] != blob.raw {
            let raw = blob.raw
            let (ok, changed) = await io { () -> (Bool, Bool) in
                if Keychain.storedLogin(id) == raw { return (true, false) }
                return (Keychain.saveLogin(id, raw), true)
            }
            guard ok else { return announce("Không lưu được login vào Keychain", kind: .error) }
            savedRaw[id] = raw
            renewed = changed
        }
        var acc = account(id) ?? Account(id: id, email: "", organizationUuid: blob.organizationUuid ?? "",
                                         oauthAccount: Data(), hasLogin: true, preferSetupToken: false)
        acc.hasLogin = true
        acc.refreshTokenExpiresAt = blob.refreshTokenExpiresAt
        acc.accessTokenExpiresAt = blob.accessTokenExpiresAt
        if renewed { acc.lastRefreshedAt = Date() }
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

    func switchTo(_ id: String) {
        Task { await serial { await self.switchLocked(id, quiet: false) } }
    }

    @discardableResult
    private func switchLocked(_ id: String, quiet: Bool, forceLogin: Bool = false) async -> Bool {
        await syncLocked()
        guard let acc = account(id) else { return false }
        if !acc.loginUsable && !acc.hasSetupToken {
            announce("\(acc.email): login đã hết hạn và chưa có token dự phòng. Hãy đăng nhập lại.", kind: .error)
            return false
        }
        let (hadLogin, written) = await io { () -> (Bool, String?) in
            guard let raw = Keychain.storedLogin(id) else { return (false, nil) }
            return (true, Keychain.writeClaudeLogin(raw) ? raw : nil)
        }
        if hadLogin {
            guard let written else {
                announce("Không ghi được login vào Keychain", kind: .error)
                return false
            }
            savedRaw[id] = written
            lastLiveRaw = written   // our own write, not an outside login
        }
        do {
            let data = acc.oauthAccount
            try await ioThrowing { try ClaudeFiles.setOauthAccount(data) }
            try await applyEnvMode(for: acc, forceLogin: forceLogin)
        } catch {
            announce(error.localizedDescription, kind: .error)
            return false
        }
        if state.activeId != id { state.activeId = id }
        update(id) { $0.lastUsedAt = Date() }
        save()
        if !quiet {
            staleSessions = await io { Self.runningClaudePids() }
            let mode = state.activeUsesSetupToken ? " bằng token dự phòng" : ""
            announce("Đã chuyển sang \(acc.title)\(mode).", kind: .success)
            refreshActiveUsage(maxAge: 0)
        }
        return true
    }

    private func setupToken(_ id: String) async -> String? {
        if let t = setupTokens[id] { return t }
        let t = await io { Keychain.setupToken(id) }
        if let t { setupTokens[id] = t }
        return t
    }

    private func setActiveUsesSetupToken(_ on: Bool) {
        if state.activeUsesSetupToken != on { state.activeUsesSetupToken = on }
    }

    /// settings.json carries the setup-token only while the login can't be used
    /// (or the account is set to always use it).
    private func applyEnvMode(for acc: Account, forceLogin: Bool = false) async throws {
        let wantSetup = !forceLogin && (acc.preferSetupToken || !acc.loginUsable)
        if wantSetup, let token = await setupToken(acc.id) {
            try await ioThrowing { try ClaudeFiles.setEnvToken(token) }
            setActiveUsesSetupToken(true)
            return
        }
        setActiveUsesSetupToken(false)
        guard let current = await io({ ClaudeFiles.envToken() }) else { return }
        for other in state.accounts where other.hasSetupToken {
            if await setupToken(other.id) == current {
                return try await ioThrowing { try ClaudeFiles.setEnvToken(nil) }
            }
        }
        announce("~/.claude/settings.json có \(ClaudeFiles.envKey) không do app đặt — nó đang đè lên login.", kind: .error)
    }

    // MARK: Keep-alive

    private func checkHealthLocked() async {
        for acc in state.accounts {
            if let exp = acc.setupTokenExpiresAt, exp.daysFromNow < 30 {
                notifyOnce("setup-\(acc.id)", "Token dự phòng của \(acc.email) còn khoảng \(max(exp.daysFromNow, 0)) ngày. Hãy chạy lại claude setup-token.")
            }
            guard let exp = acc.refreshTokenExpiresAt else { continue }
            if exp <= Date() {
                if acc.id == state.activeId, !state.activeUsesSetupToken, acc.hasSetupToken {
                    try? await applyEnvMode(for: acc)
                    save()
                    notifyOnce("fallback-\(acc.id)", "Login của \(acc.email) đã hết hạn — đã chuyển sang token dự phòng.")
                } else if !acc.hasSetupToken {
                    notifyOnce("expired-\(acc.id)", "Login của \(acc.email) đã hết hạn. Hãy đăng nhập lại hoặc thêm token dự phòng.")
                }
            } else if !state.autoKeepAlive, exp.timeIntervalSinceNow < Self.keepAliveWindow {
                notifyOnce("soon-\(acc.id)", "Login của \(acc.email) còn \(exp.daysFromNow) ngày. Bấm Gia hạn ngay hoặc bật tự gia hạn hằng ngày.")
            }
        }
    }

    /// Every logged-in account, active one included, is renewed at least once a
    /// day. Each refresh pushes the login's expiry ~30 days out, so this keeps
    /// all of them alive. A renewal Claude Code did on its own counts, and an
    /// access token that is still valid means one happened within its ~8 h life.
    static let renewInterval: TimeInterval = 24 * 3600
    @ObservationIgnored private var renewing = false

    func renewDue(_ acc: Account, now: Date = Date()) -> Bool {
        guard acc.loginUsable, acc.hasLogin else { return false }
        if let exp = acc.accessTokenExpiresAt, exp > now { return false }
        guard let last = acc.lastRenewedAt else { return true }
        return now.timeIntervalSince(last) >= Self.renewInterval
    }

    /// When the account is next due, for the UI.
    func nextRenewal(_ acc: Account) -> Date? {
        guard acc.loginUsable else { return nil }
        let afterLast = acc.lastRenewedAt.map { $0.addingTimeInterval(Self.renewInterval) } ?? Date()
        return max(afterLast, acc.accessTokenExpiresAt ?? .distantPast)
    }

    /// Called from inside a tick, so it queues the renewal instead of awaiting it;
    /// one account per tick, the next one a minute later.
    private func keepAliveIfDue() {
        guard !renewing, let due = state.accounts.first(where: { renewDue($0) }) else { return }
        renewing = true
        Task {
            await serial { await self.refreshLoginLocked(due.id, manual: false) }
            renewing = false
        }
    }

    func refreshLogin(_ id: String) async {
        await serial { await self.refreshLoginLocked(id, manual: true) }
    }

    /// Lets Claude Code itself refresh an account while it is live: first `/usage`
    /// (free; Claude Code refreshes an expired token before calling the API), and
    /// only if the tokens didn't change, one tiny haiku message.
    private func refreshLoginLocked(_ id: String, manual: Bool) async {
        guard let acc = account(id), acc.loginUsable else { return }
        if let exp = acc.accessTokenExpiresAt, exp > Date() {
            if manual {
                announce("\(acc.title): token còn hạn đến \(Fmt.reset(exp)). Claude Code chỉ làm mới khi token hết hạn, nên chưa cần làm gì.", kind: .info)
            }
            return
        }
        let before = acc.refreshTokenExpiresAt
        // Right after launch savedRaw is empty; compare against the stored copy.
        let beforeRaw: String?
        if let cached = savedRaw[id] { beforeRaw = cached } else { beforeRaw = await io { Keychain.storedLogin(id) } }
        var usage: UsageSnapshot?
        var ping: ShellResult?
        let ran = await withTemporarilyActiveLocked(id) {
            self.usageLoading.insert(id)
            usage = await self.fetchLiveUsage()
            self.usageLoading.remove(id)
            let live = await io { Keychain.readClaudeLogin() }
            if live == beforeRaw {
                ping = await self.runClaude(["-p", "Reply with OK", "--model", "haiku", "--max-turns", "1"], timeout: 180)
            }
        }
        guard ran else { return }
        let renewed = savedRaw[id] != beforeRaw
        update(id) {
            if renewed { $0.lastKeepAliveAt = Date() }
            if let usage { $0.usage = usage }
        }
        save()

        let after = account(id)?.refreshTokenExpiresAt
        if renewed {
            if manual {
                announce("Đã gia hạn \(acc.title): hạn login \(Fmt.date(before)) → \(Fmt.date(after)).", kind: .success)
            }
        } else {
            let why = ((ping?.stderr ?? "") + (ping?.stdout ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            let text = "Không gia hạn được \(acc.title)" + (why.isEmpty ? "." : ": \(why)")
            if manual { announce(text, kind: .error) } else { notifyOnce("renew-fail-\(id)", text) }
        }
    }

    /// Makes an idle account the live login for a few seconds, runs `work`, keeps
    /// whatever tokens Claude Code rotated, and switches back.
    private func withTemporarilyActiveLocked(_ id: String, _ work: () async -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        // A background /usage read of the active account must finish first, or
        // its numbers could land on the wrong account.
        let deadline = Date().addingTimeInterval(70)
        while !usageLoading.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let previous = state.activeId
        guard await switchLocked(id, quiet: true, forceLogin: true) else { return false }
        await work()
        await syncLocked()
        // Also when previous == id: forceLogin may have lifted a setup-token
        // from settings.json, and switching back restores it.
        if let previous { await switchLocked(previous, quiet: true) }
        save()
        return true
    }

    /// Runs the claude CLI against the live login (never a setup-token from the
    /// environment), without saving a session transcript, at low priority.
    private func runClaude(_ args: [String], timeout: TimeInterval) async -> ShellResult? {
        guard let claude = Self.claudePath else { return nil }
        var env = ProcessInfo.processInfo.environment
        for key in [ClaudeFiles.envKey, "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env[key] = nil }
        let runEnv = env
        let home = FileManager.default.homeDirectoryForCurrentUser
        return await Task.detached(priority: .utility) {
            Shell.run(claude, args + ["--no-session-persistence", "--strict-mcp-config"],
                      env: runEnv, cwd: home, timeout: timeout, qos: .utility)
        }.value
    }

    // MARK: Usage

    /// `/usage` is a local command: no model turn, nothing billed. It reads the
    /// plan limits of the live login; a setup-token can't (no profile scope).
    private func fetchLiveUsage() async -> UsageSnapshot? {
        guard let r = await runClaude(["-p", "/usage", "--output-format", "json"], timeout: 60), r.status == 0 else { return nil }
        let out = r.stdout
        return await io {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
                  let text = obj["result"] as? String else { return nil }
            return UsageParser.parse(text)
        }
    }

    func canReadUsage(_ acc: Account) -> Bool {
        acc.loginUsable && !(acc.id == state.activeId && state.activeUsesSetupToken)
    }

    /// The active account's usage when the last read is older than `maxAge`. Not
    /// serialized: it only reads, and drops the result if the account changed.
    func refreshActiveUsage(maxAge: TimeInterval = 180) {
        guard let acc = active, canReadUsage(acc), !busy, !usageLoading.contains(acc.id) else { return }
        if let u = acc.usage, -u.fetchedAt.timeIntervalSinceNow < maxAge { return }
        usageLoading.insert(acc.id)
        Task {
            let snap = await fetchLiveUsage()
            usageLoading.remove(acc.id)
            guard let snap, state.activeId == acc.id else { return }
            update(acc.id) { $0.usage = snap }
            save()
        }
    }

    /// Any account's usage; an idle one is made live for a few seconds to read it.
    func refreshUsage(_ id: String) async {
        guard let acc = account(id) else { return }
        guard canReadUsage(acc) else {
            return announce("\(acc.title): cần login thường còn hạn để đọc usage.", kind: .warning)
        }
        if id == state.activeId { return refreshActiveUsage(maxAge: 0) }
        await serial {
            var snap: UsageSnapshot?
            let ran = await self.withTemporarilyActiveLocked(id) {
                self.usageLoading.insert(id)
                snap = await self.fetchLiveUsage()
                self.usageLoading.remove(id)
            }
            guard ran else { return }
            if let snap {
                self.update(id) { $0.usage = snap }
                self.save()
            } else {
                self.announce("Không đọc được usage của \(acc.title).", kind: .error)
            }
        }
    }

    func refreshAllUsage() async {
        for acc in state.accounts where canReadUsage(acc) {
            await refreshUsage(acc.id)
        }
    }

    /// When the active account is nearly out, the account with the most room left.
    func suggestion() -> (account: Account, load: Int)? {
        guard let active, let load = active.usage?.load, load >= 80 else { return nil }
        let best = state.accounts
            .filter { $0.id != active.id && health($0).level != .expired }
            .compactMap { a in a.usage.map { (account: a, load: $0.load) } }
            .min { $0.load < $1.load }
        guard let best, best.load < load else { return nil }
        return best
    }

    // MARK: Account actions

    /// Runs `claude auth login` in the background and opens its sign-in link the
    /// way the user picked; with an email the page is pre-filled (logging an
    /// expired account back in).
    func addAccount(email: String? = nil, open mode: LoginOpenMode = .normal) {
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude", kind: .error) }
        loginProcess?.cancel()
        Task {
            await serial {
                await self.syncLocked()
                // Baseline first: the wait only starts once there is something to compare against.
                self.addingBaseline = await io { Keychain.readClaudeLogin() }
                let login = LoginProcess()
                login.onURL = { [weak self] url, needsCode in
                    self?.loginURL = url
                    self?.loginNeedsCode = needsCode
                    self?.openLoginURL(mode)
                }
                login.onExit = { [weak self, weak login] status, cancelled, output in
                    guard let self, let login, self.loginProcess === login else { return }
                    self.loginProcess = nil
                    self.loginURL = nil
                    self.loginNeedsCode = false
                    if status == 0 {
                        self.tick(force: true)   // pick the new login up now, not at the next tick
                    } else if !cancelled, self.addingSince != nil {
                        self.clearAddingState()
                        let tail = output.split(separator: "\n").suffix(2).joined(separator: " ").prefix(200)
                        self.announce("Đăng nhập không thành công: \(tail)", kind: .error)
                    }
                }
                do {
                    try login.start(claude: claude, email: email)
                } catch {
                    return self.announce("Không chạy được claude auth login: \(error.localizedDescription)", kind: .error)
                }
                self.loginProcess = login
                self.addingSince = Date()
                self.addingEmail = email
            }
        }
    }

    /// Opens (or re-opens) the pending sign-in link.
    func openLoginURL(_ mode: LoginOpenMode) {
        guard let url = loginURL else { return }
        switch mode {
        case .normal:
            LoginBrowser.openNormal(url)
        case .privateWindow(let app):
            LoginBrowser.openPrivate(url, in: app)
        case .copyOnly:
            LoginBrowser.copy(url)
            announce("Đã copy link đăng nhập. Dán vào trình duyệt bạn muốn.", kind: .info)
        }
    }

    /// Sends the code a sign-in page showed back to the waiting `claude auth login`.
    func submitLoginCode(_ code: String) {
        guard let loginProcess else { return announce("Không còn phiên đăng nhập nào đang chờ. Bấm Thêm tài khoản lại.", kind: .error) }
        loginProcess.submitCode(code)
        announce("Đã gửi mã. App sẽ nhận tài khoản sau vài giây.", kind: .info)
    }

    /// The user gave up: stop the login process too.
    func cancelAdding() {
        loginProcess?.cancel()
        loginProcess = nil
        loginURL = nil
        loginNeedsCode = false
        clearAddingState()
    }

    /// The login finished (or timed out in the UI); the process exits on its own.
    private func clearAddingState() {
        if addingSince != nil { addingSince = nil }
        addingEmail = nil
    }

    /// A `claude setup-token` token the user just copied, if the clipboard holds one.
    func clipboardSetupToken() -> String? {
        NSPasteboard.general.string(forType: .string).flatMap(Self.cleanSetupToken)
    }

    /// `claude setup-token` prints the token wrapped across lines, so a copy from
    /// Terminal carries a newline and indent in the middle. Tokens never contain
    /// whitespace: drop all of it, then require the token's shape.
    nonisolated static func cleanSetupToken(_ text: String) -> String? {
        let t = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard t.hasPrefix("sk-ant-oat"), t.count >= 40,
              t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        else { return nil }
        return t
    }

    /// Before tokens were cleaned, a pasted token with a line break was written to
    /// the keychain but reported as failed. `security -w` prints such a value as
    /// hex; decode it, clean it and keep it.
    private func recoverHalfSavedSetupTokens() async {
        for acc in state.accounts where !acc.hasSetupToken {
            let id = acc.id
            let recovered = await io { () -> String? in
                guard var stored = Keychain.setupToken(id) else { return nil }
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
                guard let token = AccountStore.cleanSetupToken(stored), Keychain.saveSetupToken(id, token) else { return nil }
                return token
            }
            guard let recovered else { continue }
            setupTokens[id] = recovered
            update(id) { $0.setupTokenAddedAt = Date() }
            save()
            announce("Đã khôi phục token dự phòng đã dán cho \(acc.email).", kind: .success)
        }
    }

    func createSetupToken() {
        guard let claude = Self.claudePath else { return announce("Không tìm thấy lệnh claude", kind: .error) }
        openInTerminal("setup-token", "'\(claude)' setup-token")
    }

    func saveSetupToken(_ token: String, for id: String) async -> Bool {
        guard let t = Self.cleanSetupToken(token) else {
            announce("Đây không phải token của claude setup-token. Token bắt đầu bằng sk-ant-oat01-, chỉ gồm chữ, số, - và _.", kind: .error)
            return false
        }
        return await serial {
            guard await io({ Keychain.saveSetupToken(id, t) }) else {
                self.announce("Không lưu được token vào Keychain", kind: .error)
                return false
            }
            self.setupTokens[id] = t
            self.update(id) { $0.setupTokenAddedAt = Date() }
            if id == self.state.activeId, let acc = self.account(id) { try? await self.applyEnvMode(for: acc) }
            self.save()
            self.announce("Đã lưu token dự phòng cho \(self.account(id)?.email ?? "")", kind: .success)
            return true
        }
    }

    func removeSetupToken(_ id: String) {
        Task {
            await serial {
                self.update(id) { $0.setupTokenAddedAt = nil; $0.preferSetupToken = false }
                if id == self.state.activeId, let acc = self.account(id) { try? await self.applyEnvMode(for: acc) }
                self.setupTokens[id] = nil
                await io { Keychain.delete(service: Keychain.storeService, account: "\(id).setup") }
                self.save()
            }
        }
    }

    func setPreferSetupToken(_ on: Bool, for id: String) {
        update(id) { $0.preferSetupToken = on }
        save()
        Task {
            await serial {
                if id == self.state.activeId, let acc = self.account(id) { try? await self.applyEnvMode(for: acc) }
            }
        }
    }

    func setLabel(_ label: String, for id: String) {
        update(id) { $0.label = label.isEmpty ? nil : label }
        save()
    }

    func setAutoKeepAlive(_ on: Bool) {
        if state.autoKeepAlive != on { state.autoKeepAlive = on }
        save()
    }

    func remove(_ id: String) {
        guard id != state.activeId else { return }
        savedRaw[id] = nil
        setupTokens[id] = nil
        state.accounts.removeAll { $0.id == id }
        save()
        Task { await io { Keychain.forget(id) } }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            announce("Không đổi được mở cùng macOS: \(error.localizedDescription)", kind: .error)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
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
            return (.soon, state.autoKeepAlive ? "Còn \(days) ngày · app sắp gia hạn" : "Còn \(days) ngày · nên bấm Gia hạn")
        }
        return (.good, "Đăng nhập tốt · còn \(days) ngày")
    }

    // MARK: Helpers

    /// Writes back only on a real change, so observers don't redraw for nothing.
    private func update(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        var acc = state.accounts[i]
        change(&acc)
        if acc != state.accounts[i] { state.accounts[i] = acc }
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

    /// Encodes on the main thread (a few KB) and writes on a serial queue.
    private func save() {
        guard state != lastSaved else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        lastSaved = state
        let url = stateURL
        Self.saveQueue.async { try? data.write(to: url, options: .atomic) }
    }
}

/// DateFormatter is expensive to create; these are made once.
@MainActor
enum Fmt {
    private static let full: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy HH:mm"; return f }()
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"; return f }()

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return full.string(from: d)
    }

    /// "hôm nay 16:59", "mai 22:59", "26/10 08:00".
    static func reset(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "hôm nay \(time.string(from: d))" }
        if cal.isDateInTomorrow(d) { return "mai \(time.string(from: d))" }
        return dayTime.string(from: d)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "vừa xong" }
        if s < 3600 { return "\(Int(s / 60)) phút trước" }
        if s < 86400 { return "\(Int(s / 3600)) giờ trước" }
        return date(d)
    }
}
