import ChatTurnContracts
import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots

/// Approval execution retains the original exchange and all ordinary gates.
public enum AgentConversationApproval {
    // 2026-09-28: persist the exact path at filing; missing held state never proves it.
    @TaskLocal public static var exactProtocol = false

    public static func replay(id: String, dataRoot: URL, exactProtocol: Bool = false,
                              perform: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        if exactProtocol {
            return try await AgentConversationContext.$isInternalRead.withValue(true) { try await perform() }
        }
        return try await AgentConversationSession.replayApproval(id, dataRoot: dataRoot, perform: perform)
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

    static func replayApproval(_ id: String, dataRoot: URL,
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
        return try await send(row, store: store, peer: peer, reservation: nil, dataRoot: dataRoot) {
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
                  [historyBefore, historyExchange].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw AgentConversationStore.Failure(message: "Choose one offered session-history page or exchange. This only reads retained messages.")
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
        let dot = try agent.hasPrefix("peer:") && AgentPeerStore(dataRoot: dataRoot).list().contains {
            "peer:" + $0.id == agent && ChatGPTDotIPCTransport.owns($0)
        }
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
        if agent.hasPrefix("peer:"), string(args["message_id"]) == nil, string(args["task_id"]) == nil {
            args.removeValue(forKey: "limit"); args.removeValue(forKey: "offset")
        }
        // A built-in lane's wake names its thread by id (walk 09-25: the read
        // refused it while suggesting it): read that thread's newest exchanges.
        if tool == "agent_read", ["codex", "claude", "omp"].contains(agent), label == nil, !fresh,
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
        if !dot, args.contains(where: { advanced.contains($0.key) && $0.value != .string("") }) {
            guard label == nil, !fresh, historyBefore == nil, historyExchange == nil else { throw AgentConversationStore.Failure(message: "Choose either a conversation name or exact protocol identifiers, not both.") }
            return try await AgentConversationApproval.$exactProtocol.withValue(tool == "agent_message") {
                try await perform(tool, args)
            }
        }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        var peer = peers.first { "peer:" + $0.id == agent }
        // 2026-09-23: a contact removed and connected again gets a new id; its
        // older records and windows keep the old one under the same name. A READ
        // follows the one saved contact with that name. A send never routes by
        // name (another contact could share it): it is refused, naming the id.
        if agent.hasPrefix("peer:"), peer == nil,
           let name = (try? store.records())?.first(where: { $0.agent == agent })?.name {
            let same = peers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if same.count == 1, tool != "agent_read" {
                throw AgentConversationStore.Failure(message: "That contact's id changed; the current \(same[0].name) is peer:\(same[0].id); send to that.")
            }
            if same.count == 1 { peer = same[0]; agent = "peer:" + same[0].id; args["agent"] = .string(agent) }
        }
        if agent.hasPrefix("peer:"), peer == nil { throw AgentConversationStore.Failure(message: "This contact is no longer connected.") }
        let botName = try BotDefinitionStore(dataRoot: dataRoot).list().first {
            "bot:" + $0.id.uuidString.lowercased() == agent.lowercased()
        }?.name
        let name = peer?.name ?? botName ?? agent.capitalized
        let fingerprint = peer.map(AgentConversationStore.routeFingerprint)
        if peer.map(ChatGPTDotIPCTransport.owns) == true, tool == "agent_read" {
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
            if ["codex", "claude", "omp"].contains(agent) {
                if label != nil || pinned.record != nil, let row = previous, let conversation = row.conversationID {
                    let read = try await builtInThread(agent: agent, conversation: conversation, args: args,
                                                       scope: scope, dataRoot: dataRoot, perform: perform)
                    if isRefusal(read) { return read }
                    if historyBefore != nil || historyExchange != nil {
                        return view(row, details: false, dataRoot: dataRoot,
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
                    return view(refreshed, details: args["details"] == .bool(true), dataRoot: dataRoot,
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
            return view(refreshed, details: args["details"] == .bool(true), dataRoot: dataRoot,
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
            if !reserved, inFlight(row, peer?.transport, dataRoot: dataRoot),
               let queued = try queue(behind: row, name: name, peer: peer, args: args, scope: scope,
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
            if row.conversationID == nil, row.receipt != nil, !confirmedNotSent(row),
               !agent.hasPrefix("bot:"), peer?.transport != .desktop, peer?.transport != .grokBot, !dot {
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
             "replyTo": route.replyTo, "correlationId": route.correlationId].compactMapValues { $0 }
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
        if let owner = peer?.id ?? (["codex", "claude", "omp"].contains(agent) ? agent : nil), let text = string(args["text"]) {
            await ContactThread.write(.send(owner: owner, text: text, sendID: row.operationID,
                                            byPerson: row.personInitiated == true), dataRoot: dataRoot)
        }
        // Grok's conversation is always the asking chat; a saved id from another chat is refused.
        if let conversation = row.conversationID, peer?.transport != .grokBot, !dot { args["conversation_id"] = .string(conversation) }
        if case .object(let receipt)? = row.receipt, receipt["needs_input"] == .bool(true),
           let task = receipt["task_id"] { args["task_id"] = task }
        // Her inbox row says whether an answer is owed.
        if agent == "claude" { args["expects_reply"] = .bool(row.awaitsReply) }
        return noting(try await send(row, store: store, peer: peer, reservation: reservation, dataRoot: dataRoot) { [args] in
            try await perform(tool, args)
        }, carried: carried)
    }

    private static func send(_ row: AgentConversationRecord, store: AgentConversationStore, peer: AgentPeerContact?,
                             reservation: String?, dataRoot: URL,
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
            return try await AgentConversationLiveContext.$target.withValue(live) { try await perform() }
        }
        AgentConversationRunning.shared.begin(row: row.id, operation: row.operationID) { send.cancel() }
        // 2026-09-26 (User): an ACP, command-line or NativeAgent contact never
        // holds her turn. No reply within about 2s: this returns as running at
        // once, and the send goes on in a tracked task that settles this exact
        // exchange and hands the reply to her as a turn of its own.
        if reservation == nil, let transport = peer?.transport, [.acp, .mcpHost, .nativeAgent].contains(transport),
           !(await finishes(ended, within: 2, cancelling: send)), !Task.isCancelled {
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
            Task {
                _ = try? await conclude(send, row: row, store: store, peer: peer, live: live,
                                        reservation: nil, background: true, dataRoot: dataRoot)
                AgentConversationWatches.end(row: row.id, operation: row.operationID)
            }
            return view(shown, details: false, dataRoot: dataRoot)
        }
        return try await conclude(send, row: row, store: store, peer: peer, live: live,
                                  reservation: reservation, background: false, dataRoot: dataRoot)
    }

    /// True when the stream ends (the send finished) within `seconds`. A
    /// caller cancelled meanwhile cancels the send, as waiting on it would.
    private static func finishes(_ ended: AsyncStream<Void>, within seconds: Double,
                                 cancelling send: Task<JSONValue, Error>) async -> Bool {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in ended {}; return !Task.isCancelled }
                group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
        } onCancel: { send.cancel() }
    }

    /// Waits for the send and settles its exchange: the receipt it returned,
    /// a stop she asked for, or an unknown outcome; never a resend. A send
    /// nobody waits on (a queued follow-up, a background send) hands the
    /// contact's answer to her as a turn, as a delayed reply does.
    private static func conclude(_ send: Task<JSONValue, Error>, row: AgentConversationRecord, store: AgentConversationStore,
                                 peer: AgentPeerContact?, live: AgentConversationLiveTarget, reservation: String?,
                                 background: Bool, dataRoot: URL) async throws -> JSONValue {
        defer { AgentConversationRunning.shared.end(row: row.id, operation: row.operationID) }
        let hub = AgentConversationLiveHub.shared
        // Her answer is hers: a background send hands over what it ended with,
        // unless she stopped it or a `wait` is watching and takes it itself.
        func owed(_ saved: AgentConversationRecord) -> Bool {
            background && saved.personInitiated != true && saved.phase != "waiting" && !saved.automaticRead
                && !stoppedOrReleased(saved) && !AgentConversationRunning.shared.watched(saved.id)
        }
        do {
            let receipt = try await withTaskCancellationHandler { try await send.value } onCancel: { send.cancel() }
            let firstActivity = await hub.firstActivity(live)
            // A queued follow-up's call has no one waiting on it: its result is an arrival.
            let saved = try record(receipt, for: row, store: store, peer: peer, firstActivity: firstActivity,
                                   inline: reservation == nil && !background, background: background, queued: reservation != nil)
            await hub.settle(live, state: saved.phase == "waiting" ? "waiting" : "finished")
            return compact(view(saved, details: false, dataRoot: dataRoot, includeHistory: false), row: saved)
        } catch {
            await hub.settle(live, state: "finished")
            // An exception may occur after dispatch. Keep the exact previous
            // binding and mark uncertainty; never synthesize a replacement send.
            // One that ended because she asked it to stop is simply stopped.
            let stopped = try? store.update(id: row.id, operationID: row.operationID) {
                guard $0.phase == "sending" || background && backgroundSend($0) else { return }
                if var stop = $0.stop, stop.operationID == row.operationID, stop.state == "stopping" {
                    stop.state = "stopped"
                    $0.stop = stop
                    $0.phase = "ready"
                    $0.receipt = .object(["status": .string("cancelled"), "sent": .bool(true), "completed": .bool(false),
                        "detail": .string("Stopped at your request before a reply came back.")])
                    return
                }
                $0.phase = "attention"
                $0.receipt = .object(["status": .string("outcome_unknown"),
                    "detail": .string("The send did not establish an outcome. The conversation was preserved; no message was resent.")])
                if owed($0) {
                    $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
                }
            }
            if let stopped, stopped.stop?.state == "stopped", !Task.isCancelled {
                return compact(view(stopped, details: false, dataRoot: dataRoot, includeHistory: false), row: stopped)
            }
            throw error
        }
    }

    /// `wait` on a contact: back as soon as the reply in flight on its thread
    /// settles (every settle is a store write, which wakes this) or when
    /// `seconds` run out, saying which. What it returns is `read`'s agent_read.
    /// `admit` (agent_read's own wait) reads through the gates first, so a
    /// read that would be refused is refused, not waited past.
    package static func waitForReply(input: [String: JSONValue], scope: String, dataRoot: URL, admit: Bool = false,
                             read: @escaping Dispatch) async throws -> JSONValue {
        guard let agent = string(input["agent"]) else { throw AgentConversationStore.Failure(message: "Name the contact to wait for.") }
        let pinned = named(string(input["conversation"]), agent: agent, scope: scope, dataRoot: dataRoot)
        let label = pinned.label
        var readInput: [String: JSONValue] = ["agent": .string(agent)]
        // The name she gave, so the read resolves to this same record.
        if let label { readInput["conversation"] = input["conversation"] ?? .string(label) }
        for key in ["session_id", "__session_id", "details"] { readInput[key] = input[key] }
        let asked: Double = switch input["seconds"] { case .int(let n)?: Double(n); case .double(let n)?: n; default: 60 }
        let started = Date()
        let deadline = started.addingTimeInterval(min(max(asked, 1), 300))
        if let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { "peer:" + $0.id == agent }),
           ChatGPTDotIPCTransport.owns(peer) {
            var snapshot = try await read("agent_read", readInput)
            if isRefusal(snapshot) { return snapshot }
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
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                try await Task.sleep(for: .seconds(min(2, remaining)))
                if Date() >= deadline { break }
                snapshot = try await read("agent_read", readInput)
                if isRefusal(snapshot) { return snapshot }
                outcome = "settled"
            }
            guard case .object(var fields) = snapshot else { return snapshot }
            fields["wait_outcome"] = .string(outcome)
            fields["waited_ms"] = .int(Int64(Date().timeIntervalSince(started) * 1000))
            return .object(fields)
        }
        if admit {
            let first = try await $returnsHistory.withValue(false) { try await read("agent_read", readInput) }
            if isRefusal(first) { return first }
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
            guard let row = try pinned.record.flatMap({ id in try store.records().first { $0.id == id } })
                    ?? store.find(scopeSessionID: scope, agent: agent, label: label) else { outcome = "not_opened"; break }
            latest = row
            if watching == nil { watching = row.id; AgentConversationRunning.shared.watch(row.id) }
            guard replyInFlight(row, transport, dataRoot: dataRoot) else {
                if outcome != "nothing_in_flight" { outcome = "settled" }
                break
            }
            outcome = "still_waiting"
            if Date() >= deadline { break }
            // A live hand-off answers in a chat of its own, which is no store write: look again shortly.
            await AgentConversationRunning.shared.change(after: seen,
                until: liveHandOff(row) ? min(deadline, Date().addingTimeInterval(15)) : deadline)
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
            _ = try? GrokRequestStore(dataRoot: dataRoot).update(message, peer: String(agent.dropFirst(5))) {
                if $0.state == "answered", let saved = $0.reply, saved == delivered || (clipped && saved.hasPrefix(delivered)) {
                    $0.seen = true
                }
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
    static func inFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL?) -> Bool {
        replyInFlight(row, transport, dataRoot: dataRoot) || row.queueReservation != nil
            || row.queued?.contains(where: { $0.held == nil }) == true
    }

    /// The reply ahead is still coming. A "sending" row only counts while this
    /// process still owns that send.
    static func replyInFlight(_ row: AgentConversationRecord, _ transport: AgentPeerTransport?, dataRoot: URL?) -> Bool {
        if row.phase == "sending" { return AgentConversationRunning.shared.live(row: row.id, operation: row.operationID) }
        // A live hand-off settles on its answer turn having completed, an FYI on
        // delivery; a release only lets go once no answer turn is mid-way (`settled`).
        if liveHandOff(row), row.phase == "waiting" || stoppedOrReleased(row) { return !settled(row, dataRoot: dataRoot) }
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

    /// At launch, before queued follow-ups resume: a background send, or a
    /// send to those lanes caught mid-way, that the restart ended settles as
    /// interrupted and unanswered, never waiting forever. Nothing is resent.
    static func settleInterrupted(dataRoot: URL) {
        let store = AgentConversationStore(dataRoot: dataRoot)
        let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        let lanes = Set(contacts
            .filter { [.acp, .mcpHost, .nativeAgent].contains($0.transport) }.map { "peer:" + $0.id })
        let running = AgentConversationRunning.shared
        for row in (try? store.records()) ?? [] where backgroundSend(row) && !running.routeWatching(row: row.id, operation: row.operationID)
            || row.phase == "sending" && lanes.contains(row.agent) && !running.live(row: row.id, operation: row.operationID) {
            _ = try? store.update(id: row.id, operationID: row.operationID) {
                guard backgroundSend($0) || $0.phase == "sending" else { return }
                var fields: [String: JSONValue] = ["status": .string("interrupted"), "completed": .bool(false),
                    "detail": .string("Interrupted by an app restart before \($0.name)'s reply came back, so it was not answered here. Nothing was resent; send it again if it is still wanted.")]
                if let conversation = $0.conversationID { fields["conversation_id"] = .string(conversation) }
                absorb(.object(fields), into: &$0)
                $0.readInput = nil
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
        return ["outcome_unknown", "delivery_unknown"].contains(status)
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

    /// Held on an approval the person has not decided yet: the queue behind it
    /// looks again often, since the decision lands in another store.
    static func awaitingApproval(_ row: AgentConversationRecord) -> Bool {
        guard unsettledAttention(row), case .object(let root)? = row.receipt else { return false }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        return approvalWaits.contains(string(value["run_status"]) ?? string(value["status"]) ?? "")
    }

    /// agent_cancel settled this send: the lane stopped it, or (where there is
    /// no stop) the thread let go of waiting; a late answer still arrives.
    package static func stoppedOrReleased(_ row: AgentConversationRecord) -> Bool {
        guard let stop = row.stop, stop.operationID == row.operationID else { return false }
        return ["stopped", "released"].contains(stop.state)
    }

    /// Queue a follow-up on the thread and start its sender. Nil when the reply
    /// settled in the meantime, so the caller just sends it.
    private static func queue(behind row: AgentConversationRecord, name: String, peer: AgentPeerContact?,
                              args: [String: JSONValue], scope: String, surface: String, dataRoot: URL,
                              perform: @escaping Dispatch) throws -> JSONValue? {
        guard let text = string(args["text"]) else { return nil }
        let store = AgentConversationStore(dataRoot: dataRoot)
        let transport = peer?.transport
        guard let queued = try store.enqueue(id: row.id, text: text,
                byPerson: PersonInitiatedSend.current?.matches(args) == true,
                stillInFlight: { inFlight($0, transport, dataRoot: dataRoot) }) else { return nil }
        let (saved, item) = queued
        let carried = args.filter { ["session_id", "__session_id"].contains($0.key) }
        _ = AgentConversationRunning.shared.adopt(item.id)
        // A child task keeps this call's context (session, turn envelope, and a
        // person's own send mark), so the queued send clears the same gates later.
        Task {
            await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: saved.label, carried: carried,
                                  transport: transport, scope: scope, surface: surface, dataRoot: dataRoot, perform: perform)
        }
        let ahead = (saved.queued ?? []).filter { $0.held == nil && $0.id != item.id }.count
        return .object(["agent": .string(name), "agent_id": .string(row.agent), "conversation": .string(saved.label),
            "state": .string("queued"), "queued": .bool(true), "sent": .bool(false), "queued_id": .string(item.id),
            "queue_position": .int(Int64(ahead + 1)),
            "detail": .string("Queued behind the reply in progress from \(name)" + (ahead > 0 ? " and \(ahead) earlier queued message\(ahead == 1 ? "" : "s")" : "")
                + ". It goes by itself, in order, when that reply settles; do not send it again. agent_cancel stops the reply in progress.")])
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
                "state": .string(item.held != nil ? "held" : going ? "sending" : "queued"),
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
            Task {
                await sendWhenSettled(row: row.id, item: item.id, agent: row.agent, label: row.label, carried: [:],
                                      transport: transport, scope: row.scopeSessionID, surface: row.sourceSurface,
                                      dataRoot: dataRoot, perform: perform)
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
        let queuedAt = (try? store.records().first { $0.id == id })?.queued?.first { $0.id == item }?.queuedAt ?? Date()
        // A reply still being handed to her as a turn goes first, too. Order
        // among queued messages is `takeQueued`'s (only the head, one at a time).
        let ready: (AgentConversationRecord) -> Bool = {
            !replyInFlight($0, transport, dataRoot: dataRoot) && $0.deliveryState != "delivering"
        }
        while !Task.isCancelled {
            let seen = AgentConversationRunning.shared.seen
            guard let row = try? store.records().first(where: { $0.id == id }),
                  row.queued?.contains(where: { $0.id == item && $0.held == nil }) == true else { return }
            if let taken = try? store.takeQueued(id: id, item: item, ready: ready) {
                var input = carried
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
            let giveUp = queuedAt.addingTimeInterval(24 * 60 * 60)
            if Date() >= giveUp {
                if let entry = row.queued?.first(where: { $0.id == item }) {
                    try? store.holdQueued(id: id, item: entry, reason: "Not sent: the reply ahead of it did not settle within a day.")
                }
                return
            }
            // Every settle is a store write, which wakes this. The one piece of
            // evidence that is not (a live hand-off's answer, which lands as a
            // chat of its own) is looked for once a minute. No time settles anything.
            let deadline = awaitingApproval(row) ? min(giveUp, Date().addingTimeInterval(15))
                : liveHandOff(row) && replyInFlight(row, transport, dataRoot: dataRoot)
                ? min(giveUp, Date().addingTimeInterval(60)) : giveUp
            await AgentConversationRunning.shared.change(after: seen, until: deadline)
        }
    }

    /// Stop the reply in flight on this thread, on the lane's own terms, and
    /// write what happened on the thread: stopping, stopped, or cannot_stop.
    private static func cancel(_ previous: AgentConversationRecord?, name: String, peer: AgentPeerContact?, clearQueue: Bool,
                               args: [String: JSONValue], store: AgentConversationStore, dataRoot: URL,
                               perform: Dispatch) async throws -> JSONValue {
        guard let row = previous else {
            return .object(["agent": .string(name), "state": .string("not_opened"), "stopped": .bool(false),
                            "detail": .string("There is no conversation with \(name) here to stop.")])
        }
        let latest = (try? store.records().first { $0.id == row.id }) ?? row
        let flying = replyInFlight(latest, peer?.transport, dataRoot: dataRoot)
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
        let cleared = clearQueue ? try store.clearQueued(id: row.id) : 0
        func answer(_ record: AgentConversationRecord, _ extra: [String: JSONValue]) -> JSONValue {
            guard case .object(var fields) = compact(view(record, details: false, dataRoot: dataRoot, includeHistory: false), row: record) else { return .object(extra) }
            fields.merge(extra) { _, new in new }
            if cleared > 0 { fields["queue_cleared"] = .int(Int64(cleared)) }
            return .object(fields)
        }
        guard flying else {
            return answer((try? store.records().first { $0.id == row.id }) ?? latest, ["stopped": .bool(false),
                "detail": .string("Nothing from \(name) is in flight on this conversation, so there was nothing to stop."
                + (cleared > 0 ? " The queued messages were withdrawn." : ""))])
        }
        func write(_ asked: String, _ detail: String, receipt: JSONValue? = nil) -> JSONValue {
            var state = asked
            let saved = try? store.update(id: latest.id, operationID: latest.operationID) {
                // The reply may already have ended on the stop before this is written.
                if state == "stopping", !["sending", "waiting"].contains($0.phase) {
                    let status: String = if case .object(let fields)? = $0.receipt, case .string(let value)? = fields["status"] { value } else { "" }
                    state = $0.phase == "attention" || ["cancelled", "canceled", "interrupted"].contains(status) ? "stopped" : "finished"
                    if state == "stopped" { $0.phase = "ready" }
                }
                $0.stop = AgentConversationStop(state: state, operationID: latest.operationID, at: Date(),
                                                detail: state == "finished" ? "The reply finished before the stop landed." : detail)
                if state == "released" { $0.phase = "ready"; $0.automaticRead = false; $0.nextReadAt = nil }
                guard state == "stopped", asked == "stopped" else { return }
                $0.phase = "ready"; $0.automaticRead = false; $0.nextReadAt = nil
                if case .object(var fields) = $0.receipt ?? .object([:]) {
                    fields["status"] = .string("cancelled"); fields["completed"] = .bool(false); fields["terminal"] = .bool(true)
                    fields["detail"] = .string(detail)
                    if case .object(let task)? = receipt { fields["cancel_receipt"] = .object(task) }
                    $0.receipt = AgentConversationStore.cacheReceipt(.object(fields))
                }
            }
            guard let saved else {
                return answer((try? store.records().first { $0.id == row.id }) ?? latest,
                              ["stopped": .bool(false), "detail": .string("\(name)'s reply settled before the stop landed.")])
            }
            return answer(saved, ["stopped": .bool(state == "stopped"), "stop_state": .string(state),
                                  "detail": .string(saved.stop?.detail ?? detail)])
        }
        if state == "not_here" || state == "cannot_stop" && (latest.phase == "sending" || backgroundSend(latest)),
           AgentConversationRunning.shared.live(row: latest.id, operation: latest.operationID) {
            // This process's own send: its task cancels it on the lane's terms.
            // Written first, so the send's own ending finds the stop it answers.
            let written = write("stopping", "Stopping \(name)'s reply in progress; the conversation settles as stopped when it ends.")
            _ = AgentConversationRunning.shared.stop(row: latest.id, operation: latest.operationID)
            return written
        }
        if state == "stopped" || state == "stopping" {
            return write(state, string(fields["detail"]) ?? "", receipt: fields["task"])
        }
        // Routes with no stop: said plainly. Where the answer comes back on its
        // own (a hand-off's chat, Grok Bot's turn), the thread stops waiting on
        // it (`released`, settled in `settled`) so what is queued can go.
        if unsettledAttention(latest) {
            return write("released", "Its outcome is not known and \(name)'s route has no stop for it; this conversation no longer waits on it, and anything \(name) answers still arrives.")
        }
        if liveHandOff(latest) {
            return write("released", "It waits in \(name)'s inbox for its next turn, which has no stop from here; this conversation no longer waits on it, and any answer still comes as a chat of its own.")
        }
        if peer?.transport == .grokBot {
            return write("released", "\(name) runs as a routine with no stop from here; this conversation no longer waits on it, and if it answers, that still arrives in the chat that asked.")
        }
        if [.desktop, .desktopChat].contains(peer?.transport) {
            return write("cannot_stop", "It was typed into \(name)'s own window, which has no stop from here; whatever \(name) answers still arrives.")
        }
        if state == "not_here" {
            return write("cannot_stop", "\(name)'s route has no stop for a reply already handed over; it keeps working and its answer still arrives.")
        }
        return write(state, string(fields["detail"]) ?? "", receipt: fields["task"])
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
        if let row { result = view(row.readInput == nil ? row : try await refresh(row, store: store, input: args, perform: perform), details: false, dataRoot: dataRoot) }
        let exchanges = ((try? store.records()) ?? []).filter { record in
            record.agent == agent || (record.agent.hasPrefix("peer:") && record.name.caseInsensitiveCompare(name) == .orderedSame)
        }.flatMap { $0.exchanges ?? [] }
        let asks = exchanges.compactMap { exchange in exchange.prompt.map { (exchange.sentAt as Date?, exchange.byPerson == true ? "the person" : "you", $0) } }
        // Walk 4 (09-26): an answer a wait took is never handed over as a turn,
        // so the exchanges carry it; a handed-over turn with the same words
        // within ten minutes is that same answer, shown once.
        let answered = exchanges.compactMap { exchange in exchange.reply.map { (exchange.settledAt ?? exchange.sentAt, $0) } }
        let turns = await HerScreen.routineReplies(dataRoot: dataRoot).filter { turn in
            !answered.contains { $0.1 == turn.text && abs($0.0.timeIntervalSince(turn.at ?? $0.0)) < 600 }
        }
        let replies = answered.map { ($0.0 as Date?, name, $0.1) } + turns.map { ($0.at, name, $0.text) }
        let talk = (asks + replies).sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }.suffix(8)
        guard case .object(var fields) = result, !talk.isEmpty else { return result }
        if !replies.isEmpty {
            // Its words are remote data: consumed now, unless its owner is trusted.
            if peer?.elevationAllowed != true { PeerDataTaint.markConsumed(peer: agent) }
            // The current ask's own state comes from its request id (refreshed
            // above). A late answer to a superseded ask shows here but never
            // reads as the answer to the one still waiting.
            if !["waiting", "sending"].contains(fields["state"].flatMap { if case .string(let v) = $0 { v } else { nil } } ?? "") {
                fields["state"] = .string("replied")
            }
            fields["untrusted_remote_data"] = .bool(true)
        }
        fields["conversation"] = .array(talk.map { at, from, text in
            .object(["at": at.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null, "from": .string(from),
                     "text": .string(HerScreen.clip(text, 800))])
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
        // A desktop contact's read is send-only ("read": false, "sent": false):
        // not an access refusal, just nothing to read there.
        if case .object(let value) = receipt, value["status"] == .string("nothing_to_read")
            || (value["operation"] == .string("read") && value["read"] == .bool(false) && value["error"] == nil) {
            return try store.update(id: row.id, operationID: row.operationID, touch: false) { $0.selected = true }
        }
        // A read that did not reach its owner cannot expose a cached reply.
        if isRefusal(receipt) { throw AgentConversationStore.Failure(message: "This conversation cannot be opened with the current access settings.") }
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
                               queued: Bool = false) throws -> AgentConversationRecord {
        try store.update(id: row.id, operationID: row.operationID) {
            // A lane that settles on its own (Grok's desktop watch) may have
            // settled this operation already; its answer is never replaced.
            // A background send settles its own running exchange.
            guard $0.phase == "sending" || background && backgroundSend($0) else { return }
            // Don't keep a previous request locator for a new uncertain send.
            $0.readInput = nil
            absorb(receipt, into: &$0)
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
            "state": .string(row.phase), "history": .string("agent_read shows the retained exchanges.")]
        if let id = threadID(row.agent) { thread["thread_id"] = .string(id) }
        fields["thread"] = .object(thread)
        return .object(fields)
    }

    /// Her own conversation with the agent: the one chat session the contact
    /// owns (`ContactThread.session`), whichever chat she reached it from.
    /// None for a helper bot, whose conversation is its shelf.
    static func threadID(_ agent: String) -> String? {
        if agent.hasPrefix("peer:") { return ContactThread.session(owner: String(agent.dropFirst(5))) }
        return ["codex", "claude", "omp"].contains(agent) ? ContactThread.session(owner: agent) : nil
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
    /// lane's recent twelve (delegation_status has no conversation filter).
    private static func builtInThread(agent: String, conversation: String, args: [String: JSONValue], scope: String,
                                      dataRoot: URL, perform: Dispatch) async throws -> JSONValue {
        var list = args.filter { ["agent", "session_id", "__session_id", "details"].contains($0.key) }
        list["limit"] = .int(12)
        guard case .object(var fields) = try await perform("agent_read", list) else {
            throw AgentConversationStore.Failure(message: "That conversation could not be read.")
        }
        if isRefusal(.object(fields)) { return .object(fields) }
        func inThread(_ value: JSONValue) -> Bool {
            guard case .object(let row) = value else { return false }
            if row["conversation_id"] == .string(conversation) { return true }
            if let thread = string(row["thread_id"]) { return "codex:" + thread == conversation }
            return false
        }
        var found = false
        for key in ["exchanges", "jobs"] {
            guard case .array(let rows)? = fields[key] else { continue }
            let kept = rows.filter(inThread)
            found = found || !kept.isEmpty
            fields[key] = .array(kept)
        }
        for key in ["read_more", "has_more", "next_offset", "summary", "count"] { fields.removeValue(forKey: key) }
        fields["conversation_id"] = .string(conversation)
        if let name = threadLabel(agent: agent, conversation: conversation, scope: scope, dataRoot: dataRoot) {
            fields["conversation"] = .string(name)
        }
        if !found {
            fields["detail"] = .string("None of \(agent)'s twelve most recent exchanges is in that conversation. Read an older one exactly by its message_id.")
        }
        return labelled(.object(fields), agent: agent, scope: scope, dataRoot: dataRoot)
    }

    package static func absorb(_ receipt: JSONValue, into row: inout AgentConversationRecord) {
        // A wake owns completion. A lookup before its job is visible, or
        // while its receipt is unreadable, is not a terminal no-reply result.
        if ["codex", "claude", "omp"].contains(row.agent), row.phase == "waiting",
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
        else if row.agent == "codex", let thread = string(value["thread_id"]) { row.conversationID = "codex:" + thread }
        if case .object(let action)? = root["read_with"], case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        } else if let locator = AgentConversationRouting.readLocator(agent: row.agent,
            message: value["message_id"] ?? value["messageId"] ?? value["matched_message_id"],
            conversation: row.conversationID.map(JSONValue.string), task: value["task_id"]),
                  case .object(let action) = locator, case .object(var read)? = action["input"] {
            read["details"] = .bool(true); row.readInput = read
        }
        let state = GrokBotRoute.normalizedStatus(string(value["run_status"]) ?? string(value["status"]) ?? string(value["state"]) ?? "unknown")
        if isRefusal(receipt) || ["failed", "interrupted", "waiting_approval", "waiting_for_approval", "waiting for approval", "waiting_on_you", "waiting_on_person", "waiting on you", "outcome_unknown", "unavailable", "cancelled", "canceled", "reconnect_required", "session_unavailable"].contains(state) {
            row.phase = "attention"
        } else if row.agent.hasPrefix("peer:"), ["answered", "replied"].contains(state), value["reply"] == nil, value["answer"] == nil {
            // Evidence only (walk 2, 09-25): a contact's "answered" that carries no
            // reply field, not even an empty one, is a status, never an answer.
            row.phase = "attention"
        } else if value["needs_input"] == .bool(true) || value["completed"] == .bool(true)
                    || value["terminal"] == .bool(true) || ["replied", "completed", "succeeded", "done", "answered", "sent", "delivered"].contains(state)
                    || (state == "delivered_live" && reply(value) != nil) {
            // A live hand-off whose answer came back (a bridge reply naming it) is answered.
            // delivered: in Claude's inbox; she answers in a chat of her own.
            row.phase = "ready"
        } else if ["enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending", "delivered_live", "delivery_unknown"].contains(state) {
            // delivered_live: in the agent's live session; its answer is a chat of its own (`settled`).
            row.phase = "waiting"
        } else if reply(value) != nil {
            row.phase = "ready"
        } else { row.phase = "attention" }
        // A reply asked to stop that has now ended: stopped, unless its real
        // answer beat the stop, which is said as it is. Either way it settled.
        if var stop = row.stop, stop.operationID == row.operationID, stop.state == "stopping", row.phase != "waiting" {
            let answered = row.phase == "ready" && reply(value) != nil && !["cancelled", "canceled", "interrupted", "aborted"].contains(state)
            stop.state = answered ? "finished" : "stopped"
            if answered { stop.detail = "The reply finished before the stop landed." }
            row.stop = stop
            row.phase = "ready"
        }
        if row.phase != "waiting" { row.nextReadAt = nil; row.automaticRead = false }
    }

    static func view(_ row: AgentConversationRecord, details: Bool, dataRoot: URL,
                     historyBefore: String? = nil, historyExchange: String? = nil, includeHistory: Bool = true) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object = receipt else { return receipt }
        let peer = row.agent.hasPrefix("peer:") ? (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == row.agent } : nil
        var result = details ? receipt : conversationPresentation(row, transport: peer?.transport, dataRoot: dataRoot)
        if !details, includeHistory, returnsHistory {
            result = AgentConversationHistoryView.adding(to: result, row: row,
                before: historyBefore, exchange: historyExchange, dataRoot: dataRoot)
        }
        result = withLive(result, row: row, dataRoot: dataRoot)
        guard case .object(var shown) = result else { return result }
        if let id = threadID(row.agent) {
            shown["thread_id"] = .string(id)
            result = .object(shown)
        }
        // Cached reads retain peer provenance instead of laundering it through
        // this presentation layer. Elevation still comes from the current owner.
        // Compact send/wait/stop results do not present retained history.
        let hasRemoteData = ["session_history", "live"].contains { key in
            guard case .object(let fields)? = shown[key] else { return false }
            return fields["untrusted_remote_data"] == .bool(true)
        }
        // A built-in lane (Claude, Codex, OMP) is a peer too (Agent, 10-02).
        if shown["untrusted_remote_data"] == .bool(true) || !(string(shown["reply"]) ?? "").isEmpty || hasRemoteData,
           peer?.elevationAllowed != true {
            PeerDataTaint.markConsumed(peer: row.agent, line: string(shown["reply"]) ?? "")
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
        guard ["codex", "claude", "omp"].contains(row.agent), case .object(let root)? = row.receipt,
              case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] else { return nil }
        return job
    }

    /// Handed straight into the agent's live session (Claude): no reply comes
    /// back on the job; the agent answers in a bridge chat of its own.
    package static func liveHandOff(_ row: AgentConversationRecord) -> Bool {
        guard let job = builtInJob(row) else { return false }
        return (job["run_status"] ?? job["status"]) == .string("delivered_live")
    }

    /// A live hand-off is settled only on evidence, never elapsed time (Sol,
    /// 09-25: a resend before its answer duplicates work): the agent has written
    /// in a chat since. An FYI is settled on delivery: nothing is owed, so a next
    /// message is no resend. An explicit cancel of the thread settles it here too.
    static func settled(_ row: AgentConversationRecord, dataRoot: URL?) -> Bool {
        let released = stoppedOrReleased(row)
        if !row.awaitsReply && !released { return true }
        let handed = row.operationStartedAt ?? row.updatedAt
        guard let dataRoot else { return false }
        let answers = HerScreen.bridgeChats(dataRoot: dataRoot).filter { $0.who == row.agent && ($0.heard ?? .distantPast) > handed }
        // An answer counts once her turn on it has completed (her reply is that
        // chat's last word), not while it is still being written.
        guard answers.allSatisfy({ $0.answered == true }) else { return false }
        return released || !answers.isEmpty
    }

    package static func conversationPresentation(_ row: AgentConversationRecord, transport: AgentPeerTransport? = nil, dataRoot: URL? = nil) -> JSONValue {
        let receipt = row.receipt ?? .object(["status": .string("unknown")])
        guard case .object(let root) = receipt else { return receipt }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        let handOff = liveHandOff(row), handOffSettled = handOff && settled(row, dataRoot: dataRoot)
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
            result.merge(current.timing) { _, timing in timing }
        }
        if ["codex", "claude", "omp"].contains(row.agent), root["jobs"] != nil {
            let original = AgentConversationView.codingReply(value)
            if let text = original.text {
                result["reply"] = .string(text)
                result["reply_truncated"] = .bool(original.truncated)
                result["reply_state"] = .string("reply_received")
            } else {
                result["reply_state"] = .string("no_reply_observed")
                if (value["run_status"] ?? value["status"]) == .string("delivered_live") {
                    result["detail"] = .string("Waiting in \(row.name)'s inbox until its next turn; no one is answering yet.")
                } else if row.phase == "ready" {
                    result["detail"] = .string("This saved record has delivery status but no original answer text. No message was resent.")
                }
            }
        } else if let text = reply(value) { result["reply"] = .string(text) }
        for key in ["untrusted_remote_data", "source_availability", "read_error", "completed", "terminal", "needs_input", "needs_authentication", "sent", "reason", "error", "execution_error", "reply_truncated", "artifacts", "parts", "has_more", "read_with", "attribution", "messages"] {
            if let field = value[key] ?? root[key] { result[key] = field }
        }
        // delegation_status.detail is a format selector ("full"), not an
        // explanation of the selected exchange.
        if root["jobs"] == nil, let detail = value["detail"] { result["detail"] = detail }
        if row.phase == "waiting", handOff {
            result["detail"] = .string("Waiting in \(row.name)'s inbox until its next turn; no one is answering yet."
                + (handOffSettled ? " A new message can go now." : " A new message can go once \(row.name) answers."))
        } else if row.phase == "waiting" {
            let automatic = row.automaticRead || ["codex", "claude", "omp"].contains(row.agent)
            result["detail"] = .string(transport == .desktop
                ? "\(row.name) is answering in its own chat; the answer is read from there and lands on this exchange by itself (within three minutes). Do not resend this message."
                : backgroundSend(row)
                ? "\(row.name) is working on it. Its reply comes to you as a turn by itself when it lands (wait on this conversation returns it instead); do not resend this message."
                : automatic
                ? "Waiting for \(row.name). NativeAgent will bring the answer back; no repeated checks or resend needed."
                : "Waiting for \(row.name)'s configured return connection. Do not resend this message.")
        } else if row.phase == "sending" {
            result["detail"] = .string("The previous send has not settled. It may have been interrupted; no message has been resent.")
        }
        if row.phase == "attention", let detail = row.deliveryState { result["detail"] = .string(detail) }
        if row.phase == "attention", deadThread {
            result["detail"] = .string("“\(row.label)” points at a \(row.name) conversation whose session no longer exists, so no work started and nothing was sent on. Start a new conversation (new_conversation: true) to ask again.")
        }
        if row.phase == "sending" {
            // The owner keeps the previous receipt for task-resumption routing
            // until dispatch settles. Never show its answer as this new turn.
            for key in ["reply", "completed", "terminal", "sent", "reply_truncated", "artifacts", "parts"] { result.removeValue(forKey: key) }
            result["status"] = .string("sending")
            result["reply_state"] = .string("no_reply_observed")
        }
        if let stop = row.stop, stop.operationID == row.operationID,
           stop.state != "cannot_stop" || ["sending", "waiting"].contains(row.phase) {
            result["stop"] = .object(["state": .string(stop.state), "detail": .string(stop.detail),
                                      "at": .string(ISO8601DateFormatter().string(from: stop.at))])
            if stop.state == "stopped" { result["status"] = .string("cancelled"); result["detail"] = .string(stop.detail) }
        }
        if let queued = queueProjection(row) { result["queued"] = queued }
        if ["sending", "waiting"].contains(row.phase), case .string(let detail)? = result["detail"] {
            let cancel = [.desktop, .desktopChat].contains(transport) ? "."
                : handOff || transport == .grokBot ? "; agent_cancel stops waiting on it." : "; agent_cancel stops it."
            result["detail"] = .string(detail + " A follow-up queues behind it" + cancel)
        }
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
        .object(["agent": .string(name), "conversation": .string(label), "state": .string("attention"), "detail": .string(text), "sent": .bool(false)])
    }
}
