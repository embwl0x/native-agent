import AuthoredCapabilities
import Foundation
import Senses
import AgentWorkspace
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TurnTrace
import Transcripts
import Desk
import Experiences
import PersonaEngine
import MemoryV2
import ProviderRouting
import TrustCenter
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate
import Context
import ToolRegistry
import StandingBots
import ChatToolParsing
import NativeAgentShared
// Blueprint: | `ChatTurnEvidence.swift` | Produced turn evidence and durable answer/owner-turn stamps; records retain their existing locks and formats |

struct ProducedChatTurn: Sendable {
    let result: TurnEngineResult
    let context: TurnContext
    let personaFingerprint: String
    let attachments: [MultimodalAttachment]
    let answerID: String
}

/// Verified owner turns advance the current/previous stamp once per turn under its file lock.
public enum UserTurnStamp {
    struct Stamp: Codable { var at: Double; var previous: Double?; var key: String }

    static func url(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("cognition/user_turn.json") }

    private static func read(_ dataRoot: URL) throws -> Stamp? {
        let data: Data
        do { data = try Data(contentsOf: url(dataRoot)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        let stamp = try JSONDecoder().decode(Stamp.self, from: data)
        guard stamp.at.isFinite, !stamp.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              stamp.previous.map({ $0.isFinite && $0 <= stamp.at }) ?? true else {
            throw ToolFailureError("The conversation turn stamp has invalid timestamps or identity.", effects: .none)
        }
        return stamp
    }

    private static let operation = "cognition.turn-stamp"

    private static func unavailable(_ dataRoot: URL, _ error: any Error) {
        nativeLog("UserTurnStamp unavailable; original bytes preserved: %@", error.localizedDescription)
        // One debt for the one damaged file: every read of it owes the same repair.
        RepairOwed.owe(dataRoot, id: "turn-stamp:" + url(dataRoot).path, kind: .run,
            operation: operation, owner: "Conversation turn stamp", words: error.localizedDescription,
            tap: ToolFailureError.fileRepairInstruction(url(dataRoot),
                shape: "The JSON stamp must retain its actual at timestamp, optional previous timestamp and turn key."))
    }

    private static func reportedRead(_ dataRoot: URL) -> Stamp? {
        do { return try read(dataRoot) }
        catch { unavailable(dataRoot, error); return nil }
    }

    public static func record(dataRoot: URL, key: String, at date: Date = Date()) {
        let url = url(dataRoot)
        do {
            let keptKey = try CredentialFileLock.withLock(url) {
                let old = try read(dataRoot)
                if let old, old.key == key { return old.key }
                // Keep even a delayed event in pending offers, but never let its older timestamp replace a newer conversation stamp.
                try ReachAnswerSettlement.record(dataRoot: dataRoot, turn: date, now: date)
                if var old, date.timeIntervalSince1970 < old.at {
                    if old.previous.map({ date.timeIntervalSince1970 > $0 }) ?? true {
                        old.previous = date.timeIntervalSince1970
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(old), to: url)
                    }
                    return old.key
                }
                let stamp = Stamp(at: date.timeIntervalSince1970, previous: old?.at, key: key)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(stamp), to: url)
                return stamp.key
            }
            RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: url.path, id: keptKey))
        } catch {
            unavailable(dataRoot, error)
        }
    }

    /// His latest verified turn (this one, while it runs).
    public static func last(dataRoot: URL) -> Date? {
        reportedRead(dataRoot).map { Date(timeIntervalSince1970: $0.at) }
    }

    /// The verified turn before his latest: where a gap this turn closes opened.
    public static func previous(dataRoot: URL) -> Date? {
        reportedRead(dataRoot)?.previous.map { Date(timeIntervalSince1970: $0) }
    }
}

/// The answer fields of the existing Reach ledger, shared by its codec and the verified-turn boundary. All other offer fields pass through unchanged. The ledger lock also prevents a runtime snapshot from erasing a turn's proof.
package enum ReachAnswerSettlement {
    /// A return within one day is the structural answer fact, not a judgment of the response's meaning. This is Reach's existing answer window.
    package static let window: TimeInterval = 24 * 3_600

    private static func url(_ root: URL) -> URL { root.appendingPathComponent("cognition/reach.json") }

    package static func record(dataRoot: URL, turn: Date? = nil, now: Date) throws {
        try update(dataRoot: dataRoot, proposed: nil, turn: turn, now: now)
    }

    package static func write(_ data: Data, dataRoot: URL) throws {
        try update(dataRoot: dataRoot, proposed: data, turn: nil, now: nil)
    }

    private static func update(dataRoot: URL, proposed: Data?, turn: Date?, now: Date?) throws {
        let path = url(dataRoot)
        try CredentialFileLock.withLock(path) {
            let current = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
            guard let data = proposed ?? current else { return }
            func ledger(_ data: Data) throws -> [String: JSONValue] {
                guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
                      case .array? = object["offers"] else {
                    throw CocoaError(.coderReadCorrupt)
                }
                return object
            }
            func epoch(_ value: JSONValue?) -> Double? {
                switch value {
                case .double(let value)?: return value.isFinite ? value : nil
                case .int(let value)?: return Double(value)
                default: return nil
                }
            }
            let original = try ledger(data)
            var object = original
            guard case .array(var offers)? = object["offers"] else { return }
            let previous = try current.map(ledger)
            let priorOffers: [JSONValue]
            if case .array(let rows)? = previous?["offers"] { priorOffers = rows } else { priorOffers = [] }
            for index in offers.indices {
                guard case .object(var offer) = offers[index], case .string(let id)? = offer["id"] else {
                    throw CocoaError(.coderReadCorrupt)
                }
                if let prior = priorOffers.first(where: {
                    if case .object(let row) = $0 { return row["id"] == .string(id) }; return false
                }), case .object(let row) = prior {
                    // A stale runtime snapshot never replaces durable answer evidence.
                    for key in ["answered", "answeredAt"] where row[key] != nil && row[key] != .null { offer[key] = row[key] }
                }
                if let sent = epoch(offer["sentAt"]),
                   offer["outcome"] == .string("sent") || offer["outcome"] == .string("sending") {
                    if let turn, turn.timeIntervalSince1970 > sent,
                       turn.timeIntervalSince1970 - sent <= window {
                        let first = min(epoch(offer["answeredAt"]) ?? turn.timeIntervalSince1970, turn.timeIntervalSince1970)
                        offer["answeredAt"] = .double(first)
                    }
                    // An uncertain delivery retains the event but cannot yet land an answer. Confirmation uses that same saved event.
                    if offer["outcome"] == .string("sent") {
                        if let answered = epoch(offer["answeredAt"]), answered > sent, answered - sent <= window {
                            offer["answered"] = .bool(true)
                        } else if offer["answered"] == nil || offer["answered"] == .null,
                                  let now, now.timeIntervalSince1970 - sent > window {
                            offer["answered"] = .bool(false)
                        }
                    }
                }
                offers[index] = .object(offer)
            }
            object["offers"] = .array(offers)
            if proposed != nil || object != original {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(JSONValue.object(object)), to: path)
            }
        }
    }
}
