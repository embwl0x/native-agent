import AgentWorkspace
import ChatTurnContracts
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationHistoryView.swift` | `AgentConversationHistoryView` enum; `adding` |

/// Scrollback reads the contact’s canonical session across doors; it must not replay messages or feed a peer’s model context.
enum AgentConversationHistoryView {
    /// A contact can have inbound history before the agent ever opens a send record.
    static func adding(to presentation: JSONValue, agent: String, name: String,
                       before: String? = nil, exchange: String? = nil, limit: Int = 8, dataRoot: URL,
                       peers: [AgentPeerContact]? = nil, lines snapshot: Result<[ContactThread.Line], Error>? = nil) -> JSONValue {
        guard case .object(var result) = presentation else { return presentation }
        if before != nil || exchange != nil {
            // Preserve live reply readiness while giving the selected historical moment reading space.
            for key in ["reply", "reply_state", "reply_truncated", "artifacts", "parts", "evidence", "untrusted_remote_data"] { result.removeValue(
                forKey: key) }
            result["viewing"] = .string(
                "Conversation history. Each message keeps its own time and state.")
        }
        var metadata: [String: JSONValue] = [
            "coverage": .string("""
                Your one conversation with \(name), from its session: what you sent it from any chat, its replies, and the messages it started, \
                whichever door each came through.
                """),
            "order": .string("oldest_first"), "untrusted_remote_data": .bool(false)
        ]
        func unavailable(_ detail: String) -> JSONValue {
            metadata["status"] = .string("unavailable")
            metadata["detail"] = .string(detail)
            result["session_history"] = .object(metadata)
            // A selected history read owns its failure; the retained send's status cannot explain this read.
            if before != nil || exchange != nil {
                result["status"] = .string("unavailable")
                result["detail"] = .string(detail)
                result["effects"] = .string("none")
            }
            return .object(result)
        }
        let owner = agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent
        let contacts: [AgentPeerContact]
        do { contacts = try peers ?? AgentPeerStore(dataRoot: dataRoot).list() }
        catch {
            return unavailable("Contact identity could not be read: " + error.localizedDescription
                + ". Repair agents/peers.json; the conversation is preserved.")
        }
        let peers = contacts
        let lines: [ContactThread.Line]
        do { lines = try snapshot?.get() ?? ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: AgentContactIdentity(contacts: peers)) }
        catch {
            return unavailable(
                "This conversation's session could not be read (\(error.localizedDescription)). The conversation is preserved; no message was repeated.")
        }
        let selected: ArraySlice<ContactThread.Line>
        if let exchange {
            guard let index = lines.firstIndex(where: { $0.id == exchange }) else {
                return unavailable(
                    "That message was not found in this conversation's session. The conversation is preserved; no message was repeated.")
            }
            selected = lines[index...index]
            metadata["selected_message"] = .string(exchange)
            if index > 0 { metadata["earlier_before"] = .string(exchange) }
        } else {
            let end: Int
            if let before {
                guard let index = lines.firstIndex(where: { $0.id == before }) else {
                    return unavailable("This earlier-page boundary was not found in the session. Return to recent messages; no message was repeated.")
                }
                end = index
            } else { end = lines.count }
            let start = max(0, end - min(128, max(1, limit)))
            selected = lines[start..<end]
            if start > 0 { metadata["earlier_before"] = .string(lines[start].id) }
        }
        // Only a history read failure carries its own status beside the send.
        if lines.isEmpty {
            metadata["detail"] = .string("The saved session read returned no messages; this does not prove that no earlier conversation exists.")
        }
        // Read send state from its owning ledger, or its retained row after ledger pruning.
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
