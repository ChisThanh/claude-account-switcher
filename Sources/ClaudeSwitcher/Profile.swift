import CryptoKit
import Foundation

/// A config dir of its own per account, for running `claude` as an account that
/// isn't the live login. With CLAUDE_CONFIG_DIR set, Claude Code keeps the login
/// in the keychain item "Claude Code-credentials-<first 8 hex of sha256(dir)>"
/// instead of the shared one, so these runs never touch the live login or the
/// sessions using it.
enum Profile {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSwitcher/profiles")
    }

    static func dir(_ id: String) -> URL { root.appendingPathComponent(id) }

    static func keychainService(_ id: String) -> String {
        let digest = SHA256.hash(data: Data(dir(id).path.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// Puts the account's latest login and oauthAccount in its dir; returns the dir.
    static func prepare(_ id: String, login raw: String, oauthAccount: Data) -> URL? {
        let d = dir(id)
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let cfgURL = d.appendingPathComponent(".claude.json")
            var cfg = ClaudeFiles.readJSON(cfgURL) ?? [:]
            cfg["oauthAccount"] = try JSONSerialization.jsonObject(with: oauthAccount)
            cfg["hasCompletedOnboarding"] = true
            if !FileManager.default.fileExists(atPath: cfgURL.path) {
                FileManager.default.createFile(atPath: cfgURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try ClaudeFiles.writeJSON(cfg, to: cfgURL)
        } catch {
            return nil
        }
        if login(id) != raw, !Keychain.write(service: keychainService(id), account: Keychain.user, value: raw) {
            return nil
        }
        return d
    }

    /// The login as Claude Code left it in this dir (rotated if it refreshed).
    static func login(_ id: String) -> String? {
        Keychain.read(service: keychainService(id), account: Keychain.user)
    }

    static func remove(_ id: String) {
        Keychain.delete(service: keychainService(id), account: Keychain.user)
        try? FileManager.default.removeItem(at: dir(id))
    }
}
