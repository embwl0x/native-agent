import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import Privacy
import StandingBots
import TurnTrace
import MacControl
// Blueprint: | `AgentConversationSession.swift` | Conversation admission, approval replay, inline observation and one send settlement. |

/// Approval execution retains the original exchange and all ordinary gates.
public enum AgentConversationApproval {
    /// Approval replay and repair dry runs must traverse the original gated dispatch chain.
    package static func replay(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
                              id: String, dataRoot: URL, awaitingHostReply: Bool = false,
                              dispatch: @escaping AgentConversationSession.Dispatch,
                              perform: @escaping @Sendable (Turn, AgentConversationContext,
                                  MacOperationContext) async throws -> JSONValue) async throws -> JSONValue {
        if awaitingHostReply {
            return try await perform(turn, conversation.internalRead, mac)
        }
        return try await AgentConversationSession.replayApproval(turn: turn, mac: mac, conversation: conversation, workspace: workspace, id,
            dataRoot: dataRoot, dispatch: dispatch, perform: perform)
    }
}

/// Conversation coordination implements no protocol or permissions; sends and reads enter their owners.
package enum AgentConversationSession {
    package typealias Dispatch = @Sendable (String, [String: JSONValue], Turn, AgentConversationContext, MacOperationContext) async throws -> JSONValue

    static func approvalRow(_ id: String, store: AgentConversationStore) throws -> AgentConversationRecord? {
        try store.records().first {
            guard $0.phase == "attention", case .object(let receipt)? = $0.receipt else { return false }
            return receipt["approvalId"] == .string(id) && AgentConversationRecord.approvalWaits(string(receipt["status"]) ?? "")
        }
    }

    static func replayApproval(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
                               _ id: String, dataRoot: URL, dispatch: @escaping Dispatch,
                               perform: @escaping @Sendable (Turn, AgentConversationContext,
                                   MacOperationContext) async throws -> JSONValue) async throws -> JSONValue {
        let store = AgentConversationStore(dataRoot: dataRoot)
        guard let held = try approvalRow(id, store: store) else {
            throw AgentConversationStore.Failure(message: "This conversation has moved on; the older result was not applied.")
        }
        let peer = try AgentPeerStore(dataRoot: dataRoot).list().first { "peer:" + $0.id == held.agent }
        guard AgentConversationStore.sameRoute(held.peerRouteFingerprint, peer) else {
            let detail = "The contact's connection changed. Start a separate conversation explicitly; this conversation has been preserved."
            try store.update(id: held.id, operationID: held.operationID) {
                guard $0.phase == "attention", $0.receipt == held.receipt else {
                    throw AgentConversationStore.Failure(message: "This conversation has moved on; the older result was not applied.")
                }
                $0.receipt = .object(["status": .string("failed"), "sent": .bool(false),
                    "approvalId": .string(id), "detail": .string(detail)])
            }
            throw AgentConversationStore.Failure(message: detail)
        }
        // Occupy this exact exchange before publishing sending; no queued follow-up can take its place while the approved call is resumed.
        AgentConversationRunning.shared.begin(row: held.id, operation: held.operationID) {}
        let row: AgentConversationRecord
        do { row = try store.update(id: held.id, operationID: held.operationID) {
            guard $0.phase == "attention", $0.receipt == held.receipt else {
                throw AgentConversationStore.Failure(message: "This conversation has moved on; the older result was not applied.")
            }
            $0.phase = "sending"
            if let index = $0.exchanges?.firstIndex(where: { $0.id == held.operationID }) {
                $0.exchanges?[index].phase = "sending"
                $0.exchanges?[index].status = "sending"
                $0.exchanges?[index].settledAt = nil
            }
        } } catch {
            AgentConversationRunning.shared.end(row: held.id, operation: held.operationID)
            throw error
        }
        return try await send(turn: turn, mac: mac, conversation: conversation, workspace: workspace, row, store: store, peer: peer, reservation: nil,
            dataRoot: dataRoot, dispatch: { tool, input, turn, conversation, mac in
            try await dispatch(tool, input, turn, conversation.internalRead, mac)
        }) { turn, conversation, mac in
            try await perform(turn, conversation.internalRead, mac)
        }
    }

    package static func dispatch(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation, tool: String,
        input: [String: JSONValue], surface: String,
                         scope: String, dataRoot: URL, reservation: String? = nil,
                         perform: @escaping Dispatch) async throws -> JSONValue {
        // A job is the agent's commission, not a conversation: reading or stopping one names it in `job`, as agent.apply and agent.discard do.
        if tool == "agent_read" || tool == "agent_cancel", let id = input["job"]?.stringValue {
            return try await AgentJobs.answer(tool: tool, id: id, agent: input["agent"]?.stringValue, dataRoot: dataRoot)
        }
        if tool == "agent_read" || tool == "agent_cancel", input["agent"]?.stringValue == nil {
            throw ToolFailureError("Name the agent whose conversation this is, or job for a job's id.", argumentPath: "agent", effects: .none)
        }
        var input = input
        if tool == "agent_message" {
            try AgentMessageFiles.requireSupported(conversation: conversation, input, dataRoot: dataRoot)
            if try AgentMessageFiles.paths(input["files"]).isEmpty { input.removeValue(forKey: "files") }
        }
        let wait: Int
        if tool == "agent_message" {
            switch input.removeValue(forKey: "wait_seconds") {
            case nil, .null?: wait = 20
            case .int(let seconds)? where (0...120).contains(seconds): wait = Int(seconds)
            default:
                throw ToolFailureError("wait_seconds must be an integer from 0 to 120 (default 20).",
                    argumentPath: "wait_seconds", effects: .none)
            }
        } else { wait = 0 }
        let result = try await dispatchConversation(turn: turn, mac: mac, conversation: conversation, workspace: workspace, tool: tool, input: input,
            surface: surface, scope: scope,
            dataRoot: dataRoot, reservation: reservation, waitSeconds: wait, perform: perform)
        if tool == "agent_read", !readRefused(result), case .object(var fields) = result,
           fields["status"] != .string("unavailable"), fields["state"] != .string("unknown_contact"),
           !["failed", "error", "refused", "not_found"].contains(string(fields["status"]) ?? "") || fields["thread_id"] != nil {
            if case .object(let history)? = fields["session_history"], history["status"] == .string("unavailable") {
                fields["status"] = .string("unavailable")
                return .object(fields)
            }
            fields["execution"] = .string("executed")
            fields["effect"] = .string("none")
            return .object(fields)
        }
        guard tool == "agent_message" else { return result }
        let agent = string(input["agent"]) ?? ""
        let peer = try AgentPeerStore(dataRoot: dataRoot).list().first {
            "peer:" + $0.id == agent || ($0.handles ?? []).contains(agent)
        }
        return messageReceipt(result, live: AgentConversationDelivery.answersLive(peer: peer))
    }

    private static func dispatchConversation(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        tool: String, input: [String: JSONValue], surface: String,
                         scope: String, dataRoot: URL, reservation: String?, waitSeconds: Int,
                         perform: @escaping Dispatch) async throws -> JSONValue {
        var args = input.filter { $0.value != .null }
        var label = string(args.removeValue(forKey: "conversation"))
        let clearQueue = args.removeValue(forKey: "clear_queue") == .bool(true)
        let historyBefore = string(args.removeValue(forKey: "history_before"))
        let historyExchange = string(args.removeValue(forKey: "history_exchange"))
        if historyBefore != nil || historyExchange != nil {
            guard tool == "agent_read", args["details"] != .bool(true), !agentIsBot(args),
                  historyBefore == nil || historyExchange == nil,
                  [historyBefore, historyExchange].compactMap({ $0 }).allSatisfy(ContactThread.isMessageID) else {
                throw AgentConversationStore.Failure(message: "Choose one offered session-history page or message. This only reads the conversation.")
            }
        }
        let freshValue = args.removeValue(forKey: "new_conversation")
        if let freshValue, case .bool = freshValue {} else if freshValue != nil {
            throw AgentConversationStore.Failure(message: "new_conversation must be true or false.")
        }
        let fresh = freshValue == .bool(true)
        // Answer demand is local record state, never peer input.
        let expectsValue = args.removeValue(forKey: "expects_reply")
        if let expectsValue, case .bool = expectsValue {} else if expectsValue != nil {
            throw AgentConversationStore.Failure(message: "expects_reply must be true or false.")
        }
        guard let agent = string(args["agent"]) else { return try await perform(tool, args, turn, conversation, mac) }
        if tool == "agent_message", HelperContact.matches(conversation: conversation, args) {
            if fresh || label != nil {
                throw AgentConversationStore.Failure(message: """
                    This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not \
                    supported by this adapter.
                    """)
            }
            return try await perform(tool, args, turn, conversation, mac)
        }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let peer = peers.first { "peer:" + $0.id == agent }
        // Authored ability routes must not take built-in shortcuts.
        let builtIn = peer?.ability == nil
        let dot = builtIn && peer.map(ChatGPTDotIPCTransport.owns) == true
        if dot, fresh {
            throw AgentConversationStore.Failure(
                message: "Dot has one conversation; new_conversation:true is not supported. Continue Dot's current conversation.")
        }
        // The ChatGPT route owns its own session, bypassing the exchange queue.
        if dot, tool == "agent_message" { return try await perform(tool, args, turn, conversation, mac) }
        let bots = try BotDefinitionStore(dataRoot: dataRoot).list()
        let botName = bots.first { "bot:" + $0.id.uuidString.lowercased() == agent.lowercased() }?.name
        if peer == nil, botName == nil {
            return unknownContact(agent, contacts: peers.map { ("peer:" + $0.id, $0.name) }
                + bots.map { ("bot:" + $0.id.uuidString.lowercased(), $0.name) })
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let records = Result { try store.records() }
        if tool == "agent_cancel", let label, UUID(uuidString: label) != nil {
            // A mounted flight supplies its exact record identity and original scope. A missing/moved record is not a label for another thread.
            guard let exact = try records.get().first(where: { $0.id == label && $0.agent == agent }),
                  exact.scopeSessionID == scope else {
                throw AgentConversationStore.Failure(
                    message: "The displayed conversation is unavailable in its original chat. No other conversation was stopped.")
            }
        }
        let pinned = named(label, agent: agent, scope: scope, rows: (try? records.get()) ?? [])
        label = pinned.label
        // Task filters apply only to A2A; routine history requests open the conversation.
        let listing: Set<String> = ["page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after"]
        if args.keys.contains(where: listing.contains),
           peer?.transport != .a2a {
            args = args.filter { !listing.contains($0.key) }
        }
        // limit/offset page nothing on a contact's route without an exact message or task; they mean "show me the recent talk".
        if !dot, agent.hasPrefix("peer:"), string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            args.removeValue(forKey: "limit"); args.removeValue(forKey: "offset")
        }
        // Resolve thread IDs to the same visible conversation, queue and history as names.
        if !dot, tool == "agent_message", label == nil, !fresh, let conversation = string(args["conversation_id"]),
           string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            let rows = (try? records.get()) ?? []
            label = rows.filter { $0.agent == agent && $0.conversationID == conversation }
                .sorted { $0.updatedAt > $1.updatedAt }.first { row in
                    (try? store.find(scopeSessionID: scope, agent: agent, label: row.label, in: rows))?.id == row.id
                }?.label
            if label != nil { args.removeValue(forKey: "conversation_id") }
        }
        let advanced: Set<String> = ["conversation_id", "message_id", "task_id", "page_size", "page_token", "context_id", "status", "history_length",
            "include_artifacts", "status_timestamp_after", "limit", "offset"]
        if !dot, reservation == nil, args.contains(where: { advanced.contains($0.key) && $0.value != .string("")
            && !(tool == "agent_read" && label != nil && ["limit", "offset"].contains($0.key)) }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(
                message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            if tool == "agent_message" {
                var exactArgs = args
                exactArgs["expects_reply"] = expectsValue
                return try await sendExact(turn: turn, mac: mac, conversation: conversation, workspace: workspace, agent: agent, peer: peer,
                    args: exactArgs, surface: surface, scope: scope,
                                           dataRoot: dataRoot, waitSeconds: waitSeconds, perform: perform)
            }
            let exact = try await perform(tool, args, turn, conversation, mac)
            if tool == "agent_read" {
                consumeRead(exact, peer: peer, message: string(args["message_id"]), scope: scope, conversation: conversation, dataRoot: dataRoot)
            }
            return exact
        }
        let name = peer?.name ?? botName ?? agent.capitalized
        let fingerprint = peer.map(AgentConversationStore.routeFingerprint)
        // A history locator names committed words, not the current transport operation. Reading it must never depend on refreshing that operation.
        if tool == "agent_read", historyBefore != nil || historyExchange != nil {
            guard !fresh else { throw AgentConversationStore.Failure(message: "Start a new conversation by sending its first message.") }
            return AgentConversationHistoryView.adding(to: .object([
                "status": .string("read"), "agent": .string(name), "agent_id": .string(agent)
            ]), agent: agent, name: name, before: historyBefore, exchange: historyExchange, dataRoot: dataRoot)
        }
        if dot, tool == "agent_read" {
            return try await perform(tool, args, turn, conversation, mac)
        }
        if fresh, agent.hasPrefix("bot:") || peer?.transport == .desktop || peer?.transport == .grokBot {
            return attention(name, label: label ?? "Main", """
                This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not \
                supported by this adapter.
                """)
        }
        if agent.hasPrefix("bot:"), let label, label != "Main" {
            return attention(name, label: label, """
                This helper has one continuous conversation. Omit the conversation label to continue it; a different label cannot create an \
                independent discussion for this bot.
                """)
        }
        var previous = try pinned.record ?? store.find(scopeSessionID: scope, agent: agent, label: label, in: records.get())
        if let row = previous, !AgentConversationStore.sameRoute(row.peerRouteFingerprint, peer) {
            guard tool == "agent_message", fresh else {
                return attention(name, label: row.label,
                    "The contact's connection changed. Start a separate conversation explicitly; this conversation has been preserved.")
            }
        }
        if tool == "agent_cancel" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "A stop applies to an existing conversation.") }
            return try await cancel(turn: turn, mac: mac, conversation: conversation, previous, name: name, peer: peer, clearQueue: clearQueue, args: args,
                                    store: store, dataRoot: dataRoot, perform: perform)
        }
        if tool == "agent_read" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "Start a new conversation by sending its first message.") }
            if agent.hasPrefix("bot:") {
                // Bot conversations belong to their durable owner across asking chats; read its latest reply, never a cached ask.
                return AgentConversationView.withQueue(try await perform(tool, args, turn, conversation, mac), row: previous)
            }
            if peer?.transport == .grokBot, args["details"] != .bool(true), historyBefore == nil, historyExchange == nil {
                return try await routineRead(turn: turn, mac: mac, conversation: conversation, workspace: workspace, agent: agent, name: name, peer: peer,
                    row: previous, store: store, args: args,
                                             scope: scope, dataRoot: dataRoot, perform: perform)
            }
            guard let row = previous else {
                let result: JSONValue = .object(["agent": .string(name), "agent_id": .string(agent),
                    "status": .string("no_history"), "state": .string("no_history"),
                    "detail": .string("No conversation history with this contact. Send your first message to start one.")])
                let history = AgentConversationHistoryView.adding(to: result, agent: agent, name: name,
                    before: historyBefore, exchange: historyExchange, dataRoot: dataRoot)
                guard case .object(var fields) = history, case .object(let scrollback)? = fields["session_history"],
                      case .array(let messages)? = scrollback["messages"], !messages.isEmpty else { return history }
                fields["status"] = .string("read"); fields["state"] = .string("ready")
                fields.removeValue(forKey: "detail")
                return .object(fields)
            }
            let refreshed = try await refresh(turn: turn, mac: mac, conversation: conversation, row, store: store, input: args, perform: perform)
            let readView = AgentConversationView.view(refreshed, details: args["details"] == .bool(true), read: true, dataRoot: dataRoot,
                        historyBefore: historyBefore, historyExchange: historyExchange, includeHistory: conversation.returnsHistory)
            consumeRead(readView, peer: peer, message: string(refreshed.readInput?["message_id"]), scope: scope, conversation: conversation,
                            dataRoot: dataRoot)
            return readView
        }
        guard tool == "agent_message" else { return try await perform(tool, args, turn, conversation, mac) }
        // A reservation already read settlement under the store lock; a background callback alone publishes its own terminal receipt.
        if let row = previous, row.phase == "waiting", !fresh, reservation == nil, !backgroundSend(row),
           !row.automaticRead, row.readInput != nil {
            previous = try await refresh(turn: turn, mac: mac, conversation: conversation, row, store: store, input: args, perform: perform)
        }
        var supersedeWaiting = false
        if var row = previous, !fresh {
            // Queued sends wait in order for evidence-based settlement or an explicit stop/release. A reservation admits its queued message; every other
            // message waits behind the queue.
            let reserved = reservation != nil && row.queueReservation == reservation
            if !reserved, try inFlight(row, peer?.transport, dataRoot: dataRoot) {
                if let queued = try queue(turn: turn, mac: mac, conversation: conversation, workspace: workspace, behind: row, name: name, peer: peer,
                    args: args, expectsReply: expectsValue, scope: scope, surface: surface, dataRoot: dataRoot, perform: perform) {
                    return queued
                }
                guard let current = try store.records().first(where: { $0.id == row.id }) else {
                    throw AgentConversationStore.Failure(message: "The conversation is missing after queue admission; nothing was sent.")
                }
                row = current
                previous = current
            }
            if row.phase == "waiting", (peer?.transport == .desktop || backgroundSend(row))
                    && !AgentConversationRunning.shared.routeWatching(row: row.id, operation: row.operationID) {
                supersedeWaiting = true
            } else if ["sending", "waiting"].contains(row.phase) {
                return notSent(name, label: row.label, """
                    The previous message has not settled. NativeAgent is preserving its state; open this conversation to see its available reply. \
                    No new message was sent.
                    """)
            }
            // New sends preserve terminal exchange history; unsettled attention queues instead.
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .desktopChat,
               peer?.transport != .grokBot, peer?.ability == nil, !dot {
                return attention(name, label: row.label, """
                    This contact did not confirm a resumable conversation. Start a separate conversation explicitly rather than silently losing its \
                    context.
                    """)
            }
        }
        // Report an unnamed continuation when its thread began in another chat.
        let carried = label == nil && !fresh && !agent.hasPrefix("bot:") && peer?.transport != .desktop && peer?.transport != .grokBot
            ? previous.flatMap { $0.scopeSessionID != scope && !($0.exchanges ?? []).isEmpty ? $0 : nil } : nil
        let replyRoute = turn.replyRoute?.stringFields
        let messageID = try protocolMessageID(args, peer: peer)
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: name, label: label, record: fresh ? nil : previous?.id,
                                  fresh: fresh, sourceSurface: surface, fingerprint: fingerprint, replyRoute: replyRoute,
                                  message: string(args["text"]),
                                  personInitiated: turn.personInitiatedSend?.matches(args) == true,
                                  supersedeWaiting: supersedeWaiting,
                                  expectsReply: expectsValue != .bool(false),
                                  reservation: reservation, messageID: messageID)
        if let messageID { args["message_id"] = .string(messageID) }
        // A routine has one conversation, whichever chat asks; the send derives it, so none is carried.
        if let conversation = row.conversationID, !conversation.isEmpty,
           peer?.transport != .grokBot, !dot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        args["expects_reply"] = .bool(row.awaitsReply)
        return noting(try await send(turn: turn, mac: mac, conversation: conversation, workspace: workspace, row, store: store, peer: peer,
            reservation: reservation, dataRoot: dataRoot,
                                    waitSeconds: waitSeconds, dispatch: perform) { [args] turn, conversation, mac in
            if let peer, let text = string(args["text"]) {
                try await ContactThread.attempt(.send(owner: peer.id, conversation: row.conversationID, text: text, sendID: row.operationID,
                    byPerson: row.personInitiated == true, turn: turn), dataRoot: dataRoot)
            }
            if let peer, let ability = peer.ability {
                return try await viaAbility(turn: turn, mac: mac, conversation: conversation, ability, peer: peer, row: row, args: args, dataRoot: dataRoot,
                    perform: perform)
            }
            return try await perform(tool, args, turn, conversation, mac)
        }, carried: carried)
    }

    /// Generate only for an absent ID; a queued/approved send keeps its arguments.
    private static func protocolMessageID(_ args: [String: JSONValue], peer: AgentPeerContact?) throws -> String? {
        if let supplied = args["message_id"] {
            guard case .string(let id) = supplied, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolFailureError("message_id must be a non-empty protocol message string.",
                    argumentPath: "message_id", effects: .none)
            }
            return id
        }
        return peer?.transport == .grokBot ? UUID().uuidString.lowercased() : nil
    }

    /// Explicit protocol identities select their own send record and retain the same settlement owner.
    static func sendExact(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation, agent: String,
        peer: AgentPeerContact?, args: [String: JSONValue],
                                  surface: String, scope: String, dataRoot: URL, waitSeconds: Int,
                                  perform: @escaping Dispatch) async throws -> JSONValue {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let replyRoute = turn.replyRoute?.stringFields
        let messageID = try protocolMessageID(args, peer: peer)
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: peer?.name ?? agent,
            label: nil, record: nil, fresh: true, sourceSurface: surface,
            fingerprint: peer.map(AgentConversationStore.routeFingerprint), replyRoute: replyRoute,
            message: string(args["text"]), personInitiated: turn.personInitiatedSend?.matches(args) == true,
            expectsReply: args["expects_reply"] != .bool(false), messageID: messageID)
        // An approval replay may run outside this send's live task context.
        var args = args
        if peer?.transport == .grokBot, let messageID { args["message_id"] = .string(messageID) }
        return try await send(turn: turn, mac: mac, conversation: conversation, workspace: workspace, row, store: store, peer: peer, reservation: nil,
            dataRoot: dataRoot,
                              waitSeconds: waitSeconds, dispatch: perform) { [args] turn, conversation, mac in
            if let peer, let text = string(args["text"]) {
                // An exact send's line belongs to the conversation it names: a held one's own session, the contact's session for any other.
                try await ContactThread.attempt(.send(owner: peer.id, conversation: string(args["conversation_id"]), text: text,
                    sendID: row.operationID, byPerson: row.personInitiated == true, turn: turn), dataRoot: dataRoot)
            }
            return try await perform("agent_message", args, turn, conversation, mac)
        }
    }

    /// Run once; the first failure may offer its owning repair.
    static func send(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        _ row: AgentConversationRecord, store: AgentConversationStore, peer: AgentPeerContact?,
                             reservation: String?, dataRoot: URL, waitSeconds: Int = 0, dispatch: @escaping Dispatch,
                             perform: @escaping @Sendable (Turn, AgentConversationContext,
                                 MacOperationContext) async throws -> JSONValue) async throws -> JSONValue {
        let liveReply = AgentConversationDelivery.answersLive(peer: peer)
        let seconds = reservation == nil && liveReply ? waitSeconds : 0
        let deadline = Date().addingTimeInterval(Double(seconds))
        let running = AgentConversationRunning.shared
        var watching = seconds > 0
        if watching { running.watch(row.id) }
        defer { if watching { running.unwatch(row.id) } }
        func releaseWait(_ original: JSONValue) async throws -> AgentConversationRecord {
            do { return try store.update(id: row.id, operationID: row.operationID, touch: false) {
                if $0.phase != "waiting", $0.phase != "sending", !heldReplyPending($0) {
                    $0.shownInline = $0.operationID + ":" + $0.phase
                    $0.automaticRead = false; $0.nextReadAt = nil
                    if $0.deliveryState == "delivering" { $0.deliveryState = nil }
                }
                running.unwatch(row.id)
                watching = false
            } } catch {
                throw await oweSettlement(error, stage: "release inline waiter", original: original,
                    row: row, store: store, dataRoot: dataRoot)
            }
        }
        // All routes publish progress through this send’s single live stream.
        let live = AgentConversationLiveTarget.record(row, dataRoot: dataRoot)
        let hub = AgentConversationLiveHub.shared
        await hub.begin(live, lane: peer?.transport.rawValue ?? (row.agent.hasPrefix("bot:") ? "bot" : row.agent))
        // Own the send in a separate task so cancellation reaches its lane-specific handler.
        let send = Task {
            try Task.checkCancellation()
            let receipt = try await perform(turn, conversation.live(live), mac)
            if Task.isCancelled { return receipt }
            return await AgentContactHealth.heal(receipt, row: row, dataRoot: dataRoot)
        }
        AgentConversationRunning.shared.begin(row: row.id, operation: row.operationID) { send.cancel() }
        // Adopt the accepted operation immediately; an explicit inline wait observes this owner without racing its admission.
        if reservation == nil, let peer, liveReply || peer.ability != nil || [.acp, .mcpHost, .nativeAgent].contains(peer.transport) {
            AgentConversationWatches.begin(row: row.id, operation: row.operationID)
            var running: [String: JSONValue] = ["status": .string("running"), "sent": .null, "completed": .bool(false),
                "background_send": .bool(true), "delivery": .string("unconfirmed")]
            if let conversation = row.conversationID { running["conversation_id"] = .string(conversation) }
            AgentConversationRunning.shared.conclude(row: row.id, operation: row.operationID) {
                defer { AgentConversationWatches.end(row: row.id, operation: row.operationID) }
                do {
                    _ = try await conclude(turn: turn, mac: mac, conversation: conversation, workspace: workspace, send, row: row, store: store, peer: peer,
                        live: live,
                        reservation: nil, background: true, dataRoot: dataRoot, dispatch: dispatch)
                } catch { nativeLog("Background conversation settlement remains owed: %@", error.localizedDescription) }
            }
            let shown: AgentConversationRecord
            do {
                shown = try store.update(id: row.id, operationID: row.operationID) {
                    guard $0.phase == "sending" else { return }
                    $0.receipt = .object(running); $0.readInput = nil
                    $0.phase = "waiting"
                    $0.automaticRead = false; $0.nextReadAt = nil; $0.selected = true; $0.shownInline = nil
                }
            } catch {
                throw await oweSettlement(error, stage: "publish waiting", original: .object(running),
                    row: row, store: store, dataRoot: dataRoot)
            }
            let current: AgentConversationRecord
            if watching {
                try await waitInline(row: row, store: store, until: deadline)
                current = try await releaseWait(.object(running))
            }
            else { current = shown }
            return messageReceipt(AgentConversationView.compact(AgentConversationView.view(current, details: false, dataRoot: dataRoot,
                includeHistory: false), row: current), live: liveReply)
        }
        let receipt = try await conclude(turn: turn, mac: mac, conversation: conversation, workspace: workspace, send, row: row, store: store, peer: peer,
            live: live,
                                         reservation: reservation, background: false, dataRoot: dataRoot, dispatch: dispatch)
        guard watching else { return messageReceipt(receipt, live: liveReply) }
        // Subscribe before reading: a reply between the read and suspension changes `seen`, so the existing owner signal cannot be missed.
        do {
            try await waitInline(row: row, store: store, until: deadline)
        } catch {
            throw await oweSettlement(error, stage: "read inline reply", original: receipt,
                row: row, store: store, dataRoot: dataRoot)
        }
        // Release the watch under the same store lock as settlement. A reply either belongs to this receipt or sees no watch and delivers later.
        let current = try await releaseWait(receipt)
        return messageReceipt(AgentConversationView.compact(AgentConversationView.view(current, details: false, dataRoot: dataRoot,
            includeHistory: false), row: current), live: liveReply)
    }

    private static func messageReceipt(_ receipt: JSONValue, live: Bool) -> JSONValue {
        guard case .object(var fields) = receipt else { return receipt }
        // Every send names where it stands: failed (with its cause and next move), answered, queued or held (it goes by itself, so not sent
        // yet is not a failure), or delivered.
        let queuedOrHeld = fields["queued"] == .bool(true) || fields["state"] == .string("queued") || fields["status"] == .string("held")
        if fields["status"] == .string("failed") || fields["delivery"] == .string("failed") || fields["sent"] == .bool(false) && !queuedOrHeld {
            fields["delivery"] = .string("failed")
        } else if fields["reply"] != nil, !["waiting", "sending", "working"].contains(string(fields["state"]) ?? "") {
            fields["delivery"] = .string("answered")
        } else if queuedOrHeld || fields["state"] == .string("waiting") || fields["state"] == .string("working")
                    || ["held", "queued", "accepted", "running", "waiting", "enqueued"].contains(string(fields["status"]) ?? "") {
            fields["delivery"] = .string(fields["status"] == .string("held") ? "held" : "queued")
        } else if ["delivered", "sent"].contains(string(fields["status"]) ?? "") {
            fields["delivery"] = .string("delivered")
        }
        fields["wait_ignored"] = live ? nil : .string("lane_is_async")
        return .object(fields)
    }

    /// A held send stays available to every contact door while its sender awaits the inbound reply. Delivery alone does not end that wait.
    package static func heldReplyPending(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "ready", row.awaitsReply, case .object(let receipt)? = row.receipt,
              ["held", "delivering", "delivered"].contains(string(receipt["status"]) ?? "") else { return false }
        return row.exchanges?.last(where: { $0.id == row.operationID })?.reply == nil
    }

    /// The caller's requested duration bounds observation; only the send owner settles execution.
    private static func waitInline(row: AgentConversationRecord, store: AgentConversationStore, until deadline: Date) async throws {
        let running = AgentConversationRunning.shared
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let seen = running.seen
                guard let current = try store.records().first(where: { $0.id == row.id }),
                      current.operationID == row.operationID,
                      current.phase == "sending" || current.phase == "waiting" || heldReplyPending(current),
                      Date() < deadline else { return }
                await running.change(after: seen, until: deadline)
            }
        } onCancel: { running.cancel(row: row.id, operation: row.operationID) }
    }

    /// Settle the original send without resending; unwaited answers become arrivals in the asking chat.
    private static func conclude(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, workspace: WorkspaceOperation,
        _ send: Task<JSONValue, Error>, row: AgentConversationRecord, store: AgentConversationStore,
                                 peer: AgentPeerContact?, live: AgentConversationLiveTarget, reservation: String?,
                                 background: Bool, dataRoot: URL, dispatch: @escaping Dispatch) async throws -> JSONValue {
        let outcome = await withTaskCancellationHandler { await send.result } onCancel: {
            AgentConversationRunning.shared.cancel(row: row.id, operation: row.operationID)
        }
        let result: Result<JSONValue, Error> = await settle {
            defer { AgentConversationRunning.shared.end(row: row.id, operation: row.operationID) }
            let hub = AgentConversationLiveHub.shared
            switch outcome {
            case .success(let receipt):
                let firstActivity = await hub.firstActivity(live)
                // A queued send has no inline waiter, so its result becomes an arrival.
                let saved: AgentConversationRecord
                do {
                    let retained = try await store.retainReply(receipt, for: row)
                    saved = try record(retained, for: row, store: store, peer: peer, firstActivity: firstActivity,
                                       inline: reservation == nil && !background, background: background, queued: reservation != nil,
                                       stopped: AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID))
                } catch {
                    let retentionError = error
                    // Supersession needs positive evidence. A failed reread or a missing row cannot prove that this reply was retained.
                    if retentionError is AgentConversationStore.Failure {
                        do {
                            if let current = try store.records().first(where: { $0.id == row.id }),
                               current.operationID != row.operationID {
                                await hub.settle(live, state: "finished")
                                return .success(receipt)
                            }
                        } catch {
                            nativeLog("Conversation retention reread failed: %@", error.localizedDescription)
                        }
                    }
                    let failure = await oweSettlement(retentionError, stage: "retain reply", original: receipt,
                        row: row, store: store, dataRoot: dataRoot)
                    await hub.settle(live, state: "failed", note: failure.localizedDescription)
                    return .failure(failure)
                }
                await hub.settle(live, state: saved.sendFailed ? "failed" : saved.phase == "waiting" ? "waiting" : "finished")
                return .success(AgentConversationView.compact(AgentConversationView.view(saved, details: false, dataRoot: dataRoot,
                    includeHistory: false), row: saved))
            case .failure(let error):
                await hub.settle(live, state: AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID) ? "finished" : "failed",
                                 note: error.localizedDescription)
                // Dispatch may precede an exception: preserve its exact binding and uncertainty instead of synthesizing another send.
                let stopped: AgentConversationRecord
                do { stopped = try store.update(id: row.id, operationID: row.operationID) {
                    guard $0.exchanges?.last(where: { $0.id == row.operationID })?.reply == nil else { return }
                    if AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID) {
                        let detail = Self.stoppedDetail(row.name)
                        $0.stop = AgentConversationStop(state: "stopped", operationID: row.operationID, at: Date(), detail: detail)
                        $0.phase = "ready"
                        $0.receipt = .object(["status": .string("cancelled"), "terminal": .bool(true), "completed": .bool(false),
                            "detail": .string(detail)])
                        return
                    }
                    $0.phase = "attention"
                    $0.automaticRead = false; $0.nextReadAt = nil
                    $0.receipt = .object(Self.sendFailure(error, row: row))
                    $0.shownInline = reservation == nil && !background ? $0.operationID + ":" + $0.phase : nil
                    if background, $0.personInitiated != true, $0.phase != "waiting", !$0.automaticRead,
                       !stoppedOrReleased($0), !AgentConversationRunning.shared.watched($0.id) {
                        $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                }
                } catch let storageError {
                    return .failure(await oweSettlement(storageError, stage: "settle failure or Stop",
                        original: operationEvidence(outcome), row: row, store: store, dataRoot: dataRoot))
                }
                if stopped.stop?.state == "stopped" {
                    return .success(AgentConversationView.compact(AgentConversationView.view(stopped, details: false, dataRoot: dataRoot,
                        includeHistory: false), row: stopped))
                }
                if var failure = error as? AgentConversationStore.Failure { failure.effects = .unknown; return .failure(failure) }
                // Typed refusals carry their own remedy and card; any other fault reaches the agent in the receipt's words.
                if !(error is ToolFailureError || error is AutonomyGateError || error is CancellationError) {
                    let said = Self.sendFailure(error, row: row)
                    return .failure(ToolFailureError(string(said["detail"]) ?? error.localizedDescription,
                        effects: said["sent"] == .bool(false) ? .none : .unknown, code: "agent_send_failed", status: .failed))
                }
                return .failure(error)
            }
        }
        // Launch in the caller's context, after detached settlement ended the original send. Its session and person's send mark remain intact.
        do {
            guard let saved = try store.records().first(where: { $0.id == row.id }) else {
                throw AgentConversationStore.Failure(message: "The accepted conversation row is missing while reading its queued work.")
            }
            if saved.queued?.contains(where: { $0.waitingForMac == true || $0.id == row.operationID && $0.held == nil }) == true {
                resumeQueued(turn: turn, mac: mac, conversation: conversation, workspace: workspace, saved, dataRoot: dataRoot, afterRestart: false,
                    perform: dispatch)
            }
        } catch {
            throw await oweSettlement(error, stage: "read queued work", original: .object(["operation": operationEvidence(outcome),
                "settlement": operationEvidence(result)]),
                row: row, store: store, dataRoot: dataRoot)
        }
        return try result.get()
    }

    /// Every send ends in words the agent acts on: whether anything left, why it did not finish, and the next move. A refusal before dispatch
    /// sent nothing; a send that broke in flight may have reached the contact, and is never resent for it.
    static func sendFailure(_ error: Error, row: AgentConversationRecord) -> [String: JSONValue] {
        var fields: [String: JSONValue]
        let nothingLeft: Bool
        if let refusal = error as? ToolFailureError {
            fields = refusal.failureEvidence(defaultCode: "agent_send_failed", defaultOwner: refusal.tap == nil ? nil : row.agent)
            nothingLeft = refusal.effects == .none
            fields["status"] = .string(!nothingLeft ? "failed" : refusal.argumentPath != nil ? "invalid_arguments" : refusal.status.rawValue)
            fields["detail"] = .string(refusal.message)
        } else {
            // A gate refusal never ran, and a contact door's argument refusal comes before any transport; transport faults are its own receipts.
            nothingLeft = error is AutonomyGateError || error is AgentCommunicationError
                || (error as? AgentConversationStore.Failure).map { $0.effects == .none } == true
            fields = ["status": .string("failed"), "detail": .string(error.localizedDescription)]
        }
        var next = nothingLeft
            ? " Nothing was sent to \(row.name). Fix the cause above, then send again."
            : " If it reached \(row.name), the answer arrives in this conversation; nothing was resent. Send again if you still want it answered."
        if let gate = error as? AutonomyGateError, gate.notRunStatus == .approvalUnavailable {
            next = " Nothing was sent to \(row.name): this needs the person's approval, and a turn another agent started cannot ask for one. "
                + "Send it from your own chat or your own thought, where the person can approve it."
        }
        fields["detail"] = .string((string(fields["detail"]) ?? "The send failed.") + next)
        fields["sent"] = nothingLeft ? .bool(false) : .null
        if nothingLeft { fields["execution"] = .string("not_run") }
        fields["delivery"] = .string("failed")
        return fields
    }

    /// A send that broke in flight: it may have reached the contact, so it neither proves a broken path nor invites a resend.
    package static func mayHaveReached(_ evidence: [String: JSONValue]) -> Bool {
        evidence["status"] == .string("outcome_unknown") || evidence["status"] == .string("failed") && evidence["sent"] == .null
    }

    /// The person's or the agent's Stop ends the local work, never the remote one.
    static func stoppedDetail(_ name: String) -> String {
        "Stopped here. If the message had reached \(name), its answer arrives in this conversation; nothing was resent."
    }

    private static func operationEvidence(_ outcome: Result<JSONValue, Error>) -> JSONValue {
        switch outcome {
        case .success(let receipt): return receipt
        case .failure(let error):
            if let failure = error as? ToolFailureError {
                var fields = failure.failureEvidence(defaultCode: "agent_send_failed")
                fields["detail"] = .string(failure.message)
                return .object(fields)
            }
            return .object(["status": .string("failed"), "detail": .string(error.localizedDescription)])
        }
    }

    /// The send is never replayed to repair storage. Keep its original result and the exact failing transition in the existing repair-owed owner.
    private static func oweSettlement(_ error: Error, stage: String, original: JSONValue,
                                      row: AgentConversationRecord, store: AgentConversationStore, dataRoot: URL) async -> ToolFailureError {
        let words = "Conversation \(row.id), operation \(row.operationID), \(stage): " + error.localizedDescription
            + ". Original operation outcome: " + NativeAgentSecretRedactor.redactText(String(describing: original))
        let next = ToolFailureError.call("app", ["action": .string("agent.read"),
            "args": .object(["agent": .string(row.agent), "conversation": .string(row.id)])])
        await RepairOwed.owe(dataRoot, id: row.operationID + ":" + stage, kind: .message,
            operation: "agent.settlement:" + row.operationID + ":" + stage, owner: store.fileURL.path,
            words: words, lever: "Repair conversation storage, then reconcile this exact operation; never resend it to repair bookkeeping.",
            nextCall: next).value
        return ToolFailureError(words, effects: .unknown, owner: store.fileURL.path, nextCall: next,
            code: "agent_conversation_settlement_owed",
                instruction: "Repair the named saved source, then inspect the original outcome before any new send.", recovery: .reconcile)
    }

    /// Authored routes traverse ordinary ability admission and answer through `agent.reply`, inline or on a later wake.
    private static func viaAbility(turn: Turn, mac: MacOperationContext, conversation: AgentConversationContext, _ ability: String, peer: AgentPeerContact,
        row: AgentConversationRecord,
                                   args: [String: JSONValue], dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        let recent = (row.exchanges ?? []).filter { $0.id != row.operationID }.suffix(6).map { exchange -> JSONValue in
            .object(["sent": exchange.prompt.map(JSONValue.string) ?? .null, "reply": exchange.reply.map(JSONValue.string) ?? .null])
        }
        var input: [String: JSONValue] = ["text": args["text"] ?? .null, "agent": .string("peer:" + peer.id), "name": .string(peer.name),
                                          "thread": .string(row.id), "exchange": .string(row.operationID), "recent": .array(recent)]
        var call: [String: JSONValue] = ["action": .string("authored." + ability), "args": .object(input)]
        for key in ["session_id", "__session_id"] { call[key] = args[key] }
        let run = try await perform("app", call, turn, conversation, mac)
        let reply = ToolResult(run)
        // An answer already settled during the run remains authoritative despite later run outcomes.
        if let reply = try AgentConversationStore(dataRoot: dataRoot).records().first(where: { $0.id == row.id })?
            .exchanges?.first(where: { $0.id == row.operationID })?.reply { return answered(peer, reply) }
        // The gate’s card or refusal is the send’s actual outcome.
        let status = string(run.objectValue?["status"]) ?? ""
        if readRefused(reply.payload) || AgentConversationRecord.approvalWaits(status) { return reply.payload }
        if [.failed, .refused, .cancelled, .timeout].contains(reply.outcome) {
            return .object(["status": .string("failed"), "agent": .string("peer:" + peer.id), "ability_run": reply.payload,
                "detail": .string("Your ability \(ability) did not take the message (ability_run says why); nothing landed from \(peer.name).")])
        }
        return .object(["status": .string("accepted"), "sent": .bool(true), "completed": .bool(false), "agent": .string("peer:" + peer.id),
            "detail": .string("Your ability \(ability) took it; \(peer.name)'s answer lands in this conversation when it comes.")])
    }

    /// Only the contact’s routed ability may answer as that contact; progress updates must not settle the exchange.
    package static func answer(part: String?, agent: String?, exchange: String?, text: String, done: Bool,
                               dataRoot: URL) async throws -> JSONValue {
        let peers = try AgentPeerStore(dataRoot: dataRoot).list().filter {
            $0.ability != nil && $0.ability == part && (agent == nil || "peer:" + $0.id == agent)
        }
        guard let part, peers.count == 1, let peer = peers.first else {
            throw AgentConversationStore.Failure(message: part == nil
                ? "Only the ability a contact is reached through answers as it (agent.connect {agent, ability}). Nothing landed."
                : peers.isEmpty ? "No contact\(agent.map { " " + $0 } ?? "") is reached through \(part). Nothing landed."
                : "\(part) reaches several contacts; name one with agent (peer:<id>). Nothing landed.")
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let rows = try store.records().filter { $0.agent == "peer:" + peer.id }
        let unanswered = rows.flatMap { row in (row.exchanges ?? []).filter { $0.reply == nil && (exchange == nil || $0.id == exchange) }.map { (row, $0) } }
        guard let found = unanswered.max(by: { $0.1.sentAt < $1.1.sentAt }) else {
            throw AgentConversationStore.Failure(message: exchange.map { "Exchange \($0) is not an unanswered message to \(peer.name). Nothing landed." }
                ?? "Nothing sent to \(peer.name) is unanswered. Nothing landed.")
        }
        let (row, settling) = (found.0, found.1.id)
        let result: JSONValue = .object(["status": .string(done ? "landed" : "progress"), "agent": .string("peer:" + peer.id),
                                         "thread": .string(row.id), "exchange": .string(settling)])
        guard done else {
            if settling == row.operationID { await AgentConversationLiveHub.shared.text(.record(row, dataRoot: dataRoot), replace: text) }
            return result
        }
        let receipt = try await store.retainReply(answered(peer, text), for: row, exchange: settling)
        try store.settleExchange(id: row.id, exchange: settling, reply: text, receipt: receipt)
        return result
    }

    static func answered(_ peer: AgentPeerContact, _ text: String) -> JSONValue {
        .object(["status": .string("answered"), "agent": .string("peer:" + peer.id), "sent": .bool(true), "completed": .bool(true),
                 "reply": .string(text), "untrusted_remote_data": .bool(true)])
    }
}
