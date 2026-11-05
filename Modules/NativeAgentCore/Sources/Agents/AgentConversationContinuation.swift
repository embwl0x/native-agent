import MacControl
import BackgroundLoops
import AuthoredCapabilities
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentWorkspace
import AgentConversations
import AgentLinkTransport
import Cognition
import CognitiveSubstrate
import CryptoKit
import Desk
import Foundation
import NativeAgentShared
import ToolRegistry
import NativeAgentCore
import PersistenceCore
import StandingBots
import Transcripts
import os

// Blueprint: | `AgentConversationContinuation.swift` | Read delayed replies without resending. |

/// Read delayed replies under the delegation runner’s lifecycle; stored routes grant no execution authority and never authorize resends.
public struct AgentConversationContinuation: Sendable {
    let dataRoot: URL
    let clients: any AgentContactClients
    let grok: GrokInboundReply
    private let dot: ChatGPTDotConversation
    let completionSender: any AgentBridgeCompletionSending
    private let queuesResumed = OSAllocatedUnfairLock(initialState: false)
    private let pushOwner = UUID()
    private struct ReplyWork: Sendable {
        var tasks: [String: Task<Void, Never>] = [:]
        var pending: Set<String> = []
        var stopped = false
    }
    private let replyWork = OSAllocatedUnfairLock(initialState: ReplyWork())

    init(dataRoot: URL, clients: any AgentContactClients, grok: GrokInboundReply, dot: ChatGPTDotConversation,
         completionSender: any AgentBridgeCompletionSending) {
        self.dataRoot = dataRoot
        self.clients = clients
        self.grok = grok
        self.dot = dot
        self.completionSender = completionSender
    }

    private var store: AgentConversationStore { AgentConversationStore(dataRoot: dataRoot) }
    private var lifecycle: CodexCompletionLifecycle {
        CodexCompletionLifecycle(
            receiptURL: dataRoot.appendingPathComponent("agent-conversations/completions.jsonl"),
            ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
    }

    public func nextDeadline(after now: Date) -> Date? {
        let rows: [AgentConversationRecord]
        let peers: [AgentPeerContact]
        do {
            rows = try store.records()
            peers = try AgentPeerStore(dataRoot: dataRoot).list()
        }
        catch {
            nativeLog("Conversation continuation deadline unavailable: %@", error.localizedDescription)
            return nil
        }
        let active = replyWork.withLock { Set($0.tasks.keys) }
        let dotAgents = Set(peers.filter { $0.ability == nil && ChatGPTDotIPCTransport.owns($0) }.map { "peer:" + $0.id })
        let ordinary = rows.filter { !active.contains($0.agent) && !dotAgents.contains($0.agent)
            && ($0.notice != nil || $0.automaticRead && ($0.deliveryState == "delivering"
                || $0.phase == "waiting" && !$0.agent.hasPrefix("bot-run:"))) }
            .map { $0.nextReadAt ?? now }.min()
        return [ordinary, AgentLocalHealth.nextRefresh(dataRoot, now: now)]
            .compactMap { $0 }.min()
    }

    /// Resume through the original gated chain without an approval filer; card-requiring sends stay held with their reason.
    private func resumeQueues(workspace: WorkspaceOperation) async throws {
        try Task.checkCancellation()
        replyWork.withLock { $0.stopped = false }
        await AgentDiscoverySession.shared.watchInstalls(dataRoot: dataRoot)
        try Task.checkCancellation()
        ChatGPTDotIPCTransport.listen(dataRoot: dataRoot)
        do { try await dot.resumeAdmissions() }
        catch is CancellationError { throw CancellationError() }
        catch { nativeLog("Dot admission recovery failed: %@", error.localizedDescription) }
        try Task.checkCancellation()
        AgentConversationWatches.start()
        await AgentConversationLiveHub.shared.start()
        try Task.checkCancellation()
        let store = store
        await AgentA2APushReceiver.shared.installInvalidator(owner: pushOwner) { peer, task in
            for row in (try? store.records()) ?? [] where row.agent == "peer:" + peer
                && row.automaticRead && row.phase == "waiting"
                && (row.readInput?["task_id"] == .string(task) || row.receiptField("task_id") == .string(task)) {
                _ = try? store.update(id: row.id, operationID: row.operationID, touch: false) { $0.nextReadAt = Date() }
            }
        }
        try Task.checkCancellation()
        if !queuesResumed.withLock({ $0 }) {
            // Read retained waiting tasks once at startup after registering their invalidation source. The task owns current state.
            let now = Date()
            for row in try store.records() where row.agent.hasPrefix("peer:")
                && row.automaticRead && row.phase == "waiting"
                && string(row.readInput?["task_id"] ?? row.receiptField("task_id")) != nil
                && (row.nextReadAt ?? .distantPast) > now {
                _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                    if $0.automaticRead && $0.phase == "waiting" && $0.nextReadAt == row.nextReadAt {
                        $0.nextReadAt = now
                    }
                }
            }
        }
        guard !queuesResumed.withLock({ $0 }) else { return }
        // Load and seed recipes before any contact row reads them.
        AgentRecipeStore.load(dataRoot: dataRoot)
        try grok.resumeHandOvers(dataRoot: dataRoot, continuation: self)
        // IPC conversation changes arrive by push, never polling.
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        // Authored contact routes retain exchanges through the ordinary conversation owner.
        let dotAgents = Set(peers.filter { $0.ability == nil && ChatGPTDotIPCTransport.owns($0) }.map { "peer:" + $0.id })
        _ = try store.dropUnsettleable(dot: dotAgents, saved: Set(peers.map { "peer:" + $0.id }))
        for row in try AgentConversationSession.orphanedQueues(dataRoot: dataRoot) {
            if dotAgents.contains(row.agent) { continue } // Direct-session contacts cannot resume queued sends.
            let session = row.scopeSessionID, surface = row.sourceSurface
            let tools = clients.toolDispatchClient(enforceAppAutonomy: false)
            var turn = Turn(session: session)
            turn.verifiedSessionID = session
            // Restart retains routing, not the initiating transport's authentication.
            // Neither the recipient's Trust nor a bot destination supplies caller authority.
            turn.envelope = .current(turn: nil, surface: surface)
            AgentConversationSession.resumeQueued(turn: turn, mac: .init(dataRoot: dataRoot), conversation: .init(), workspace: workspace, row,
                dataRoot: dataRoot) { tool, input, turn, conversation, mac in
                let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: dataRoot,
                    verifiedSessionId: session)
                var invocation = ChatToolInvocation().serving(conversation: conversation.internalRead)
                invocation.macOperation = mac
                return try await chain.dispatch(tool: tool, input: input, surface: surface, turn: turn, invocation: invocation)
            }
        }
        queuesResumed.withLock { $0 = true }
    }

    public func stop() async {
        await settle {
            let tasks = replyWork.withLock { state in
                state.stopped = true
                return Array(state.tasks.values)
            }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            await AgentConversationWatches.stop()
            await grok.stop()
            await AgentA2APushReceiver.shared.removeInvalidator(owner: pushOwner)
            await dot.stopSubscriptions()
            await ChatGPTDotIPCTransport.stop()
            await AgentDiscoverySession.shared.stop()
            await AgentConversationLiveHub.shared.shutdown()
        }
    }

    public func reconcileReplies() async throws {
        let configRoot = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let lifecycle = CodexCompletionLifecycle(receiptURL: configRoot.appendingPathComponent("claude-bridge/message-replies.jsonl"), dataRoot: dataRoot)
        let human = CodexCompletionLifecycle(receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"), dataRoot: dataRoot)
        var firstError: Error?
        // Let each independent owner recover before reporting any one owner’s fault.
        for owner in [lifecycle, human, self.lifecycle] {
            do {
                _ = try await owner.reconcileInterruptedClaims()
                try await owner.reconcileSavedDeliveries(sender: completionSender,
                    client: clients.bridgeChatClient(), notifyRequestedResult: owner.receiptURL != human.receiptURL)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if firstError == nil { firstError = error }
                nativeLog("Reply recovery for %@ failed: %@", owner.receiptURL.path, error.localizedDescription)
            }
        }
        let owed = Set(try await self.lifecycle.reconciliationRows().filter { $0.status == "owed" || $0.status == "sent_unconfirmed" }.map(\.id))
        // Re-arm only work that is not armed already and was not already shown inline: this runs on every reply-delivery change, so a
        // second write here would wake the reader that wakes it.
        for row in try store.records() where row.phase == "attention" && row.receipt != nil
            && owed.contains("agent-conversation:" + row.operationID)
            && !(row.deliveryState == "delivering" && row.automaticRead) && row.shownInline != row.operationID + ":ready" {
            _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
        }
        if let firstError { throw firstError }
    }

    package func tick(workspace: WorkspaceOperation) async throws {
        try await resumeQueues(workspace: workspace)
        Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
        let now = Date()
        let dotAgents = Set(try AgentPeerStore(dataRoot: dataRoot).list().filter { $0.ability == nil && ChatGPTDotIPCTransport.owns(
            $0) }.map { "peer:" + $0.id })
        let due = try store.records().filter {
            !dotAgents.contains($0.agent) && ($0.notice != nil || $0.automaticRead && ($0.phase == "waiting" || $0.deliveryState == "delivering"))
                && Self.readIsDue($0, at: now)
        }
        // Each contact owns its ordered replies; a turn never holds another contact's arrival behind reconciliation.
        for contact in Set(due.map(\.agent)) {
            replyWork.withLock { state in
                guard !state.stopped, !Task.isCancelled else { return }
                if state.tasks[contact] != nil { state.pending.insert(contact); return }
                state.tasks[contact] = Task {
                    let read: Bool
                    do { read = try await readDueReplies(contact: contact) }
                    catch is CancellationError { read = false }
                    catch {
                        read = false
                        nativeLog("Conversation reply handling for %@ failed: %@", contact, error.localizedDescription)
                    }
                    await settle {
                        let rearm = replyWork.withLock { state in
                            state.tasks.removeValue(forKey: contact)
                            let pending = state.pending.remove(contact) != nil
                            return !state.stopped && (read || pending)
                        }
                        // Reproject the contact's canonical nextReadAt after releasing its work, without an artificial retry wake.
                        if rearm { StoreChangeBus.shared.emit(.init(store: .replyDelivery, path: store.fileURL)) }
                    }
                }
            }
        }
    }

    private func readDueReplies(contact: String) async throws -> Bool {
        var read = Set<String>()
        var rearm = false
        while true {
            try Task.checkCancellation()
            // Reread after each turn: it may have advanced this contact's conversation or accepted another reply.
            guard let row = try store.records().filter({
                $0.agent == contact && !read.contains($0.operationID)
                    && ($0.notice != nil || $0.automaticRead && ($0.phase == "waiting" || $0.deliveryState == "delivering"))
                    && Self.readIsDue($0, at: Date())
            }).sorted(by: { ($0.nextReadAt ?? .distantPast) < ($1.nextReadAt ?? .distantPast) }).first else { return rearm }
            read.insert(row.operationID)
            // Delegate notices belong to the asking chat and must not change the thread’s send state.
            if let notice = row.notice {
                rearm = true
                do {
                    try await deliver(row, receipt: .object(["event": .string(notice.event), "text": .string(notice.text)]),
                                      notice: notice)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                        $0.nextReadAt = Date().addingTimeInterval(60)
                    }
                }
                continue
            }
            guard let operationStartedAt = row.operationStartedAt else {
                try attention(row, """
                    The accepted operation's start time is unavailable. Repair its saved operation evidence before continuing; no message was \
                    repeated.
                    """)
                continue
            }
            let readingUntil = Date().addingTimeInterval(30)
            do {
                if row.agent.hasPrefix("bot-run:") {
                    if try await handleBotRun(row) { rearm = true }
                    continue
                }
                rearm = true
                guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
                    "peer:" + $0.id == row.agent
                }), [.nativeAgent, .a2a].contains(peer.transport)
                    // Queued follow-up answers share the same handover path.
                    || row.deliveryState == "delivering",
                    AgentConversationStore.sameRoute(row.peerRouteFingerprint, peer),
                    NativeAgentChatSessionID.normalizedPathComponent(row.scopeSessionID) != nil
                else {
                    try attention(row, "This contact or its conversation route changed. Reopen the conversation before continuing.")
                    continue
                }
                // A write-triggered wake must not busy-poll its own store.
                _ = try store.update(id: row.id, operationID: row.operationID) {
                    $0.nextReadAt = readingUntil
                }
                if row.deliveryState == "delivering", let receipt = row.receipt {
                    try await deliver(row, receipt: receipt, peer: peer)
                    continue
                }
                guard var input = row.readInput, input["agent"] == .string(row.agent) else {
                    try attention(row, "The saved reply reference is incomplete; the message has not been sent again.")
                    continue
                }
                input["details"] = .bool(true)
                if peer.transport == .nativeAgent { input["max_chars"] = .int(16000) }
                let read = try await readReply(input: input, row: row, peer: peer)
                let receipt = try await store.retainReply(read, for: row)
                try Task.checkCancellation()
                guard case .object(let fields) = receipt else {
                    try attention(row, "The contact returned an unreadable reply record.")
                    continue
                }
                if AgentConversationSession.readRefused(receipt) || fields["needs_authentication"] == .bool(true) {
                    try attention(row, "The contact needs attention before its reply can be retrieved.", receipt: receipt)
                    continue
                }
                let settled = fields["terminal"] == .bool(true) || fields["needs_input"] == .bool(true)
                let cached = AgentConversationStore.cacheReceipt(receipt)
                _ = try store.update(id: row.id, operationID: row.operationID) {
                    $0.receipt = cached
                    if $0.conversationID == nil, let conversation = string(fields["conversation_id"]) {
                        $0.conversationID = conversation
                    }
                    if fields["needs_input"] == .bool(true), let task = fields["task_id"] {
                        $0.readInput?["task_id"] = task
                    }
                    if $0.nextReadAt == readingUntil {
                        // The retained task is the one state reader. Pushes only invalidate it sooner; delivery evidence never selects a different receive
                        // mechanism.
                        $0.nextReadAt = Date().addingTimeInterval(Date().timeIntervalSince(operationStartedAt) > 300 ? 60 : 15)
                    }
                }
                if settled, row.personInitiated == true {
                    // Person-initiated answers settle in their thread without running an agent turn.
                    try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID)
                    continue
                }
                if settled {
                    try await deliver(row, receipt: cached, peer: peer)
                    continue
                }
                if Date().timeIntervalSince(operationStartedAt) > 24 * 60 * 60 {
                    try attention(row, "The contact has not supplied a finished reply. Its original message remains available; it was not sent again.",
                        receipt: cached)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Read failure is safe to retry; a delivery failure is not. The lifecycle below records ambiguity before this boundary.
                if row.agent.hasPrefix("bot-run:") {
                    try attention(row, "The helper's exact result could not be read: \(error.localizedDescription). Repair its request or result evidence.")
                } else if Date().timeIntervalSince(operationStartedAt) > 24 * 60 * 60 {
                    try attention(row, "The contact's reply could not be recovered within a day. The original message has not been repeated.")
                } else {
                    _ = try store.update(id: row.id, operationID: row.operationID) {
                        if $0.nextReadAt == readingUntil || $0.nextReadAt == row.nextReadAt {
                            $0.nextReadAt = Date().addingTimeInterval(60)
                        }
                    }
                }
            }
        }
    }

    private static func readIsDue(_ row: AgentConversationRecord, at now: Date) -> Bool {
        // A pending helper result follows its queue/shelf owner; saved read dates cannot hold that owner's event.
        if row.notice == nil, row.agent.hasPrefix("bot-run:"), row.deliveryState != "delivering" { return true }
        return (row.nextReadAt ?? .distantPast) <= now
    }

    private func deliver(_ row: AgentConversationRecord, receipt: JSONValue, peer: AgentPeerContact? = nil,
                         bot: (id: UUID, name: String)? = nil, notice: AgentConversationNotice? = nil) async throws {
        // Inline waiters take precedence; helper outcomes return as receipts, not additional model turns. A reply the waiting call already
        // showed is delivered: its delivery settles once here, so neither this reader nor recovery arms it again.
        if notice == nil, try store.offerReplyToInlineWait(row, receipt: receipt) {
            try await settleShownInline(row)
            return
        }
        if let bot {
            try await deliverBotResult(row, receipt: receipt, bot: bot)
            return
        }
        let peer = try peer.map { expected in
            guard let current = try AgentPeerStore(dataRoot: dataRoot).list().first(where: { $0.id == expected.id }) else {
                throw StandingBotsError.invalidValue("The contact is no longer connected.")
            }
            return current
        }
        let deliveryID = "agent-conversation:" + row.operationID + (notice.map { ":" + $0.event } ?? "")
        // Run reply arrivals in the contact’s own session while returning the answer to the original asking door.
        let session = peer.map { ContactThread.session(owner: $0.id) } ?? row.scopeSessionID
        let route = AgentBridgeCompletionRoute(asking: row, turnSessionId: session)
        let retainedReply: ContactThread.Line?
        if notice == nil, peer != nil {
            let path = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
            let rows = try await SwiftNativePersistenceCore.withFileLock(path) { try await SwiftNativePersistenceCore.readJSONL(path) }
            retainedReply = rows.reversed().lazy.compactMap { value -> ContactThread.Line? in
                guard case .object(let fields) = value else { return nil }
                return ContactThread.Line(fields)
            }.first { $0.answers == row.operationID && $0.run != nil }
        } else { retainedReply = nil }
        let turnSurface: String
        let turnEnvelope: TurnEnvelope
        let origin: ChatMessageOrigin
        let incoming: String
        if let notice {
            // Delegate output carries only its attested agent authority, never person authorship.
            turnSurface = "chat"
            turnEnvelope = TurnEnvelope(surface: turnSurface, agent: row.agent,
                verifiedUserId: peer?.id,
                deliveryRoute: route.chatToolReplyRoute, declaredRemote: false)
            origin = try ChatMessageOrigin(surface: BridgeLane.bridgeSurfaceName(forSender: row.agent), agent: row.agent,
                authored: BridgeLane.laneAuthorship(forSender: row.agent))
            incoming = notice.text
        } else if let peer {
            turnSurface = peer.elevationAllowed ? "chat" : AgentBridgeSurface.id
            turnEnvelope = envelope(peer: peer, route: route.chatToolReplyRoute)
            origin = ChatMessageOrigin(surface: turnSurface, agent: "agent", authored: .agent, replyTo: deliveryID)
            incoming = incomingText(receipt, peer: peer, label: row.label, retainedText: retainedReply?.text)
        } else { throw StandingBotsError.invalidValue("A reply must have an identified author.") }
        let isTerminalCompletion = notice?.event.hasPrefix("stalled:") != true
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = try await lifecycle.cachedRequestDigest(deliveryId: deliveryID)
            ?? SHA256.hash(data: try encoder.encode(receipt)).map { String(format: "%02x", $0) }.joined()
        let answered: Answered
        do {
            answered = try await answer(deliveryID, digest: digest, session: session, route: route, principal: row.agent,
                                        runID: retainedReply?.run, notify: isTerminalCompletion, start: {
                // Once the turn owns the event, glance and arrivals must not repeat it.
                _ = try store.update(id: row.id, operationID: row.operationID, touch: notice == nil) {
                    if notice == nil { $0.phase = "ready"; $0.deliveryState = "delivering"; $0.receipt = receipt }
                    $0.shownInline = $0.operationID + ":" + $0.phase
                }
            }) { runID, binding in
                let client = clients.bridgeChatClient()
                // Consume the exact saved run so history and the handover turn cannot duplicate it.
                let request = TurnRequest(message: incoming, sessionID: session, surface: turnSurface,
                    suppressUserAppend: retainedReply != nil,
                    envelope: turnEnvelope, verifiedSessionID: session, replyRoute: route.chatToolReplyRoute,
                    origin: origin, pinnedRunID: runID, codexCompletion: binding, threadKind: .agent,
                    ownedSessionID: peer.map { ContactThread.session(owner: $0.id) })
                let admitted = try await TurnAdmission.admittedRun(turn: request.turn(),
                    arrival: request.arrival(retainedReply != nil ? .saved : .shown), dataRoot: dataRoot, waitForCapacity: true) { turn in
                    (try await request.chat(on: client, holding: turn), turn)
                }
                if notice == nil, case .ran(let (response, _)) = admitted {
                    _ = try? store.update(id: row.id, operationID: row.operationID) { $0.deliveryRunID = response.runId }
                }
                return admitted
            }
        } catch is TurnAdmission.Full {
            if notice != nil {
                // Unstarted work has not been handed to the agent.
                _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                    if $0.shownInline == $0.operationID + ":" + $0.phase { $0.shownInline = nil }
                    $0.nextReadAt = Date().addingTimeInterval(30)
                }
                return
            }
            _ = try store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "waiting"
                // Retry admission using this exact frozen reply/digest; rereading the peer could change the claimed payload.
                $0.deliveryState = "delivering"
                $0.automaticRead = true
                $0.nextReadAt = Date().addingTimeInterval(30)
            }
            return
        } catch {
            if let notice {
                // Do not rerun uncertain execution or mark it handed over.
                FileHandle.standardError.write(Data(("AgentConversationContinuation: delegation notice turn "
                    + "\(deliveryID) interrupted; not rerun: \(error.localizedDescription)\n").utf8))
                try? told(row, notice, handed: false)
            } else { try? attention(row, "Reply handling was interrupted. The peer reply is retained; no message was repeated.", receipt: receipt) }
            throw error
        }
        if let notice { return try told(row, notice) }
        switch answered {
        case .held:
            // Never a second turn for one event; the thread itself is untouched.
            try attention(row, "Reply handling was interrupted. The original reply is retained; no second turn or message was started.", receipt: receipt)
        case .settled(let result):
            try await finish(row, delivered: result?.status == "completed" || result?.status == "sent_unconfirmed", runID: row.deliveryRunID,
                sessionID: session,
                       sentUnconfirmed: result?.status == "sent_unconfirmed")
        case .delivered(let result, let runID):
            try await finish(row, delivered: result.status == "completed" || result.status == "sent_unconfirmed", runID: runID, sessionID: session,
                       sentUnconfirmed: result.status == "sent_unconfirmed")
        }
    }

    enum Answered {
        case delivered(AgentBridgeCompletionDelivery, runID: String)
        case settled(AgentBridgeCompletionDelivery?)
        /// In progress, of unknown outcome, or claimed with other content: never a second turn.
        case held
    }
    struct NotStarted: Error {}

    /// Claim, run and cache each answer once; release admission before delivering it to the asking door.
    func answer(_ deliveryID: String, digest: String, session: String, route: AgentBridgeCompletionRoute, principal: String,
                runID: String? = nil, notify: Bool = true, start: () throws -> Void = {},
                run: (_ runID: String, _ binding: CodexCompletionTranscriptBinding) async throws
                    -> TurnAdmission.Admitted<(ChatTurnRuntime.ChatResponse, Turn)>)
        async throws -> Answered {
        let runID = runID ?? CausalTransitionEvidence.opaqueIdentity(deliveryID)
        let response: ChatTurnRuntime.ChatResponse
        let turn: Turn
        switch try await lifecycle.claim(deliveryId: deliveryID, requestDigest: digest, sessionId: session, responseRunId: runID,
                                        route: route, principal: principal, source: principal) {
        case .cached(let cached):
            response = cached
            // A saved delivery is a new native operation over an already-produced answer.
            turn = TurnRequest(message: cached.output, sessionID: cached.sessionId, surface: route.surface,
                envelope: .native("completion.delivery"), pinnedRunID: cached.runId).turn()
        case .settled(let result): return .settled(result)
        case .inProgress, .outcomeUnknown, .conflict: return .held
        case .start:
            var enteredRun = false
            do {
                try start()
                enteredRun = true
                let admitted = try await run(runID, CodexCompletionTranscriptBinding(deliveryId: deliveryID, requestDigest: digest,
                    model: "", reasoningEffort: nil, isTerminalCompletion: notify))
                let produced: (ChatTurnRuntime.ChatResponse, Turn)
                switch admitted {
                case .ran(let ran): produced = ran
                case .steered(let steered):
                    // The agent's turn in progress read it and answers it: settled here, never run or posted again.
                    let read = AgentBridgeCompletionDelivery(status: "steered", surface: route.surface, delivery: "read_in_turn:" + steered.turnID,
                        artifactCount: 0, attempts: 0, reason: "The agent's turn in progress read it; that turn's reply answers it.")
                    try await lifecycle.recordDelivery(read, deliveryId: deliveryID, requestDigest: digest)
                    return .settled(read)
                }
                response = produced.0
                turn = produced.1
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            } catch {
                if !enteredRun || error is TurnAdmission.Full || error is NotStarted {
                    try await lifecycle.markNotStarted(deliveryId: deliveryID, requestDigest: digest,
                        detail: "Continuation did not start: " + error.localizedDescription)
                } else {
                    try await lifecycle.markOutcomeUnknown(deliveryId: deliveryID, requestDigest: digest,
                        detail: "Resident continuation interrupted; never rerun automatically: " + error.localizedDescription)
                }
                throw error
            }
        }
        return .delivered(await AgentBridgeCompletionRouter.deliverAnswer(turn: turn, deliveryId: deliveryID, requestDigest: digest,
            text: ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters),
            attachments: response.attachments ?? [], route: route, client: clients.bridgeChatClient(),
            sender: completionSender, lifecycle: lifecycle, notifyRequestedResult: notify), runID: response.runId)
    }

    /// The event is the agent's now: clear it, leaving the thread's own state (a stalled send is still owed its answer) as it is.
    private func told(_ row: AgentConversationRecord, _ notice: AgentConversationNotice, handed: Bool = true) throws {
        _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
            if $0.notice == notice { $0.notice = nil }
            if !handed, $0.shownInline == $0.operationID + ":" + $0.phase { $0.shownInline = nil }
            $0.nextReadAt = nil
        }
    }

    /// Only explicitly requested runs have bookmarks; scheduled history must not create unsolicited turns.
    private func handleBotRun(_ row: AgentConversationRecord) async throws -> Bool {
        guard NativeAgentChatSessionID.normalizedPathComponent(row.scopeSessionID) != nil,
              let input = row.readInput, let agent = string(input["agent"]), agent.hasPrefix("bot:"),
              let botID = UUID(uuidString: String(agent.dropFirst(4))),
              row.agent == "bot-run:" + botID.uuidString,
              let request = string(input["message_id"]), let requestID = UUID(uuidString: request) else {
            try attention(row, "This requested check has lost its exact return reference. No run was repeated.")
            return false
        }
        // Helper-session results already belong there; running an agent turn inside that session would corrupt speaker identity.
        let askedByItself = row.scopeSessionID.lowercased() == "bot-" + botID.uuidString.lowercased()
        if row.deliveryState == "delivering", let receipt = row.receipt {
            if askedByItself { try await finishBotRunOnOwnPage(row, botID: botID, requestID: requestID, receipt: receipt) }
            else { try await deliver(row, receipt: receipt, bot: (botID, row.name)) }
            return true
        }
        let shelf = ShelfStore(dataRoot: dataRoot)
        func exactEntry() throws -> ShelfEntry? {
            do {
                let found = try shelf.entry(requestID)
                guard found.botId == botID else { throw StandingBotsError.corruptStore("bot result identity mismatch") }
                return found
            } catch StandingBotsError.notFound(let missing) where missing == requestID { return nil }
        }
        var entry = try exactEntry()
        if entry == nil {
            switch try BotRunQueue(dataRoot: dataRoot).presence(bot: botID, requestID: requestID) {
            case .queued, .running, .deadlineExceeded: return false
            case .absent:
                // Completion may have landed between the first shelf read and the queue/claim check. Reread after proving no live writer.
                entry = try exactEntry()
            }
        }
        // Only the queue owner's positive refusal proves no turn executed. Missing queue/shelf evidence cannot manufacture an interrupted run.
        if entry == nil {
            if let detail = try BotRunQueue(dataRoot: dataRoot).refusal(bot: botID, requestID: requestID) {
                let receipt: JSONValue = .object(["agent": .string(agent), "message_id": .string(requestID.uuidString),
                    "status": .string("refused"), "effects": .string("none"), "completed": .bool(false), "detail": .string(detail)])
                _ = try store.update(id: row.id, operationID: row.operationID) { $0.receipt = receipt }
                if askedByItself { try await finishBotRunOnOwnPage(row, botID: botID, requestID: requestID, receipt: receipt) }
                else { try await deliver(row, receipt: receipt, bot: (botID, row.name)) }
                return true
            }
            try attention(row, """
                This requested check has no queue, claim, result or refusal evidence. Its outcome is unavailable; repair the exact request evidence \
                before deciding what happened. No run was repeated.
                """)
            return true
        }
        var fields: [String: JSONValue] = ["agent": .string(agent), "message_id": .string(requestID.uuidString)]
        fields["read_with"] = .object(["action": .string("bot.reply"),
            "args": .object(["id": .string(requestID.uuidString), "bot_id": .string(botID.uuidString)])])
        guard let entry else { throw StandingBotsError.corruptStore("requested result was not saved") }
        fields["status"] = .string(entry.runtimeStatus.rawValue)
        fields["reply"] = .string(String(entry.actualReply.prefix(16000)))
        fields["reply_truncated"] = .bool(entry.actualReply.count > 16000)
        if let detail = entry.statusDetail { fields["detail"] = .string(detail) }
        if let approvalID = entry.approvalID { fields["approval_id"] = .string(approvalID) }
        fields["completed"] = .bool(entry.runtimeStatus == .completed)
        let artifacts = entry.artifacts ?? []
        let shown: [JSONValue] = artifacts.prefix(8).compactMap { artifact in
            guard artifact.name.utf8.count <= 512, artifact.path.utf8.count <= 2048 else { return nil }
            var reference: [String: JSONValue] = ["name": .string(artifact.name), "path": .string(artifact.path)]
            if let type = artifact.type, type.utf8.count <= 128 { reference["type"] = .string(type) }
            if let mime = artifact.mime, mime.utf8.count <= 256 { reference["mime"] = .string(mime) }
            if let size = artifact.byteSize { reference["byte_size"] = .int(Int64(size)) }
            return .object(reference)
        }
        if !shown.isEmpty { fields["artifacts"] = .array(shown) }
        if artifacts.count > shown.count { fields["artifacts_truncated"] = .int(Int64(artifacts.count - shown.count)) }
        // Preserve useful exact references even for unusually large Unicode replies; the complete answer remains with the shelf owner.
        if (try? JSONEncoder().encode(JSONValue.object(fields)).count) ?? Int.max > 90 * 1024 {
            if let reply = string(fields["reply"]) { fields["reply"] = .string(String(reply.prefix(4000))) }
            fields["reply_truncated"] = .bool(true)
        }
        let receipt = AgentConversationStore.cacheReceipt(.object(fields))
        _ = try store.update(id: row.id, operationID: row.operationID) { $0.receipt = receipt }
        if askedByItself { try await finishBotRunOnOwnPage(row, botID: botID, requestID: requestID, receipt: receipt) }
        else { try await deliver(row, receipt: receipt, bot: (botID, row.name)) }
        return true
    }

    /// Only refusals need a native receipt row; execution already wrote its reply. Deduplicate resumed writes by operation identity before settling delivery.
    private func finishBotRunOnOwnPage(_ row: AgentConversationRecord, botID: UUID, requestID: UUID,
                                     receipt: JSONValue) async throws {
        if case .object(let fields) = receipt, fields["status"] == .string("refused") {
            guard let detail = try BotRunQueue(dataRoot: dataRoot).refusal(bot: botID, requestID: requestID) else {
                throw StandingBotsError.corruptStore("Exact helper refusal unavailable: \(requestID)")
            }
            let name = row.name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let turn = TurnRequest(message: detail, sessionID: row.scopeSessionID, surface: row.sourceSurface,
                envelope: .native("bot.receipt"), pinnedRunID: "requested-result:agent-conversation:" + row.operationID).turn()
            try await clients.bridgeChatClient().appendAnswerForAskingChat(sessionID: row.scopeSessionID,
                text: name + ": refused · " + detail, attachments: [], surface: row.sourceSurface,
                deliveryID: "requested-result:agent-conversation:" + row.operationID, mechanicalRow: .botReceipt, turn: turn)
        }
        try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID)
    }

    /// Deliver saved outcomes through the existing claim, router and transcript owner without another model judgment.
    private func deliverBotResult(_ row: AgentConversationRecord, receipt: JSONValue,
                                  bot: (id: UUID, name: String)) async throws {
        guard case .object(let fields) = receipt,
              let request = string(fields["message_id"]), let requestID = UUID(uuidString: request) else {
            throw StandingBotsError.invalidValue("The requested result has no exact shelf entry.")
        }
        let status: String
        let refusal = try BotRunQueue(dataRoot: dataRoot).refusal(bot: bot.id, requestID: requestID)
        if refusal != nil { status = "refused" }
        else {
            let entry = try ShelfStore(dataRoot: dataRoot).entry(requestID)
            guard entry.botId == bot.id else { throw StandingBotsError.corruptStore("bot result identity mismatch") }
            status = entry.runtimeStatus.rawValue
        }
        let name = bot.name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let read: JSONValue = .object(["action": .string("bot.reply"), "args": .object([
            "id": .string(requestID.uuidString), "bot_id": .string(bot.id.uuidString)])])
        // This row is the app’s receipt; helper prose stays on its shelf under its own provenance.
        let detail: String
        if let refusal { detail = refusal }
        else { detail = try read.serialize(pretty: false) }
        let line = name + ": " + status + " · " + detail
        let deliveryID = "agent-conversation:" + row.operationID
        let digest = try await lifecycle.cachedRequestDigest(deliveryId: deliveryID)
            ?? SHA256.hash(data: try JSONEncoder().encode(receipt)).map { String(format: "%02x", $0) }.joined()
        let route = AgentBridgeCompletionRoute(asking: row, turnSessionId: row.scopeSessionID)
        let answered = try await answer(deliveryID, digest: digest, session: row.scopeSessionID,
            route: route, principal: row.agent, start: {
                _ = try store.update(id: row.id, operationID: row.operationID) {
                    $0.deliveryState = "delivering"; $0.receipt = receipt
                }
            }) { runID, _ in
                let turn = TurnRequest(message: line, sessionID: row.scopeSessionID, surface: row.sourceSurface,
                    envelope: .native("bot.receipt"), pinnedRunID: runID).turn()
                // The peer's asking-chat writer is idempotent by delivery ID. The result-delivery identity also lets the router attach its notification intent
                // to this actual row without a model turn.
                try await clients.bridgeChatClient().appendAnswerForAskingChat(sessionID: row.scopeSessionID,
                    text: line, attachments: [], surface: row.sourceSurface, deliveryID: "requested-result:" + deliveryID,
                    mechanicalRow: .botReceipt, turn: turn)
                ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                    id: "reply:" + row.operationID, line: line, thread: row.id, session: row.scopeSessionID)])
                // A bot receipt is written directly, never a turn, so it is never read by another.
                return .ran((ChatResponse(runId: runID, model: "native", output: line,
                    sessionId: row.scopeSessionID, providerCallCount: 0), turn))
            }
        let result: AgentBridgeCompletionDelivery?
        switch answered {
        case .delivered(let delivery, _), .settled(let delivery?): result = delivery
        case .settled(nil), .held:
            try attention(row, """
                Result delivery is already claimed or has an unknown outcome. Its saved result remains available; no helper run or delivery turn \
                was repeated.
                """, receipt: receipt)
            return
        }
        if let result, ["completed", "sent_unconfirmed"].contains(result.status) {
            try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID,
                             sentUnconfirmed: result.status == "sent_unconfirmed")
        } else {
            _ = try store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "waiting"; $0.deliveryState = "delivering"; $0.automaticRead = true
                $0.nextReadAt = Date().addingTimeInterval(30)
            }
        }
    }

    /// The waiting call showed this reply: its owed delivery is accepted, and the row stops delivering.
    private func settleShownInline(_ row: AgentConversationRecord) async throws {
        let deliveryID = "agent-conversation:" + row.operationID
        if let owed = try await lifecycle.reconciliationRows().first(where: {
            $0.id == deliveryID && ($0.status == "owed" || $0.status == "sent_unconfirmed")
        }) {
            try await lifecycle.recordDelivery(.init(status: "completed", surface: row.sourceSurface, delivery: "shown_inline",
                artifactCount: 0, attempts: 0, reason: "The waiting call showed the reply."), deliveryId: deliveryID, requestDigest: owed.digest)
        }
        _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
            guard $0.deliveryState == "delivering" || $0.automaticRead else { return }
            $0.deliveryState = "delivered"; $0.automaticRead = false; $0.nextReadAt = nil
        }
    }

    private func finish(_ row: AgentConversationRecord, delivered: Bool, runID: String?, sessionID: String, sentUnconfirmed: Bool = false) async throws {
        // Delivery of an earlier completion must not overwrite a conversation the agent has already advanced.
        _ = try? store.update(id: row.id, operationID: row.operationID) {
            $0.phase = delivered ? "ready" : "attention"
            $0.deliveryState = sentUnconfirmed ? "sent_unconfirmed" : delivered ? "delivered" : "attention"
            $0.deliveryRunID = runID; $0.automaticRead = false; $0.nextReadAt = nil
        }
        if delivered, let runID {
            try await SwiftNativeChatOrchestrationClient.settleReplyCheckpoint(dataRoot: dataRoot,
                sessionId: sessionID, runId: runID, verdict: sentUnconfirmed ? "sent_unconfirmed" : "completed")
        }
    }

    private func attention(_ row: AgentConversationRecord, _ detail: String, receipt: JSONValue? = nil) throws {
        _ = try store.update(id: row.id, operationID: row.operationID) {
            $0.phase = "attention"; $0.automaticRead = false; $0.nextReadAt = nil
            if let receipt { $0.receipt = AgentConversationStore.cacheReceipt(receipt) }
            if case .object(var fields)? = $0.receipt {
                fields["conversation_attention"] = .string(detail)
                $0.receipt = AgentConversationStore.cacheReceipt(.object(fields))
            } else { $0.receipt = .object(["status": .string("attention"), "detail": .string(detail)]) }
            $0.deliveryState = detail
        }
    }

    private func readReply(input: [String: JSONValue], row: AgentConversationRecord, peer: AgentPeerContact) async throws -> JSONValue {
        // Every page of this read bypasses conversation presentation before re-entering the ordinary tool gates.
        let tools = clients.bridgeToolDispatchClient(fileAccess: "read_only", verifiedSessionId: row.scopeSessionID,
            conversation: AgentConversationContext().internalRead)
        var turn = Turn(session: row.scopeSessionID)
        turn.verifiedSessionID = row.scopeSessionID
        turn.envelope = envelope(peer: peer, route: nil)
        // Reads re-enter the app action's gate with one operation shared by its pages.
        let invocation = ChatToolInvocation()
        let first = try await tools.dispatch(tool: "agent_read", input: input, surface: AgentBridgeSurface.id, turn: turn, invocation: invocation)
        guard peer.transport == .nativeAgent, case .object(var fields) = first,
              case .object(var evidence)? = fields["remote_evidence"],
              var body = string(fields["reply"]) else { return first }
        // Keep wire pagination below conversation presentation so the agent receives a complete reply.
        for _ in 0..<3 where evidence["has_more"] == .bool(true) {
            try Task.checkCancellation()
            guard let offset = evidence["next_offset"] else { break }
            var page = input; page["offset"] = offset
            let next = try await tools.dispatch(tool: "agent_read", input: page, surface: AgentBridgeSurface.id, turn: turn, invocation: invocation)
            guard case .object(let nextFields) = next,
                  nextFields["status"] == fields["status"],
                  let addition = string(nextFields["reply"]),
                  case .object(let nextEvidence)? = nextFields["remote_evidence"],
                  nextEvidence["next_offset"] != offset else { break }
            body += addition; evidence = nextEvidence
        }
        evidence["reply"] = nil // no duplicate body in the bounded cache
        fields["reply"] = .string(body); fields["remote_evidence"] = .object(evidence)
        return .object(fields)
    }

    private func envelope(peer: AgentPeerContact, route: ChatToolSessionContext.ReplyRoute?) -> TurnEnvelope {
        TurnEnvelope(surface: peer.elevationAllowed ? "chat" : AgentBridgeSurface.id, agent: "peer", verifiedUserId: peer.id,
            commandSignatureVerified: true, deliveryRoute: route, declaredRemote: !peer.elevationAllowed)
    }

    private func incomingText(_ receipt: JSONValue, peer: AgentPeerContact, label: String, retainedText: String? = nil) -> String {
        guard case .object(let fields) = receipt else { return "The contact's reply is unreadable." }
        let body = (retainedText ?? string(fields["reply"])).map(AgentBridgeSurface.quotingImpersonation)
        var message = AgentBridgeSurface.turnHeader(peerName: peer.name, elevated: peer.elevationAllowed)
            + AgentBridgeSurface.contactLines(name: peer.name, id: peer.id, conversation: label, answering: true)
        message += body ?? "The contact reported \(string(fields["status"]) ?? "an unknown outcome") without reply text."
        let remoteHasMore: Bool = if case .object(let evidence)? = fields["remote_evidence"] {
            evidence["has_more"] == .bool(true)
        } else { false }
        if remoteHasMore {
            message += "\n[Only the first part of this reply is available here. Read the remainder from this conversation before treating it as a full answer.]"
        }
        return message
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

private extension AgentConversationRecord {
    func receiptField(_ key: String) -> JSONValue? {
        guard case .object(let fields)? = receipt else { return nil }
        return fields[key]
    }
}
