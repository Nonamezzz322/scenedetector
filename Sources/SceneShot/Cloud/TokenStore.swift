import Foundation

/// File-based token store — avoids the Keychain entirely, so macOS never prompts for the
/// keychain password (ad-hoc-signed apps change code identity on every rebuild, which makes
/// the Keychain re-prompt and never remember "Always Allow").
///
/// Tokens live in a 0600 JSON file under Application Support, readable only by the current
/// user account. Trade-off vs the Keychain: NOT encrypted at rest — any process running as
/// this user could read it (same posture as browser cookie stores). Acceptable for an
/// unsandboxed local tool holding read-only OAuth tokens. Application Support (not Caches) so
/// the file persists and the user doesn't have to re-authorize after a cache cleanup.
enum TokenStore {
    private static let lock = NSLock()

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SceneShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("tokens.json")
    }()

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return dict
    }

    private static func writeAll(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dict = readAll()
        if let value, !value.isEmpty { dict[account] = value } else { dict.removeValue(forKey: account) }
        writeAll(dict)
        return true
    }

    static func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return readAll()[account]
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        set(nil, account: account)
    }
}
