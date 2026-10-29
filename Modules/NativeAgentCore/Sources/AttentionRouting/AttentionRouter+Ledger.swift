import Foundation
import CryptoKit
import DeviceSync
import PersistenceCore
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import TelegramBot
import Experiences
import Transcripts
// Blueprint: | `AttentionRouter+Ledger.swift` | `AttentionRouter.State` deduplication ledger, event/reason digests, checked damaged-ledger reads and bounded durable persistence |

extension AttentionRouter {
    struct State: Codable {
        /// Event id → digest of the reason it was last delivered under.
        var reasons: [String: String]
        /// Insertion order, oldest first. Bounds the ledger.
        var order: [String]

        static let empty = State(reasons: [:], order: [])

        mutating func remember(eventId: String, digest: String, limit: Int) {
            if reasons[eventId] == nil { order.append(eventId) }
            reasons[eventId] = digest
            if order.count > limit { dropOldest(order.count - limit) }
        }

        mutating func dropOldest(_ count: Int) {
            guard count > 0 else { return }
            let evicted = order.prefix(count)
            for old in evicted { reasons.removeValue(forKey: old) }
            order.removeFirst(evicted.count)
        }
    }

    /// What the ledger says was delivered, event id → reason digest. The `app`
    /// door diffs it around one action to report the knocks that action set off.
    /// Delivered knocks by key: none when the ledger was never written; a
    /// ledger that does not read or decode throws, never reads as none.
    public static func deliveredKnocks(dataRoot: URL) throws -> [String: String] {
        let url = dataRoot.appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("attention_router.json")
        let data: Data
        do { data = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return [:] }
        return try JSONDecoder().decode(State.self, from: data).reasons
    }

    /// Well above any live burst; the ledger is a dedupe window, not history.
    static let ledgerLimit = 500

    /// Evict oldest entries until the encoded ledger fits, independently of the entry-count cap.
    static let ledgerMaxBytes = 128 * 1024

    private var stateURL: URL {
        dataRoot
            .appendingPathComponent("notify", isDirectory: true)
            .appendingPathComponent("attention_router.json")
    }

    /// A canonical device event id, so the relay and the phone carry it as is.
    static func knockIdentity(_ event: String, _ version: String) -> String {
        SHA256.hash(data: Data((event + ":" + version).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// CHECKED read. A missing ledger is the only empty one. An unreadable
    /// or damaged ledger is not "nothing was delivered": routing throws its
    /// cause, so no event knocks again on invented history. Damaged bytes stay
    /// at their canonical path until repaired.
    func load() async throws -> State {
        if let cached { return cached }
        let data: Data
        do { data = try Data(contentsOf: stateURL) }
        catch where MacSyncEngine.isNoSuchFileError(error) { return .empty }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            cached = state
            return state
        } catch {
            throw NSError(domain: "AttentionRouter", code: -2, userInfo: [NSLocalizedDescriptionKey:
                "AttentionRouter could not decode \(stateURL.path): \(error.localizedDescription). History is unknown; bytes remain in place. Nothing was sent.", NSUnderlyingErrorKey: error])
        }
    }

    /// Encode under BOTH budgets: `ledgerLimit` has already bounded the entry
    /// count; this evicts the OLDEST entries until the encoding fits
    /// `ledgerMaxBytes`. The newest entry is always kept, so a single
    /// pathological event id can never leave an empty ledger behind.
    private static func encodeWithinByteCap(
        _ state: State,
        maxBytes: Int = ledgerMaxBytes
    ) throws -> (state: State, data: Data) {
        var trimmed = state
        let encoder = JSONEncoder()
        var data = try encoder.encode(trimmed)
        while data.count > maxBytes, trimmed.order.count > 1 {
            trimmed.dropOldest(max(1, trimmed.order.count / 10))
            data = try encoder.encode(trimmed)
        }
        return (trimmed, data)
    }

    func persist(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let capped = try Self.encodeWithinByteCap(state)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(capped.data, to: stateURL)
        cached = capped.state
    }
}
