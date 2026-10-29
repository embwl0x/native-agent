import AgentWorkspace
import ChatTurnContracts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |

/// On-demand scrollback over the conversation itself: the one session the
/// contact owns (`ContactThread`), both directions, whichever door or chat
/// each message came through. Her sends carry their state from
/// the record that sent them. It never replays messages or supplies context
/// to a peer's model session.
enum AgentConversationHistoryView {
    /// A contact can have inbound history before she ever opens a send record.
    static func adding(to presentation: JSONValue, agent: String, name: String,
                       before: String? = nil, exchange: String? = nil, dataRoot: URL,
                       peers: [AgentPeerContact]? = nil, lines snapshot: Result<[ContactThread.Line], Error>? = nil) -> JSONValue {
        guard case .object(var result) = presentation else { return presentation }
        if before != nil || exchange != nil {
            // Keep live readiness for Reply, but give the selected historical
            // moment the reading space. Recent messages restores the latest.
            for key in ["reply", "reply_state", "reply_truncated", "artifacts", "parts", "evidence", "untrusted_remote_data"] { result.removeValue(forKey: key) }
            result["viewing"] = .string("Conversation history. State and Reply controls describe the conversation now; the messages below keep their own times and states.")
        }
        var metadata: [String: JSONValue] = [
            "coverage": .string("Your one conversation with \(name), from its session: what you sent it from any chat, its replies, and the messages it started, whichever door each came through."),
            "order": .string("oldest_first"), "untrusted_remote_data": .bool(false)
        ]
        let owner = agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent
        let peers = peers ?? (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        let lines: [ContactThread.Line]
        do { lines = try snapshot?.get() ?? ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: AgentContactIdentity(dataRoot: dataRoot, peers: peers)) }
        catch {
            metadata["status"] = .string("unavailable")
            metadata["detail"] = .string("This conversation's session could not be read (\(error.localizedDescription)). The conversation is preserved; no message was repeated.")
            result["session_history"] = .object(metadata); return .object(result)
        }
        let selected: ArraySlice<ContactThread.Line>
        if let exchange {
            guard let index = lines.firstIndex(where: { $0.id == exchange }) else {
                metadata["status"] = .string("unavailable")
                metadata["detail"] = .string("That message is no longer in this conversation's session. The conversation is preserved; no message was repeated.")
                result["session_history"] = .object(metadata); return .object(result)
            }
            selected = lines[index...index]
            metadata["selected_message"] = .string(exchange)
            if index > 0 { metadata["earlier_before"] = .string(exchange) }
        } else {
            let end: Int
            if let before {
                guard let index = lines.firstIndex(where: { $0.id == before }) else {
                    metadata["status"] = .string("unavailable")
                    metadata["detail"] = .string("This earlier-page boundary is no longer in the session. Return to recent messages; no message was repeated.")
                    result["session_history"] = .object(metadata); return .object(result)
                }
                end = index
            } else { end = lines.count }
            let start = max(0, end - 8)
            selected = lines[start..<end]
            if start > 0 { metadata["earlier_before"] = .string(lines[start].id) }
        }
        // Only a history read failure carries its own status beside the send.
        if lines.isEmpty { metadata["detail"] = .string("Nothing has been said in this conversation yet.") }
        // A send's state: the ledger of the record that sent it, from whichever
        // chat, or its own row once the ledger let it go.
        let sends: Result<[String: AgentConversationExchange], Error> = Result {
            Dictionary(try AgentConversationStore(dataRoot: dataRoot).records().flatMap { ($0.exchanges ?? []) + ($0.releasing ?? []) }.map { ($0.id, $0) },
                       uniquingKeysWith: { first, _ in first })
        }
        var names = Dictionary(uniqueKeysWithValues: peers.map { ("peer:" + $0.id, $0.name) })
        for line in selected {
            if let source = line.source { names[source] = names[PeerTrust.principal(source, dataRoot: dataRoot, peers: peers)] ?? source }
        }
        var untrusted = false
        let messages: [JSONValue] = ContactThread.project(selected, person: "the person, from the contact's thread", names: names,
            mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) }).map { line in
            let full = exchange != nil
            var value: [String: JSONValue] = [
                "message": .string(line.id), "at": .string(NativeTimestampFormat.fractionalZulu(line.at)),
                // The person wrote it in the contact's thread; it isn't yours to answer.
                "from": .string(line.speaker),
                "text": .string(full ? line.text : String(line.text.prefix(800)))
            ]
            if !full, line.text.count > 800 { value["text_truncated"] = .bool(true) }
            if let door = line.door { value["door"] = .string(door) }
            if let id = line.sendID {
                value["send"] = .string(id)
                switch sends {
                case .success(let ledger):
                    value["state"] = .string(ledger[id]?.status ?? line.sendState
                        ?? "state unavailable: this send is older than its conversation's send ledger and its row kept no state")
                case .failure(let error):
                    value["state"] = .string(line.sendState ?? "state unavailable: \(error.localizedDescription)")
                }
            }
            if let answers = line.answers { value["answers_send"] = .string(answers) }
            else if !line.mine { value["started_by"] = .string(name) }
            let speakers = line.speakers
            if !speakers.isEmpty {
                // A lane's name becomes the one contact it is, as its own turns' sources do.
                let principals = speakers.map { PeerTrust.principal($0, dataRoot: dataRoot, peers: peers) }
                let trusted = principals.allSatisfy { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) }
                if !line.mine { value["agent_id"] = .string(principals[0]) }
                value["untrusted_remote_data"] = .bool(!trusted)
                untrusted = untrusted || !trusted
            }
            return .object(value)
        }
        metadata["messages"] = .array(messages)
        metadata["untrusted_remote_data"] = .bool(untrusted)
        result["session_history"] = .object(metadata)
        return .object(result)
    }
}
