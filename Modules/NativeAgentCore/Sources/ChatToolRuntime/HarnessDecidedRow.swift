import Foundation
import NativeAgentShared
import NativeAgentCore
import ChatTurnContracts
import NotificationInbox
import PersistenceCore
import PersonaEngine
import AgentConversations

// Blueprint: | `HarnessDecidedRow.swift` | `HarnessDecidedRow`: rolling per-requester/tool decision visibility without push; info writes stay off the tool gate's path |

/// One rolling info row per requester/tool shows her decision without a push.
/// The detail names the session; the write stays off the tool gate's path.
public enum HarnessDecidedRow {
    public static func post(requester: String, tool: String, sessionID: String?, dataRoot: URL, ran: Bool = false) {
        Task { _ = await record(requester: requester, tool: tool, sessionID: sessionID, dataRoot: dataRoot, ran: ran) }
    }

    /// The same row, written before it returns, for a call whose own receipt
    /// says it was recorded: the row's id and how many decisions it holds.
    /// Nil when the inbox did not write. A decision after the open row was
    /// archived starts a new row, never vanishing into the archived one.
    public static func record(
        requester: String, tool: String, sessionID: String?, dataRoot: URL, ran: Bool = false
    ) async -> (id: String, decisions: Int)? {
        let envelope = TurnEnvelope.current(surface: "")
        let requester: String = {
            guard let work = ChatToolSessionContext.envelope?.workIdentity,
                  work.hasPrefix("carry."), work.count > 6 else { return requester }
            return "house." + work.dropFirst(6)
        }()
        guard requester.hasPrefix("house.") && envelope.agent == "self"
            || (!PeerDataTaint.trustedTurn && !PeerDataTaint.ownerTrusts(requester)) else { return nil }
        let peerID = requester.hasPrefix("peer:") ? String(requester.dropFirst(5)) : envelope.verifiedUserId
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        let peer = peers.first { $0.id == peerID || $0.name.caseInsensitiveCompare(requester) == .orderedSame }
        let displayName = peer?.name ?? (requester.hasPrefix("peer:") || requester == "a remote peer" ? "another agent" : requester)
        let key = "harness_decided.\(requester).\(tool)"
        let title = "\(PersonaCompiler.agentDisplayName(dataRoot: dataRoot)) \(ran ? "ran" : "allowed"): \(displayName) → \(tool)"
        let id = key + "." + UUID().uuidString.prefix(8).lowercased()
        let row: JSONValue = .object([
            "id": .string(id),
            "created_at": .string(NativeTimestampFormat.plainZulu(Date())),
            "source": .string("harness_decided"),
            "severity": .string("info"),
            "title": .string(String(title.prefix(200))),
            "summary": .string(""),
            "detail": .string(sessionID ?? ""),
            "principal": .object(["peerID": peer.map { .string($0.id) } ?? peerID.map(JSONValue.string) ?? .null,
                                   "displayName": .string(displayName)]),
            "actions": .array([]),
            "status": .string("unread"),
        ])
        do {
            let written = try await LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
                .appendOrRollUpInformational(row, id: id, rollupKey: key, occurrenceID: UUID().uuidString)
            return (written.cardID, written.occurrenceCount)
        } catch {
            FileHandle.standardError.write(Data("HarnessDecidedRow: \(key) not recorded: \(error)\n".utf8))
            return nil
        }
    }
}
