import Foundation
import PersistenceCore
// Blueprint: | `ChatSessionRetention+PinnedChats.swift` | One durable ordered pin list for navigation, retention and phone publication; unreadable protection halts retention |

extension ChatSessionRetention {
    // Storage: pinned_session_ids.json owns the ordered Mac pin list.
    // Local backup/data export exclude it; off-disk backup includes it. Phone
    // pins project this same owner through the host. PrivacyMap: chat.

    /// Distinguish a closed pin from invalid or already-unpinned requests.
    public enum CloseResult: Equatable {
        case closed(encoded: String)
        case refusedInvalidSessionID
        case refusedAlreadyUnpinned
    }

    public nonisolated static func decode(_ raw: String) throws -> [String] {
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = try JSONDecoder().decode([String].self, from: Data(cleanRaw.utf8))
        return cleanedSessionIds(ids)
    }

    public static func load(dataRoot: URL = defaultDataRoot()) throws -> [String] {
        let bytes: Data
        do { bytes = try Data(contentsOf: macPinnedSessionIdsPath(dataRoot: dataRoot)) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return cleanedSessionIds(try JSONDecoder().decode([String].self, from: bytes))
    }

    /// The durable list is committed before a caller publishes its derived view.
    @discardableResult
    @MainActor
    public static func save(
        _ ids: [String],
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> String {
        let clean = cleanedSessionIds(ids)
        let data = try JSONEncoder().encode(clean)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: macPinnedSessionIdsPath(dataRoot: dataRoot))
        let encoded = String(decoding: data, as: UTF8.self)
        return encoded
    }

    /// Close through the durable owner; a failed write leaves the pin visible.
    @MainActor
    public static func closePinnedTab(
        sessionID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> CloseResult {
        let cleanSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSessionID.isEmpty else {
            return .refusedInvalidSessionID
        }

        let current = try load(dataRoot: dataRoot)
        guard current.contains(cleanSessionID) else {
            return .refusedAlreadyUnpinned
        }

        return .closed(encoded: try save(
            current.filter { $0 != cleanSessionID },
            dataRoot: dataRoot
        ))
    }

    @discardableResult
    @MainActor
    public static func request(
        encodedPinnedIDs: String,
        dataRoot: URL = defaultDataRoot(),
        publish: ([String]) -> Void
    ) -> Bool {
        let requested: [String], persisted: [String]
        do {
            requested = try decode(encodedPinnedIDs)
            persisted = try load(dataRoot: dataRoot)
        } catch { return false }
        guard requested == persisted else { return false }
        publish(persisted)
        return true
    }

    static func macPinnedChatSessionIds(dataRoot: URL) throws -> Set<String> {
        Set(try load(dataRoot: dataRoot))
    }

    public static func macPinnedSessionIdsPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("pinned_session_ids.json")
    }

    private static func cleanedSessionIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id -> String? in
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

}
