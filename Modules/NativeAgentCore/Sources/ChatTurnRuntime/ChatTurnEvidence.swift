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
// Blueprint: | `ChatTurnEvidence.swift` | Produced turn evidence and the durable owner-turn stamp; records retain their existing locks and formats |

struct ProducedChatTurn: Sendable {
    let result: TurnEngineResult
    let context: TurnContext
    let personaFingerprint: String
    let attachments: [MultimodalAttachment]
    let answerID: String
    let cognitiveProjection: (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)?
}

/// Verified owner turns advance the current/previous stamp once per turn under its file lock.
public enum UserTurnStamp {
    struct Stamp: Codable { var at: Double; var previous: Double?; var key: String; var door: String? }

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

    public static func record(dataRoot: URL, key: String, door: String? = nil, at date: Date = Date()) {
        let url = url(dataRoot)
        do {
            let keptKey = try CredentialFileLock.withLock(url) {
                let old = try read(dataRoot)
                if let old, old.key == key { return old.key }
                // A delayed event's older timestamp never replaces a newer conversation stamp.
                if var old, date.timeIntervalSince1970 < old.at {
                    if old.previous.map({ date.timeIntervalSince1970 > $0 }) ?? true {
                        old.previous = date.timeIntervalSince1970
                        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(old), to: url)
                    }
                    return old.key
                }
                let stamp = Stamp(at: date.timeIntervalSince1970, previous: old?.at, key: key, door: door)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(stamp), to: url)
                return stamp.key
            }
            RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: url.path, id: keptKey))
        } catch {
            unavailable(dataRoot, error)
        }
    }

    public static func last(dataRoot: URL) -> Date? {
        reportedRead(dataRoot).map { Date(timeIntervalSince1970: $0.at) }
    }

    /// The preceding verified user turn marks where this turn's gap opened.
    public static func previous(dataRoot: URL) -> Date? {
        reportedRead(dataRoot)?.previous.map { Date(timeIntervalSince1970: $0) }
    }
}
