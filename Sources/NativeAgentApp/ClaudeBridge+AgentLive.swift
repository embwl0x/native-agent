import Privacy
import Foundation
import Network
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

/// The live half of an agent conversation. In-process lanes (ACP, A2A SSE)
/// feed `AgentConversationLiveHub` directly; the built-in lanes' wake helpers
/// run out of process and POST here (`/codex/live`, `/omp/live`) keyed by
/// the accepted message id. Every coalesced change goes
/// out on `/claude/events` as `kind: "agent_live"` (not kept in the backfill
/// ring) and is persisted to `agents/conversation-live.json`.
extension ClaudeBridge {
    func installAgentLivePublisher() {
        Task {
            await AgentConversationLiveHub.shared.setPublisher { [weak self] live in
                self?.publishEvent(kind: "agent_live", payload: Self.agentLivePayload(live), retain: false)
            }
        }
    }

    static func agentLivePayload(_ live: AgentConversationLive) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "key": live.key, "recordId": live.recordID ?? NSNull(), "operationId": live.operationID ?? NSNull(),
            "agent": live.agent, "messageId": live.messageID ?? NSNull(), "lane": live.lane,
            "state": live.state, "streams": live.streams,
            "startedAt": iso.string(from: live.startedAt), "lastActivityAt": iso.string(from: live.lastActivityAt),
            "partialText": live.partial.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "partialChars": live.partialChars, "partialTruncated": live.partialTruncated,
            "note": live.note.map { NativeAgentSecretRedactor.redactText($0) } ?? NSNull(),
            "finishedAt": live.finishedAt.map { iso.string(from: $0) } ?? NSNull(),
        ]
    }

    func handleAgentLive(conn: NWConnection, body: Data, agent: String) {
        messageRuntime().handleAgentLive(response: { [weak self] status, object in
            self?.writeJSON(conn, status: status, obj: object)
        }, body: body, agent: agent)
    }
}
