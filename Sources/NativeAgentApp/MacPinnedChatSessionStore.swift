import Foundation
import PersistenceCore

/// The one Mac-side mutation seam for the ordered pinned-chat strip.
///
/// `UserDefaults` remains the reactive UI value used by `@AppStorage`, while
/// PersistenceCore's mirrored file protects the same sessions from retention.
/// Callers must update both through this type so the Mac UI, retention, and the
/// iOS snapshot cannot drift into separate pin owners.
@MainActor
enum MacPinnedChatSessionStore {
    static let defaultsKey = ChatSessionRetention.macPinnedSessionIdsDefaultsKey

    /// The concrete outcome of a pinned-tab close request. Keeping refusal
    /// separate from success lets the mounted control show an honest outcome
    /// when another surface has already removed a pin.
    enum CloseResult: Equatable {
        case closed(encoded: String)
        case refusedInvalidSessionID
        case refusedAlreadyUnpinned
    }

    nonisolated static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id -> String? in
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    nonisolated static func decode(_ raw: String) -> [String] {
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids: [String]
        if let data = cleanRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = cleanRaw.split(separator: "|").map(String.init)
        }
        return normalized(ids)
    }

    static func load(defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: defaultsKey) ?? "")
    }

    /// Persists the retention mirror before publishing the reactive defaults
    /// value. A failed disk write therefore cannot make the UI claim a pin
    /// state that retention did not record.
    @discardableResult
    static func save(
        _ ids: [String],
        defaults: UserDefaults = .standard,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> String {
        let clean = normalized(ids)
        try ChatSessionRetention.saveMacPinnedChatSessionIds(clean, dataRoot: dataRoot)
        let data = try JSONEncoder().encode(clean)
        let encoded = String(decoding: data, as: UTF8.self)
        defaults.set(encoded, forKey: defaultsKey)
        return encoded
    }

    /// Removes one pin through the same mirror-first transaction used by every
    /// pinned-session mutation. If the retention mirror cannot be written,
    /// `save` throws before it changes `UserDefaults`, leaving the visible tab
    /// pinned now and after the next reload.
    static func closePinnedTab(
        sessionID: String,
        defaults: UserDefaults = .standard,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> CloseResult {
        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else {
            return .refusedInvalidSessionID
        }

        let current = load(defaults: defaults)
        guard current.contains(cleanSessionID) else {
            return .refusedAlreadyUnpinned
        }

        return .closed(encoded: try save(
            current.filter { $0 != cleanSessionID },
            defaults: defaults,
            dataRoot: dataRoot
        ))
    }
}
