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
// Blueprint: | `AdaptiveMemoryPromoter+Migrations.swift` | `AdaptiveMemoryPromoter`: Retained moment-to-care conversion for existing moment rows and its durable completion marker |

extension AdaptiveMemoryPromoter {
    // MARK: - Moments into cares, once

    /// Once per store, keep moments in the matching, closest or new care with their pointer and time.
    /// Pending moments resolve as "now a care"; kept moments remain in memory; existing care moments are not duplicated.
    /// Unread stores or unsaved cares leave the marker unwritten for the next launch.
    public static func moveMomentsIntoCaresOnce(
        memory: SwiftNativeMemoryV2, dataRoot: URL,
        keep: @Sendable (_ note: String, _ moved: Double, _ felt: String,
                         _ provenance: CognitiveCareProvenance) async throws -> Bool
    ) async {
        let marker = dataRoot.appendingPathComponent("memory/migrations", isDirectory: true)
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
