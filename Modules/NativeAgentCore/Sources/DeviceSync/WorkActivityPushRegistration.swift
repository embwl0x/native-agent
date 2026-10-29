import CryptoKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `WorkActivityPushRegistration.swift` | Work-activity push registration, start reservation state and pairing fingerprints with unchanged saved Codable keys |
struct WorkActivityPushRegistration: Codable, Equatable, Sendable {
    enum StartOutcome: String, Codable, Sendable {
        case unknown, accepted, observed, notObserved
    }
    struct StartReservation: Codable, Equatable, Sendable {
        var retainedAt: Date
        var expiresAt: Date
    }
    var pairing: String
    var environment: String
    var bundleID: String
    var enabled = false
    var startToken: String?
    var activityTokens: [String: String] = [:]
    var lastContents: [String: MobileWorkActivity.ContentState] = [:]
    var startedIDs: Set<String> = []
    // Optional so registrations saved before start reservations remain readable.
    var startOutcomes: [String: StartOutcome]?
    var startReservations: [String: StartReservation]?

    mutating func retireInactiveStarts(activeIDs: Set<String>, now: Date) {
        if startReservations == nil { startReservations = [:] }
        // Adopt legacy reservations into retention once; their start time is unknown.
        for id in startedIDs where startReservations?[id] == nil {
            startReservations?[id] = StartReservation(retainedAt: now,
                                                     expiresAt: lastContents[id]?.updatedAt.addingTimeInterval(5 * 60) ?? now)
        }
        let retired = (startReservations ?? [:]).filter {
            activityTokens[$0.key] == nil && !activeIDs.contains($0.key)
                && $0.value.retainedAt < now.addingTimeInterval(-86400) && $0.value.expiresAt < now
        }.map(\.key)
        for id in retired {
            lastContents.removeValue(forKey: id)
            startedIDs.remove(id)
            startOutcomes?.removeValue(forKey: id)
            startReservations?.removeValue(forKey: id)
        }
    }
    static func fingerprint(_ pairing: String) -> String {
        SHA256.hash(data: Data(pairing.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ value: JSONValue?) throws -> Self? {
        guard let value else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(value.serialize(pretty: false).utf8))
    }
}
