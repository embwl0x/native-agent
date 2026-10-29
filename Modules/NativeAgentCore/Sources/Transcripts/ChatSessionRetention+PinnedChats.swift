import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import CryptoKit
import os
// Blueprint: | `ChatSessionRetention+PinnedChats.swift` | Pinned-chat preferences and retention mirror; mirror writes precede defaults publication, and unreadable protection halts retention |

extension ChatSessionRetention {
    public static let macPinnedSessionIdsDefaultsKey = "NativeAgent.pinnedChatSessionIds"

    // Storage: pinned_session_ids.json mirrors the Mac preference for retention.
    // Local backup/data export exclude it; off-disk backup includes it. Phone
    // pins project the host preference, not this file. PrivacyMap: chat.

    /// Distinguish a closed pin from invalid or already-unpinned requests.
    public enum CloseResult: Equatable {
        case closed(encoded: String)
        case refusedInvalidSessionID
        case refusedAlreadyUnpinned
    }

    public nonisolated static func decode(_ raw: String) -> [String] {
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids: [String]
        if let data = cleanRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = cleanRaw.split(separator: "|").map(String.init)
        }
        return cleanedSessionIds(ids)
    }

    @MainActor
    public static func load(defaults: UserDefaults = .standard) -> [String] {
        decode(defaults.string(forKey: macPinnedSessionIdsDefaultsKey) ?? "")
    }

    /// Publish defaults only after the retention mirror is written.
    @discardableResult
    @MainActor
    public static func save(
        _ ids: [String],
        defaults: UserDefaults = .standard,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> String {
        let clean = cleanedSessionIds(ids)
        try ChatSessionRetention.saveMacPinnedChatSessionIds(clean, dataRoot: dataRoot)
        let data = try JSONEncoder().encode(clean)
        let encoded = String(decoding: data, as: UTF8.self)
        defaults.set(encoded, forKey: macPinnedSessionIdsDefaultsKey)
        return encoded
    }

    /// Close through the mirror-first transaction; a failed write leaves the pin visible.
    @MainActor
    public static func closePinnedTab(
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

    @discardableResult
    @MainActor
    public static func request(
        encodedPinnedIDs: String,
        defaults: UserDefaults = .standard,
        publish: ([String]) -> Void
    ) -> Bool {
        let requested = decode(encodedPinnedIDs)
        let persisted = load(defaults: defaults)
        guard requested == persisted else { return false }
        publish(persisted)
        return true
    }

    public static func saveMacPinnedChatSessionIds(
        _ ids: [String],
        dataRoot: URL = defaultDataRoot()
    ) throws {
        let clean = cleanedSessionIds(ids)
        let path = macPinnedSessionIdsPath(dataRoot: dataRoot)
        let payload = try JSONValue.array(clean.map { .string($0) }).serializedData(pretty: true)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(payload, to: path)
    }

    static func macPinnedChatSessionIds(dataRoot: URL) throws -> Set<String> {
        var protected = try sharedMacPinnedChatSessionIds(dataRoot: dataRoot)
        protected.formUnion(decode(UserDefaults.standard.string(forKey: macPinnedSessionIdsDefaultsKey) ?? ""))
        return protected
    }

    private static func sharedMacPinnedChatSessionIds(dataRoot: URL) throws -> Set<String> {
        let path = macPinnedSessionIdsPath(dataRoot: dataRoot)
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        // An unreadable or newer pin format is not an empty pin list. Stop
        // retention before moving any conversation whose protection is unknown.
        guard case .array(let values) = try JSONValue.parse(data) else {
            throw PersistenceCoreError.ioFailure("I couldn’t read your pinned chats. I’ve left your conversations in place.")
        }
        return Set(try values.map { value in
            guard case .string(let id) = value else {
                throw PersistenceCoreError.ioFailure("I couldn’t read your pinned chats. I’ve left your conversations in place.")
            }
            let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean
        })
    }

    private static func macPinnedSessionIdsPath(dataRoot: URL) -> URL {
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
