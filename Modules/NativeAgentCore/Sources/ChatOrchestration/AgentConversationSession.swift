import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots

/// Conversational operation over existing gated adapters. No protocol or
/// permission is implemented here; every actual send/read enters its owner.
enum AgentConversationSession {
    typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue

    static func dispatch(tool: String, input: [String: JSONValue], surface: String,
                         scope: String, dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        var args = input.filter { $0.value != .null }
        let label = string(args.removeValue(forKey: "conversation"))
        let historyBefore = string(args.removeValue(forKey: "history_before"))
        let historyExchange = string(args.removeValue(forKey: "history_exchange"))
        if historyBefore != nil || historyExchange != nil {
            guard tool == "agent_read", args["details"] != .bool(true), !agentIsBot(args),
                  historyBefore == nil || historyExchange == nil,
                  [historyBefore, historyExchange].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw AgentConversationStore.Failure(message: "Choose one offered session-history page or exchange. This only reads retained messages.")
            }
        }
        let freshValue = args.removeValue(forKey: "new_conversation")
        if let freshValue, case .bool = freshValue {} else if freshValue != nil {
            throw AgentConversationStore.Failure(message: "new_conversation must be true or false.")
        }
        let fresh = freshValue == .bool(true)
        guard let agent = string(args["agent"]) else { return try await perform(tool, args) }
        // Exact protocol calls remain available for diagnostics and existing clients.
        let advanced: Set<String> = ["conversation_id", "message_id", "task_id", "page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after", "limit", "offset"]
        if args.contains(where: { advanced.contains($0.key) && $0.value != .string("") }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            return try await perform(tool, args)
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let peer = try AgentPeerStore(dataRoot: dataRoot).list().first { "peer:" + $0.id == agent }
        if agent.hasPrefix("peer:"), peer == nil { throw AgentConversationStore.Failure(message: "This contact is no longer connected.") }
        let botName = try BotDefinitionStore(dataRoot: dataRoot).list().first {
            "bot:" + $0.id.uuidString.lowercased() == agent.lowercased()
        }?.name
        let name = peer?.name ?? botName ?? agent.capitalized
        let fingerprint = peer.map(AgentConversationStore.routeFingerprint)
        if fresh, agent.hasPrefix("bot:") || peer?.transport == .desktop || peer?.transport == .grokBot {
            return attention(name, label: label ?? "Main", "This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not supported by this adapter.")
        }
        if agent.hasPrefix("bot:"), let label, label != "Main" {
            return attention(name, label: label, "This helper has one continuous conversation. Omit the conversation label to continue it; a different label cannot create an independent discussion for this bot.")
        }
        var previous = try store.find(scopeSessionID: scope, agent: agent, label: label)
        if let row = previous, !AgentConversationStore.sameRoute(row.peerRouteFingerprint, peer) {
            guard tool == "agent_message", fresh else {
                return attention(name, label: row.label, "The contact's connection changed. Start a separate conversation explicitly; this conversation has been preserved.")
            }
        }
        if tool == "agent_read" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "Start a new conversation by sending its first message.") }
            if agent.hasPrefix("bot:") {
                // Bots already own a durable conversation and shelf, even if
                // this Agent chat has never opened it. Always read the owner's
                // latest actual reply; exact message-ID reads still bypass
                // this facade above. Do not substitute an older cached ask.
                return try await perform(tool, args)
            }
            if ["codex", "claude", "omp"].contains(agent) {
                // The built-in lanes keep their own thread; the window shows
                // its recent exchanges, not one chat's retained receipt.
                if args["limit"] == nil, args["message_id"] == nil { args["limit"] = .int(6) }
                return try await perform(tool, args)
            }
            guard let row = previous else {
                return .object(["agent": .string(agent), "with": .string(name), "state": .string("not_opened"),
                    "detail": .string("No saved conversation in this chat. Send your first message to start one.")])
            }
            let refreshed = try await refresh(row, store: store, input: args, perform: perform)
            return view(refreshed, details: args["details"] == .bool(true), dataRoot: dataRoot,
                        historyBefore: historyBefore, historyExchange: historyExchange)
        }
        guard tool == "agent_message" else { return try await perform(tool, args) }
        // The existing callback owns built-in completion. Recover its exact
        // receipt when continuing, including the executor's eventual thread ID.
        if let row = previous, row.phase == "waiting", !fresh, !row.automaticRead, row.readInput != nil {
            previous = try await refresh(row, store: store, input: args, perform: perform)
        }
        if let row = previous, !fresh {
            if ["sending", "waiting"].contains(row.phase) {
                return attention(name, label: row.label, "The previous message has not settled. NativeAgent is preserving its state; open this conversation to see its available reply. No new message was sent.")
            }
            // 2026-09-22 WHY: ACP and Muse reads return nothing_to_read, so one
            // timeout or approval card locked the thread for good. With a known
            // conversation id an explicit next message just continues it.
            // Grok can't start fresh, so an unanswered or unknown send must not strand it.
            let resumable = peer?.transport == .grokBot
                || row.conversationID != nil && (peer?.transport == .acp || peer?.transport == .desktopChat)
            if row.phase == "attention", !resumable, !settledBotTurn(row), !confirmedNotSent(row) {
                return attention(name, label: row.label, "This conversation needs attention. Open it to see the retained result; no message was repeated.")
            }
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .grokBot {
                return attention(name, label: row.label, "This contact did not confirm a resumable conversation. Start a separate conversation explicitly rather than silently losing its context.")
            }
        }
        let replyRoute = ChatToolSessionContext.replyRoute.map { route in
            ["surface": route.surface, "destinationId": route.destinationId,
             "threadId": route.threadId, "sourceKey": route.sourceKey,
             "replyTo": route.replyTo, "correlationId": route.correlationId].compactMapValues { $0 }
        }
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: name, label: label,
                                  fresh: fresh, sourceSurface: surface, fingerprint: fingerprint, replyRoute: replyRoute,
                                  message: string(args["text"]),
                                  legacyFingerprint: peer.map(AgentConversationStore.legacyRouteFingerprint))
        // Grok's conversation is always the asking chat; a saved id from another chat is refused.
        if let conversation = row.conversationID, peer?.transport != .grokBot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        do {
            let receipt = try await perform(tool, args)
            let saved = try record(receipt, for: row, store: store, peer: peer)
            return view(saved, details: false, dataRoot: dataRoot)
        } catch {
            // An exception may occur after dispatch. Keep the exact previous
            // binding and mark uncertainty; never synthesize a replacement send.
            _ = try? store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "attention"
                $0.receipt = .object(["status": .string("outcome_unknown"),
                    "detail": .string("The send did not establish an outcome. The conversation was preserved; no message was resent.")])
            }
            throw error
        }
    }

    private static func refresh(_ row: AgentConversationRecord, store: AgentConversationStore,
                                input: [String: JSONValue], perform: Dispatch) async throws -> AgentConversationRecord {
        var read = row.readInput ?? ["agent": .string(row.agent)]
        read["details"] = .bool(true)
        for key in ["session_id", "__session_id"] { read[key] = input[key] }
        let receipt = try await perform("agent_read", read)
        // Synchronous command/ACP adapters do not expose a recovery endpoint.
        // Their gate still ran; show the clearly labelled retained last result.
        if case .object(let value) = receipt, value["status"] == .string("nothing_to_read") {
            return try store.update(id: row.id, operationID: row.operationID) { $0.selected = true }
        }
        // A read that did not reach its owner cannot expose a cached reply.
        if isRefusal(receipt) { throw AgentConversationStore.Failure(message: "This conversation cannot be opened with the current access settings.") }
        // Without an exact locator this read was admission-only. An unscoped
        // recent listing cannot become evidence for the bookmarked exchange.
        if row.readInput == nil {
            return try store.update(id: row.id, operationID: row.operationID) { $0.selected = true }
        }
        return try store.update(id: row.id, operationID: row.operationID) {
            absorb(receipt, into: &$0)
            $0.selected = true
        }
    }

    private static func record(_ receipt: JSONValue, for row: AgentConversationRecord,
                               store: AgentConversationStore, peer: AgentPeerContact?) throws -> AgentConversationRecord {
        try store.update(id: row.id, operationID: row.operationID) {
            // Don't keep a previous request locator for a new uncertain send.
            $0.readInput = nil
            absorb(receipt, into: &$0)
            $0.automaticRead = $0.phase == "waiting" && $0.readInput != nil
                && (peer?.transport == .a2a || peer?.transport == .nativeAgent)
            $0.nextReadAt = $0.automaticRead ? Date() : nil
            if !isRefusal(receipt) { $0.selected = true }
        }
    }

    /// Shared by recovery: consume only identities/evidence supplied by owners.
    static func absorb(_ receipt: JSONValue, into row: inout AgentConversationRecord) {
        row.receipt = AgentConversationStore.cacheReceipt(receipt)
        guard case .object(let root) = receipt else { row.phase = "attention"; return }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        if let conversation = string(value["conversation_id"]) ?? string(value["conversationId"]) { row.conversationID = conversation }
        else if row.agent == "codex", let thread = string(value["thread_id"]) { row.conversationID = "codex:" + thread }
        if case .object(let action)? = root["read_with"], case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        } else if let locator = AgentConversationRouting.readLocator(agent: row.agent,
            message: value["message_id"] ?? value["messageId"] ?? value["matched_message_id"],
            conversation: row.conversationID.map(JSONValue.string), task: value["task_id"]),
                  case .object(let action) = locator, case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        }
        let state = string(value["run_status"]) ?? string(value["status"]) ?? string(value["state"]) ?? "unknown"
        if isRefusal(receipt) || ["failed", "interrupted", "waiting_approval", "waiting_for_approval", "waiting for approval", "waiting_on_you", "waiting_on_person", "waiting on you", "outcome_unknown", "unavailable", "cancelled", "canceled", "reconnect_required", "session_unavailable"].contains(state) {
            row.phase = "attention"
        } else if value["needs_input"] == .bool(true) || value["completed"] == .bool(true)
                    || value["terminal"] == .bool(true) || ["replied", "completed", "succeeded", "done", "answered", "sent"].contains(state) {
            row.phase = "ready"
        } else if ["enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending"].contains(state) {
            row.phase = "waiting"
        } else if reply(value) != nil {
            row.phase = "ready"
        } else { row.phase = "attention" }
        if row.phase != "waiting" { row.nextReadAt = nil; row.automaticRead = false }
    }

    static func view(_ row: AgentConversationRecord, details: Bool, dataRoot: URL,
                     historyBefore: String? = nil, historyExchange: String? = nil) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        // Cached reads retain peer provenance instead of laundering it through
        // this presentation layer. Elevation still comes from the current owner.
        if row.agent.hasPrefix("peer:"), root["untrusted_remote_data"] == .bool(true) || !(row.exchanges ?? []).isEmpty,
           (try? AgentPeerStore(dataRoot: dataRoot).list().first { "peer:" + $0.id == row.agent }?.elevationAllowed) != true {
            PeerDataTaint.markConsumed(peer: row.agent)
        }
        if details { return receipt }
        return AgentConversationHistoryView.adding(to: conversationPresentation(row), row: row,
            before: historyBefore, exchange: historyExchange)
    }

    /// Compare routing-owner evidence locally without presenting cached text or
    /// treating the conversation list as consumption of a peer's reply.
    static func workspaceChangeObservation(_ row: AgentConversationRecord,
                                          location: AgentWorkspaceLocation,
                                          previous: AgentWorkspaceChanges.Stamp?) -> AgentWorkspaceChanges.Observation? {
        AgentWorkspaceChanges.evaluate(location: location, result: conversationPresentation(row), previous: previous)
    }

    private static func conversationPresentation(_ row: AgentConversationRecord) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        var result: [String: JSONValue] = ["agent": .string(row.agent), "with": .string(row.name),
            "conversation": .string(row.label), "state": .string(row.phase),
            "can_reply": .bool(!["sending", "waiting"].contains(row.phase)
                && (row.phase != "attention" || settledBotTurn(row) || confirmedNotSent(row))),
            "status": value["run_status"] ?? value["status"] ?? .string(row.phase),
            "reply_with": .object(["tool": .string("agent_message"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "text": .string("<your next message>")])]),
            "inspect_receipt": .object(["tool": .string("agent_read"), "input": .object([
                "agent": .string(row.name), "conversation": .string(row.label), "details": .bool(true)])])]
        if ["codex", "claude", "omp"].contains(row.agent), root["jobs"] != nil {
            let original = AgentConversationView.codingReply(value)
            if let text = original.text {
                result["reply"] = .string(text)
                result["reply_truncated"] = .bool(original.truncated)
                result["reply_state"] = .string("reply_received")
            } else {
                result["reply_state"] = .string("no_reply_observed")
                if row.phase == "ready" {
                    result["detail"] = .string("This saved record has delivery status but no original answer text. No message was resent.")
                }
            }
        } else if let text = reply(value) { result["reply"] = .string(text) }
        for key in ["untrusted_remote_data", "source_availability", "completed", "terminal", "needs_input", "needs_authentication", "sent", "reason", "error", "execution_error", "reply_truncated", "artifacts", "parts", "has_more"] {
            if let field = value[key] ?? root[key] { result[key] = field }
        }
        // delegation_status.detail is a format selector ("full"), not an
        // explanation of the selected exchange.
        if root["jobs"] == nil, let detail = value["detail"] { result["detail"] = detail }
        if row.phase == "waiting" {
            let automatic = row.automaticRead || ["codex", "claude", "omp"].contains(row.agent)
            result["detail"] = .string(automatic
                ? "Waiting for \(row.name). NativeAgent will bring the answer back; no repeated checks or resend needed."
                : "Waiting for \(row.name)'s configured return connection. Do not resend this message.")
        } else if row.phase == "sending" {
            result["detail"] = .string("The previous send has not settled. It may have been interrupted; no message has been resent.")
        }
        if row.phase == "attention", let detail = row.deliveryState { result["detail"] = .string(detail) }
        if row.phase == "sending" {
            // The owner keeps the previous receipt for task-resumption routing
            // until dispatch settles. Never show its answer as this new turn.
            for key in ["reply", "completed", "terminal", "sent", "reply_truncated", "artifacts", "parts"] { result.removeValue(forKey: key) }
            result["status"] = .string("sending")
            result["reply_state"] = .string("no_reply_observed")
        }
        result["evidence"] = .string("Latest retained conversation result; an agent's answer is not independent verification of its work.")
        return .object(result)
    }

    private static func reply(_ row: [String: JSONValue]) -> String? {
        string(row["reply"]) ?? string(row["answer"]) ?? AgentConversationView.codingReply(row).text ?? string(row["findings"])
    }
    private static func settledBotTurn(_ row: AgentConversationRecord) -> Bool {
        guard row.agent.hasPrefix("bot:"), case .object(let receipt)? = row.receipt,
              string(receipt["entry_id"]) != nil || string(receipt["message_id"]) != nil else { return false }
        // A saved terminal bot turn permits a new explicit follow-up, including
        // after a partial answer. It is never an automatic retry of that turn.
        return ["failed", "interrupted", "waiting_approval", "waiting_on_you", "waiting_for_approval", "waiting_on_person", "waiting for approval", "waiting on you"].contains(
            string(receipt["run_status"]) ?? string(receipt["status"]) ?? "")
    }
    private static func confirmedNotSent(_ row: AgentConversationRecord) -> Bool {
        guard case .object(let receipt)? = row.receipt,
              receipt["sent"] == .bool(false) else { return false }
        // Only a new explicit message may try again after a pre-dispatch refusal.
        // Pending approvals and uncertain/accepted sends still require recovery;
        // the adapter rechecks current authority and connection on every attempt.
        return ["reconnect_required", "unavailable", "needs_setup", "no_outbound_route",
                "blocked", "denied", "blocked_by_trust", "busy"].contains(string(receipt["status"]) ?? "")
    }
    private static func isRefusal(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        return row["error"] != nil || row["sent"] == .bool(false)
            || ["blocked", "denied", "blocked_by_trust", "approval_required", "approval_filed", "needs_setup", "no_outbound_route"].contains(string(row["status"]) ?? "")
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return value
    }
    private static func agentIsBot(_ input: [String: JSONValue]) -> Bool {
        string(input["agent"])?.hasPrefix("bot:") == true
    }
    private static func attention(_ name: String, label: String, _ text: String) -> JSONValue {
        .object(["with": .string(name), "conversation": .string(label), "state": .string("attention"), "detail": .string(text), "sent": .bool(false)])
    }
}
