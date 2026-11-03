import Foundation
import CryptoKit
// Blueprint: | `NotificationDeliveryLedger.swift` | Immutable notification occurrences and one flock-serialized per-destination delivery ledger; attempt-matched settlement, supersession and signed phone acknowledgements |

/// The only delivery verdict, shared by native banners and external clients.
/// `delivered` means the named destination accepted it (not that a person read it).
public enum NotificationDeliveryOutcome: Codable, Sendable, Equatable {
    case delivered
    case notDelivered(reason: String)
    case suppressed(preference: String)
    case unknown(sent: Bool, reason: String)

    public var mayAttempt: Bool {
        if case .notDelivered = self { return true }
        return false
    }

    public var settled: Bool {
        switch self {
        case .delivered, .suppressed: return true
        case .notDelivered, .unknown: return false
        }
    }
}

/// A transport can throw this without losing its classified outcome at a host port.
public struct NotificationDeliveryFailure: Error, LocalizedError, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let errorDescription: String?
    public init(_ outcome: NotificationDeliveryOutcome, _ description: String) {
        self.outcome = outcome
        self.errorDescription = description
    }
}

public struct NotificationOccurrence: Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String
    public let sourceRevision: String?
    public let honorsQuietHours: Bool
    public let eventID: String
    public let cardID: String?
    public let title: String
    public let body: String
    public let reason: String
    public let userInfo: [String: String]
    public let importance: String
    public let route: String
    public let origin: Data?
    public let soundName: String?
    public let destinations: [String]

    public init(eventID: String, cardID: String?, title: String, body: String, reason: String,
                userInfo: [String: String], importance: String, route: String, origin: Data? = nil,
                soundName: String? = nil, destinations: [String], commandID: String? = nil, sourceRevision: String? = nil,
                honorsQuietHours: Bool = true) throws {
        self.sourceRevision = sourceRevision
        self.honorsQuietHours = honorsQuietHours
        self.eventID = eventID; self.cardID = cardID; self.title = title; self.body = body
        self.reason = reason; self.userInfo = userInfo; self.importance = importance
        self.route = route; self.origin = origin; self.soundName = soundName
        self.destinations = destinations.sorted()
        // All immutable content participates. A changed stable card is a new occurrence.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity: [String: JSONValue] = [
            "event": .string(eventID), "card": cardID.map(JSONValue.string) ?? .null,
            "title": .string(title), "body": .string(body), "reason": .string(reason),
            "info": .object(userInfo.mapValues(JSONValue.string)), "importance": .string(importance),
            "route": .string(route), "origin": origin.map { .string($0.base64EncodedString()) } ?? .null,
            "sound": soundName.map(JSONValue.string) ?? .null,
            "destinations": .array(self.destinations.map(JSONValue.string)),
            "command": commandID.map(JSONValue.string) ?? .null,
            "sourceRevision": sourceRevision.map(JSONValue.string) ?? .null,
            "honorsQuietHours": .bool(honorsQuietHours),
        ]
        self.fingerprint = Self.digest(try encoder.encode(identity))
        self.id = Self.digest(Data(UUID().uuidString.utf8))
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct NotificationDeliveryLedger: Sendable {
    public struct Row: Codable, Sendable, Equatable {
        public var outcome: NotificationDeliveryOutcome
        public var attemptID: String?
    }
    public struct Entry: Codable, Sendable, Equatable {
        public let occurrence: NotificationOccurrence
        public var supersededBy: String?
        public var rows: [String: Row]
        public var retainedPhoneEventID: String?
    }
    public struct State: Codable, Sendable, Equatable {
        public var entries: [String: Entry] = [:]
        public var current: [String: String] = [:]
        /// Retained inbox intents are consumed once; they never replay over a newer occurrence.
        public var imported: [String: String] = [:]
        public init() {}
    }
    public struct Claim: Sendable {
        public let occurrence: NotificationOccurrence
        public let destination: String
        public let attemptID: String
    }

    public let path: URL
    public init(dataRoot: URL) {
        path = dataRoot.appendingPathComponent("notify/deliveries.json")
    }

    public func read() throws -> State {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return State() }
        let state = try JSONDecoder().decode(State.self, from: data)
        for (key, entry) in state.entries {
            guard key == entry.occurrence.id, Set(entry.rows.keys) == Set(entry.occurrence.destinations) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for (event, id) in state.current {
            guard let entry = state.entries[id], entry.occurrence.eventID == event, entry.supersededBy == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return state
    }

    private func change<T: Sendable>(_ update: @escaping @Sendable (inout State) throws -> T) async throws -> T {
        try await SwiftNativePersistenceCore.withFileLock(path, waitingAtMost: 5) {
            var state = try read()
            let before = state
            let result = try update(&state)
            if state != before {
                try SwiftNativePersistenceCore.writeDataAtomicDurable(try JSONEncoder().encode(state), to: path)
            }
            return result
        }
    }

    /// `importKey` names a current/retained inbox intent, not mutable delivery state.
    /// A previously consumed intent may never make an older occurrence current again.
    @discardableResult
    public func retain(_ occurrence: NotificationOccurrence, importKey: String? = nil,
                       consumedImports: Set<String> = [], priorOutcome: NotificationDeliveryOutcome? = nil,
                       isCurrent: @escaping @Sendable () -> Bool = { true }) async throws -> String {
        try await change { state in
            guard isCurrent() else { throw CocoaError(.userCancelled) }
            if let importKey, let id = state.imported[importKey] { return id }
            if let current = state.current[occurrence.eventID],
               state.entries[current]?.occurrence.fingerprint == occurrence.fingerprint {
                for key in consumedImports { state.imported[key] = current }
                if let importKey { state.imported[importKey] = current }
                return current
            }
            let first = state.current[occurrence.eventID] == nil
            for key in consumedImports { state.imported[key] = occurrence.id }
            if let importKey { state.imported[importKey] = occurrence.id }
            if let old = state.current[occurrence.eventID] {
                state.entries[old]?.supersededBy = occurrence.id
            }
            state.current[occurrence.eventID] = occurrence.id
            let retainedReceipt = first && priorOutcome != nil && occurrence.destinations.contains("phone")
                ? NotificationOccurrence.digest(Data((occurrence.eventID + ":" + Self.reasonDigest(occurrence.reason)).utf8)) : nil
            state.entries[occurrence.id] = Entry(occurrence: occurrence, rows: Dictionary(uniqueKeysWithValues:
                occurrence.destinations.map { ($0, Row(outcome: first ? (priorOutcome ?? .notDelivered(reason: "pending")) : .notDelivered(reason: "pending"))) }),
                retainedPhoneEventID: retainedReceipt)
            return occurrence.id
        }
    }

    /// Admission and durable unknown reservation precede the effect. No await of a
    /// transport holds the lock. A crash leaves unknown, which cannot be resent.
    public func claim(_ id: String, destination: String, suppressedBy: String? = nil) async throws -> Claim? {
        try await change { state in
            guard var entry = state.entries[id], entry.supersededBy == nil,
                  state.current[entry.occurrence.eventID] == id,
                  var row = entry.rows[destination] else { return nil }
            if let suppressedBy, row.outcome != .delivered {
                // A preference closes new admission; it cannot rewrite an
                // already admitted send as though no effect could have left.
                if case .unknown = row.outcome { return nil }
                let outcome = NotificationDeliveryOutcome.suppressed(preference: suppressedBy)
                if row.outcome != outcome {
                    row.attemptID = nil
                    row.outcome = outcome; entry.rows[destination] = row; state.entries[id] = entry
                }
                return nil
            }
            guard row.outcome.mayAttempt else { return nil }
            let attempt = UUID().uuidString.lowercased()
            row.attemptID = attempt
            row.outcome = .unknown(sent: false, reason: "dispatch reserved; outcome unconfirmed")
            entry.rows[destination] = row; state.entries[id] = entry
            return Claim(occurrence: entry.occurrence, destination: destination, attemptID: attempt)
        }
    }

    public func finish(_ claim: Claim, outcome: NotificationDeliveryOutcome) async throws {
        try await change { state in
            guard var entry = state.entries[claim.occurrence.id],
                  var row = entry.rows[claim.destination], row.attemptID == claim.attemptID else { return }
            // A signed phone receipt can arrive before the transport returns.
            guard row.outcome != .delivered else { return }
            row.outcome = outcome
            entry.rows[claim.destination] = row; state.entries[claim.occurrence.id] = entry
        }
    }

    public func confirmPhone(_ ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        try await change { state in
            for id in Array(state.entries.keys) {
                guard var entry = state.entries[id],
                      ids.contains(id) || entry.retainedPhoneEventID.map(ids.contains) == true,
                      var row = entry.rows["phone"] else { continue }
                // Receipt names the immutable occurrence, including when superseded.
                row.outcome = .delivered
                entry.rows["phone"] = row; state.entries[id] = entry
            }
        }
    }

    private static func reasonDigest(_ reason: String) -> String {
        SHA256.hash(data: Data(reason.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
