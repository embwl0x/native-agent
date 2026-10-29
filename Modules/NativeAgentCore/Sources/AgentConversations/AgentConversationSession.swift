import ChatTurnContracts
import ChatToolParsing
import AgentWorkspace
import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace
// Blueprint: | `AgentConversationSession.swift` | `AgentConversationSession` owns dispatch, waits, queues, state transitions and TaskLocal history selection; `approvalRow`, `replayApproval`; `viaAbility` and `answer` (`agent.reply`): a contact reached through one of their abilities; live message waits default to 20 seconds (0–120), include held MCP sends through reply arrival, reuse conversation changes and release inline ownership under the settlement lock; explicit protocol sends share that owner; queued follow-ups wait until an inline waiter takes its answer; queued senders register for approval resolutions and execution settlements before reading, including replay failures recorded only in the approval store, and hold unsent at the one-day boundary; `clear_queue` withdraws queued and reserved messages before cancelling or joining local work; sends and Stop settle through `settle`, with no persisted stopping state or second desktop terminal writer |

/// Approval execution retains the original exchange and all ordinary gates.
public enum AgentConversationApproval {
    // Persist the exact path at filing; missing held state never proves it.
    @TaskLocal public static var exactProtocol = false

    /// `dispatch` is the replay's gated chain, which a repair's dry run goes through.
    public static func replay(id: String, dataRoot: URL, exactProtocol: Bool = false,
                              dispatch: @escaping @Sendable (String, [String: JSONValue]) async throws -> JSONValue,
                              perform: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        if exactProtocol {
            return try await AgentConversationContext.$isInternalRead.withValue(true) { try await perform() }
        }
        return try await AgentConversationSession.replayApproval(id, dataRoot: dataRoot, dispatch: dispatch, perform: perform)
    }
}

/// Conversational operation over existing gated adapters. No protocol or
/// permission is implemented here; every actual send/read enters its owner.
package enum AgentConversationSession {
    package typealias Dispatch = @Sendable (String, [String: JSONValue]) async throws -> JSONValue
    // Recursive reads made by wait return the current exchange, without history.
    @TaskLocal static var returnsHistory = true

    static func approvalRow(_ id: String, store: AgentConversationStore) throws -> AgentConversationRecord? {
        try store.records().first {
            guard $0.phase == "attention", case .object(let receipt)? = $0.receipt else { return false }
            return receipt["approvalId"] == .string(id) && AgentConversationRecord.approvalWaits(string(receipt["status"]) ?? "")
        }
    }

    static func replayApproval(_ id: String, dataRoot: URL, dispatch: @escaping Dispatch,
                               perform: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
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
        // Occupy this exact exchange before publishing sending; no queued
        // follow-up can take its place while the approved call is resumed.
        AgentConversationRunning.shared.begin(row: held.id, operation: held.operationID) {}
        let row: AgentConversationRecord
        do { row = try store.update(id: held.id, operationID: held.operationID) {
            guard $0.phase == "attention", $0.receipt == held.receipt else {
                throw AgentConversationStore.Failure(message: "This conversation has moved on; the older result was not applied.")
            }
            $0.phase = "sending"
            if let index = $0.exchanges?.firstIndex(where: { $0.id == held.operationID }) {
                $0.exchanges?[index].phase = "sending"
                $0.exchanges?[index].status = "outcome_unknown"
                $0.exchanges?[index].settledAt = nil
            }
        } } catch {
            AgentConversationRunning.shared.end(row: held.id, operation: held.operationID)
            throw error
        }
        return try await send(row, store: store, peer: peer, reservation: nil, dataRoot: dataRoot, dispatch: { tool, input in
            try await AgentConversationContext.$isInternalRead.withValue(true) { try await dispatch(tool, input) }
        }) {
            try await AgentConversationContext.$isInternalRead.withValue(true) { try await perform() }
        }
    }

    package static func dispatch(tool: String, input: [String: JSONValue], surface: String,
                         scope: String, dataRoot: URL, reservation: String? = nil,
                         perform: @escaping Dispatch) async throws -> JSONValue {
        var input = input
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
        let result = try await dispatchConversation(tool: tool, input: input, surface: surface, scope: scope,
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
        let peer = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first {
            "peer:" + $0.id == agent || ($0.handles ?? []).contains(agent)
        }
        return messageReceipt(result, live: AgentConversationDelivery.answersLive(agent: agent, peer: peer, dataRoot: dataRoot))
    }

    private static func dispatchConversation(tool: String, input: [String: JSONValue], surface: String,
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
        // Whether this send wants an answer; the app's own record, never sent on.
        let expectsValue = args.removeValue(forKey: "expects_reply")
        if let expectsValue, case .bool = expectsValue {} else if expectsValue != nil {
            throw AgentConversationStore.Failure(message: "expects_reply must be true or false.")
        }
        guard var agent = string(args["agent"]) else { return try await perform(tool, args) }
        if tool == "agent_message", HelperContact.matches(args) {
            if fresh || label != nil {
                throw AgentConversationStore.Failure(message: "This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not supported by this adapter.")
            }
            return try await perform(tool, args)
        }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let door = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot, peers: peers)
        agent = door?.agent ?? agent
        let peer = peers.first { "peer:" + $0.id == agent }
        // Reached through one of her abilities: no built-in shortcut (Dot's, an inbox's) applies.
        let builtIn = peer?.ability == nil
        let dot = builtIn && peer.map(ChatGPTDotIPCTransport.owns) == true
        if dot, fresh {
            throw AgentConversationStore.Failure(message: "Dot has one conversation; new_conversation:true is not supported. Continue Dot's current conversation.")
        }
        // Dot is one simple conversation: sends go straight to him, like reads,
        // never through the queue/exchange machinery of other contacts.
        if dot, tool == "agent_message" { return try await perform(tool, args) }
        let bots = try BotDefinitionStore(dataRoot: dataRoot).list()
        let botName = bots.first { "bot:" + $0.id.uuidString.lowercased() == agent.lowercased() }?.name
        if peer == nil, botName == nil, door == nil {
            return unknownContact(agent, contacts: peers.map { ("peer:" + $0.id, $0.name) }
                + bots.map { ("bot:" + $0.id.uuidString.lowercased(), $0.name) })
        }
        // A coding lane's thread id selects its conversation record, just as
        // its name does. Job listings are diagnostics, not conversation state.
        if tool == "agent_read", builtIn, door != nil,
           label == nil, !fresh, string(args["message_id"]) == nil,
           let conversation = string(args["conversation_id"]) {
            label = conversation
            args.removeValue(forKey: "conversation_id")
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let records = Result { try store.records() }
        let pinned = named(label, agent: agent, scope: scope, rows: (try? records.get()) ?? [])
        label = pinned.label
        // A2A task-listing filters mean nothing to any other contact; history_length
        // on Grok Bot is "show me the recent talk", so it opens the conversation.
        let listing: Set<String> = ["page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after"]
        if args.keys.contains(where: listing.contains),
           peer?.transport != .a2a {
            args = args.filter { !listing.contains($0.key) }
        }
        // limit/offset page nothing on a contact's route without an exact
        // message or task; they mean "show me the recent talk".
        if !dot, agent.hasPrefix("peer:"), string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            args.removeValue(forKey: "limit"); args.removeValue(forKey: "offset")
        }
        // A thread's id (from a wake or an older result) goes on as the thread
        // she knows by name: one visible name, the same record, queue and history.
        if !dot, tool == "agent_message", label == nil, !fresh, let conversation = string(args["conversation_id"]),
           string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            let rows = (try? records.get()) ?? []
            label = rows.filter { $0.agent == agent && $0.conversationID == conversation }
                .sorted { $0.updatedAt > $1.updatedAt }.first { row in
                    (try? store.find(scopeSessionID: scope, agent: agent, label: row.label, in: rows))?.id == row.id
                }?.label
            if label != nil { args.removeValue(forKey: "conversation_id") }
        }
        // Exact protocol calls remain available for diagnostics and existing clients.
        let advanced: Set<String> = ["conversation_id", "message_id", "task_id", "page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after", "limit", "offset"]
        if !dot, args.contains(where: { advanced.contains($0.key) && $0.value != .string("")
            && !(tool == "agent_read" && label != nil && ["limit", "offset"].contains($0.key)) }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            return try await AgentConversationApproval.$exactProtocol.withValue(tool == "agent_message") {
                if tool == "agent_message" {
                    var exactArgs = args
                    exactArgs["expects_reply"] = expectsValue
                    return try await sendExact(agent: agent, peer: peer, args: exactArgs, surface: surface, scope: scope,
                                               dataRoot: dataRoot, waitSeconds: waitSeconds, perform: perform)
                }
                return try await perform(tool, args)
            }
        }
        let name = peer?.name ?? botName ?? agent.capitalized
        let fingerprint = peer.map(AgentConversationStore.routeFingerprint)
        if dot, tool == "agent_read" {
            return try await perform(tool, args)
        }
        if fresh, agent.hasPrefix("bot:") || peer?.transport == .desktop || peer?.transport == .grokBot {
            return attention(name, label: label ?? "Main", "This contact owns one persistent conversation through its saved route. Continue that conversation; a separate thread is not supported by this adapter.")
        }
        if agent.hasPrefix("bot:"), let label, label != "Main" {
            return attention(name, label: label, "This helper has one continuous conversation. Omit the conversation label to continue it; a different label cannot create an independent discussion for this bot.")
        }
        var previous = try pinned.record ?? store.find(scopeSessionID: scope, agent: agent, label: label, in: records.get())
        if let row = previous, !AgentConversationStore.sameRoute(row.peerRouteFingerprint, peer) {
            guard tool == "agent_message", fresh else {
                return attention(name, label: row.label, "The contact's connection changed. Start a separate conversation explicitly; this conversation has been preserved.")
            }
        }
        if tool == "agent_cancel" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "A stop applies to an existing conversation.") }
            return try await cancel(previous, name: name, peer: peer, clearQueue: clearQueue, args: args,
                                    store: store, dataRoot: dataRoot, perform: perform)
        }
        if tool == "agent_read" {
            guard !fresh else { throw AgentConversationStore.Failure(message: "Start a new conversation by sending its first message.") }
            if agent.hasPrefix("bot:") {
                // Bots already own a durable conversation and shelf, even if
                // this Agent chat has never opened it. Always read the owner's
                // latest actual reply; exact message-ID reads still bypass
                // this facade above. Do not substitute an older cached ask.
                return AgentConversationView.withQueue(try await perform(tool, args), row: previous)
            }
            if peer?.transport == .grokBot, args["details"] != .bool(true), historyBefore == nil, historyExchange == nil {
                return try await routineRead(agent: agent, name: name, peer: peer, row: previous, store: store, args: args,
                                             dataRoot: dataRoot, perform: perform)
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
            let refreshed = try await refresh(row, store: store, input: args, perform: perform)
            return AgentConversationView.view(refreshed, details: args["details"] == .bool(true), read: true, dataRoot: dataRoot,
                        historyBefore: historyBefore, historyExchange: historyExchange, includeHistory: returnsHistory)
        }
        guard tool == "agent_message" else { return try await perform(tool, args) }
        // The existing callback owns built-in completion. Recover its exact
        // receipt when continuing, including the executor's eventual thread ID.
        if let row = previous, row.phase == "waiting", !fresh, !row.automaticRead, row.readInput != nil {
            previous = try await refresh(row, store: store, input: args, perform: perform)
        }
        var handOffSettled = false
        if let row = previous, !fresh {
            // Queued sends wait in order for evidence-based settlement or an explicit stop/release.
            // A reservation admits its queued message; every other message waits behind the queue.
            let reserved = reservation != nil && row.queueReservation == reservation
            if !reserved, inFlight(row, peer?.transport),
               let queued = try queue(behind: row, name: name, peer: peer, args: args, expectsReply: expectsValue, scope: scope,
                                      surface: surface, dataRoot: dataRoot, perform: perform) {
                return queued
            }
            if row.phase == "waiting", liveHandOff(row) || ((peer?.transport == .desktop || backgroundSend(row))
                    && !AgentConversationRunning.shared.routeWatching(row: row.id, operation: row.operationID)) {
                handOffSettled = true
            } else if ["sending", "waiting"].contains(row.phase) {
                // Only a send this process no longer owns (the app quit mid-send).
                return attention(name, label: row.label, "The previous message has not settled. NativeAgent is preserving its state; open this conversation to see its available reply. No new message was sent.")
            }
            // A new send supersedes terminal attention and preserves the old exchange's status.
            // Unsettled attention queues above.
            // Desktop chats without an id open a side chat on the next send.
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .desktopChat,
               peer?.transport != .grokBot, peer?.ability == nil, !dot {
                return attention(name, label: row.label, "This contact did not confirm a resumable conversation. Start a separate conversation explicitly rather than silently losing its context.")
            }
        }
        // Report an unnamed continuation when its thread began in another chat.
        let carried = label == nil && !fresh && !agent.hasPrefix("bot:") && peer?.transport != .desktop && peer?.transport != .grokBot
            ? previous.flatMap { $0.scopeSessionID != scope && !($0.exchanges ?? []).isEmpty ? $0 : nil } : nil
        let replyRoute = ChatToolSessionContext.replyRoute?.stringFields
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: name, label: label, record: fresh ? nil : previous?.id,
                                  fresh: fresh, sourceSurface: surface, fingerprint: fingerprint, replyRoute: replyRoute,
                                  message: string(args["text"]),
                                  legacyFingerprints: peer.map(AgentConversationStore.legacyRouteFingerprints) ?? [],
                                  personInitiated: PersonInitiatedSend.current?.matches(args) == true,
                                  supersedeWaiting: handOffSettled,
                                  expectsReply: expectsValue != .bool(false),
                                  reservation: reservation)
        // Her side of a contact's conversation lives in the contact's own session, as Dot's does.
        if let owner = peer?.id, let text = string(args["text"]) {
            await ContactThread.write(.send(owner: owner, text: text, sendID: row.operationID,
                                            byPerson: row.personInitiated == true), dataRoot: dataRoot)
        }
        // Grok's conversation is always the asking chat; a saved id from another chat is refused.
        if let conversation = Self.usableSavedConversation(row.conversationID, agent: row.agent, dataRoot: dataRoot),
           peer?.transport != .grokBot, !dot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        // Her inbox row says whether an answer is owed.
        args["expects_reply"] = .bool(row.awaitsReply)
        return noting(try await send(row, store: store, peer: peer, reservation: reservation, dataRoot: dataRoot,
                                    waitSeconds: waitSeconds, dispatch: perform) { [args] in
            // HOW she reaches it: one of her abilities, or its built-in route.
            if let peer, let ability = peer.ability {
                return try await viaAbility(ability, peer: peer, row: row, args: args, dataRoot: dataRoot, perform: perform)
            }
            return try await perform(tool, args)
        }, carried: carried)
    }

    /// Explicit protocol identities still use the send owner and its deadline.
    /// They select a separate record rather than borrowing this chat's thread.
    static func sendExact(agent: String, peer: AgentPeerContact?, args: [String: JSONValue],
                                  surface: String, scope: String, dataRoot: URL, waitSeconds: Int,
                                  perform: @escaping Dispatch) async throws -> JSONValue {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let replyRoute = ChatToolSessionContext.replyRoute?.stringFields
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: peer?.name ?? agent,
            label: nil, record: nil, fresh: true, sourceSurface: surface,
            fingerprint: peer.map(AgentConversationStore.routeFingerprint), replyRoute: replyRoute,
            message: string(args["text"]), personInitiated: PersonInitiatedSend.current?.matches(args) == true,
            expectsReply: args["expects_reply"] != .bool(false))
        if let peer, let text = string(args["text"]) {
            await ContactThread.write(.send(owner: peer.id, text: text, sendID: row.operationID,
                byPerson: row.personInitiated == true), dataRoot: dataRoot)
        }
        return try await send(row, store: store, peer: peer, reservation: nil, dataRoot: dataRoot,
                              waitSeconds: waitSeconds, dispatch: perform) {
            try await perform("agent_message", args)
        }
    }

    /// Reuse a saved handle only in the lane's format; otherwise the next send supplies one.
    static func usableSavedConversation(_ saved: String?, agent: String, dataRoot: URL) -> String? {
        guard let saved, !saved.isEmpty else { return nil }
        guard let door = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot) else { return saved }
        let prefix: String?
        switch door.handle {
        case "claude": prefix = "claude:"
        case "codex": prefix = "codex:"
        default: prefix = nil
        }
        guard let prefix else { return saved }
        return saved.hasPrefix(prefix) ? saved : nil
    }

    /// `perform` is the operation; `dispatch` the chain a repair's dry run
    /// goes through, so every send heals the same way (`AgentContactHealth.heal`).
    static func send(_ row: AgentConversationRecord, store: AgentConversationStore, peer: AgentPeerContact?,
                             reservation: String?, dataRoot: URL, waitSeconds: Int = 20, dispatch: @escaping Dispatch,
                             perform: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        let liveReply = AgentConversationDelivery.answersLive(agent: row.agent, peer: peer, dataRoot: dataRoot)
        let seconds = reservation == nil && liveReply ? waitSeconds : 0
        let deadline = Date().addingTimeInterval(Double(seconds))
        let running = AgentConversationRunning.shared
        var watching = seconds > 0
        if watching { running.watch(row.id) }
        defer { if watching { running.unwatch(row.id) } }
        func releaseWait() throws -> AgentConversationRecord {
            try store.update(id: row.id, operationID: row.operationID, touch: false) {
                if $0.phase != "waiting", $0.phase != "sending", !heldReplyPending($0) {
                    $0.shownInline = $0.operationID + ":" + $0.phase
                    $0.automaticRead = false; $0.nextReadAt = nil
                    if $0.deliveryState == "delivering" { $0.deliveryState = nil }
                }
                running.unwatch(row.id)
                watching = false
            }
        }
        // Every lane feeds one live stream for this send: working from now,
        // partial text where the lane streams it, settled when the call returns.
        let live = AgentConversationLiveTarget.record(row, dataRoot: dataRoot)
        let hub = AgentConversationLiveHub.shared
        await hub.begin(live, lane: peer?.transport.rawValue ?? (row.agent.hasPrefix("bot:") ? "bot" : row.agent))
        // The send runs as its own task so agent_cancel can stop it: the lane's
        // cancellation handler (ACP session/cancel, a CLI's SIGINT then SIGTERM).
        let (ended, end) = AsyncStream<Void>.makeStream()
        let send = Task {
            defer { end.finish() }
            return try await AgentConversationLiveContext.$target.withValue(live) {
                try Task.checkCancellation()
                let receipt = try await perform()
                if Task.isCancelled { return receipt }
                return try await AgentContactHealth.heal(receipt, row: row, dataRoot: dataRoot, again: {
                    try Task.checkCancellation(); return try await perform()
                }, dispatch: { tool, input in
                    try Task.checkCancellation(); return try await dispatch(tool, input)
                })
            }
        }
        AgentConversationRunning.shared.begin(row: row.id, operation: row.operationID) { send.cancel() }
        // The response deadline releases only this call. The accepted send
        // keeps its existing owner and settles later, without another send.
        if reservation == nil, let peer, liveReply || peer.ability != nil || [.acp, .mcpHost, .nativeAgent].contains(peer.transport),
           !(await finishes(ended, within: liveReply ? max(0, deadline.timeIntervalSinceNow) : 2, row: row)), !Task.isCancelled {
            AgentConversationWatches.begin(row: row.id, operation: row.operationID)
            var running: [String: JSONValue] = ["status": .string("running"), "sent": .null, "completed": .bool(false),
                "background_send": .bool(true), "delivery": .string("unconfirmed")]
            if let conversation = row.conversationID { running["conversation_id"] = .string(conversation) }
            let shown = (try? store.update(id: row.id, operationID: row.operationID) {
                guard $0.phase == "sending" else { return }
                $0.receipt = .object(running); $0.readInput = nil
                $0.phase = "waiting"
                $0.automaticRead = false; $0.nextReadAt = nil; $0.selected = true; $0.shownInline = nil
            }) ?? row
            AgentConversationRunning.shared.conclude(row: row.id, operation: row.operationID) {
                defer { AgentConversationWatches.end(row: row.id, operation: row.operationID) }
                _ = try? await conclude(send, row: row, store: store, peer: peer, live: live,
                                        reservation: nil, background: true, dataRoot: dataRoot)
            }
            let current = watching ? try releaseWait() : shown
            return messageReceipt(AgentConversationView.compact(AgentConversationView.view(current, details: false, dataRoot: dataRoot, includeHistory: false), row: current), live: liveReply)
        }
        let receipt = try await conclude(send, row: row, store: store, peer: peer, live: live,
                                         reservation: reservation, background: false, dataRoot: dataRoot)
        guard watching else { return messageReceipt(receipt, live: liveReply) }
        // Subscribe before reading: a reply between the read and suspension
        // changes `seen`, so the existing owner signal cannot be missed.
        while !Task.isCancelled {
            let seen = running.seen
            guard let current = try store.records().first(where: { $0.id == row.id }),
                  current.operationID == row.operationID,
                  current.phase == "waiting" || heldReplyPending(current), Date() < deadline else { break }
            await running.change(after: seen, until: deadline)
        }
        // Release the watch under the same store lock as settlement. A reply
        // either belongs to this receipt or sees no watch and delivers later.
        let current = try releaseWait()
        return messageReceipt(AgentConversationView.compact(AgentConversationView.view(current, details: false, dataRoot: dataRoot, includeHistory: false), row: current), live: liveReply)
    }

    private static func messageReceipt(_ receipt: JSONValue, live: Bool) -> JSONValue {
        guard case .object(var fields) = receipt else { return receipt }
        if fields["status"] == .string("failed") {
            fields["delivery"] = .string("failed")
        } else if fields["reply"] != nil, !["waiting", "sending", "working"].contains(string(fields["state"]) ?? "") {
            fields["delivery"] = .string("answered")
        } else if fields["state"] == .string("waiting") || fields["state"] == .string("working")
                    || ["held", "queued", "accepted", "running", "waiting", "enqueued"].contains(string(fields["status"]) ?? "") {
            fields["delivery"] = .string(fields["status"] == .string("held") ? "held" : "queued")
        }
        fields["wait_ignored"] = live ? nil : .string("lane_is_async")
        return .object(fields)
    }

    /// A pull host's send stays available to `takeHeld` even while its sender
    /// awaits the inbound bridge reply. Delivery alone does not end that wait.
    package static func heldReplyPending(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "ready", row.awaitsReply, case .object(let receipt)? = row.receipt,
              receipt["transport"] == .string("mcpHost"),
              ["held", "delivering", "delivered"].contains(string(receipt["status"]) ?? "") else { return false }
        return row.exchanges?.last(where: { $0.id == row.operationID })?.reply == nil
    }

    /// True when the stream ends (the send finished) within `seconds`. A
    /// caller cancelled meanwhile cancels the send, as waiting on it would.
    private static func finishes(_ ended: AsyncStream<Void>, within seconds: Double,
                                 row: AgentConversationRecord) async -> Bool {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in ended {}; return !Task.isCancelled }
                group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
        } onCancel: { AgentConversationRunning.shared.cancel(row: row.id, operation: row.operationID) }
    }

    /// Waits for the send and settles its exchange: the receipt it returned,
    /// a stop she asked for, or an unknown outcome; never a resend. A send
    /// nobody waits on (a queued follow-up, a background send) hands the
    /// contact's answer to her as a turn, as a delayed reply does.
    private static func conclude(_ send: Task<JSONValue, Error>, row: AgentConversationRecord, store: AgentConversationStore,
                                 peer: AgentPeerContact?, live: AgentConversationLiveTarget, reservation: String?,
                                 background: Bool, dataRoot: URL) async throws -> JSONValue {
        let outcome = await withTaskCancellationHandler { await send.result } onCancel: {
            AgentConversationRunning.shared.cancel(row: row.id, operation: row.operationID)
        }
        let result: Result<JSONValue, Error> = await settle {
            defer { AgentConversationRunning.shared.end(row: row.id, operation: row.operationID) }
            let hub = AgentConversationLiveHub.shared
            switch outcome {
            case .success(let receipt):
                let firstActivity = await hub.firstActivity(live)
                // A queued follow-up's call has no one waiting on it: its result is an arrival.
                let saved: AgentConversationRecord
                do {
                    let retained = try await store.retainReply(receipt, for: row)
                    saved = try record(retained, for: row, store: store, peer: peer, firstActivity: firstActivity,
                                       inline: reservation == nil && !background, background: background, queued: reservation != nil,
                                       stopped: AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID))
                } catch is AgentConversationStore.Failure where (try? store.records().first { $0.id == row.id })?.operationID != row.operationID {
                    // It settled on its own and a queued follow-up went on meanwhile: its answer is all there is to return.
                    await hub.settle(live, state: "finished")
                    return .success(receipt)
                } catch {
                    if case .object(var fields) = receipt {
                        fields["retention_error"] = .string(error.localizedDescription)
                        _ = try? store.update(id: row.id, operationID: row.operationID) {
                            absorb(.object(fields), into: &$0)
                            $0.phase = "attention"; $0.automaticRead = false; $0.nextReadAt = nil
                            $0.deliveryState = "The transport returned its outcome, but saving the conversation failed: " + error.localizedDescription
                        }
                    }
                    await hub.settle(live, state: "failed", note: error.localizedDescription)
                    return .failure(error)
                }
                await hub.settle(live, state: saved.sendFailed ? "failed" : saved.phase == "waiting" ? "waiting" : "finished")
                return .success(AgentConversationView.compact(AgentConversationView.view(saved, details: false, dataRoot: dataRoot, includeHistory: false), row: saved))
            case .failure(let error):
                await hub.settle(live, state: AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID) ? "finished" : "failed",
                                 note: error.localizedDescription)
                // An exception may occur after dispatch. Keep the exact previous
                // binding and mark uncertainty; never synthesize a replacement send.
                // One that ended because she asked it to stop is simply stopped.
                let stopped = try? store.update(id: row.id, operationID: row.operationID) {
                    guard $0.exchanges?.last(where: { $0.id == row.operationID })?.reply == nil else { return }
                    if AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID) {
                        let detail = "Local work stopped; the remote outcome is unknown. Nothing was resent."
                        $0.stop = AgentConversationStop(state: "stopped", operationID: row.operationID, at: Date(), detail: detail)
                        $0.phase = "ready"
                        $0.receipt = .object(["status": .string("outcome_unknown"), "terminal": .bool(true), "completed": .bool(false), "detail": .string(detail)])
                        return
                    }
                    $0.phase = "attention"
                    $0.automaticRead = false; $0.nextReadAt = nil
                    if let refusal = error as? ToolFailureError {
                        // A send that may have gone out stays outcome_unknown: reconcile, never resend.
                        var fields = refusal.failureEvidence(defaultCode: "agent_send_failed",
                            defaultOwner: refusal.tap == nil ? nil : row.agent)
                        fields["status"] = .string(refusal.effects != .none ? "outcome_unknown"
                            : refusal.argumentPath != nil ? "invalid_arguments" : refusal.status.rawValue)
                        fields["sent"] = refusal.effects == .none ? .bool(false) : .null
                        fields["detail"] = .string(refusal.message)
                        $0.receipt = .object(fields)
                    } else {
                        $0.receipt = .object(["status": .string("outcome_unknown"),
                            "detail": .string("The send did not establish an outcome. The conversation was preserved; no message was resent.")])
                    }
                    $0.shownInline = reservation == nil && !background ? $0.operationID + ":" + $0.phase : nil
                    if background, $0.personInitiated != true, $0.phase != "waiting", !$0.automaticRead,
                       !stoppedOrReleased($0), !AgentConversationRunning.shared.watched($0.id) {
                        $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                }
                if let stopped, stopped.stop?.state == "stopped" {
                    return .success(AgentConversationView.compact(AgentConversationView.view(stopped, details: false, dataRoot: dataRoot, includeHistory: false), row: stopped))
                }
                if var failure = error as? AgentConversationStore.Failure { failure.effects = .unknown; return .failure(failure) }
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// A contact reached through one of her abilities: its ordinary authored
    /// run through the whole chain, given the message, the contact, this
    /// exchange and the thread's recent talk. It answers with `agent.reply`
    /// (`answer`), during this run or on a later wake; this returns the
    /// exchange as the run left it: answered, taken, or what stopped it.
    private static func viaAbility(_ ability: String, peer: AgentPeerContact, row: AgentConversationRecord,
                                   args: [String: JSONValue], dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        let recent = (row.exchanges ?? []).filter { $0.id != row.operationID }.suffix(6).map { exchange -> JSONValue in
            .object(["sent": exchange.prompt.map(JSONValue.string) ?? .null, "reply": exchange.reply.map(JSONValue.string) ?? .null])
        }
        var input: [String: JSONValue] = ["text": args["text"] ?? .null, "agent": .string("peer:" + peer.id), "name": .string(peer.name),
                                          "thread": .string(row.id), "exchange": .string(row.operationID), "recent": .array(recent)]
        var call: [String: JSONValue] = ["action": .string("authored." + ability), "args": .object(input)]
        for key in ["session_id", "__session_id"] { call[key] = args[key] }
        let run = try await perform("app", call)
        // Answered during the run: that answer already settled this exchange, whatever went on after it.
        if let reply = try AgentConversationStore(dataRoot: dataRoot).records().first(where: { $0.id == row.id })?
            .exchanges?.first(where: { $0.id == row.operationID })?.reply { return answered(peer, reply) }
        // A gate's own answer (a card, a refusal) is the send's, as on any route.
        let status = string(run.objectValue?["status"]) ?? ""
        if readRefused(run) || AgentConversationRecord.approvalWaits(status) { return run }
        if [.failed, .refused, .cancelled, .timeout].contains(ChatToolOutcome.exactResultClass(run)) {
            return .object(["status": .string("failed"), "agent": .string("peer:" + peer.id), "ability_run": run,
                "detail": .string("Your ability \(ability) did not take the message (ability_run says why); nothing landed from \(peer.name).")])
        }
        return .object(["status": .string("accepted"), "sent": .bool(true), "completed": .bool(false), "agent": .string("peer:" + peer.id),
            "detail": .string("Your ability \(ability) took it; \(peer.name)'s answer lands in this conversation when it comes.")])
    }

    /// `agent.reply`: the one way the ability a contact is reached through
    /// answers as that contact. `text` lands in its thread as its reply,
    /// settling the exchange it answers (the one named, else her newest message
    /// to it still unanswered) through `settleExchange`; `done: false` shows it on that
    /// exchange as progress and settles nothing. Any other caller is refused.
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
        // The exchange named, else her newest message to it still unanswered.
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

    /// A contact's answer through her ability, as its exchange keeps it.
    static func answered(_ peer: AgentPeerContact, _ text: String) -> JSONValue {
        .object(["status": .string("answered"), "agent": .string("peer:" + peer.id), "sent": .bool(true), "completed": .bool(true),
                 "reply": .string(text), "untrusted_remote_data": .bool(true)])
    }
}
