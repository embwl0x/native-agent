import ChatTurnContracts
import AgentWorkspace
import ApprovalInbox
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import TurnTrace
// Blueprint: | `AgentConversationSession.swift` | `AgentConversationSession` enum; `approvalRow`, `replayApproval`; `viaAbility` and `answer` (`agent.reply`): a contact reached through one of their abilities; queued follow-ups register for approval resolutions and execution settlements before reading, including replay failures recorded only in the approval store; conversation receipt writes also wake them, and they hold unsent at the one-day boundary without approval sampling; `clear_queue` withdraws queued and reserved messages immediately after cancellation admission, before cancelling or joining local work; sends and Stop requests settle through `settle`, with no persisted stopping state or second desktop terminal writer |

/// Approval execution retains the original exchange and all ordinary gates.
public enum AgentConversationApproval {
    // 2026-09-28: persist the exact path at filing; missing held state never proves it.
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
    @TaskLocal private static var returnsHistory = true

    static func approvalRow(_ id: String, store: AgentConversationStore) throws -> AgentConversationRecord? {
        try store.records().first {
            guard $0.phase == "attention", case .object(let receipt)? = $0.receipt else { return false }
            return receipt["approvalId"] == .string(id) && approvalWaits.contains(string(receipt["status"]) ?? "")
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
        agent = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot)?.agent ?? agent
        let saved = try agent.hasPrefix("peer:") ? AgentPeerStore(dataRoot: dataRoot).list().first { "peer:" + $0.id == agent } : nil
        // Reached through one of her abilities: no built-in shortcut (Dot's, an inbox's) applies.
        let builtIn = saved?.ability == nil
        let dot = builtIn && saved.map(ChatGPTDotIPCTransport.owns) == true
        if dot, fresh {
            throw AgentConversationStore.Failure(message: "Dot has one conversation; new_conversation:true is not supported. Continue Dot's current conversation.")
        }
        // Dot is one simple conversation: sends go straight to him, like reads,
        // never through the queue/exchange machinery of other contacts.
        if dot, tool == "agent_message" { return try await perform(tool, args) }
        let pinned = named(label, agent: agent, scope: scope, dataRoot: dataRoot)
        label = pinned.label
        // A2A task-listing filters mean nothing to any other contact; history_length
        // on Grok Bot is "show me the recent talk", so it opens the conversation.
        let listing: Set<String> = ["page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after"]
        if args.keys.contains(where: listing.contains),
           (try? AgentPeerStore(dataRoot: dataRoot).list())?.first(where: { "peer:" + $0.id == agent })?.transport != .a2a {
            args = args.filter { !listing.contains($0.key) }
        }
        // limit/offset page nothing on a contact's route without an exact
        // message or task; they mean "show me the recent talk" (Grok Bot, 09-24).
        if !dot, agent.hasPrefix("peer:"), string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            args.removeValue(forKey: "limit"); args.removeValue(forKey: "offset")
        }
        // A built-in lane's wake names its thread by id (walk 09-25: the read
        // refused it while suggesting it): read that thread's newest exchanges.
        if tool == "agent_read", builtIn, AgentConversationDelivery.lane(for: agent, dataRoot: dataRoot) != nil, label == nil, !fresh,
           let conversation = string(args["conversation_id"]), string(args["message_id"]) == nil {
            return try await builtInThread(agent: agent, conversation: conversation, args: args,
                                           scope: scope, dataRoot: dataRoot, perform: perform)
        }
        // A thread's id (from a wake or an older result) goes on as the thread
        // she knows by name: one visible name, the same record, queue and history.
        if !dot, tool == "agent_message", label == nil, !fresh, let conversation = string(args["conversation_id"]),
           string(args["message_id"]) == nil, string(args["task_id"]) == nil,
           let named = threadLabel(agent: agent, conversation: conversation, scope: scope, dataRoot: dataRoot) {
            label = named
            args.removeValue(forKey: "conversation_id")
        }
        // Exact protocol calls remain available for diagnostics and existing clients.
        let advanced: Set<String> = ["conversation_id", "message_id", "task_id", "page_size", "page_token", "context_id", "status", "history_length", "include_artifacts", "status_timestamp_after", "limit", "offset"]
        if !dot, args.contains(where: { advanced.contains($0.key) && $0.value != .string("")
            && !(tool == "agent_read" && label != nil && ["limit", "offset"].contains($0.key)) }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            return try await AgentConversationApproval.$exactProtocol.withValue(tool == "agent_message") {
                try await perform(tool, args)
            }
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let peer = peers.first { "peer:" + $0.id == agent }
        if agent.hasPrefix("peer:"), peer == nil { throw AgentConversationStore.Failure(message: "This contact is no longer connected.") }
        let botName = try BotDefinitionStore(dataRoot: dataRoot).list().first {
            "bot:" + $0.id.uuidString.lowercased() == agent.lowercased()
        }?.name
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
        var previous = try pinned.record.flatMap { id in try store.records().first { $0.id == id } }
            ?? store.find(scopeSessionID: scope, agent: agent, label: label)
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
                return withQueue(try await perform(tool, args), row: previous)
            }
            if builtIn, AgentConversationDelivery.lane(for: agent, dataRoot: dataRoot) != nil {
                if label != nil || pinned.record != nil, let row = previous, let conversation = row.conversationID {
                    let read = try await builtInThread(agent: agent, conversation: conversation, args: args,
                                                       scope: scope, dataRoot: dataRoot, perform: perform)
                    if readRefused(read) { return read }
                    if historyBefore != nil || historyExchange != nil {
                        return view(row, details: false, read: true, dataRoot: dataRoot,
                                    historyBefore: historyBefore, historyExchange: historyExchange)
                    }
                    let presentation = args["details"] != .bool(true) && returnsHistory
                        ? AgentConversationHistoryView.adding(to: read, row: row, dataRoot: dataRoot) : read
                    return withQueue(withLive(presentation, row: row, dataRoot: dataRoot), row: row)
                }
                if label != nil || pinned.record != nil {
                    guard let row = previous else {
                        return attention(name, label: label ?? "Main", "No saved conversation with that name. Send its first message to start one.")
                    }
                    let refreshed = try await refresh(row, store: store, input: args, perform: perform)
                    return view(refreshed, details: args["details"] == .bool(true), read: true, dataRoot: dataRoot,
                                historyBefore: historyBefore, historyExchange: historyExchange)
                }
                // The built-in lanes keep their own thread; the window shows
                // its recent exchanges, not one chat's retained receipt.
                if args["limit"] == nil, args["message_id"] == nil { args["limit"] = .int(6) }
                let read = labelled(try await perform(tool, args), agent: agent, scope: scope, dataRoot: dataRoot)
                return withQueue(withLive(read, row: previous, dataRoot: dataRoot), row: previous)
            }
            if peer?.transport == .grokBot, args["details"] != .bool(true), historyBefore == nil, historyExchange == nil {
                return try await routineRead(agent: agent, name: name, peer: peer, row: previous, store: store, args: args,
                                             dataRoot: dataRoot, perform: perform)
            }
            guard let row = previous else {
                return .object(["agent": .string(name), "agent_id": .string(agent), "state": .string("not_opened"),
                    "detail": .string("No saved conversation in this chat. Send your first message to start one.")])
            }
            let refreshed = try await refresh(row, store: store, input: args, perform: perform)
            return view(refreshed, details: args["details"] == .bool(true), read: true, dataRoot: dataRoot,
                        historyBefore: historyBefore, historyExchange: historyExchange)
        }
        guard tool == "agent_message" else { return try await perform(tool, args) }
        // The existing callback owns built-in completion. Recover its exact
        // receipt when continuing, including the executor's eventual thread ID.
        if let row = previous, row.phase == "waiting", !fresh, !row.automaticRead, row.readInput != nil {
            previous = try await refresh(row, store: store, input: args, perform: perform)
        }
        var handOffSettled = false
        if let row = previous, !fresh {
            // 2026-09-25 (User): a message written while the reply is still in
            // flight waits on the thread and goes by itself when that reply
            // settles on evidence, never on elapsed time; never refused, never
            // dropped. agent_cancel settles it early (a stop, or a release where
            // the route has none: Grok Bot, a live hand-off).
            // The queued message this thread is reserved for goes now; any other
            // message waits behind the reply and every queued message before it.
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
            // A terminal attention state never wedges a thread (09-22 ACP/Muse,
            // 09-24 Grok app, 09-25 Claude "Main" with no job behind it): a new
            // explicit message supersedes it, and the old exchange keeps its
            // own honest status. One that may still act (`unsettledAttention`)
            // is in flight above, so a new message queues behind it instead.
            // A desktop chat with no conversation id opens a new side chat on
            // the next send (its missing chat healed, or a relaunch cut the
            // last one off): nothing to resume, nothing to refuse.
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .desktopChat,
               peer?.transport != .grokBot, peer?.ability == nil, !dot {
                return attention(name, label: row.label, "This contact did not confirm a resumable conversation. Start a separate conversation explicitly rather than silently losing its context.")
            }
        }
        // No conversation named, and the thread it goes on in began in another
        // chat (walk 09-25: a test probe landed in an older test chat): said in the result.
        let carried = label == nil && !fresh && !agent.hasPrefix("bot:") && peer?.transport != .desktop && peer?.transport != .grokBot
            ? previous.flatMap { $0.scopeSessionID != scope && !($0.exchanges ?? []).isEmpty ? $0 : nil } : nil
        let replyRoute = ChatToolSessionContext.replyRoute.map { route in
            ["surface": route.surface, "destinationId": route.destinationId,
             "threadId": route.threadId, "sourceKey": route.sourceKey,
             "replyTo": route.replyTo, "correlationId": route.correlationId,
             "requesterUserId": route.requesterUserId].compactMapValues { $0 }
        }
        let row = try store.begin(scopeSessionID: scope, agent: agent, name: name, label: label, record: fresh ? nil : previous?.id,
                                  fresh: fresh, sourceSurface: surface, fingerprint: fingerprint, replyRoute: replyRoute,
                                  message: string(args["text"]),
                                  legacyFingerprints: peer.map(AgentConversationStore.legacyRouteFingerprints) ?? [],
                                  personInitiated: PersonInitiatedSend.current?.matches(args) == true,
                                  supersedeWaiting: handOffSettled,
                                  expectsReply: AgentConversationRecord.expectsReply(
                                      explicit: expectsValue.flatMap { if case .bool(let value) = $0 { value } else { nil } },
                                      text: string(args["text"])),
                                  reservation: reservation)
        // Her side of a contact's conversation lives in the contact's own session, as Dot's does.
        if let owner = peer?.id, let text = string(args["text"]) {
            await ContactThread.write(.send(owner: owner, text: text, sendID: row.operationID,
                                            byPerson: row.personInitiated == true), dataRoot: dataRoot)
        }
        // Grok's conversation is always the asking chat; a saved id from another chat is refused.
        if let conversation = row.conversationID, peer?.transport != .grokBot, !dot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        // Her inbox row says whether an answer is owed.
        args["expects_reply"] = .bool(row.awaitsReply)
        return noting(try await send(row, store: store, peer: peer, reservation: reservation, dataRoot: dataRoot, dispatch: perform) { [args] in
            // HOW she reaches it: one of her abilities, or its built-in route.
            if let peer, let ability = peer.ability {
                return try await viaAbility(ability, peer: peer, row: row, args: args, dataRoot: dataRoot, perform: perform)
            }
            return try await perform(tool, args)
        }, carried: carried)
    }

    /// `perform` is the operation; `dispatch` the chain a repair's dry run
    /// goes through, so every send heals the same way (`AgentContactHealth.heal`).
    private static func send(_ row: AgentConversationRecord, store: AgentConversationStore, peer: AgentPeerContact?,
                             reservation: String?, dataRoot: URL, dispatch: @escaping Dispatch,
                             perform: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
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
        // 2026-09-26 (User): an ACP, command-line or NativeAgent contact never
        // holds her turn. No reply within about 2s: this returns as running at
        // once, and the send goes on in a tracked task that settles this exact
        // exchange and hands the reply to her as a turn of its own.
        if reservation == nil, let peer, peer.ability != nil || [.acp, .mcpHost, .nativeAgent].contains(peer.transport),
           !(await finishes(ended, within: 2, row: row)), !Task.isCancelled {
            AgentConversationWatches.begin(row: row.id, operation: row.operationID)
            var running: [String: JSONValue] = ["status": .string("running"), "sent": .bool(true), "completed": .bool(false),
                                                "background_send": .bool(true)]
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
            return view(shown, details: false, dataRoot: dataRoot)
        }
        return try await conclude(send, row: row, store: store, peer: peer, live: live,
                                  reservation: reservation, background: false, dataRoot: dataRoot)
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
                    saved = try record(receipt, for: row, store: store, peer: peer, firstActivity: firstActivity,
                                       inline: reservation == nil && !background, background: background, queued: reservation != nil,
                                       stopped: AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID))
                } catch is AgentConversationStore.Failure where (try? store.records().first { $0.id == row.id })?.operationID != row.operationID {
                    // It settled on its own and a queued follow-up went on meanwhile: its answer is all there is to return.
                    await hub.settle(live, state: "finished")
                    return .success(receipt)
                } catch {
                    await hub.settle(live, state: "failed", note: error.localizedDescription)
                    return .failure(error)
                }
                await hub.settle(live, state: saved.phase == "waiting" ? "waiting" : "finished")
                return .success(compact(view(saved, details: false, dataRoot: dataRoot, includeHistory: false), row: saved))
            case .failure(let error):
                await hub.settle(live, state: "finished")
                // An exception may occur after dispatch. Keep the exact previous
                // binding and mark uncertainty; never synthesize a replacement send.
                // One that ended because she asked it to stop is simply stopped.
                let stopped = try? store.update(id: row.id, operationID: row.operationID) {
                    guard $0.phase == "sending" || background && backgroundSend($0) else { return }
                    if AgentConversationRunning.shared.stopped(row: row.id, operation: row.operationID) {
                        let detail = "Local work stopped; the remote outcome is unknown. Nothing was resent."
                        $0.stop = AgentConversationStop(state: "stopped", operationID: row.operationID, at: Date(), detail: detail)
                        $0.phase = "ready"
                        $0.receipt = .object(["status": .string("outcome_unknown"), "terminal": .bool(true), "completed": .bool(false), "detail": .string(detail)])
                        return
                    }
                    $0.phase = "attention"
                    if let refusal = error as? ToolFailureError {
                        // A send that may have gone out stays outcome_unknown: reconcile, never resend.
                        var fields: [String: JSONValue] = ["status": .string(refusal.effects != .none ? "outcome_unknown"
                            : refusal.argumentPath != nil ? "invalid_arguments" : refusal.status.rawValue),
                            "reason": .string(refusal.code ?? (refusal.argumentPath == nil ? "agent_send_failed" : "invalid_arguments")),
                            "sent": refusal.effects == .none ? .bool(false) : .null, "effects": .string(refusal.effects.rawValue),
                            "detail": .string(refusal.message), "argument_path": refusal.argumentPath.map(JSONValue.string) ?? .null,
                            "accepted": refusal.accepted.map(JSONValue.string) ?? .null]
                        let call = refusal.nextCall.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                        if refusal.recovery == .terminal, let instruction = refusal.instruction {
                            fields["remedy"] = Repair.terminal(instruction: instruction)
                        } else if refusal.personDecides, let tap = refusal.tap {
                            fields["remedy"] = Repair.why(owner: refusal.owner ?? row.agent, tap: tap, instruction: refusal.instruction)
                        } else if refusal.recovery == .reconcile, let call, let instruction = refusal.instruction {
                            fields["remedy"] = Repair.reconcile(instruction: instruction, nextCall: call)
                        } else if refusal.tap != nil || refusal.owner != nil && (refusal.recovery == nil || refusal.recovery == .repair) {
                            fields["remedy"] = Repair.remedy(owner: refusal.owner ?? row.agent, nextCall: call,
                                tap: refusal.tap, instruction: refusal.instruction)
                        } else if let call {
                            fields["remedy"] = .object(["kind": .string(refusal.recovery?.rawValue ?? (refusal.argumentPath == nil ? "inspect" : "correct_arguments")),
                                "instruction": .string(refusal.instruction ?? "Use next_call."), "next_call": call])
                        }
                        $0.receipt = .object(fields)
                    } else {
                        $0.receipt = .object(["status": .string("outcome_unknown"),
                            "detail": .string("The send did not establish an outcome. The conversation was preserved; no message was resent.")])
                    }
                    if background, $0.personInitiated != true, $0.phase != "waiting", !$0.automaticRead,
                       !stoppedOrReleased($0), !AgentConversationRunning.shared.watched($0.id) {
                        $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                    }
                }
                if let stopped, stopped.stop?.state == "stopped" {
                    return .success(compact(view(stopped, details: false, dataRoot: dataRoot, includeHistory: false), row: stopped))
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
        let door: [String: JSONValue] = if case .object(let fields) = run { fields } else { [:] }
        let status = string(door["status"]) ?? ""
        if readRefused(run) || approvalWaits.contains(status) { return run }
        // The run's own receipt sits under the door's result; a thrown or crashed run carries its error there.
        let own: [String: JSONValue] = if case .object(let fields)? = door["result"] { fields } else { door }
        if own["error"] != nil || ["error", "failed", "refused", "stopped", "timed_out", "cancelled"].contains(status) {
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
        try store.settleExchange(id: row.id, exchange: settling, reply: text, receipt: answered(peer, text))
        return result
    }

    /// A contact's answer through her ability, as its exchange keeps it.
    private static func answered(_ peer: AgentPeerContact, _ text: String) -> JSONValue {
        .object(["status": .string("answered"), "agent": .string("peer:" + peer.id), "sent": .bool(true), "completed": .bool(true),
                 "reply": .string(text), "untrusted_remote_data": .bool(true)])
    }

    /// `wait` on a contact: back as soon as the reply in flight on its thread
    /// settles (every settle is a store write, which wakes this) or when
    /// `seconds` run out, saying which. What it returns is `read`'s agent_read.
    /// `admit` (agent_read's own wait) reads through the gates first, so a
    /// read that would be refused is refused, not waited past.
    package static func waitForReply(input: [String: JSONValue], scope: String, dataRoot: URL, admit: Bool = false,
                             read: @escaping Dispatch) async throws -> JSONValue {
        guard var agent = string(input["agent"]) else { throw AgentConversationStore.Failure(message: "Name the contact to wait for.") }
        agent = AgentConversationDelivery.door(for: agent, dataRoot: dataRoot)?.agent ?? agent
        let pinned = named(string(input["conversation"]), agent: agent, scope: scope, dataRoot: dataRoot)
        let label = pinned.label
        let exact = input.filter { ["conversation_id", "message_id", "task_id"].contains($0.key) && $0.value != .null && $0.value != .string("") }
        let retained = exact.isEmpty ? nil : try AgentConversationStore(dataRoot: dataRoot).records().filter { row in
            row.agent == agent && exact.allSatisfy { key, value in
                key == "conversation_id" ? row.conversationID.map(JSONValue.string) == value : row.readInput?[key] == value
            }
        }.max { $0.updatedAt < $1.updatedAt }
        var readInput = exact
        readInput["agent"] = .string(agent)
        // The name she gave, so the read resolves to this same record.
        if let label { readInput["conversation"] = input["conversation"] ?? .string(label) }
        for key in ["session_id", "__session_id", "details"] { readInput[key] = input[key] }
        if !exact.isEmpty, retained == nil {
            var result = try await read("agent_read", readInput)
            if case .object(var fields) = result { fields["wait_outcome"] = .string("not_tracked"); result = .object(fields) }
            return result
        }
        let asked: Double = switch input["seconds"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: 60 }
        let started = Date()
        let deadline = started.addingTimeInterval(min(max(asked, 1), 300))
        if let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { "peer:" + $0.id == agent }),
           peer.ability == nil, ChatGPTDotIPCTransport.owns(peer) {
            // His reply lands through the listener, which marks the change.
            var seen = AgentConversationRunning.shared.seen
            var snapshot = try await read("agent_read", readInput)
            if readRefused(snapshot) { return snapshot }
            var outcome = "nothing_in_flight"
            while case .object(let fields) = snapshot, case .array(let messages)? = fields["conversation"],
                  let sent = messages.lastIndex(where: {
                      if case .object(let message) = $0 { return message["from"] == .string("Agent") }
                      return false
                  }), !messages.dropFirst(sent + 1).contains(where: {
                      if case .object(let message) = $0 { return message["from"] == .string(peer.name) }
                      return false
                  }) {
                outcome = "still_waiting"
                if Date() >= deadline { break }
                await AgentConversationRunning.shared.change(after: seen, until: deadline)
                try Task.checkCancellation()
                if Date() >= deadline { break }
                seen = AgentConversationRunning.shared.seen
                snapshot = try await read("agent_read", readInput)
                if readRefused(snapshot) { return snapshot }
                outcome = "settled"
            }
            guard case .object(var fields) = snapshot else { return snapshot }
            fields["wait_outcome"] = .string(outcome)
            fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
            return .object(fields)
        }
        if admit {
            let first = try await $returnsHistory.withValue(false) { try await read("agent_read", readInput) }
            if readRefused(first) { return first }
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let transport = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == agent }?.transport
        var outcome = "nothing_in_flight"
        var latest: AgentConversationRecord?
        // While this watches, a reply that lands comes back here, not as a second turn.
        var watching: String?
        defer { if let watching { AgentConversationRunning.shared.unwatch(watching) } }
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            guard let row = try (retained?.id ?? pinned.record).flatMap({ id in try store.records().first { $0.id == id } })
                    ?? (retained == nil ? store.find(scopeSessionID: scope, agent: agent, label: label) : nil),
                  retained == nil || row.operationID == retained?.operationID else { outcome = "not_opened"; break }
            latest = row
            if watching == nil { watching = row.id; AgentConversationRunning.shared.watch(row.id) }
            guard replyInFlight(row, transport) else {
                if outcome != "nothing_in_flight" { outcome = "settled" }
                break
            }
            outcome = "still_waiting"
            if Date() >= deadline { break }
            await AgentConversationRunning.shared.change(after: seen, until: deadline)
        }
        if Task.isCancelled { outcome = "cancelled" }
        // Out of time (or stopped): the saved snapshot, never another read
        // that could hold the turn past `seconds`.
        let snapshot: JSONValue?
        if ["still_waiting", "cancelled"].contains(outcome), let latest {
            snapshot = view(latest, details: input["details"] == .bool(true), dataRoot: dataRoot, includeHistory: false)
        } else {
            snapshot = try await $returnsHistory.withValue(false) { try await read("agent_read", readInput) }
        }
        guard case .object(var fields)? = snapshot else { return .object(["wait_outcome": .string(outcome)]) }
        // Grok Bot's answer is in this turn's hands now: it is not handed over again.
        // Only a wait that read it back (settled, or already there) and carries
        // that exact answer claims it; a stopped or timed-out wait never does.
        if transport == .grokBot, ["settled", "nothing_in_flight"].contains(outcome), !Task.isCancelled,
           let delivered = string(fields["reply"]), let latest, agent.hasPrefix("peer:"),
           let message = string(latest.readInput?["message_id"]) {
            let clipped = fields["reply_truncated"] == .bool(true)
            GrokRequestStore(dataRoot: dataRoot).shown(message, peer: String(agent.dropFirst(5)), by: "wait") {
                $0 == delivered || (clipped && $0.hasPrefix(delivered))
            }
        }
        // A contact's wait hands back the exchange, not its retained history.
        if agent.hasPrefix("peer:"), let latest,
           case .object(let shown) = compact(.object(fields), row: (try? store.records().first { $0.id == latest.id }) ?? latest) {
            fields = shown
        }
        fields["wait_outcome"] = .string(outcome)
        fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
        let detail = switch outcome {
        case "settled": "The reply in flight settled while you waited; this is the conversation now."
        case "still_waiting": "Still in flight when the wait ran out; nothing was resent. Wait again, or carry on: the answer still arrives."
        case "not_opened": "There is no conversation with that contact here to wait on."
        case "cancelled": "The wait was stopped."
        default: "Nothing was in flight on this conversation, so there was nothing to wait for."
        }
        fields["wait_detail"] = .string(detail)
        return .object(fields)
    }

    /// The thread is occupied: its reply is still coming, or a queued message
    /// is ahead (waiting or taken to go next). A new message queues behind.
    static func inFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?) -> Bool {
        replyInFlight(row, transport) || row.queueReservation != nil
            || row.queued?.contains(where: { $0.held == nil }) == true
    }

    /// The reply ahead is still coming. A "sending" row only counts while this
    /// process still owns that send.
    static func replyInFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?) -> Bool {
        if row.phase == "sending" { return AgentConversationRunning.shared.live(row: row.id, operation: row.operationID) }
        // A live hand-off settles on its own reply, delivery of an FYI, or release.
        if liveHandOff(row), row.phase == "waiting" || stoppedOrReleased(row) { return !settled(row) }
        if unsettledAttention(row) { return true }
        guard row.phase == "waiting" else { return false }
        // A desktop answer, or a background send, is watched by this process; none after a restart.
        if transport == .desktop || backgroundSend(row) { return !stoppedOrReleased(row) && AgentConversationRunning.shared.routeWatching(row: row.id, operation: row.operationID) }
        // Every other lane settles on its own receipt, or a stop.
        return !stoppedOrReleased(row)
    }

    /// A send still running in this process's background task (ACP, command
    /// line, NativeAgent peer): waiting only while that task watches it.
    static func backgroundSend(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "waiting", case .object(let receipt)? = row.receipt else { return false }
        return receipt["background_send"] == .bool(true)
    }

    /// At launch, before queued follow-ups resume: a send no process owns any
    /// more settles as interrupted and unanswered, never waiting forever. That
    /// is a background send, any lane's send caught mid-way, or one left with
    /// an unknown outcome, begun before this process. Nothing is resent.
    static func settleInterrupted(dataRoot: URL) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let running = AgentConversationRunning.shared
        let desktop = Set(((try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []).filter { $0.transport == .desktop }.map { "peer:" + $0.id })
        func orphaned(_ row: AgentConversationRecord) -> Bool {
            if backgroundSend(row) { return !running.routeWatching(row: row.id, operation: row.operationID) }
            guard ownerless(row) else { return false }
            // Only a desktop answer is watched by the process that pasted it; every
            // other waiting lane settles on its own evidence after a restart.
            if row.phase == "waiting" { return desktop.contains(row.agent) && !running.routeWatching(row: row.id, operation: row.operationID) }
            return row.phase == "sending" || unsettledAttention(row) && !awaitingApproval(row)
        }
        // A receipt correction, not news: an old row keeps its time (a phase change still moves it).
        for row in (try? store.records()) ?? [] where orphaned(row) {
            _ = try? store.update(id: row.id, operationID: row.operationID, touch: false) {
                guard orphaned($0) else { return }
                interrupted(&$0)
            }
        }
        // The restart that cut a reply off may also have marked the agent
        // unavailable, which hides it from the sidebar with no way back. Where
        // an agent's newest send is that interrupted one, lift a mark written
        // since it began (a later real failure would be its own, newer send).
        let peers = AgentPeerStore(dataRoot: dataRoot)
        // 2026-09-28: Rank sends by their start, preserving updatedAt ordering for legacy records.
        let newest = Dictionary(((try? store.records()) ?? []).filter { $0.agent.hasPrefix("peer:") }
            .map { row in (row.agent, (row: row, startedAt: row.operationStartedAt ?? row.updatedAt)) }) {
                a, b in a.startedAt >= b.startedAt ? a : b
            }
        for (agent, send) in newest {
            guard case .object(let receipt)? = send.row.receipt, receipt["status"] == .string("interrupted") else { continue }
            peers.clearUnavailable(peerID: String(agent.dropFirst(5)), since: send.startedAt)
        }
    }

    /// Begun before this process and not running in it: no process owns this
    /// send any more. Never judged by liveness alone (a send of this process
    /// is briefly not yet registered as live).
    static func ownerless(_ row: AgentConversationRecord) -> Bool {
        (row.operationStartedAt ?? row.updatedAt) < AbandonedTurnReconciler.processEpoch
            && !AgentConversationRunning.shared.live(row: row.id, operation: row.operationID)
    }

    /// What a send the app's own quit or restart cut off says: its turn ended
    /// with the process, so it was not answered here and nothing is resent.
    package static func restartDetail(_ name: String) -> String {
        "Interrupted by an app restart before \(name)'s reply came back, so it was not answered here. Nothing was resent; send it again if it is still wanted."
    }

    /// Settles the row's send as one the restart cut off. A send still
    /// "sending" holds the previous exchange's receipt, so it gets a fresh one;
    /// any other keeps its ids and read locator. An unknown outcome may still
    /// finish remotely: only the wait is let go, so a reply that comes can be read back.
    private static func interrupted(_ row: inout AgentConversationRecord) {
        guard row.phase != "sending", case .object(var root)? = row.receipt else {
            var fields: [String: JSONValue] = ["status": .string("interrupted"), "completed": .bool(false),
                "detail": .string(restartDetail(row.name))]
            if let conversation = row.conversationID { fields["conversation_id"] = .string(conversation) }
            absorb(.object(fields), into: &row)
            return
        }
        let detail = row.phase == "attention"
            ? "An app restart ended this app's wait for \(row.name)'s reply. Nothing was resent; if the reply comes, it still arrives here when this conversation is read, so send again only if it is still wanted."
            : restartDetail(row.name)
        func settle(_ fields: inout [String: JSONValue]) {
            fields["status"] = .string("interrupted")
            if fields["run_status"] != nil { fields["run_status"] = .string("interrupted") }
            fields["completed"] = .bool(false)
            fields["detail"] = .string(detail)
        }
        settle(&root)
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(var job) = jobs[0] {
            settle(&job)
            root["jobs"] = .array([.object(job)])
        }
        absorb(.object(root), into: &row)
    }

    /// An attention send that may still act: dispatched with an unknown outcome
    /// (it may be running remotely), or held on an approval that may still send
    /// it. It fences the thread until terminal evidence or agent_cancel.
    package static func unsettledAttention(_ row: AgentConversationRecord) -> Bool {
        guard row.phase == "attention", !stoppedOrReleased(row), case .object(let root)? = row.receipt else { return false }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        if root["sent"] == .bool(false) || value["sent"] == .bool(false) { return false }
        let status = GrokBotRoute.normalizedStatus(string(value["run_status"]) ?? string(value["status"]) ?? "")
        if approvalWaits.contains(status), approvalDecided(string(value["approvalId"]) ?? string(root["approvalId"])) {
            return false
        }
        // An unknown outcome holds the thread while its reply may still come;
        // a terminal one (its call ended, bounded by the route's own timeout)
        // has nothing more coming, so the next message goes.
        return ["outcome_unknown", "delivery_unknown"].contains(status) && value["terminal"] != .bool(true)
            || approvalWaits.contains(status)
    }

    private static let approvalWaits: Set<String> = ["waiting_approval", "waiting_for_approval", "waiting for approval",
                                                     "approval_filed", "approval_required"]

    /// A send held on an approval stops fencing the thread once that approval is
    /// decided (denied, expired), or its approved replay has finished. Keep the
    /// approved exchange's place until its replay claims it, ahead of its queue.
    static func approvalDecided(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        let url = PersistenceCore.defaultDataRoot().appendingPathComponent("workflows/approvals/requests.json")
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first(where: { $0["id"] as? String == id }) else { return false }
        guard let status = row["status"] as? String, status != "pending" else { return false }
        if row["decision"] as? String == "approved" { return row["executedAction"] != nil && !(row["executedAction"] is NSNull) }
        return true
    }

    /// Held on an approval the person has not decided yet: lifecycle events
    /// wake the queue when the decision or replay receipt lands in its store.
    static func awaitingApproval(_ row: AgentConversationRecord) -> Bool {
        guard unsettledAttention(row), case .object(let root)? = row.receipt else { return false }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        return approvalWaits.contains(string(value["run_status"]) ?? string(value["status"]) ?? "")
    }

    /// agent_cancel settled this send: the lane stopped it, or (where there is
    /// no stop) the thread let go of waiting; a retired desktop reader leaves
    /// any late answer in the remote chat.
    package static func stoppedOrReleased(_ row: AgentConversationRecord) -> Bool {
        guard let stop = row.stop, stop.operationID == row.operationID else { return false }
        return ["stopped", "released"].contains(stop.state)
    }

    /// Queue a follow-up on the thread and start its sender. Nil when the reply
    /// settled in the meantime, so the caller just sends it.
    private static func queue(behind row: AgentConversationRecord, name: String, peer: AgentPeerContact?,
                              args: [String: JSONValue], expectsReply: JSONValue?, scope: String, surface: String, dataRoot: URL,
                              perform: @escaping Dispatch) throws -> JSONValue? {
        guard let text = string(args["text"]) else { return nil }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let transport = peer?.transport
        var arguments = args
        arguments["expects_reply"] = expectsReply
        guard let queued = try store.enqueue(id: row.id, text: text,
                byPerson: PersonInitiatedSend.current?.matches(args) == true,
                arguments: arguments,
                stillInFlight: { inFlight($0, transport) }) else { return nil }
        let (saved, item) = queued
        let carried = args.filter { ["session_id", "__session_id"].contains($0.key) }
        _ = AgentConversationRunning.shared.adopt(item.id)
        // A child task keeps this call's context (session, turn envelope, and a
        // person's own send mark), so the queued send clears the same gates later.
        AgentConversationRunning.shared.launch(item.id) {
            await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: saved.label, carried: carried,
                                  transport: transport, scope: scope, surface: surface, dataRoot: dataRoot, perform: perform)
        }
        let ahead = (saved.queued ?? []).filter { $0.held == nil && $0.id != item.id }.count
        // What it waits on: the earlier message's card, or a reply still coming.
        let awaitingCard: Bool = if case .object(let receipt)? = saved.receipt { receipt["status"] == .string("waiting_approval") } else { false }
        let blocker = awaitingCard ? "your earlier message to \(name), which waits on the person's card" : "the reply in progress from \(name)"
        let lever = awaitingCard ? "It goes by itself once that card is decided, approved or not; agent_cancel {clear_queue: true} withdraws it."
            : "It goes by itself, in order, when that reply settles; agent_cancel stops the reply in progress."
        return .object(["agent": .string(name), "agent_id": .string(row.agent), "conversation": .string(saved.label),
            "state": .string("queued"), "queued": .bool(true), "sent": .bool(false), "queued_id": .string(item.id),
            "queue_position": .int(Int64(ahead + 1)),
            "detail": .string("Queued behind \(blocker)" + (ahead > 0 ? " and \(ahead) earlier queued message\(ahead == 1 ? "" : "s")" : "")
                + ". Do not send it again. " + lever)])
    }

    /// The thread's queued follow-ups as every read shows them: queued, sending
    /// (reserved, going now) or held with why. Nil when none are saved.
    static func queueProjection(_ row: AgentConversationRecord?) -> JSONValue? {
        guard let row, let queued = row.queued, !queued.isEmpty else { return nil }
        return .array(queued.map { item in
            // Held only when written so; one without a sender yet is picked up
            // at launch (`resumeQueued`), so it still reads as queued.
            let going = item.id == row.queueReservation
            return .object(["id": .string(item.id), "text": .string(HerScreen.clip(item.text, 400)),
                "queued_at": .string(ISO8601DateFormatter().string(from: item.queuedAt)),
                "by_person": .bool(item.byPerson == true),
                "state": .string(item.held == DataRootLife.stoppedReason ? "stopped" : item.held != nil ? "held" : going ? "sending" : "queued"),
                "detail": .string(item.held ?? (going ? "Going now: the reply ahead of it has settled."
                    : "Goes by itself when the reply ahead of it settles."))])
        })
    }

    /// A lane's own read (built-in thread, bot shelf) with the saved queue added.
    static func withQueue(_ result: JSONValue, row: AgentConversationRecord?) -> JSONValue {
        guard let queued = queueProjection(row), case .object(var fields) = result else { return result }
        fields["queued"] = queued
        return .object(fields)
    }

    /// Threads with queued messages no sender in this process is waiting on
    /// (the app restarted): `resumeQueued` picks each up.
    static func orphanedQueues(dataRoot: URL) -> [AgentConversationRecord] {
        // The same startup pass first settles the sends the restart ended,
        // so what is queued behind them can go.
        settleInterrupted(dataRoot: dataRoot)
        return ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []).filter { row in
            (row.queued ?? []).contains { $0.held == nil && !AgentConversationRunning.shared.waiting($0.id) }
                || row.queueReservation.map { !AgentConversationRunning.shared.waiting($0) } == true
        }
    }

    /// After a restart, under the same order and reservation as before: an
    /// unused reservation is let go, a message older than a day or typed by the
    /// person (their send was their own act, which a restart does not carry)
    /// is held with the reason, and the rest get a sender again. `perform`
    /// enters the gated chain below the conversation layer, as the original did.
    static func resumeQueued(_ row: AgentConversationRecord, dataRoot: URL, perform: @escaping Dispatch) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        if let reserved = row.queueReservation, !AgentConversationRunning.shared.waiting(reserved) {
            _ = try? store.releaseReservation(id: row.id, item: reserved)
        }
        for item in row.queued ?? [] where item.held == nil && AgentConversationRunning.shared.adopt(item.id) {
            if Date().timeIntervalSince(item.queuedAt) >= 24 * 60 * 60 || item.byPerson == true {
                try? store.holdQueued(id: row.id, item: item, reason: item.byPerson == true
                    ? "Not sent: the app restarted before the reply ahead of it settled, and the send was yours to make. Send it again if it is still wanted."
                    : "Not sent: the reply ahead of it did not settle within a day.")
                AgentConversationRunning.shared.release(item.id)
                continue
            }
            let transport = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == row.agent }?.transport
            // The door the thread was asked from, as the row kept it: its sends
            // write it back and carry it on, never this launch's.
            let route = row.replyRoute.map { saved in
                ChatToolSessionContext.ReplyRoute(surface: saved["surface"] ?? row.sourceSurface, destinationId: saved["destinationId"],
                    threadId: saved["threadId"], sourceKey: saved["sourceKey"], replyTo: saved["replyTo"],
                    correlationId: saved["correlationId"], requesterUserId: saved["requesterUserId"])
            }
            AgentConversationRunning.shared.launch(item.id) {
                await ChatToolSessionContext.$replyRoute.withValue(route) {
                    await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: row.label, carried: [:],
                                          transport: transport, scope: row.scopeSessionID, surface: row.sourceSurface,
                                          dataRoot: dataRoot, perform: perform)
                }
            }
        }
    }

    /// Sends one queued follow-up once everything ahead of it has settled.
    /// Anything that stops it going is written on the thread, never dropped.
    private static func sendWhenSettled(row id: String, item: String, agent: String, label: String,
                                        carried: [String: JSONValue], transport: AgentPeerTransport?,
                                        scope: String, surface: String, dataRoot: URL, perform: @escaping Dispatch) async {
        defer { AgentConversationRunning.shared.release(item) } // adopted by `queue`
        let store = AgentConversationStore(dataRoot: dataRoot)
        // Register before reading: denials reconcile on read, and replay
        // settlement can land solely in the approval store, even on failure.
        let approvals = await ApprovalLifecycleBus.shared.events()
        let approvalChanges = Task {
            for await event in approvals where event.phase == .resolved || event.phase == .executed {
                AgentConversationRunning.shared.changed()
            }
        }
        defer { approvalChanges.cancel() }
        let queuedAt = (try? store.records().first { $0.id == id })?.queued?.first { $0.id == item }?.queuedAt ?? Date()
        let giveUp = queuedAt.addingTimeInterval(24 * 60 * 60)
        // A reply still being handed to her as a turn goes first, too. Order
        // among queued messages is `takeQueued`'s (only the head, one at a time).
        let ready: (AgentConversationRecord) -> Bool = {
            !replyInFlight($0, transport) && $0.deliveryState != "delivering"
        }
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            guard let row = try? store.records().first(where: { $0.id == id }),
                  row.queued?.contains(where: { $0.id == item && $0.held == nil }) == true else { return }
            if Date() >= giveUp {
                if let entry = row.queued?.first(where: { $0.id == item }) {
                    try? store.holdQueued(id: id, item: entry, reason: "Not sent: the reply ahead of it did not settle within a day.")
                }
                return
            }
            if let taken = try? store.takeQueued(id: id, item: item, ready: ready) {
                var input = (taken.arguments ?? [:]).merging(carried) { _, current in current }
                input["agent"] = .string(agent)
                input["text"] = .string(taken.text)
                input["conversation"] = .string(label)
                var why = "the conversation did not take it."
                do {
                    let result = try await dispatch(tool: "agent_message", input: input, surface: surface, scope: scope,
                                                    dataRoot: dataRoot, reservation: taken.id, perform: perform)
                    if case .object(let fields) = result, let detail = string(fields["detail"]) { why = detail }
                } catch { why = error.localizedDescription }
                // Still reserved: it never began (refused before its send), so it
                // stays on the thread, held with the reason, and the queue moves on.
                if (try? store.releaseReservation(id: id, item: taken.id)) == true {
                    try? store.holdQueued(id: id, item: taken, reason: "Not sent: " + why)
                }
                return
            }
            // Exact reply settlement writes the store and wakes this waiter.
            await AgentConversationRunning.shared.change(after: seen, until: giveUp)
        }
    }

    /// Stop the reply in flight on this thread, on the lane's own terms, and
    /// join local settlement before reporting what the stop actually did.
    private static func cancel(_ previous: AgentConversationRecord?, name: String, peer: AgentPeerContact?, clearQueue: Bool,
                               args: [String: JSONValue], store: AgentConversationStore, dataRoot: URL,
                               perform: Dispatch) async throws -> JSONValue {
        guard let row = previous else {
            return .object(["agent": .string(name), "state": .string("not_opened"), "stopped": .bool(false),
                            "detail": .string("There is no conversation with \(name) here to stop.")])
        }
        let latest = (try? store.records().first { $0.id == row.id }) ?? row
        // A send no process owns any more (a restart mid-send) still counts, so it can be released.
        let orphan = latest.phase == "sending" && ownerless(latest)
        // A message waiting on the person's card is theirs to decide: a stop
        // neither withdraws the card nor releases the conversation from it.
        let awaitingCard: Bool = if case .object(let receipt)? = latest.receipt { receipt["status"] == .string("waiting_approval") } else { false }
        let flying = !awaitingCard && (orphan || replyInFlight(latest, peer?.transport))
        // Admission first: the lane owner's stop runs through agent_cancel's own
        // gate, and nothing here (queue, stop state) changes unless it clears.
        // With nothing in flight it carries no lane target, so it stops nothing.
        var owner: [String: JSONValue] = ["agent": .string(latest.agent)]
        for key in ["session_id", "__session_id"] { owner[key] = args[key] }
        if flying {
            if case .object(let receipt)? = latest.receipt, receipt["terminal"] != .bool(true), let task = string(receipt["task_id"]) {
                owner["task_id"] = .string(task)
            }
            if let message = string(latest.readInput?["message_id"]) { owner["message_id"] = .string(message) }
            if let conversation = latest.conversationID { owner["conversation_id"] = .string(conversation) }
        }
        let result = try await perform("agent_cancel", owner)
        guard case .object(let fields) = result else { return result }
        let state = string(fields["status"]) ?? "cannot_stop"
        guard ["stopped", "stopping", "cannot_stop", "not_here"].contains(state) else { return result } // refused by its gate
        // Withdraw before local cancellation can publish ready and wake queued sends.
        // Keep its result so a failed withdrawal still lets accepted work settle.
        let withdrawal = Result { clearQueue ? try store.clearQueued(id: row.id) : 0 }
        let settled: Result<JSONValue, Error> = await settle {
            let running = AgentConversationRunning.shared
            let stoppedSend = await running.stop(row: latest.id, operation: latest.operationID)
            let retiredWatch = await running.retireWatches(row: latest.id, operation: latest.operationID)
            return Result {
                let cleared = try withdrawal.get()
                let current = try store.records().first { $0.id == row.id } ?? latest
                func answer(_ record: AgentConversationRecord, _ extra: [String: JSONValue]) -> JSONValue {
                    guard case .object(var fields) = compact(view(record, details: false, dataRoot: dataRoot, includeHistory: false), row: record) else { return .object(extra) }
                    fields.merge(extra) { _, new in new }
                    if cleared > 0 { fields["queue_cleared"] = .int(Int64(cleared)) }
                    return .object(fields)
                }
                if stoppedSend || retiredWatch || stoppedOrReleased(current) {
                    return answer(current, ["stopped": .bool(current.stop?.state == "stopped"),
                        "detail": .string(current.stop?.detail ?? "The reply finished before the stop landed.")])
                }
                if awaitingCard || !orphan && !replyInFlight(current, peer?.transport) {
                    let standing = awaitingCard
                        ? "Your earlier message to \(name) waits on the person's card; a stop does not withdraw a card, and this conversation still waits on it."
                        : "Nothing from \(name) is in flight on this conversation, so there was nothing to stop."
                    return answer(current, ["stopped": .bool(false), "detail": .string(standing + (cleared > 0 ? " The queued messages were withdrawn." : ""))])
                }
                if state == "stopping" {
                    return answer(current, ["stopped": .bool(false), "detail": fields["detail"] ?? .string("The remote stop has not finished.")])
                }
                let detail: String
                let terminal: String
                if state == "stopped" { terminal = "stopped"; detail = string(fields["detail"]) ?? "" }
                else if let ability = peer?.ability {
                    terminal = "released"; detail = "Your ability \(ability) already took the message and has no stop from here; this conversation no longer waits on it, and if \(name) answers, that still lands here."
                } else if [.desktop, .desktopChat].contains(peer?.transport) {
                    terminal = "released"; detail = "Local reply observation is no longer running. The message's remote outcome is unchanged; any answer stays in that chat."
                } else if orphan {
                    terminal = "released"; detail = "No send to \(name) runs here any more (the app restarted mid-send), so it settled as interrupted; this conversation no longer waits on it, and anything \(name) answers still arrives."
                } else if unsettledAttention(current) {
                    terminal = "released"; detail = "Its outcome is not known and \(name)'s route has no stop for it; this conversation no longer waits on it, and anything \(name) answers still arrives."
                } else if liveHandOff(current) {
                    terminal = "released"; detail = "It waits in \(name)'s inbox for its next turn, which has no stop from here; this conversation no longer waits on it, and any answer still comes as a chat of its own."
                } else if peer?.transport == .grokBot {
                    terminal = "released"; detail = "\(name) runs as a routine with no stop from here; this conversation no longer waits on it, and if it answers, that still arrives in the chat that asked."
                } else {
                    terminal = "cannot_stop"; detail = string(fields["detail"]) ?? "\(name)'s route has no stop for a reply already handed over; it keeps working and its answer still arrives."
                }
                let saved = try store.update(id: current.id, operationID: latest.operationID) {
                    if stoppedOrReleased($0) || $0.phase == "ready" { return }
                    if orphan, $0.phase == "sending" { interrupted(&$0) }
                    $0.stop = AgentConversationStop(state: terminal, operationID: latest.operationID, at: Date(), detail: detail)
                    if terminal != "cannot_stop" { $0.phase = "ready"; $0.automaticRead = false; $0.nextReadAt = nil }
                    if case .object(var receipt)? = $0.receipt {
                        receipt["detail"] = .string(detail)
                        if terminal == "stopped" {
                            receipt["status"] = .string("cancelled"); receipt["completed"] = .bool(false); receipt["terminal"] = .bool(true)
                            if let task = fields["task"] { receipt["cancel_receipt"] = task }
                        }
                        $0.receipt = AgentConversationStore.cacheReceipt(.object(receipt))
                    }
                }
                return answer(saved, ["stopped": .bool(saved.stop?.state == "stopped"),
                    "detail": .string(saved.stop?.detail ?? "The reply finished before the stop landed.")])
            }
        }
        do { return try settled.get() }
        catch var failure as AgentConversationStore.Failure { failure.effects = .unknown; throw failure }
    }

    /// A routine (Grok Bot) answers as its own turn in the chat that asked,
    /// never in the send record. Its read carries both sides in time order:
    /// her asks from the record (any chat), its replies from those chats
    /// (HerScreen.routineReplies, matched by the request's run id).
    private static func routineRead(agent: String, name: String, peer: AgentPeerContact?, row: AgentConversationRecord?,
                                    store: AgentConversationStore, args: [String: JSONValue], dataRoot: URL,
                                    perform: Dispatch) async throws -> JSONValue {
        var result: JSONValue = .object(["agent": .string(name), "agent_id": .string(agent), "state": .string("not_opened")])
        // A send that failed left no request id; Grok's read takes only one, so
        // refreshing would fail the whole read ("missing message_id").
        if let row { result = view(row.readInput == nil ? row : try await refresh(row, store: store, input: args, perform: perform), details: false, read: true, dataRoot: dataRoot) }
        // Her asks and the answers a wait took, from its one conversation (every
        // door it has); an answer handed over as a turn lands in the chat that
        // asked. Walk 4 (09-26): a handed-over turn with the same words within
        // ten minutes is that same answer, shown once.
        let said = try ContactThread.mergedLines(dataRoot: dataRoot, owner: agent.hasPrefix("peer:") ? String(agent.dropFirst(5)) : agent, identity: AgentContactIdentity(dataRoot: dataRoot))
        let turns = await HerScreen.routineReplies(dataRoot: dataRoot).filter { turn in
            !said.contains { !$0.mine && $0.text == turn.text && abs($0.at.timeIntervalSince(turn.date ?? $0.at)) < 600 }
        }
        let talk = ContactThread.project((said + turns).sorted { $0.at < $1.at }.suffix(8), names: [agent: name], unattested: name,
            mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) })
        guard case .object(var fields) = result, !talk.isEmpty else { return result }
        if talk.contains(where: { !$0.mine }) {
            // The current ask's own state comes from its request id (refreshed
            // above). A late answer to a superseded ask shows here but never
            // reads as the answer to the one still waiting.
            if fields["last_send_reply_state"] != .string("no_reply_expired"), !["waiting", "sending"].contains(fields["state"].flatMap { if case .string(let v) = $0 { v } else { nil } } ?? "") {
                fields["state"] = .string("replied")
            }
            fields["untrusted_remote_data"] = .bool(true)
        }
        fields["conversation"] = .array(talk.map { shown in
            .object(["at": shown.date.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null, "from": .string(shown.speaker),
                     "text": .string(HerScreen.clip(shown.text, 800))])
        })
        fields["conversation_note"] = .string("Oldest first: the messages sent and its replies, each reply after the message it answers.")
        return .object(fields)
    }

    private static func refresh(_ row: AgentConversationRecord, store: AgentConversationStore,
                                input: [String: JSONValue], perform: Dispatch) async throws -> AgentConversationRecord {
        var read = row.readInput ?? ["agent": .string(row.agent)]
        read["details"] = .bool(true)
        for key in ["session_id", "__session_id"] { read[key] = input[key] }
        let receipt = try await perform("agent_read", read)
        // Synchronous command/ACP adapters do not expose a recovery endpoint.
        // Their gate still ran; show the clearly labelled retained last result.
        // A read that did not reach its owner cannot expose a cached reply.
        if readRefused(receipt) {
            throw readFailure(receipt, agent: row.agent)
        }
        // A contact with nothing to read on its side (a desktop or inbound-only
        // door: "read": false) still has the conversation as it stands here.
        if case .object(let value) = receipt, value["status"] == .string("nothing_to_read") || value["read"] == .bool(false) {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        if row.readInput == nil {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        // A look is not news: the time moves only when the reply or state does.
        do {
            let refreshed = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                absorb(receipt, into: &$0)
                $0.selected = true
            }
            return refreshed
        } catch {
            // A queued follow-up went while this read was out (walk 3, 09-25: the
            // wait failed "moved on"): the thread as it is now, not a failure.
            if let now = try? store.records().first(where: { $0.id == row.id }), now.operationID != row.operationID { return now }
            throw error
        }
    }

    private static func record(_ receipt: JSONValue, for row: AgentConversationRecord,
                               store: AgentConversationStore, peer: AgentPeerContact?,
                               firstActivity: Date? = nil, inline: Bool = false, background: Bool = false,
                               queued: Bool = false, stopped: Bool = false) throws -> AgentConversationRecord {
        try store.update(id: row.id, operationID: row.operationID) {
            // A lane that settles on its own (Grok's desktop watch) may have
            // settled this operation already; its answer is never replaced.
            // A background send settles its own running exchange.
            guard $0.phase == "sending" || background && backgroundSend($0) else { return }
            // Don't keep a previous request locator for a new uncertain send.
            $0.readInput = nil
            absorb(receipt, into: &$0)
            if stopped, !AgentConversationRunning.shared.observing(row: row.id, operation: row.operationID) {
                let detail = if case .object(let fields) = receipt { string(fields["detail"]) } else { nil as String? }
                $0.stop = AgentConversationStop(state: "released", operationID: row.operationID, at: Date(), detail: detail ?? "Local work stopped; the remote outcome is unknown. Nothing was resent.")
                $0.phase = "ready"
            }
            $0.automaticRead = $0.phase == "waiting" && $0.readInput != nil
                && (peer?.transport == .a2a || peer?.transport == .nativeAgent)
            $0.nextReadAt = $0.automaticRead ? Date() : nil
            if !isRefusal(receipt) { $0.selected = true }
            if let firstActivity, let index = $0.exchanges?.lastIndex(where: { $0.id == row.operationID }) {
                $0.exchanges?[index].firstActivityAt = firstActivity
            }
            $0.shownInline = inline && $0.phase != "waiting" ? $0.operationID + ":" + $0.phase : nil
            // Publish settlement and delivery together, before a queued sender
            // can observe the finished exchange and advance this conversation.
            if background, $0.personInitiated != true, $0.phase != "waiting", !$0.automaticRead,
               !stoppedOrReleased($0), !AgentConversationRunning.shared.watched($0.id) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
            // A queued follow-up went while nobody was waiting on this call: a
            // contact's answer (or its refusal) then comes to her as a turn, as a
            // delayed reply does. A send-only route has nothing to hand over.
            if queued, $0.personInitiated != true, peer != nil, !$0.automaticRead, $0.phase != "waiting",
               case .object(let fields)? = $0.receipt, reply(fields) != nil || fields["sent"] == .bool(false) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
        }
    }

    /// A send, wait or stop result: the exchange itself and a one-line thread
    /// summary, not the retained history (walk 5, 09-26: every result re-shipped
    /// it). agent_read, and a send that went on in another chat's thread, keep it.
    static func compact(_ result: JSONValue, row: AgentConversationRecord?) -> JSONValue {
        guard let row, case .object(var fields) = result else { return result }
        fields.removeValue(forKey: "session_history")
        // Grok Bot's read carries its recent talk; with the reply in hand it is noise.
        if fields["reply"] != nil { fields.removeValue(forKey: "conversation_note") }
        if fields["reply"] != nil, case .array? = fields["conversation"] { fields.removeValue(forKey: "conversation") }
        var thread: [String: JSONValue] = ["conversation": .string(row.label), "exchanges": .int(Int64(row.exchanges?.count ?? 0)),
            "state": .string(row.phase), "history": .string("agent_read shows the conversation, both directions.")]
        if let id = threadID(row.agent) { thread["thread_id"] = .string(id) }
        fields["thread"] = .object(thread)
        return .object(fields)
    }

    /// Her own conversation with the agent: the one chat session the contact
    /// owns (`ContactThread.session`), whichever chat she reached it from.
    /// None for a helper bot, whose conversation is its shelf.
    static func threadID(_ agent: String) -> String? {
        if agent.hasPrefix("peer:") { return ContactThread.session(owner: String(agent.dropFirst(5))) }
        return nil
    }

    /// Names the thread a send implicitly went on in, and how old it was.
    private static func noting(_ result: JSONValue, carried: AgentConversationRecord?) -> JSONValue {
        guard let carried, let last = carried.exchanges?.last, case .object(var fields) = result else { return result }
        let when = last.settledAt ?? last.sentAt
        let seconds = max(0, Int(Date().timeIntervalSince(when)))
        let ago = seconds < 5400 ? "\(max(1, seconds / 60)) minutes" : seconds < 172_800 ? "\(seconds / 3600) hours" : "\(seconds / 86400) days"
        fields["thread_note"] = .string("No conversation was named, so this went on in “\(carried.label)”, begun in another chat; its last message was \(ago) earlier (\(ISO8601DateFormatter().string(from: when))). Name a conversation, or pass new_conversation: true, to keep a new topic apart.")
        return .object(fields)
    }

    /// The name she knows the thread bound to this exact id by: the one a send
    /// by that name from this chat would reach. Nil when none is saved.
    /// A conversation is named by its label or its id, everywhere (walk 3,
    /// 09-25: agent_read by the id a result showed came back not_opened).
    /// An exact record or conversation id wins over a label, and the record it
    /// names is the one used.
    static func named(_ label: String?, agent: String, scope: String, dataRoot: URL) -> (label: String?, record: String?) {
        guard let label else { return (nil, nil) }
        let rows = ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []).filter { $0.agent == agent }
        let exact = rows.first { $0.id == label } ?? rows.filter { $0.conversationID == label }
            .max { ($0.scopeSessionID == scope ? 1 : 0, $0.updatedAt) < ($1.scopeSessionID == scope ? 1 : 0, $1.updatedAt) }
        return exact.map { ($0.label, $0.id) } ?? (label, nil)
    }

    static func threadLabel(agent: String, conversation: String, scope: String, dataRoot: URL) -> String? {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let bound = ((try? store.records()) ?? []).filter { $0.agent == agent && $0.conversationID == conversation }
        return bound.sorted { $0.updatedAt > $1.updatedAt }.first { row in
            (try? store.find(scopeSessionID: scope, agent: agent, label: row.label))?.id == row.id
        }?.label
    }

    /// A built-in lane's read, each exchange carrying its thread's name.
    private static func labelled(_ result: JSONValue, agent: String, scope: String, dataRoot: URL) -> JSONValue {
        guard case .object(var fields) = result, case .array(let rows)? = fields["exchanges"] else { return result }
        var names: [String: String] = [:]
        fields["exchanges"] = .array(rows.map { value in
            guard case .object(var row) = value, let id = string(row["conversation_id"]) else { return value }
            if names[id] == nil { names[id] = threadLabel(agent: agent, conversation: id, scope: scope, dataRoot: dataRoot) ?? "" }
            if let name = names[id], !name.isEmpty { row["conversation"] = .string(name) }
            return .object(row)
        })
        return .object(fields)
    }

    /// One thread of a built-in lane by its id: its newest exchanges among the
    /// lane's fetched range (delegation_status has no conversation filter).
    private static func builtInThread(agent: String, conversation: String, args: [String: JSONValue], scope: String,
                                      dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        let limit = args["limit"] ?? .int(12)
        let offset = args["offset"] ?? .int(0)
        guard case .int(let count) = limit, (1...12).contains(count),
              case .int(let start) = offset, start >= 0, start <= Int64(Int.max) else {
            throw ToolFailureError("Named coding reads take limit 1–12 and a nonnegative offset.", argumentPath: "limit/offset",
                                   accepted: "app {action:\"agent.read\",args:{agent:\"<contact>\",conversation:\"<name>\",limit:5}}", effects: .none)
        }
        var list = args.filter { ["agent", "session_id", "__session_id", "details"].contains($0.key) }
        list["limit"] = .int(12)
        list["offset"] = offset
        guard case .object(var fields) = try await perform("agent_read", list) else {
            throw readFailure(.null, agent: agent)
        }
        if readRefused(.object(fields)) { return .object(fields) }
        func inThread(_ value: JSONValue) -> Bool {
            guard case .object(let row) = value else { return false }
            if row["conversation_id"] == .string(conversation) { return true }
            if let thread = string(row["thread_id"]) { return "codex:" + thread == conversation }
            return false
        }
        var found = false
        for key in ["exchanges", "jobs"] {
            guard case .array(let rows)? = fields[key] else { continue }
            let kept = Array(rows.filter(inThread).prefix(Int(count)))
            found = found || !kept.isEmpty
            fields[key] = .array(kept)
        }
        for key in ["read_more", "has_more", "next_offset", "summary", "count"] { fields.removeValue(forKey: key) }
        fields["conversation_id"] = .string(conversation)
        if let name = threadLabel(agent: agent, conversation: conversation, scope: scope, dataRoot: dataRoot) {
            fields["conversation"] = .string(name)
        }
        if !found, ["ok", "no_evidence"].contains(string(fields["status"]) ?? "") {
            fields["detail"] = .string("None of \(agent)'s exchanges in the fetched range is in that conversation. Read another range with offset, or an exchange exactly by its message_id.")
        }
        return labelled(.object(fields), agent: agent, scope: scope, dataRoot: dataRoot)
    }

    private static func readFailure(_ receipt: JSONValue, agent: String) -> ToolFailureError {
        let fields: [String: JSONValue] = if case .object(let value) = receipt { value } else { [:] }
        let remedy: [String: JSONValue] = if case .object(let value)? = fields["remedy"] { value } else { [:] }
        let call = remedy["next_call"].flatMap { value -> String? in
            if case .object = value { return try? value.serialize(pretty: false) }
            return nil
        }
        let kind = string(remedy["kind"])
        let status = string(fields["status"])
        return ToolFailureError(string(fields["detail"]) ?? string(fields["error"]) ?? "The agent read returned no conversation receipt.",
            effects: .none, owner: string(remedy["owner"]) ?? agent,
            nextCall: call ?? (kind == "terminal" || remedy["tap"] != nil ? nil : ToolFailureError.call("app", ["action": .string("agent.contacts")])),
            tap: string(remedy["tap"]), personDecides: kind == "person_decides",
            code: string(fields["failure_code"]) ?? string(fields["reason"]) ?? status ?? "agent_conversation_read_unavailable",
            status: status.flatMap(ToolFailureError.Status.init(rawValue:)) ?? (status.map(readRefusalStatuses.contains) == true ? .refused : .failed),
            instruction: string(remedy["instruction"]) ?? "Read contacts for this agent's access requirement before opening the conversation.",
            recovery: kind.flatMap(ToolFailureError.Recovery.init(rawValue:)) ?? (call == nil ? .inspect : .repair))
    }

    package static func absorb(_ receipt: JSONValue, into row: inout AgentConversationRecord) {
        var receipt = AgentConversationView.expiringReply(receipt)
        if row.phase != "sending", case .object(let previous)? = row.receipt,
           let path = previous["filePath"], case .object(var fields) = receipt, fields["filePath"] == nil {
            fields["filePath"] = path
            receipt = .object(fields)
        }
        // A wake owns completion. A lookup before its job is visible, or
        // while its receipt is unreadable, is not a terminal no-reply result.
        if row.readInput != nil, row.phase == "waiting",
           case .object(let root) = receipt,
           (root["jobs"] == .array([]) || ["not_found", "unavailable", "unknown"].contains(string(root["status"]) ?? "")),
           root["terminal"] != .bool(true), root["sent"] != .bool(false) {
            return
        }
        row.receipt = AgentConversationStore.cacheReceipt(receipt)
        guard case .object(let root) = receipt else { row.phase = "attention"; return }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        if let conversation = string(value["conversation_id"]) ?? string(value["conversationId"]) { row.conversationID = conversation }
        else if let thread = string(value["thread_id"]) { row.conversationID = "codex:" + thread }
        // A route whose saved chat is gone says null (Muse): the next send opens a new one.
        else if value["conversation_id"] == .null { row.conversationID = nil }
        if case .object(let action)? = root["read_with"], case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        } else if let locator = AgentConversationRouting.readLocator(agent: row.agent,
            message: value["message_id"] ?? value["messageId"] ?? value["matched_message_id"],
            conversation: row.conversationID.map(JSONValue.string), task: value["task_id"]),
                  case .object(let action) = locator, case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        }
        let state = GrokBotRoute.normalizedStatus(string(value["run_status"]) ?? string(value["status"]) ?? string(value["state"]) ?? "unknown")
        // A contact that pulls (an MCP host with no command line) took nothing
        // yet: the message is held and the thread is free (`takeHeld` drains it).
        if state == "held" {
            row.phase = "ready"
        } else if isRefusal(receipt) || ["failed", "interrupted", "waiting_approval", "waiting_for_approval", "waiting for approval", "waiting_on_you", "waiting_on_person", "waiting on you", "outcome_unknown", "unavailable", "cancelled", "canceled", "stopped", "reconnect_required", "session_unavailable"].contains(state) {
            row.phase = "attention"
        } else if row.agent.hasPrefix("peer:"), ["answered", "replied"].contains(state), value["reply"] == nil, value["answer"] == nil {
            // Evidence only (walk 2, 09-25): a contact's "answered" that carries no
            // reply field, not even an empty one, is a status, never an answer.
            row.phase = "attention"
        } else if AgentConversationDelivery.claudeInbox(row), ["delivered", "delivered_live", "queued", "read"].contains(state), reply(value) == nil {
            row.phase = (root["read"] ?? value["read"]) == .bool(true) && !row.awaitsReply ? "ready" : "waiting"
        } else if (value["needs_input"] == .bool(true) || value["completed"] == .bool(true)
                    || value["terminal"] == .bool(true) || ["replied", "completed", "succeeded", "done", "answered"].contains(state)) && AgentConversationDelivery.accepted(row)
                    || (state == "delivered_live" && reply(value) != nil) {
            // A live hand-off whose answer came back (a bridge reply naming it) is answered.
            row.phase = "ready"
        } else if ["enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending", "delivered", "sent", "delivered_live", "delivery_unknown"].contains(state) {
            // delivered_live: in the agent's live session; its answer is a chat of its own (`settled`).
            row.phase = "waiting"
        } else if reply(value) != nil {
            row.phase = "ready"
        } else { row.phase = "attention" }
        if row.phase != "waiting" { row.nextReadAt = nil; row.automaticRead = false }
    }

    static func view(_ row: AgentConversationRecord, details: Bool, read: Bool = false, dataRoot: URL,
                     historyBefore: String? = nil, historyExchange: String? = nil, includeHistory: Bool = true) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object = receipt else { return receipt }
        let peer = row.agent.hasPrefix("peer:") ? (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == row.agent } : nil
        var result = details ? receipt : conversationPresentation(row, transport: peer?.transport, prefix: read ? "last_send_" : "")
        if !details, includeHistory, returnsHistory {
            result = AgentConversationHistoryView.adding(to: result, row: row,
                before: historyBefore, exchange: historyExchange, dataRoot: dataRoot)
        }
        result = withLive(result, row: row, dataRoot: dataRoot)
        guard case .object(var shown) = result else { return result }
        if shown["can_reply"] == .bool(true), let presence = peer.flatMap(AgentContactHealth.checkIn) {
            shown["can_reply_detail"] = .string(presence.detail)
            result = .object(shown)
        }
        if let id = threadID(row.agent) {
            shown["thread_id"] = .string(id)
            result = .object(shown)
        }
        // The last operation was prefixed when the presentation was assembled;
        // the read keeps its own outcome, independently of that send.
        let readOwn: Set<String> = shown["session_history"] == nil ? ["read", "nothing_to_read", "unavailable"] : ["read"]
        if read, !details, let last = string(shown["status"]), !readOwn.contains(last) {
            shown["status"] = .string("read")
            result = .object(shown)
        }
        // A cached reply shown here is the words of the row that answered this
        // send, read under that row's own stamp; with no such row, under the
        // stamp its writer gave the cache (the answering door, or the route
        // the app read it from: a receipt, a live partial). The history
        // latched each of its lines itself.
        let liveText: String? = if case .object(let live)? = shown["live"], live["untrusted_remote_data"] == .bool(true) {
            string(live["partial_reply"]) ?? string(live["partial_text"]) ?? ""
        } else { nil }
        if let reply = string(shown["reply"]) ?? liveText ?? (shown["untrusted_remote_data"] == .bool(true) && shown["session_history"] == nil ? "" : nil) {
            let owner = row.agent.hasPrefix("peer:") ? String(row.agent.dropFirst(5)) : row.agent
            let lines = (try? ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: AgentContactIdentity(dataRoot: dataRoot))) ?? []
            let answered = lines.last(where: { !$0.mine && $0.answers == row.operationID })
                ?? ContactThread.Line(text: reply, stamp: row.cachedReplyStamp)
            ContactThread.consume(answered) { PeerDataTaint.markConsumed(peer: $0, line: $1) }
        }
        return result
    }

    /// What the agent is doing on the unsettled send, when it is still on it.
    static func withLive(_ result: JSONValue, row: AgentConversationRecord?, dataRoot: URL) -> JSONValue {
        guard let row, case .object(var fields) = result,
              let live = AgentConversationLiveStore(dataRoot: dataRoot).current(for: row),
              case .object(var projection) = live.projection(name: row.name) else { return result }
        if row.agent.hasPrefix("peer:"), projection["partial_text"] != nil { projection["untrusted_remote_data"] = .bool(true) }
        fields["live"] = .object(projection)
        return .object(fields)
    }

    private static func builtInJob(_ row: AgentConversationRecord) -> [String: JSONValue]? {
        guard case .object(let root)? = row.receipt,
              case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] else { return nil }
        return job
    }

    /// Handed straight into the agent's live session (Claude).
    package static func liveHandOff(_ row: AgentConversationRecord) -> Bool {
        guard let job = builtInJob(row) else { return false }
        return (job["run_status"] ?? job["status"]) == .string("delivered_live")
    }

    /// Only this exchange's settlement can release an owed reply.
    static func settled(_ row: AgentConversationRecord) -> Bool {
        stoppedOrReleased(row) || row.phase == "ready"
            || (!row.awaitsReply && [.delivered, .read].contains(AgentConversationDelivery.of(row, read: false)))
    }

    /// `prefix`: a read passes "last_send_" so the retained send never reads as the read's own outcome; a send keeps its own fields at top level.
    package static func conversationPresentation(_ row: AgentConversationRecord, transport: AgentPeerTransport? = nil, prefix: String = "") -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        let handOff = liveHandOff(row), handOffSettled = handOff && settled(row)
        let status = GrokBotRoute.normalizedStatus(string(value["run_status"]) ?? string(value["status"]) ?? row.phase)
        // The session behind this name is gone (OMP's "Main", walk 09-25).
        let deadThread = (string(value["reason"]) ?? string(value["execution_error"])) == "continuation_unavailable"
        // can_reply: a message sent now goes now. When it cannot, say until when.
        // A terminal attention state is superseded by the next message (the send path's rule).
        var canReply = (!["sending", "waiting"].contains(row.phase) || (row.phase == "waiting" && handOffSettled))
        var replyDetail: String?
        if ["sending", "waiting"].contains(row.phase), !canReply {
            replyDetail = "After \(row.name) answers the message in progress; a message sent now waits in the queue and goes by itself then."
        } else if row.phase == "attention", deadThread {
            canReply = false
            replyDetail = "In a new conversation only (new_conversation: true): the \(row.name) session behind “\(row.label)” no longer exists."
        } else if row.phase == "attention", ["waiting_approval", "waiting_for_approval", "waiting for approval", "approval_filed", "approval_required"].contains(status), unsettledAttention(row) {
            canReply = false
            replyDetail = "After the person decides on the approval for the previous message; a message sent now waits in the queue and goes by itself then."
        } else if unsettledAttention(row) {
            canReply = false
            replyDetail = "After the previous message's outcome is known (it may still be running) or agent_cancel releases it; a message sent now waits in the queue and goes by itself then."
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
            // A desktop chat app (Muse) has no stable id, only the title it gave
            // its chat; her own name stays the conversation (walk 5b, 09-26).
            result[transport == .desktopChat ? "app_chat_title" : "conversation_id"] = .string(conversation)
        }
        if backgroundSend(row) {
            result["state"] = .string("working")
            // A new remote session may not have supplied its ID yet.
            result["conversation_id"] = row.conversationID.map(JSONValue.string) ?? .null
        }
        if let current = row.exchanges?.last(where: { $0.id == row.operationID }) {
            lastSend.merge(current.timing) { _, timing in timing }
        }
        if root["jobs"] != nil {
            let original = AgentConversationView.codingReply(value)
            if let text = original.text {
                result["reply"] = .string(text)
                result["reply_truncated"] = .bool(original.truncated)
                lastSend["reply_state"] = .string("reply_received")
            } else {
                lastSend["reply_state"] = .string("no_reply_observed")
                if (value["run_status"] ?? value["status"]) == .string("delivered_live") {
                    lastSend["detail"] = .string("Waiting in \(row.name)'s inbox until its next turn; no one is answering yet.")
                } else if row.phase == "ready" {
                    lastSend["detail"] = .string("This saved record has delivery status but no original answer text. No message was resent.")
                }
            }
        } else if let text = reply(value) { result["reply"] = .string(text) }
        for key in ["untrusted_remote_data", "source_availability", "read_error", "reply_truncated", "artifacts", "parts", "has_more", "read_with", "attribution", "messages"] {
            if let field = value[key] ?? root[key] { result[key] = field }
        }
        for key in ["reply_state", "reply_deadline", "automatic_resend", "read", "execution", "completed", "terminal", "needs_input", "needs_authentication", "sent", "effects", "argument_path", "accepted", "reason", "error", "execution_error", "healed", "repair", "remedy", "harness_item", "delivered", "delivered_at"] {
            if let field = value[key] ?? root[key] { lastSend[key] = field }
        }
        // delegation_status.detail is a format selector ("full"), not an
        // explanation of the selected exchange.
        if root["jobs"] == nil, let detail = value["detail"] { lastSend["detail"] = detail }
        if row.phase == "waiting", handOff {
            lastSend["detail"] = .string("Waiting in \(row.name)'s inbox until its next turn; no one is answering yet."
                + (handOffSettled ? " A new message can go now." : " A new message can go once \(row.name) answers."))
        } else if row.phase == "waiting" {
            let automatic = row.automaticRead || row.readInput != nil
            lastSend["detail"] = .string(transport == .desktop
                ? "\(row.name) is answering in its own chat; the answer is read from there and lands on this exchange by itself (within three minutes). Do not resend this message."
                : backgroundSend(row)
                ? "\(row.name) is working on it. Its reply comes to you as a turn by itself when it lands (wait on this conversation returns it instead); do not resend this message."
                : automatic
                ? "Waiting for \(row.name). NativeAgent will bring the answer back; no repeated checks or resend needed."
                : "Waiting for \(row.name)'s configured return connection. Do not resend this message.")
        } else if row.phase == "sending" {
            lastSend["detail"] = .string("The previous send has not settled. It may have been interrupted; no message has been resent.")
        }
        if row.phase == "attention", let detail = row.deliveryState { lastSend["detail"] = .string(detail) }
        if row.phase == "attention", deadThread {
            lastSend["detail"] = .string("“\(row.label)” points at a \(row.name) conversation whose session no longer exists, so no work started and nothing was sent on. Start a new conversation (new_conversation: true) to ask again.")
        }
        if row.phase == "sending" {
            // The owner keeps the previous receipt for task-resumption routing
            // until dispatch settles. Never show its answer as this new turn.
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
            if stop.state == "stopped" { result["status"] = .string("cancelled"); lastSend["status"] = .string("cancelled"); lastSend["detail"] = .string(stop.detail) }
        }
        if let queued = queueProjection(row) { result["queued"] = queued }
        if ["sending", "waiting"].contains(row.phase), case .string(let detail)? = lastSend["detail"] {
            let cancel = [.desktop, .desktopChat].contains(transport) ? "."
                : handOff || transport == .grokBot ? "; agent_cancel stops waiting on it." : "; agent_cancel stops it."
            lastSend["detail"] = .string(detail + " A follow-up queues behind it" + cancel)
        }
        // One operation object, one prefix: outcome and timing never become
        // facts about the read that happens to show this retained send.
        for (key, field) in lastSend { result[prefix + key] = field }
        result["evidence"] = .string("Latest retained conversation result; an agent's answer is not independent verification of its work.")
        return .object(result)
    }

    private static func reply(_ row: [String: JSONValue]) -> String? {
        string(row["reply"]) ?? string(row["answer"]) ?? AgentConversationView.codingReply(row).text ?? string(row["findings"])
    }
    private static func confirmedNotSent(_ row: AgentConversationRecord) -> Bool {
        guard case .object(let receipt)? = row.receipt,
              receipt["sent"] == .bool(false) else { return false }
        // Only a new explicit message may try again after a pre-dispatch refusal.
        // Pending approvals and uncertain/accepted sends still require recovery;
        // the adapter rechecks current authority and connection on every attempt.
        return ["reconnect_required", "unavailable", "needs_setup", "no_outbound_route",
                "blocked", "denied", "blocked_by_trust", "busy", "invalid_arguments"].contains(string(receipt["status"]) ?? "")
    }
    /// A send that did not reach its owner: refused, or `sent: false`.
    private static func isRefusal(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        return readRefused(receipt) || row["sent"] == .bool(false)
            || ["needs_setup", "no_outbound_route"].contains(string(row["status"]) ?? "")
    }
    /// A read is refused only by an error or an explicit gate. `sent: false`
    /// is true of every read, and a contact with no outbound route still has
    /// its conversation here to show (fresh install 10-19: Claude Desktop).
    private static let readRefusalStatuses: Set<String> = ["blocked", "denied", "blocked_by_trust", "approval_required", "approval_filed"]

    private static func readRefused(_ receipt: JSONValue) -> Bool {
        guard case .object(let row) = receipt else { return true }
        return row["error"] != nil
            || readRefusalStatuses.contains(string(row["status"]) ?? "")
    }
    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return value
    }
    private static func agentIsBot(_ input: [String: JSONValue]) -> Bool {
        string(input["agent"])?.hasPrefix("bot:") == true
    }
    private static func attention(_ name: String, label: String, _ text: String) -> JSONValue {
        .object(["agent": .string(name), "conversation": .string(label), "state": .string("attention"), "detail": .string(text), "sent": .bool(false)])
    }
}
