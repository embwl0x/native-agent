import Foundation
import NativeAgentShared
import AgentWorkspace
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DelegationOutcomeCursor.swift` | Exact durable handled identities and receipt versions; advances only after corresponding card settlement |
/// Exact handled identities; completion timestamps never prove receipt arrival.
public struct DelegationOutcomeCursor: Sendable, Equatable {
    public struct StoreCursor: Sendable, Equatable {
        /// Upgrade-only boundary for history older cursors no longer retained by id.
        var legacyLastSeen: Date?
        /// Exact handled job ids, retained while receipts can reappear.
        public var cardedIDs: Set<String>
        public var deliveryReceiptVersions: [String: String] = [:]
        /// The outcome each id was carded UNDER (raw `DelegationOutcome`), so a
        /// job that later presents a more alarming outcome is carded again.
        /// Ids recorded before this field existed have no entry and never
        /// re-card — the cursor cannot prove what their card said.
        public var cardedOutcomes: [String: String]
        /// Open jobs whose stalled liveness warning has landed. Unlike
        /// terminal outcome ids, these are removed after a proven recovery so
        /// a later stall can speak again.
        public var announcedStallIDs: [String]

        public init(cardedIDs: Set<String> = [],
                    cardedOutcomes: [String: String] = [:],
                    announcedStallIDs: [String] = []) {
            self.cardedIDs = cardedIDs
            self.cardedOutcomes = cardedOutcomes
            self.announcedStallIDs = announcedStallIDs
        }
    }
    /// Keyed by store source id (for example "claude", "codex", or "omp").
    public var stores: [String: StoreCursor]
    public init(stores: [String: StoreCursor] = [:]) {
        self.stores = stores
    }
    /// Bounds reversible liveness warnings, not terminal receipt identities.
    public static let cardedIDLimit = 500

    public func store(_ source: String) -> StoreCursor {
        stores[source] ?? StoreCursor()
    }
    public mutating func record(source: String, id: String,
                                outcome: DelegationOutcome? = nil,
                                deliveryReceiptVersion: String? = nil) {
        stores[source, default: StoreCursor()].cardedIDs.insert(id)
        if let deliveryReceiptVersion { stores[source, default: StoreCursor()].deliveryReceiptVersions[id] = deliveryReceiptVersion }
        if let outcome { stores[source, default: StoreCursor()].cardedOutcomes[id] = outcome.rawValue }
    }
    /// The outcome `id` was carded under, when the cursor recorded one.
    public func cardedOutcome(source: String, id: String) -> DelegationOutcome? {
        store(source).cardedOutcomes[id].flatMap(DelegationOutcome.init(rawValue:))
    }
    public mutating func markStallAnnounced(source: String, id: String) {
        var cursor = store(source)
        if !cursor.announcedStallIDs.contains(id) {
            cursor.announcedStallIDs.append(id)
            if cursor.announcedStallIDs.count > Self.cardedIDLimit {
                cursor.announcedStallIDs.removeFirst(
                    cursor.announcedStallIDs.count - Self.cardedIDLimit)
            }
        }
        stores[source] = cursor
    }
    public mutating func clearStallAnnouncement(source: String, id: String) {
        var cursor = store(source)
        cursor.announcedStallIDs.removeAll { $0 == id }
        stores[source] = cursor
    }
    // Codable synthesis would silently rename the keys if a field is renamed).

    public static func load(from url: URL) throws -> DelegationOutcomeCursor? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let parsed = try JSONValue.parse(data)
        guard
              case .object(let root) = parsed,
              root["version"] == .int(1),
              case .object(let stores)? = root["stores"] else { throw CocoaError(.fileReadCorruptFile) }
        func strings(_ value: JSONValue?) throws -> [String] {
            guard let value else { return [] }
            guard case .array(let values) = value else { throw CocoaError(.fileReadCorruptFile) }
            return try values.map {
                guard case .string(let string) = $0, !string.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return string
            }
        }
        func dictionary(_ value: JSONValue?) throws -> [String: String] {
            guard let value else { return [:] }
            guard case .object(let values) = value else { throw CocoaError(.fileReadCorruptFile) }
            return try values.mapValues {
                guard case .string(let string) = $0 else { throw CocoaError(.fileReadCorruptFile) }
                return string
            }
        }
        var result = DelegationOutcomeCursor()
        for (source, value) in stores {
            guard case .object(let obj) = value else { throw CocoaError(.fileReadCorruptFile) }
            var cursor = StoreCursor()
            if let value = obj["last_seen"] {
                guard case .string(let iso) = value, let date = parseISO(iso) else { throw CocoaError(.fileReadCorruptFile) }
                cursor.legacyLastSeen = date
            }
            cursor.cardedIDs = Set(try strings(obj["carded_ids"]))
            cursor.cardedOutcomes = try dictionary(obj["carded_outcomes"])
            guard cursor.cardedOutcomes.values.allSatisfy({ DelegationOutcome(rawValue: $0) != nil })
            else { throw CocoaError(.fileReadCorruptFile) }
            cursor.deliveryReceiptVersions = try dictionary(obj["delivery_receipt_versions"])
            cursor.announcedStallIDs = try strings(obj["announced_stall_ids"])
            result.stores[source] = cursor
        }
        return result
    }
    public func toJSON() -> JSONValue {
        var stores: [String: JSONValue] = [:]
        for (source, cursor) in self.stores {
            var obj: [String: JSONValue] = [
                "carded_ids": .array(cursor.cardedIDs.sorted().map { .string($0) }),
            ]
            if let boundary = cursor.legacyLastSeen { obj["last_seen"] = .string(Self.formatISO(boundary)) }
            if !cursor.cardedOutcomes.isEmpty {
                var outcomes: [String: JSONValue] = [:]
                for (id, raw) in cursor.cardedOutcomes { outcomes[id] = .string(raw) }
                obj["carded_outcomes"] = .object(outcomes)
            }
            if !cursor.deliveryReceiptVersions.isEmpty {
                obj["delivery_receipt_versions"] = .object(cursor.deliveryReceiptVersions.mapValues { .string($0) })
            }
            if !cursor.announcedStallIDs.isEmpty {
                obj["announced_stall_ids"] = .array(
                    cursor.announcedStallIDs.map { .string($0) })
            }
            stores[source] = .object(obj)
        }
        return .object([
            "version": .int(1),
            "stores": .object(stores),
        ])
    }
    /// Atomic write — a torn cursor would either re-card everything or skip a
    /// window, and both are user-visible.
    public func write(to url: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(toJSON().serializedData(pretty: false), to: url)
    }
    /// Both bridge writers emit `new Date().toISOString()`; the no-fraction
    /// variant is the fallback for hand-edited or older records.
    public static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(iso)
    }
    public static func formatISO(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}
