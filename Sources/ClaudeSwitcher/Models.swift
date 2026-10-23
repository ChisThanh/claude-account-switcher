import Foundation

struct Account: Codable, Identifiable, Equatable {
    var id: String                  // oauthAccount.accountUuid
    var email: String
    var displayName: String?
    var organizationUuid: String
    var organizationName: String?
    var subscriptionType: String?
    var label: String?
    var oauthAccount: Data          // raw oauthAccount object from ~/.claude.json
    var hasLogin: Bool
    var refreshTokenExpiresAt: Date?
    var setupTokenAddedAt: Date?
    var preferSetupToken: Bool
    var lastUsedAt: Date?
    var lastKeepAliveAt: Date?
    var usage: UsageSnapshot?
    var accessTokenExpiresAt: Date?
    /// Last time the stored tokens changed (Claude Code refreshed or a new login).
    var lastRefreshedAt: Date?

    /// The latest renewal, whether the app ran it or Claude Code did on its own.
    var lastRenewedAt: Date? { [lastKeepAliveAt, lastRefreshedAt].compactMap { $0 }.max() }

    var title: String {
        if let label, !label.isEmpty { return label }
        return email
    }

    /// `claude setup-token` tokens last about a year; Claude Code doesn't expose
    /// the exact date, so this counts from when the token was saved here.
    var setupTokenExpiresAt: Date? { setupTokenAddedAt?.addingTimeInterval(365 * 86400) }
    var hasSetupToken: Bool { setupTokenAddedAt != nil }
    var loginUsable: Bool { hasLogin && (refreshTokenExpiresAt.map { $0 > Date() } ?? true) }
}

struct AppState: Codable, Equatable {
    var accounts: [Account] = []
    var activeId: String?
    var activeUsesSetupToken = false
    var autoKeepAlive = true
}

extension Date {
    var daysFromNow: Int { Int((timeIntervalSinceNow / 86400).rounded(.down)) }
}
