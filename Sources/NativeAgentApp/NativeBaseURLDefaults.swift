// R23 (2026-07-01): the base-URL UserDefaults key predates the daemon kill
// (2026-06-02) and was still named "daemonBaseURL". Reads migrate the legacy
// value into the native key once, write-through, so existing installs keep
// their setting. The legacy key is left in place for downgrade safety.
import Foundation

enum NativeBaseURLDefaults {
    static let key = "nativeBaseURL"
    private static let legacyKey = "daemonBaseURL"

    enum ValidationError: Error, Equatable, LocalizedError {
        case invalidBaseURL

        var errorDescription: String? {
            "Enter a complete http:// or https:// base URL without credentials, a query, or a fragment."
        }
    }

    // One-shot migration behind a thread-safe static-initializer token so a
    // first-read migration can never race a concurrent fresh write and
    // clobber it with the legacy value.
    private static let migrateOnce: Void = {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == nil,
           let legacy = defaults.string(forKey: legacyKey) {
            defaults.set(legacy, forKey: key)
        }
    }()

    static func read() -> String {
        _ = migrateOnce
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func write(_ value: String) {
        // Force the one-shot migration first so a write can never be
        // clobbered by a later first-read migration copying the legacy value.
        _ = migrateOnce
        UserDefaults.standard.set(value, forKey: key)
    }

    /// The legacy base URL remains a compatibility preference, not a second
    /// runtime owner. Validate it at the AppModel mutation boundary so a
    /// malformed draft cannot replace the last known value consumed by the
    /// app's compatibility clients.
    static func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw ValidationError.invalidBaseURL
        }

        components.scheme = scheme
        components.host = host.lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "" : "/\(path)"
        guard let normalized = components.string, !normalized.isEmpty else {
            throw ValidationError.invalidBaseURL
        }
        return normalized
    }
}
