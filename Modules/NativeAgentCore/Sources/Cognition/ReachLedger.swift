import Foundation
import ChatTurnRuntime
import PersistenceCore
import BackgroundLoops
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import ProviderRouting
import Experiences
import MemoryV2
import AgentWorkspace
import AgentConversations
import Desk
import DreamREMCycle
import Transcripts
import TurnTrace
import NativeAgentShared
import Studio
import ApprovalInbox
import ChatToolRuntime
import ContextFlow
import AuthoredCapabilities
// Blueprint: | `ReachLedger.swift` | `ReachLedger`: bounded outreach facts, checked reads and locked answer-settlement writes at cognition/reach.json |

/// Keep bounded pacing facts out of prompts; they never score closeness.
struct ReachLedger: Codable, Equatable {
    struct Offer: Codable, Equatable {
        var id: String
        var subject: String
        var kind: String
        var source: String
        var why: String
        var offeredAt: Date
        var outcome: String
        var sentAt: Date?
        var session: String?
        var knocked: Bool?
        /// Speech may land even if its separate notification fails.
        var knockFailure: String?
        var answered: Bool?
        /// Retain the first verified person turn even while speech confirmation is pending.
        var answeredAt: Date?
        /// Store how an offer landed with its originating care.
        var landed: Bool?
        /// Retain source time for the delivery-time recheck.
        var at: Date?

        var isSent: Bool { outcome == "sent" }
        /// Persist sending before delivery; after a crash it holds pacing without claiming sent or answered.
        var mayHaveReachedPerson: Bool { isSent || outcome == "sending" }
    }
    var offers: [Offer] = []
    static let cap = 40

    static func url(_ root: URL) -> URL { root.appendingPathComponent("cognition/reach.json") }

    /// Unreadable history is never empty permission to send or overwrite; outreach waits.
    static func read(_ root: URL) -> ReachLedger? {
        guard FileManager.default.fileExists(atPath: url(root).path) else { return ReachLedger() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(ReachLedger.self, from: Data(contentsOf: url(root)))
        } catch {
            nativeLog("reach: ledger %@ unreadable, outreach paused until it reads: %@",
                      url(root).path, error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func write(_ root: URL) -> Bool {
        var bounded = self
        bounded.offers = Array(offers.suffix(Self.cap))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(
                at: Self.url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
            try ReachAnswerSettlement.write(encoder.encode(bounded), dataRoot: root)
            return true
        } catch {
            nativeLog("reach: ledger not kept: %@", error.localizedDescription)
            return false
        }
    }

    /// Derive gates from rows directly; counters are diagnostic projection only.
    func counters(lastUserTurn: Date?, now: Date) -> [String: JSONValue] {
        let week = offers.filter { now.timeIntervalSince($0.offeredAt) <= 7 * 86_400 }
        var subjects: [String: Int] = [:]
        for offer in offers where offer.isSent { subjects[offer.subject, default: 0] += 1 }
        var out: [String: JSONValue] = [
            "outreach_7d": .int(Int64(week.filter(\.isSent).count)),
            "unconfirmed_7d": .int(Int64(week.filter { $0.outcome == "sending" }.count)),
            "answered": .int(Int64(offers.filter { $0.answered == true }.count)),
            "unanswered": .int(Int64(offers.filter { $0.answered == false }.count)),
            "interruptions_7d": .int(Int64(week.filter { $0.knocked == true }.count)),
            "callbacks_repeated": .int(Int64(subjects.values.filter { $0 > 1 }.count)),
        ]
        if let lastUserTurn { out["last_user_turn"] = .double(lastUserTurn.timeIntervalSince1970) }
        if let last = offers.filter(\.isSent).compactMap(\.sentAt).max() { out["last_outreach"] = .double(last.timeIntervalSince1970) }
        return out
    }
}
