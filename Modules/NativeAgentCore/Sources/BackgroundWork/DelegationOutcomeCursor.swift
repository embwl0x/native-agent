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
        /// Exact handled job ids, retained while receipts can reappear.
        public var cardedIDs: Set<String>
        public var deliveryReceiptVersions: [String: String] = [:]
        /// Recorded outcome enables escalation; without it the cursor cannot prove the card’s severity.
        public var cardedOutcomes: [String: String]

        public init(cardedIDs: Set<String> = [],
                    cardedOutcomes: [String: String] = [:]) {
            self.cardedIDs = cardedIDs
            self.cardedOutcomes = cardedOutcomes
        }
    }
    public var stores: [String: StoreCursor]
    public init(stores: [String: StoreCursor] = [:]) {
        self.stores = stores
    }
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
    public func cardedOutcome(source: String, id: String) -> DelegationOutcome? {
        store(source).cardedOutcomes[id].flatMap(DelegationOutcome.init(rawValue:))
    }
    // Keep persisted wire keys explicit so property renames cannot silently change storage.

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
            cursor.cardedIDs = Set(try strings(obj["carded_ids"]))
            cursor.cardedOutcomes = try dictionary(obj["carded_outcomes"])
            guard cursor.cardedOutcomes.values.allSatisfy({ DelegationOutcome(rawValue: $0) != nil })
            else { throw CocoaError(.fileReadCorruptFile) }
            cursor.deliveryReceiptVersions = try dictionary(obj["delivery_receipt_versions"])
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
            if !cursor.cardedOutcomes.isEmpty {
                var outcomes: [String: JSONValue] = [:]
                for (id, raw) in cursor.cardedOutcomes { outcomes[id] = .string(raw) }
                obj["carded_outcomes"] = .object(outcomes)
            }
            if !cursor.deliveryReceiptVersions.isEmpty {
                obj["delivery_receipt_versions"] = .object(cursor.deliveryReceiptVersions.mapValues { .string($0) })
            }
            stores[source] = .object(obj)
        }
        return .object([
            "version": .int(1),
            "stores": .object(stores),
        ])
    }
    /// Atomic writes prevent torn cursors from skipping outcomes or repeating every card.
    public func write(to url: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(toJSON().serializedData(pretty: false), to: url)
    }
    /// Accept ISO instants with or without fractional seconds.
    public static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(iso)
    }
    public static func formatISO(_ date: Date) -> String {
        NativeTimestampFormat.fractionalZulu(date)
    }
}
