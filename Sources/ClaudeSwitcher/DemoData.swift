import Foundation

/// Made-up accounts for `--demo` (README screenshots). example.com only.
enum DemoData {
    static func state(now: Date = Date()) -> AppState {
        func usage(_ session: Int, _ week: Int, _ fable: Int) -> UsageSnapshot {
            UsageSnapshot(fetchedAt: now.addingTimeInterval(-90), windows: [
                UsageWindow(label: UsageWindow.sessionLabel, percent: session, resetsAt: now.addingTimeInterval(2.5 * 3600), resetText: nil),
                UsageWindow(label: UsageWindow.weekLabel, percent: week, resetsAt: now.addingTimeInterval(4 * 86400), resetText: nil),
                UsageWindow(label: "Current week (Fable)", percent: fable, resetsAt: now.addingTimeInterval(4 * 86400), resetText: nil),
            ])
        }
        func account(_ id: String, _ email: String, _ name: String, _ plan: String, loginDays: Double,
                     backup: Bool, usage u: UsageSnapshot) -> Account {
            var a = Account(id: id, email: email, displayName: name, organizationUuid: id, organizationName: "\(name)'s Organization",
                            subscriptionType: plan, oauthAccount: Data(), hasLogin: true, preferSetupToken: false)
            a.refreshTokenExpiresAt = now.addingTimeInterval(loginDays * 86400)
            a.accessTokenExpiresAt = now.addingTimeInterval(5 * 3600)
            a.lastKeepAliveAt = now.addingTimeInterval(-3 * 3600)
            a.setupTokenAddedAt = backup ? now.addingTimeInterval(-20 * 86400) : nil
            a.usage = u
            return a
        }
        var s = AppState()
        s.accounts = [
            account("demo-work", "work@example.com", "Work", "max", loginDays: 27, backup: true, usage: usage(86, 92, 4)),
            account("demo-personal", "personal@example.com", "Personal", "max", loginDays: 24, backup: true, usage: usage(5, 31, 0)),
            account("demo-side", "side-project@example.com", "Side Project", "pro", loginDays: 3, backup: false, usage: usage(0, 12, 0)),
        ]
        s.activeId = "demo-work"
        return s
    }
}
