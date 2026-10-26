import Foundation

/// The two files Claude Code reads for identity: ~/.claude.json (oauthAccount:
/// email, org, plan) and ~/.claude/settings.json (env, where a setup-token goes).
/// Only the one key we own is changed; everything else is written back as read.
enum ClaudeFiles {
    static let envKey = "CLAUDE_CODE_OAUTH_TOKEN"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static var globalConfig: URL { home.appendingPathComponent(".claude.json") }
    static var settings: URL { home.appendingPathComponent(".claude/settings.json") }

    enum WriteError: LocalizedError {
        case unreadable(URL), rename(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let u): return L("Không đọc được \(u.path)", "Couldn't read \(u.path)")
            case .rename(let u): return L("Không ghi được \(u.path)", "Couldn't write \(u.path)")
            }
        }
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Temp file + rename in the same folder, keeping the original permissions
    /// (~/.claude.json is 0600).
    static func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).claudeswitcher.tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: perms]),
              rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw WriteError.rename(url)
        }
    }

    // MARK: oauthAccount

    static func oauthAccount() -> [String: Any]? {
        readJSON(globalConfig)?["oauthAccount"] as? [String: Any]
    }

    /// oauthAccount as sorted JSON, re-parsing the ~120 KB file only when its
    /// modification date moved since `cachedMTime`.
    static func oauthAccountData(cachedMTime: Date?, cached: Data?) -> (mtime: Date?, data: Data?) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: globalConfig.path))?[.modificationDate] as? Date
        if let mtime, mtime == cachedMTime { return (mtime, cached) }
        guard let oa = oauthAccount(),
              let data = try? JSONSerialization.data(withJSONObject: oa, options: [.sortedKeys]) else { return (mtime, nil) }
        return (mtime, data)
    }

    static func setOauthAccount(_ raw: Data) throws {
        guard var cfg = readJSON(globalConfig) else { throw WriteError.unreadable(globalConfig) }
        if let current = cfg["oauthAccount"],
           let currentData = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
           let wanted = try? JSONSerialization.jsonObject(with: raw),
           let wantedData = try? JSONSerialization.data(withJSONObject: wanted, options: [.sortedKeys]),
           currentData == wantedData { return }   // already right: skip rewriting 120 KB
        cfg["oauthAccount"] = try JSONSerialization.jsonObject(with: raw)
        try writeJSON(cfg, to: globalConfig)
    }

    // MARK: settings.json env token

    static func envToken() -> String? {
        (readJSON(settings)?["env"] as? [String: Any])?[envKey] as? String
    }

    static func setEnvToken(_ token: String?) throws {
        var cfg = readJSON(settings) ?? [:]
        var env = cfg["env"] as? [String: Any] ?? [:]
        if env[envKey] as? String == token { return }
        env[envKey] = token
        cfg["env"] = env
        try writeJSON(cfg, to: settings)
    }
}

/// The JSON Claude Code keeps in the "Claude Code-credentials" keychain item.
struct LoginBlob {
    let raw: String
    let organizationUuid: String?
    let refreshToken: String
    let accessTokenExpiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let subscriptionType: String?

    init?(raw: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String else { return nil }
        func date(_ key: String) -> Date? {
            (oauth[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        self.raw = raw
        organizationUuid = obj["organizationUuid"] as? String
        refreshToken = refresh
        accessTokenExpiresAt = date("expiresAt")
        refreshTokenExpiresAt = date("refreshTokenExpiresAt")
        subscriptionType = oauth["subscriptionType"] as? String
    }
}
