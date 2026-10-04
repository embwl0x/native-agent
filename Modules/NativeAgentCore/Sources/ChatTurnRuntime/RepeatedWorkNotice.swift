import Desk
import Foundation
import NativeAgentCore
import Skills
import StandingBots
import TrustCenter
import TurnTrace

extension SwiftNativeTurnEngine {
    /// Skills-as-code 4b: her own turn's landed app calls feed
    /// `SkillPatterns`, and what it notices lands as a quiet MY QUEUE line of
    /// hers. A turn a peer steered (its words consumed, an elevated peer, or
    /// the peer bridge) is the peer's habit, not hers, and is not recorded.
    /// A shape line is built only from action ids, so it carries no peer; a
    /// follow-up names a skill, and one whose origin isn't hers is filed as
    /// its peers' step. Fired detached once the context is read: the turn
    /// never waits on the Desk, and a failed or slow write only logs.
    static func noticeRepeatedWork(dispatches: [TurnEngineResult.ToolDispatchRecord], surface: String, root: URL?) {
        guard let root else { return }
        let steer = PeerDataTaint.carried(peerBridge: PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                                          peerID: ChatToolSessionContext.envelope?.verifiedUserId)
        guard steer.sources.isEmpty, steer.elevated.isEmpty else { return }
        let calls = dispatches.compactMap { dispatch -> SkillPatterns.Call? in
            guard dispatch.name == "app" else { return nil }
            let landed = ChatToolOutcome.outputLooksSuccessful(dispatch.result)
                && !ChatToolOutcome.isWaitingApproval(dispatch.result) && !ChatToolOutcome.wasCancelled(dispatch.result)
            return SkillPatterns.call(input: dispatch.input, landed: landed)
        }
        guard !calls.isEmpty else { return }
        // Whose habit: a standing bot's, the Workshop's or a swarm's own, else hers.
        let folded = WorkshopSurfaceVocabulary.canonicalSurface(surface)
        let agent: (key: String, name: String?) = if let bot = StandingBotContinuity.currentBot {
            ("bot:" + bot.id.uuidString.lowercased(), bot.name)
        } else if ["workshop", "swarms"].contains(folded) {
            (folded, folded == "workshop" ? "Workshop" : "A swarm worker")
        } else { ("her", nil) }
        let turn = TurnTraceContext.turnId ?? UUID().uuidString
        Task.detached(priority: .utility) {
            let lines = SkillPatterns.observe(turn: turn, agent: agent.key, name: agent.name, calls: calls, root: root)
            guard !lines.isEmpty else { return }
            let skills = (try? InstalledSkillInventory.entries(dataRoot: root)) ?? []
            let store = SwiftNativeDeskStore(dataRoot: root)
            for line in lines {
                let peers = line.skill.flatMap { InstalledSkillInventory.match($0, in: skills) }.map { SkillScript.voices($0.row) } ?? []
                do {
                    let queued = try await MyQueue.add(DeskStep(words: line.words, when: MyQueue.When.quiet.stored, peers: peers),
                                                       store: store)
                    // A line filed as a peer's (or matching one a peer filed) is not hers, so not linked.
                    SkillPatterns.queued(line, item: queued.entry.peerBorn ? nil : queued.entry.item.handle, root: root)
                } catch {
                    SkillPatterns.queued(line, item: nil, root: root)
                    NSLog("[skill-patterns] a line was not queued: \(error)")
                }
            }
        }
    }
}
