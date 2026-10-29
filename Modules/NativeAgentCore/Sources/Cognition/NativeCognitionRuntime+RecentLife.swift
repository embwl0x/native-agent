import Foundation
import ApprovalInbox
import BackgroundLoops
import ChatTurnRuntime
import ChatToolRuntime
import AgentConversations
import CognitiveSubstrate
import Context
import ContextFlow
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import DreamREMCycle
import ProviderRouting
import AuthoredCapabilities
import NativeAgentShared
import Studio
import Transcripts
import TurnTrace
// Blueprint: | `NativeCognitionRuntime+RecentLife.swift` | `NativeCognitionRuntime` recent life: once-only conversation/day/speaker cares reading and moment-to-care migration |

extension NativeCognitionRuntime {
    /// Once: the retired moment lane's moments become the care movements they
    /// were (`AdaptiveMemoryPromoter.moveMomentsIntoCaresOnce`).
    func moveMomentsIntoCaresOnce() async {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return }
        await AdaptiveMemoryPromoter.moveMomentsIntoCaresOnce(
            memory: SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot), dataRoot: dataRoot
        ) { [substrate] note, moved, felt, provenance in
            try await substrate.keepMomentInCares(note, moved: moved, felt: felt, provenance: provenance)
        }
    }

    /// Once, after the cares migration: her last 72 hours of lived
    /// conversation, one cares-only call per (conversation, local day, speaker) holding
    /// at least two exchanges, so an existing agent wakes with cares from what
    /// she lived. One group's failure is logged with its cause and the rest
    /// continue; groups already read are never read again.
    func readRecentLifeIntoCaresIfOwed() async {
        guard !isFlushedForTermination, !Task.isCancelled,
              dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL,
              let (alreadyRead, generation) = await substrate.careLifeReadingOwed() else { return }
        let lines: [ChatHistoryIndex.LivedLine]
        let sessions: SessionConversation
        do {
            sessions = try SessionConversation(dataRoot: dataRoot, includingArchived: true)
            lines = try ChatHistoryIndex.shared(dataRoot: dataRoot).livedLines(since: now().addingTimeInterval(-72 * 3_600))
        } catch {
            nativeLog("cares: her recent life stays owed, conversation catalog or history unreadable: %@", error.localizedDescription)
            return
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let owner = Self.resolveUserName(dataRoot: dataRoot)
        func name(_ speaker: String) -> String {
            speaker == CognitiveCare.ownerKey ? (owner.isEmpty ? "the person" : owner) : "agent \(speaker)"
        }
        // One group per (conversation, local day, speaker): that speaker's
        // lines and her replies to them. Her wake prompts and a helper's own
        // runs are not conversations she lived; a row its writer marked
        // machinery, or a debug/verification exchange, is not lived talk, and
        // neither is her reply to one. A reply joins the message with its run
        // id; a row with none joins the message before it.
        struct Group { var speaker: String; var parts: [String] = []; var exchanges = 0; var last: ChatHistoryIndex.LivedLine }
        var groups: [String: Group] = [:]
        let conversations = Dictionary(grouping: lines.filter {
            sessions.kind($0.conversation)?.isOwnWork != true && !sessions.isHelper($0.conversation)
        }, by: \.conversation)
        for (conversation, rows) in conversations {
            let rows = rows.sorted { $0.at < $1.at }
            let paired = ChatSessionRecollections.pairExchanges(rows.map {
                (conversation, $0.runId, $0.role, !$0.mechanical && ($0.role != "user" || $0.author != "self"))
            })
            // A person's lines and her replies to them; her own openings speak for no one here.
            for pair in paired where rows[pair.origin].role == "user" {
                let line = rows[pair.row], origin = rows[pair.origin]
                let speaker = CognitiveCareProvenance.personKey(origin.peer ?? CognitiveCare.ownerKey)
                let key = "\(conversation)|\(day.string(from: origin.at))|\(speaker)"
                groups[key, default: Group(speaker: speaker, last: line)].parts.append(
                    line.role == "user" ? "\(name(speaker)): \(line.words)" : "Her reply: \(line.words)")
                if pair.firstReply { groups[key]?.exchanges += 1 }
                groups[key]?.last = line
            }
        }
        let manager = MindMemoryJudgment(makeLLMClient: { [host, dataRoot, weak self] in
            host.backgroundLLMClient(dataRoot: dataRoot, cognition: self)
        })
        var passFailed = false
        for (key, group) in groups.sorted(by: { $0.key < $1.key })
        where !alreadyRead.contains(key) && group.exchanges >= 2 {
            guard !isFlushedForTermination, !Task.isCancelled else { return }
            let trusted = group.speaker == CognitiveCare.ownerKey || PeerTrust.ownerTrusts(group.speaker, dataRoot: dataRoot)
            let conversation = String(group.parts.joined(separator: "\n").suffix(12_000))
            let shown = await substrate.caresShown(for: conversation)
            guard !isFlushedForTermination, !Task.isCancelled else { return }
            do {
                let judgments = try await LLMCallContext.$purpose.withValue("memory_interpret") {
                    try await manager.appraiseCares(conversation: conversation, speaker: name(group.speaker), shown: shown)
                }
                let provenance = CognitiveCareProvenance(
                    speaker: group.speaker, trusted: trusted, appAuthored: false,
                    source: "exchange:\(group.last.conversation)/\(group.last.messageId ?? "")", at: group.last.at)
                let saved = await settle { [substrate] in
                    do {
                        try await substrate.applyCares(judgments, provenance: provenance, generation: generation)
                        await substrate.noteCareLifeReadingGroup(key, failure: nil, generation: generation)
                        return true
                    } catch {
                        await substrate.noteCareLifeReadingGroup(key, failure: String(describing: error), generation: generation)
                        return false
                    }
                }
                passFailed = passFailed || !saved
            } catch {
                let why = (error as? AfterTurnMemoryFailure)?.detail ?? String(describing: error)
                passFailed = true
                nativeLog("cares: reading %@ into her cares failed: %@", key, why)
                await substrate.noteCareLifeReadingGroup(key, failure: why, generation: generation)
            }
        }
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        await substrate.finishCareLifeReading(passFailed: passFailed, generation: generation)
    }
}
