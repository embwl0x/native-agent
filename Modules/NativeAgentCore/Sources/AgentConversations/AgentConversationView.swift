import ChatTurnContracts
import AgentWorkspace
import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationView.swift` | Retained send evidence, live progress, queues and conversation presentation. |

/// Presentation consumes authorized reads; session state transitions remain with the session owner.
public enum AgentConversationView {
    public static func claudeWorklogTail(_ url: URL) throws -> [[String: Any]] {
        guard let read = try SwiftNativePersistenceCore.tailPhysicalLines(url, limit: .max, maxBytes: 65_536)
        else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        var rows: [[String: Any]] = []
        for (index, bytes) in read.lines.dropFirst(read.leadingFragment ? 1 : 0).enumerated() {
            if bytes.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            do {
                guard String(data: Data(bytes), encoding: .utf8) != nil,
                      let row = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                      let ts = row["ts"] as? String, NativeTimestampFormat.parseISO8601FractionalFirst(ts) != nil,
                      let kind = row["kind"] as? String, !kind.isEmpty, row["summary"] is String else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                rows.append(row)
            } catch {
                throw ToolFailureError("Worklog tail row \(index + 1) in \(url.path) is malformed: \(error.localizedDescription). This read is incomplete.",
                    effects: .none, owner: url.path, code: "agent_worklog_incomplete",
                    instruction: ToolFailureError.fileRepairInstruction(url,
                        shape: """
                            Each nonblank worklog row must be a UTF-8 JSON object with an ISO 8601 ts, nonempty kind and text summary. Preserve the \
                            malformed source while repairing it.
                            """))
            }
        }
        return rows
    }

    @concurrent public static func claudeWorklog(input: [String: JSONValue] = [:]) async -> JSONValue {
        var since: Date?
        if case .string(let text)? = input["since"], !text.isEmpty {
            since = text == "today" ? Calendar.current.startOfDay(for: Date()) : NativeTimestampFormat.parseISO8601(text)
            guard since != nil else {
                return .object(["status": .string("failed"), "detail": .string("since must be today or an ISO 8601 timestamp with timezone.")])
            }
        }
        var limit = 10
        if let value = input["limit"], value != .null {
            guard case .int(let count) = value, (1...50).contains(count) else {
                return .object(["status": .string("failed"), "detail": .string("limit must be an integer from 1 to 50.")])
            }
            limit = Int(count)
        }
        let claudeWorklogURL = InstallPaths.current.claudeWorklog
        let rows: [[String: Any]]
        do { rows = try claudeWorklogTail(claudeWorklogURL) }
        catch CocoaError.fileReadNoSuchFile {
            return .object(["status": .string("unavailable"), "effects": .string("none"),
                "detail": .string("The advertised worklog is missing at \(claudeWorklogURL.path); restore its writer or remove the advertised read."),
                "remedy": Repair.remedy(owner: claudeWorklogURL.path, nextCall: nil, tap: nil)])
        } catch let failure as ToolFailureError {
            var fields = failure.failureEvidence(defaultCode: "agent_worklog_incomplete")
            fields["status"] = .string("unavailable")
            fields["detail"] = .string(failure.message)
            return .object(fields)
        } catch {
            let remedy: JSONValue = .object(["kind": .string("inspect"),
                    "instruction": .string("""
                        Inspect the path with next_call to identify the failed read's cause. If macOS denies access, the person must grant it in \
                        System Settings > Privacy & Security > Full Disk Access > NativeAgent switch. Inspection alone changes nothing.
                        """),
                    "next_call": .object(["tool": .string("app"),
                        "input": .object(["action": .string("files.info"), "args": .object(["path": .string(claudeWorklogURL.path)])])])])
            return .object(["status": .string("unavailable"), "effects": .string("none"),
                "detail": .string("Worklog read failed at \(claudeWorklogURL.path): \(error.localizedDescription)"),
                "remedy": remedy])
        }
        let entries = rows.compactMap { row -> (Date, JSONValue)? in
            guard let ts = row["ts"] as? String, let at = NativeTimestampFormat.parseISO8601FractionalFirst(ts),
                  since.map({ at >= $0 }) ?? true,
                  let summary = row["summary"] as? String, let kind = row["kind"] as? String else { return nil }
            return (at, .object([
                "time": .string(ts), "kind": .string(String(kind.prefix(80))),
                "summary": .string(String(summary.prefix(600))),
                "refs": .array((row["refs"] as? [String] ?? []).prefix(5).map { .string(String($0.prefix(200))) }),
            ]))
        }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        return .object(["status": .string("ok"), "agent": .string("claude"),
            "entries": .array(entries), "order": .string("newest_first"),
            "coverage": .string("Recent worklog tail (up to 64 KiB), not full history."),
            "untrusted_remote_data": .bool(true),
            "detail": .string(entries.isEmpty ? "No recent worklog entries match this read." : "Claude's recorded work; not independently verified.")])
    }

    /// An available outbound transport can owe a reply until its owner settles or the caller cancels.
    public static func dotReply(_ receipt: JSONValue, sentAt: Date?) -> JSONValue {
        guard sentAt != nil, ChatGPTDotIPCTransport.available, case .object(var fields) = receipt else { return receipt }
        fields["status"] = .string("waiting")
        return .object(fields)
    }

    static func queueProjection(_ row: AgentConversationRecord?) -> JSONValue? {
        guard let row, let queued = row.queued, !queued.isEmpty else { return nil }
        return .array(queued.map { item in
            let going = item.id == row.queueReservation
            let refused = item.notSentReason != nil
            var fields: [String: JSONValue] = ["id": .string(item.id), "text": .string(AgentScreen.clip(item.text, 400)),
                "queued_at": .string(ISO8601DateFormatter().string(from: item.queuedAt)),
                "by_person": .bool(item.byPerson == true),
                "state": .string(item.held == DataRootLife.stoppedReason ? "stopped" : refused ? "not_sent"
                    : item.waitingForMac == true ? "held" : going ? "sending" : "queued"),
                "detail": .string(item.held ?? (going ? "Going now: the reply ahead of it has settled."
                    : "Goes by itself when the reply ahead of it settles."))]
            if refused { fields["terminal"] = .bool(true); fields["sent"] = .bool(false) }
            return .object(fields)
        })
    }

    static func withQueue(_ result: JSONValue, row: AgentConversationRecord?) -> JSONValue {
        guard let queued = queueProjection(row), case .object(var fields) = result else { return result }
        fields["queued"] = queued
        return .object(fields)
    }

    /// Compact results keep the exchange and summary without duplicating retained history.
    static func compact(_ result: JSONValue, row: AgentConversationRecord?) -> JSONValue {
        guard let row, case .object(var fields) = result else { return result }
        fields.removeValue(forKey: "session_history")
        // A reply makes the embedded recent conversation redundant.
        if fields["reply"] != nil { fields.removeValue(forKey: "conversation_note") }
        if fields["reply"] != nil, case .array? = fields["conversation"] { fields.removeValue(forKey: "conversation") }
        var thread: [String: JSONValue] = ["conversation": .string(row.label), "exchanges": .int(Int64(row.exchanges?.count ?? 0)),
            "state": .string(row.phase), "history": .string("agent_read shows the conversation, both directions.")]
        if let id = AgentConversationSession.threadID(row) { thread["thread_id"] = .string(id) }
        fields["thread"] = .object(thread)
        return .object(fields)
    }

    package static func view(_ row: AgentConversationRecord, details: Bool, read: Bool = false, dataRoot: URL,
                     historyBefore: String? = nil, historyExchange: String? = nil, includeHistory: Bool = true,
                     historyLimit: Int = 8) -> JSONValue {
        let receipt = row.sendReceipt ?? .object(["status": .string("unknown")])
        guard case .object = receipt else { return receipt }
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() }
        catch {
            return .object(["status": .string("unavailable"), "detail": .string("Contact identity could not be read: " + error.localizedDescription),
                "retained_send": receipt, "effects": .string("none"),
                "remedy": Repair.remedy(owner: "agents/peers.json", nextCall: nil, tap: "Repair the contact address book before resolving this conversation.")])
        }
        let peer = peers.first { "peer:" + $0.id == row.agent }
        let owner = row.agent.hasPrefix("peer:") ? String(row.agent.dropFirst(5)) : row.agent
        let identity = AgentContactIdentity(contacts: peers)
        let history = !details && includeHistory
        let lines: Result<[ContactThread.Line], Error>? = history ? Result { try ContactThread.mergedLines(dataRoot: dataRoot, owner: owner,
            identity: identity) } : nil
        var result = details ? receipt : conversationPresentation(row, transport: peer?.transport, prefix: read ? "last_send_" : "")
        if history {
            result = AgentConversationHistoryView.adding(to: result, agent: row.agent, name: row.name,
                before: historyBefore, exchange: historyExchange, limit: historyLimit, dataRoot: dataRoot, peers: peers, lines: lines)
        }
        result = withLive(result, row: row, dataRoot: dataRoot)
        guard case .object(var shown) = result else { return result }
        if shown["can_reply"] == .bool(true), let presence = peer.flatMap(AgentContactHealth.checkIn) {
            shown["can_reply_detail"] = .string(presence.detail)
            result = .object(shown)
        }
        if let id = AgentConversationSession.threadID(row) {
            shown["thread_id"] = .string(id)
            result = .object(shown)
        }
        // The read keeps its outcome independently of the prefixed retained send.
        let readOwn: Set<String> = shown["session_history"] == nil ? ["read", "nothing_to_read", "unavailable"] : ["read"]
        if read, !details, let last = AgentConversationSession.string(shown["status"]), !readOwn.contains(last) {
            shown["status"] = .string("read")
            result = .object(shown)
        }
        if read {
            if case .object(let history)? = shown["session_history"], history["status"] == .string("unavailable") {
                shown["status"] = .string("unavailable")
            } else {
                // A successful read retains the send's saved error and execution as send evidence.
                shown["execution"] = .string("executed")
                shown["effect"] = .string("none")
            }
            result = .object(shown)
        }
        // Consume the answering row's stamp, otherwise the cache writer's; history consumes each line separately.
        let liveText: String? = if case .object(let live)? = shown["live"], live["untrusted_remote_data"] == .bool(true) {
            AgentConversationSession.string(live["partial_reply"]) ?? AgentConversationSession.string(live["partial_text"]) ?? ""
        } else { nil }
        if let reply = AgentConversationSession.string(shown["reply"]) ?? liveText ?? (shown["untrusted_remote_data"] == .bool(true)
            && shown["session_history"] == nil ? "" : nil) {
            let transcript = (try? (lines ?? Result { try ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: identity) }).get()) ?? []
            let answered = transcript.last(where: { !$0.mine && $0.answers == row.operationID })
                ?? ContactThread.Line(text: reply, stamp: row.cachedReplyStamp)
            ContactThread.consume(answered) { PeerDataTaint.markConsumed(peer: $0, line: $1) }
        }
        return result
    }

    static func withLive(_ result: JSONValue, row: AgentConversationRecord?, dataRoot: URL) -> JSONValue {
        guard let row, case .object(var fields) = result else { return result }
        let current: AgentConversationLive?
        do { current = try AgentConversationLiveStore(dataRoot: dataRoot).current(for: row) }
        catch {
            fields["live"] = .object(["state": .string("unavailable"),
                "detail": .string("Live conversation evidence could not be read: " + error.localizedDescription),
                "remedy": Repair.remedy(owner: "agents/conversation-live.json", nextCall: nil,
                    tap: "Repair the live conversation file; preserve its existing bytes.")])
            return .object(fields)
        }
        guard let live = current,
              case .object(var projection) = live.projection(name: row.name) else { return result }
        if row.agent.hasPrefix("peer:"), projection["partial_text"] != nil { projection["untrusted_remote_data"] = .bool(true) }
        fields["live"] = .object(projection)
        return .object(fields)
    }

    /// `prefix`: a read passes "last_send_" so the retained send never reads as the read's own outcome; a send keeps its own fields at top level.
    package static func conversationPresentation(_ row: AgentConversationRecord, transport: AgentPeerTransport? = nil, prefix: String = "") -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        let value = row.sendEvidence
        let status = row.sendStatus
        // Unavailable continuation means its backing session is gone.
        let deadThread = (AgentConversationSession.string(value["reason"]) ?? AgentConversationSession.string(
            value["execution_error"])) == "continuation_unavailable"
        // Terminal attention can be superseded; otherwise explain when a new send can proceed.
        var canReply = !["sending", "waiting"].contains(row.phase)
        var replyDetail: String?
        if row.queued?.contains(where: { $0.waitingForMac == true }) == true {
            canReply = false
            replyDetail = "Waiting for the Mac to be free; the held message will go then. A new message queues behind it."
        } else if ["sending", "waiting"].contains(row.phase), !canReply {
            replyDetail = "After \(row.name) answers the message in progress; a message sent now waits in the queue and goes by itself then."
        } else if row.phase == "attention", deadThread {
            canReply = false
            replyDetail = "In a new conversation only (new_conversation: true): the \(row.name) session behind “\(row.label)” no longer exists."
        } else if row.phase == "attention", AgentConversationRecord.approvalWaits(status), AgentConversationSession.unsettledAttention(row) {
            canReply = false
            replyDetail = "After the person decides on the approval for the previous message; a message sent now waits in the queue and goes by itself then."
        } else if AgentConversationSession.unsettledAttention(row) {
            canReply = false
            replyDetail = """
                After the previous message's outcome is known (it may still be running) or agent_cancel releases it; a message sent now waits in \
                the queue and goes by itself then.
                """
        } else if row.phase == "attention", value["sent"] == .bool(false) || root["sent"] == .bool(false) {
            replyDetail = "The last message did not go out (\(status)); a new message tries \(row.name) again."
        }
        var result: [String: JSONValue] = ["agent": .string(row.name), "agent_id": .string(row.agent),
            "conversation": .string(row.label), "state": .string(row.phase),
            "can_reply": .bool(canReply), "status": .string(status),
            "inspect_receipt": .object(["tool": .string("agent_read"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "details": .bool(true)])])]
        var lastSend: [String: JSONValue] = ["status": .string(status)]
        if let replyDetail { result["can_reply_detail"] = .string(replyDetail) }
        if canReply {
            result["reply_with"] = .object(["tool": .string("agent_message"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "text": .string("<your next message>")])])
        }
        if let conversation = row.conversationID, conversation != row.label, !row.agent.hasPrefix("bot:") {
            // Desktop titles and local conversation labels are separate identities.
            result[transport == .desktopChat ? "app_chat_title" : "conversation_id"] = .string(conversation)
        }
        if AgentConversationSession.backgroundSend(row) {
            result["state"] = .string("working")
            // A new remote session may not yet have supplied its ID.
            result["conversation_id"] = row.conversationID.map(JSONValue.string) ?? .null
        }
        if let current = row.exchanges?.last(where: { $0.id == row.operationID }) {
            lastSend.merge(current.timing) { _, timing in timing }
        }
        if let text = reply(value) { result["reply"] = .string(text) }
        for key in ["untrusted_remote_data", "source_availability", "read_error", "retention_error", "reply_truncated", "reply_location",
            "receipt_truncated", "artifacts", "parts", "has_more", "read_with", "attribution", "messages"] {
            if let field = value[key] ?? root[key] { result[key] = field }
        }
        for key in ["reply_state", "automatic_resend", "read", "execution", "completed", "terminal", "needs_input",
            "needs_authentication", "sent", "delivery", "effects", "argument_path", "accepted", "reason", "error", "execution_error", "healed",
                "repair", "remedy", "body_item", "delivered", "delivered_at"] {
            if let field = value[key] ?? root[key] { lastSend[key] = field }
        }
        if row.phase != "sending", row.sendFailed { lastSend["delivery"] = .string("failed") }
        if let detail = value["detail"] { lastSend["detail"] = detail }
        if row.phase == "waiting" {
            let automatic = row.automaticRead || row.readInput != nil
            lastSend["detail"] = .string(transport == .desktop
                ? """
                    \(row.name) is answering in its own chat; the answer is read from there and lands on this exchange by itself.
                    """
                : AgentConversationSession.backgroundSend(row)
                ? root["delivery"] == .string("unconfirmed")
                    ? """
                        The connection or send is still running; delivery to \(row.name) is unconfirmed. This operation will bring its outcome \
                        here; do not resend this message.
                        """
                    : """
                        \(row.name) is working on it. Its reply comes to you as a turn by itself when it lands (wait on this conversation returns \
                        it instead).
                        """
                : automatic
                ? "Waiting for \(row.name). NativeAgent will bring the answer back; no repeated checks or resend needed."
                : "Waiting for \(row.name)'s configured return connection. Do not resend this message.")
        } else if row.phase == "sending" {
            lastSend["detail"] = .string("The previous send has not settled. It may have been interrupted; no message has been resent.")
        }
        if row.phase == "attention", let detail = row.deliveryState { lastSend["detail"] = .string(detail) }
        if row.phase == "attention", deadThread {
            lastSend["detail"] = .string("""
                “\(row.label)” points at a \(row.name) conversation whose session no longer exists, so no work started and nothing was sent on. \
                Start a new conversation (new_conversation: true) to ask again.
                """)
        }
        if row.phase == "sending" {
            // The retained receipt routes task resumption until dispatch settles; its answer is not this turn's.
            for key in ["reply", "reply_truncated", "artifacts", "parts"] { result.removeValue(forKey: key) }
            for key in ["completed", "terminal", "sent"] { lastSend.removeValue(forKey: key) }
            result["status"] = .string("sending")
            lastSend["status"] = .string("sending")
            lastSend["reply_state"] = .string("no_reply_observed")
        }
        if let stop = row.stop, stop.operationID == row.operationID,
           stop.state != "cannot_stop" || ["sending", "waiting"].contains(row.phase) {
            result["stop"] = .object(["state": .string(stop.state), "detail": .string(stop.detail),
                                      "at": .string(ISO8601DateFormatter().string(from: stop.at))])
            if stop.state == "stopped" { result["status"] = .string("cancelled"); lastSend["status"] = .string(
                "cancelled"); lastSend["detail"] = .string(stop.detail) }
        }
        if let queued = queueProjection(row) { result["queued"] = queued }
        if ["sending", "waiting"].contains(row.phase), case .string(let detail)? = lastSend["detail"] {
            let cancel = [.desktop, .desktopChat].contains(transport) ? "."
                : transport == .grokBot ? "; agent_cancel stops waiting on it." : "; agent_cancel stops it."
            lastSend["detail"] = .string(detail + " A follow-up queues behind it" + cancel)
        }
        // Prefix outcome and timing together so neither describes the read showing this retained send.
        for (key, field) in lastSend { result[prefix + key] = field }
        result["evidence"] = .string("Latest retained conversation result; an agent's answer is not independent verification of its work.")
        return .object(result)
    }

    static func reply(_ row: [String: JSONValue]) -> String? {
        AgentConversationSession.string(row["reply"]) ?? AgentConversationSession.string(row["answer"])
            ?? AgentConversationSession.string(row["findings"])
    }

    public static func read(_ receipt: JSONValue, agent: String, input: [String: JSONValue]) -> JSONValue {
        guard input["details"] != .bool(true), case .object(let raw) = receipt else { return receipt }
        // Preserve refusals and desktop interaction instructions verbatim.
        if raw["status"] == .string("requires_interaction") || raw["error"] != nil { return receipt }
        let rows: [[String: JSONValue]]
        let kind: String
        if case .array(let values)? = raw["entries"] {
            rows = values.compactMap(\.objectValue); kind = "bot_preview"
        } else if agent.hasPrefix("bot:") {
            rows = [raw]; kind = "bot"
        } else if agent.hasPrefix("peer:") {
            rows = [raw]; kind = "peer"
        } else { return receipt }
        var result: [String: JSONValue] = [
            "agent": .string(agent), "status": raw["status"] ?? .string("ok"),
            "view": .string("conversation"),
            "exchanges": .array(rows.map { exchange($0, agent: agent, kind: kind) }),
            "meaning": .string("Agent replies with recorded progress; their work is not independently verified."),
            "order": .string(rows.count > 1 ? "newest_first" : "single_exchange")
        ]
        for key in ["source_availability", "has_more", "next_offset", "nextCursor", "truncated", "coverage", "conversation_id", "message_id",
            "task_id", "completed", "terminal", "untrusted_remote_data", "detail", "read_with"] {
            if let value = raw[key] { result[key] = value }
        }
        var exact = input.filter { !["session_id", "__session_id", "details"].contains($0.key) }
        exact["agent"] = .string(agent)
        var detail = exact; detail["details"] = .bool(true)
        result["inspect_receipt"] = call("agent_read", detail)
        if raw["has_more"] == .bool(true), let offset = raw["next_offset"] {
            var next = exact; next["offset"] = offset
            result["read_more"] = call("agent_read", next)
        }
        if let cursor = raw["nextCursor"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) {
            // The bot shelf owns its opaque cursor; do not invent offset paging.
            result["read_more"] = call("shelf_read", ["id": .string(String(agent.dropFirst(4))), "cursor": .string(cursor)])
        }
        if rows.isEmpty { result["summary"] = .string("No reply is present in this returned page; this does not prove no work occurred.") }
        return .object(result)
    }

    private static func exchange(_ row: [String: JSONValue], agent: String, kind: String) -> JSONValue {
        let evidence = row["remote_evidence"]?.objectValue ?? row
        let body: String?
        switch kind {
        case "bot": body = row["reply"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? row["findings"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        case "bot_preview": body = row["headline"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        default: body = row["reply"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? evidence["reply"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        }
        let conversation: String?
        if agent.hasPrefix("bot:") { conversation = agent }
        else { conversation = row["conversation_id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) }
        let message = row["matched_message_id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? row["message_id"]?.stringValue.flatMap({ $0.isEmpty
            ? nil : $0 }) ?? row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        let task = row["task_id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        var value: [String: JSONValue] = [
            "from": .string(row["agent_name"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? agent),
            "reply_state": body == nil ? row["reply_state"] ?? .string("no_reply_observed") : .string(kind == "bot_preview" ? "preview_only"
                : "reply_received"),
            "execution_state": evidence["original_status"] ?? row["run_status"] ?? row["status"] ?? row["state"] ?? .string("unknown")
        ]
        // Show the ask before its answer so the thread reads in conversational order.
        if let ask = row["request_text_head"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) { value["you_asked"] = .string(ask) }
        if let body {
            value["text"] = .string(body)
            value["text_kind"] = .string(kind == "bot_preview" ? "headline" : "reply")
        }
        for key in ["topic_slug", "created_at", "completed_at", "runAt", "delivery_outcome", "execution_error", "recovery_note", "needs_input",
            "needs_authentication", "artifacts"] {
            if let field = row[key] { value[key] = field }
        }
        for key in ["has_more", "next_offset", "coverage", "original_outcome", "evidence"] {
            if let field = evidence[key] { value[key] = field }
        }
        if let message { value["message_id"] = .string(message) }
        if let conversation { value["conversation_id"] = .string(conversation) }
        if let task { value["task_id"] = .string(task) }
        if let locator = AgentConversationRouting.readLocator(agent: agent, message: message.map(JSONValue.string), conversation: conversation.map(
            JSONValue.string), task: task.map(JSONValue.string)) {
            value["read_with"] = locator
            if evidence["has_more"] == .bool(true), let offset = evidence["next_offset"],
               case .object(let action) = locator, case .object(var next)? = action["input"] {
                next["offset"] = offset
                value["read_more"] = call("agent_read", next)
            }
        }
        if let conversation {
            var target: [String: JSONValue] = ["agent": .string(agent), "conversation_id": .string(conversation)]
            // A2A 0.3 native ingress does not support task resumption. A new message in the same context works for all supported adapters.
            target["text"] = .string("<your next message>")
            if row["needs_input"] == .bool(true), let task { target["task_id"] = .string(task) }
            value["reply_with"] = call("agent_message", target)
        } else {
            value["continuation"] = .string("The source did not retain a conversation handle. Do not silently start a new conversation.")
        }
        return .object(value)
    }

    private static func call(_ tool: String, _ input: [String: JSONValue]) -> JSONValue {
        .object(["tool": .string(tool), "input": .object(input)])
    }
}
