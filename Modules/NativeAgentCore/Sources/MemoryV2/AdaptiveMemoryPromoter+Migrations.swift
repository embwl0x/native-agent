import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import CognitiveSubstrate
import Transcripts
import TrustCenter
import TurnTrace
import GRDB
import NativeAgentShared
// Blueprint: | `AdaptiveMemoryPromoter+Migrations.swift` | `AdaptiveMemoryPromoter`: import-only held-turn format, once-only trusted pending-fact acceptance and moment-to-care migrations with unchanged durable markers |

extension AdaptiveMemoryPromoter {
    /// The retired held-file format (`memory/moments_held.json`), read once.
    private struct HeldTurn: Codable {
        let sessionId, surface, user, asked, assistant: String
        var turnId, runId, messageId: String?
        var occurredAt: Date?
        var speaker: String?
        var standingAgent, factsEnabled: Bool?
        var envelope: JSONValue?
        var sourceCheckpoint, elevatedSources: [String]?
    }

    /// Import held turns into the door's journal in one transaction, then empty the file.
    /// The journal is the only queue; the held file is never written again.
    func importHeldTurns(door: LivedMomentDoor) async {
        let path = door.dataRoot.appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("moments_held.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let held: [HeldTurn]
        do { held = try JSONDecoder().decode([HeldTurn].self, from: Data(contentsOf: path)) } catch {
            nativeLog("MemoryV2: held turns unreadable; left for a later import: %@", String(describing: error))
            return
        }
        guard !held.isEmpty else { return }
        let turns = held.filter { $0.factsEnabled == true }.map { turn in
            CognitiveMomentTurn(
                sessionId: turn.sessionId, surface: turn.surface, user: turn.user, asked: turn.asked,
                assistant: turn.assistant, turnId: turn.turnId, runId: turn.runId, messageId: turn.messageId,
                occurredAt: turn.occurredAt, took: nil,
                standingAgentName: turn.standingAgent == true ? (turn.speaker ?? "standing agent") : nil,
                envelope: turn.envelope, sourceCheckpoint: turn.sourceCheckpoint,
                elevatedSources: turn.elevatedSources)
        }
        if !turns.isEmpty {
            guard await door.importHeld(turns) else { return }
        }
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode([HeldTurn]()), to: path)
        } catch {
            // The rows are in the journal with stable identities; a second
            // import of the same file records nothing new.
            nativeLog("MemoryV2: held file not emptied after import: %@", String(describing: error))
        }
    }

    // MARK: - The pending backlog, once

    /// Once per store, accept trusted pending facts with their proposal's source; leave other proposals pending.
    /// An unread store leaves the marker unwritten for the next launch.
    public static func keepTrustedBacklogOnce(memory: SwiftNativeMemoryV2, dataRoot: URL) async {
        let marker = LegacyCorrectionScopeMigration.migrationsDir(dataRoot: dataRoot)
            .appendingPathComponent("trusted_pending_facts_v1.done")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        var kept = 0, waiting = 0, refused = 0
        do {
            let pending = try await memory.listProposals(status: "pending").filter { !MemoryMoments.isMoment($0.metadata) }
            guard let storage = await memory.storage else { throw MemoryV2Error.storageUnavailable }
            for proposal in pending {
                func read(_ key: String) -> String? { proposal.metadata?.objectValue?[key]?.stringValue }
                let session = read("session_id") ?? ""
                // Whose words fed it: a recorded peer source names the speaker
                // (and must be trusted below); none means the owner's own words.
                let fedBy = MemoryDataProvenance.sources(in: proposal.metadata).first
                let speaker = incomingSpeaker(isPeer: fedBy != nil, speaker: fedBy, sessionId: session, dataRoot: dataRoot)
                guard speaker.trusted, read("kind") != "correction" || speaker.key == CognitiveCare.ownerKey,
                      MemoryDataProvenance.sources(in: proposal.metadata).allSatisfy(PeerDataTaint.ownerTrusts) else {
                    waiting += 1
                    continue
                }
                var fields: [String: JSONValue] = [:]
                if case .object(let existing)? = proposal.metadata { fields = existing }
                let at = (read("turn_at") ?? read("observed_at")).flatMap(MemoryRecallScoring.parseTimestamp)
                    ?? MemoryRecallScoring.parseTimestamp(proposal.createdAt) ?? Date()
                fields.merge(MemoryMoments.sourceMetadata(sessionId: session.isEmpty ? nil : session,
                    messageId: read("history").map { String($0.dropFirst("history:".count)) },
                    turnId: read("turn_id"), at: at, speaker: speaker.key,
                    words: read("standing_evidence"))) { current, _ in current }
                _ = try await storage.updateProposalMetadata(id: proposal.id, metadata: .object(fields))
                do {
                    _ = try await memory.acceptProposal(id: proposal.id)
                    kept += 1
                } catch {
                    refused += 1
                    nativeLog("MemoryV2: pending fact \(proposal.id) left for her review, not kept: \(error)")
                }
            }
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(Data(MemoryStorage.nowISO8601().utf8), to: marker)
        } catch {
            nativeLog("MemoryV2: pending backlog not finished, the next launch runs it again: %@", String(describing: error))
        }
        nativeLog("MemoryV2: pending backlog, once: kept=\(kept) waiting=\(waiting) refused=\(refused)")
    }

    // MARK: - Moments into cares, once

    /// Once per store, keep moments in the matching, closest or new care with their pointer and time.
    /// Pending moments resolve as "now a care"; kept moments remain in memory; existing care moments are not duplicated.
    /// Unread stores or unsaved cares leave the marker unwritten for the next launch.
    public static func moveMomentsIntoCaresOnce(
        memory: SwiftNativeMemoryV2, dataRoot: URL,
        keep: @Sendable (_ note: String, _ moved: Double, _ felt: String,
                         _ provenance: CognitiveCareProvenance) async throws -> Bool
    ) async {
        let marker = LegacyCorrectionScopeMigration.migrationsDir(dataRoot: dataRoot)
            .appendingPathComponent("moments_into_cares_v1.done")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        var cared = 0, notKept = 0
        do {
            // Placing a moment in the care it belongs to needs the embedder;
            // this once-only pass loads it rather than waiting for a turn to.
            _ = try await memory.embedForDerivedContext(["moments into cares"])
            let kept = try await memory.listMemory(kind: MemoryMoments.kind)
                .filter { ($0.status ?? "active") == "active" }
                .map { (id: $0.id, content: $0.text, metadata: $0.extras, createdAt: $0.createdAt, waiting: false) }
            let waiting = try await memory.listProposals(status: "pending")
                .filter { MemoryMoments.isMoment($0.metadata) }
                .map { (id: $0.id, content: $0.content, metadata: $0.metadata, createdAt: $0.createdAt, waiting: true) }
            for moment in kept + waiting {
                func read(_ key: String) -> String? { moment.metadata?.objectValue?[key]?.stringValue }
                let session = read("session_id") ?? ""
                let exchange = read("history").map { String($0.dropFirst("history:".count)) } ?? read("turn_id")
                let at = (read("observed_at") ?? read("turn_at")).flatMap(MemoryRecallScoring.parseTimestamp)
                    ?? MemoryRecallScoring.parseTimestamp(moment.createdAt) ?? Date()
                // Moments carry the person's words or her app-authored work.
                let author = read("author") ?? "user"
                let speaker = author == "app" ? (key: CognitiveCare.ownerKey, trusted: true)
                    : incomingSpeaker(isPeer: author == "peer" || SessionConversation.kind(session, dataRoot: dataRoot, includingArchived: true)?.isPeerConversation == true,
                                      speaker: nil, sessionId: session, dataRoot: dataRoot)
                let valence = MemoryMoments.metadataNumber(moment.metadata, "valence") ?? 0
                let strong = (MemoryMoments.metadataNumber(moment.metadata, "salience") ?? 0.5) >= 0.7
                let felt = valence >= 0.3 ? (strong ? "moved" : "glad")
                    : valence <= -0.3 ? (strong ? "hurt" : "uneasy") : (strong ? "struck" : "noticed")
                let note = MemoryTextClip.sentenceClip(
                    MemoryMoments.narration(ofStored: moment.content, metadata: moment.metadata),
                    cap: CognitiveCare.noteCharacters)
                let saved = try await keep(note, valence, felt, CognitiveCareProvenance(
                    speaker: speaker.key, trusted: speaker.trusted, appAuthored: author == "app",
                    source: exchange.map { "exchange:\(session)/\($0)" } ?? "memory:\(moment.id)", at: at))
                if saved { cared += 1 } else { notKept += 1 }
                if moment.waiting {
                    _ = try await memory.rejectProposal(id: moment.id, reason: saved
                        ? "now a care" : "not kept: an untrusted peer's moment, with no care of hers to join")
                }
            }
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await SwiftNativePersistenceCore.writeDataAtomicDurableAsync(Data(MemoryStorage.nowISO8601().utf8), to: marker)
        } catch {
            nativeLog("MemoryV2: moments not all moved into cares, the next launch runs it again: %@", String(describing: error))
        }
        nativeLog("MemoryV2: moments into cares, once: cared=\(cared) notKept=\(notKept)")
    }
}
