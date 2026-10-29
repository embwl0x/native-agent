import BackgroundLoops
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import AgentWorkspace
import AgentConversations
import AgentLinkTransport
import Cognition
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

// Blueprint: | `AgentConversationContinuation.swift` | `AgentConversationContinuation`: durable reply reads, queued follow-ups and completion delivery through the existing delegation lifecycle; a collected answer is offered atomically to an inline send waiter before starting a delayed turn; requested helper outcomes return as one native receipt through the peer reply writer/router and arrival signal, without another model turn |

/// Delayed remote replies belong to the existing delegation runner's lifecycle.
/// This is a reader, never a message retry queue. Callback-owned contacts do not
/// enter this lane. Stored routing references confer no execution authority.
public struct AgentConversationContinuation: Sendable {
    let dataRoot: URL
    let clients: any AgentContactClients
    let grok: GrokInboundReply
    private let dot: ChatGPTDotConversation
    let completionSender: any AgentBridgeCompletionSending
    /// Set once this root has resumed the queues and hand-overs a restart left.
    private let queuesResumed = OSAllocatedUnfairLock(initialState: false)
    private let pushOwner = UUID()

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
        guard let rows = try? store.records() else { return now.addingTimeInterval(60) }
        // Once per launch: queued follow-ups a restart left without a sender.
        // (and Grok Bot answers saved but not yet handed to her as a turn).
        if !queuesResumed.withLock({ $0 }) { return now.addingTimeInterval(1) }
        let dotAgents = Set(((try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []).filter { $0.ability == nil && ChatGPTDotIPCTransport.owns($0) }.map { "peer:" + $0.id })
        let ordinary = rows.filter { !dotAgents.contains($0.agent) && ($0.notice != nil || $0.automaticRead && ($0.phase == "waiting" || $0.deliveryState == "delivering")) }
            .map { max($0.nextReadAt ?? now, now.addingTimeInterval(1)) }.min()
        return [ordinary, AgentLocalHealth.nextRefresh(dataRoot, now: now), ResidentWake.shared.nextDeadline(dataRoot: dataRoot)]
            .compactMap { $0 }.min()
    }

    /// Each queued message goes through the same gated chain as the person's
    /// own thread send, below the conversation layer (which `resume` owns),
    /// for that thread's chat. No approval filer: a send Trust would card is
    /// refused and the message is held with the reason.
    private func resumeQueues() async throws {
        try Task.checkCancellation()
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
            // Push proof belongs to this process, not the saved deadline. Read
            // waiting tasks once at startup after registering for pushes, so a
            // terminal callback missed while closed cannot leave them suspended.
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
        guard queuesResumed.withLock({ value in defer { value = true }; return !value }) else { return }
        ResidentWake.shared.turnEnded(dataRoot: dataRoot)
        // Every agent row below reads its recipe: seeded and loaded first.
        AgentRecipeStore.load(dataRoot: dataRoot)
        grok.resumeHandOvers(dataRoot: dataRoot, continuation: self)
        // Dot's room is pushed to her from here on; nothing pulls it.
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        // A Dot contact moved to one of her abilities keeps its exchanges like any contact.
        let dotAgents = Set(peers.filter { $0.ability == nil && ChatGPTDotIPCTransport.owns($0) }.map { "peer:" + $0.id })
        _ = try? store.dropUnsettleable(dot: dotAgents, saved: Set(peers.map { "peer:" + $0.id }))
        Task { await importContactHistory(peers: peers) }
        for row in AgentConversationSession.orphanedQueues(dataRoot: dataRoot) {
            if dotAgents.contains(row.agent) { continue } // Retired queued Dot sends are never replayed.
            let session = row.scopeSessionID, surface = row.sourceSurface
            let tools = clients.toolDispatchClient(enforceAppAutonomy: false)
            let chain = makeGatedToolDispatchClient(tools: tools, fileAccess: "auto", dataRoot: dataRoot, verifiedSessionId: session)
            AgentConversationSession.resumeQueued(row, dataRoot: dataRoot) { tool, input in
                try await ChatToolSessionContext.$verifiedSessionId.withValue(session) {
                    try await AgentConversationContext.$isInternalRead.withValue(true) {
                        try await chain.dispatch(tool: tool, input: input, surface: surface)
                    }
                }
            }
        }
    }

    public func stop() async {
        await settle {
            await AgentConversationWatches.stop()
            await grok.stop()
            await AgentA2APushReceiver.shared.removeInvalidator(owner: pushOwner)
            await dot.stopSubscriptions()
            await ChatGPTDotIPCTransport.stop()
            await AgentDiscoverySession.shared.stop()
            await AgentConversationLiveHub.shared.shutdown()
        }
    }

    /// Once (10-01): what a contact's pane showed from its records and, for a
    /// built-in lane, the live file, copied into the contact's own session so
    /// reading the pane from there loses none of it, at its own time and with
    /// its send id. Marked done once every session took it; the import never
    /// adds a row twice. Dot's history is his session already.
    private func importContactHistory(peers: [AgentPeerContact]) async {
        let marker = dataRoot.appendingPathComponent("agents/contact-history-imported.json")
        guard !FileManager.default.fileExists(atPath: marker.path), let records = try? store.records() else { return }
        let lanes = ["codex", "claude", "omp"]
        let dots = Set(peers.filter(ChatGPTDotIPCTransport.owns).map(\.id))
        var rows: [String: [JSONValue]] = [:]
        for owner in peers.map(\.id) + lanes { rows[owner] = [] }
        // Words a record or live file kept, never a transport's turn: imported
        // unattested (another agent's to every reader), never stamped with the
        // owner's identity. The owner only places them in its conversation.
        func reply(_ owner: String, name: String, text: String, id: String, key: String, at: Date) -> JSONValue {
            let lane = lanes.contains(owner)
            let surface = lane ? BridgeLane.bridgeSurfaceName(forSender: owner) : AgentBridgeSurface.id
            return .object(["id": .string(id), "sessionId": .string(ContactThread.session(owner: owner)), "role": .string("user"),
                "content": .string(AgentContacts.savedReply(owner: owner, name: name, text: text)),
                "createdAt": .string(NativeTimestampFormat.fractionalZulu(at)), "source": .string(lane ? "app" : surface),
                "metadata": .object(["origin": .object(["surface": .string(surface), "agent": .string(lane ? owner : "agent"),
                                                        "replyTo": .string(key)]),
                                     "envelope": .object(["surface": .string(surface)]), "unattested": .bool(true)])])
        }
        for record in records {
            let owner = record.agent.hasPrefix("peer:") ? String(record.agent.dropFirst(5)) : record.agent
            guard rows[owner] != nil, !dots.contains(owner) else { continue }
            for exchange in record.exchanges ?? [] {
                if let prompt = exchange.prompt, !prompt.isEmpty {
                    var metadata: [String: JSONValue] = ["dotClientUserMessageID": .string(exchange.id)]
                    if exchange.byPerson == true { metadata["byPerson"] = .bool(true) }
                    rows[owner]?.append(.object(["id": .string(exchange.id + "-sent"),
                        "sessionId": .string(ContactThread.session(owner: owner)), "role": .string("assistant"),
                        "content": .string(prompt), "createdAt": .string(NativeTimestampFormat.fractionalZulu(exchange.sentAt)),
                        "source": .string("agent-bridge"), "metadata": .object(metadata)]))
                }
                if let text = exchange.reply, !text.isEmpty {
                    rows[owner]?.append(reply(owner, name: record.name, text: text, id: exchange.id + "-reply",
                        key: "agent-conversation:" + exchange.id, at: exchange.settledAt ?? exchange.sentAt.addingTimeInterval(0.001)))
                }
            }
        }
        // A built-in lane's answers the records missed; the live copy is the
        // newest part of a reply, so one a record kept is not taken twice.
        for entry in AgentConversationLiveStore(dataRoot: dataRoot).all().values
            where entry.recordID == nil && entry.state == "finished" && lanes.contains(entry.agent) {
            guard let text = entry.partial?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let kept = records.filter { $0.agent == entry.agent }.flatMap { $0.exchanges ?? [] }
                .compactMap { $0.reply?.trimmingCharacters(in: .whitespacesAndNewlines) }
            if kept.contains(where: { $0.hasSuffix(text) || text.hasSuffix($0) }) { continue }
            rows[entry.agent]?.append(reply(entry.agent, name: entry.agent, text: text, id: UUID().uuidString.lowercased(),
                key: "agent-live:" + entry.key, at: entry.finishedAt ?? entry.lastActivityAt))
        }
        var complete = true
        for (owner, list) in rows {
            let session = ContactThread.session(owner: owner)
            guard !list.isEmpty || FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("chat/messages/\(session).jsonl").path) else { continue }
            do { _ = try await clients.bridgeChatClient().importAgentConversationHistory(sessionID: session, rows: list) }
            catch {
                complete = false
                nativeLog("AgentConversationContinuation: history for \(owner) not imported: \(error)")
            }
        }
        if complete { try? await SwiftNativePersistenceCore.writeJSON(.string(NativeTimestampFormat.fractionalZulu(Date())), to: marker) }
    }

    public func reconcileReplies() async throws {
        let configRoot = InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let lifecycle = CodexCompletionLifecycle(receiptURL: configRoot.appendingPathComponent("claude-bridge/message-replies.jsonl"), dataRoot: dataRoot)
        let human = CodexCompletionLifecycle(receiptURL: dataRoot.appendingPathComponent("chat/human-reply-delivery/receipts.jsonl"), dataRoot: dataRoot)
        var firstError: Error?
        // Each independent reply owner gets its recovery pass before a fault is reported.
        for owner in [lifecycle, human, self.lifecycle] {
            do {
                _ = try await owner.reconcileInterruptedClaims()
                if owner.receiptURL == lifecycle.receiptURL {
                    try await ClaudeBridgeMessageRuntime.recoverMessageReplies(lifecycle: owner,
                        logURL: owner.receiptURL)
                }
                try await owner.reconcileSavedDeliveries(configRoot: configRoot, sender: completionSender,
                    client: clients.bridgeChatClient(), notifyRequestedResult: owner.receiptURL != human.receiptURL)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if firstError == nil { firstError = error }
                nativeLog("Reply recovery for %@ failed: %@", owner.receiptURL.path, error.localizedDescription)
            }
        }
        let owed = Set(try await self.lifecycle.reconciliationRows().filter { $0.status == "owed" || $0.status == "sent_unconfirmed" }.map(\.id))
        for row in try store.records() where row.phase == "attention" && row.receipt != nil
            && owed.contains("agent-conversation:" + row.operationID) {
            _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                $0.deliveryState = "delivering"; $0.automaticRead = true; $0.nextReadAt = Date()
            }
        }
        if let firstError { throw firstError }
    }

    public func tick() async throws {
        try await resumeQueues()
        Task.detached(priority: .utility) { await AgentContactHealth.shared.refresh(dataRoot: dataRoot) }
        // Her wake is this tick's one full turn; the reads wait a second.
        if try await wakeHer() { return }
        let now = Date()
        let dotAgents = Set(try AgentPeerStore(dataRoot: dataRoot).list().filter { $0.ability == nil && ChatGPTDotIPCTransport.owns($0) }.map { "peer:" + $0.id })
        let due = try store.records().filter {
            !dotAgents.contains($0.agent) && ($0.notice != nil || $0.automaticRead && ($0.phase == "waiting" || $0.deliveryState == "delivering"))
                && ($0.nextReadAt ?? .distantPast) <= now
        }.sorted { ($0.nextReadAt ?? .distantPast) < ($1.nextReadAt ?? .distantPast) }
        // At most three reads and one full resident turn per owned tick.
        for row in due.prefix(3) {
            try Task.checkCancellation()
            // A delegate's stall or bad outcome: her turn in the chat it came from.
            // It never marks the thread; a failure to start is retried shortly.
            if let notice = row.notice {
                do {
                    try await deliver(row, receipt: .object(["event": .string(notice.event), "text": .string(notice.text)]),
                                      notice: notice)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    _ = try? store.update(id: row.id, operationID: row.operationID, touch: false) {
                        $0.nextReadAt = Date().addingTimeInterval(60)
                    }
                }
                return
            }
            let pushDriven: Bool
            if row.agent.hasPrefix("peer:"), let task = string(row.readInput?["task_id"] ?? row.receiptField("task_id")) {
                pushDriven = await AgentA2APushReceiver.shared.hasReceived(peerID: String(row.agent.dropFirst(5)), taskID: task)
                try Task.checkCancellation()
            } else { pushDriven = false }
            let readingUntil = Date().addingTimeInterval(30)
            do {
                if row.agent.hasPrefix("bot-run:") {
                    if try await handleBotRun(row) { return }
                    continue
                }
                guard let peer = try AgentPeerStore(dataRoot: dataRoot).list().first(where: {
                    "peer:" + $0.id == row.agent
                }), [.nativeAgent, .a2a].contains(peer.transport)
                    // A queued follow-up's answer from any contact is handed over the same way.
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
                    return
                }
                guard var input = row.readInput, input["agent"] == .string(row.agent) else {
                    try attention(row, "The saved reply reference is incomplete; the message has not been sent again.")
                    continue
                }
                input["details"] = .bool(true)
                if peer.transport == .nativeAgent { input["max_chars"] = .int(16000) }
                let tools = clients.bridgeToolDispatchClient(
                    fileAccess: "read_only", verifiedSessionId: row.scopeSessionID)
                let read = try await readReply(input: input, tools: tools, row: row, peer: peer)
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
                let taskSnapshot = fields["terminal"] == .bool(true) || fields["terminal"] == .bool(false)
                _ = try store.update(id: row.id, operationID: row.operationID) {
                    $0.receipt = cached
                    if $0.conversationID == nil, let conversation = string(fields["conversation_id"]) {
                        $0.conversationID = conversation
                    }
                    if fields["needs_input"] == .bool(true), let task = fields["task_id"] {
                        $0.readInput?["task_id"] = task
                    }
                    if $0.nextReadAt == readingUntil {
                        // A proven webhook replaces sampling only after a
                        // validated task read. Unavailable or invalid reads keep
                        // their short deadline; an ended stream without push
                        // also keeps the existing task reads.
                        $0.nextReadAt = pushDriven && taskSnapshot
                            ? (row.operationStartedAt ?? row.updatedAt).addingTimeInterval(24 * 60 * 60)
                            : Date().addingTimeInterval(Date().timeIntervalSince(row.operationStartedAt ?? row.updatedAt) > 300 ? 60 : 15)
                    }
                }
                if settled, row.personInitiated == true {
                    // The person's own send: its answer settles in the thread, no agent turn.
                    try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID)
                    continue
                }
                if settled {
                    try await deliver(row, receipt: cached, peer: peer)
                    return
                }
                if Date().timeIntervalSince(row.operationStartedAt ?? row.updatedAt) > 24 * 60 * 60 {
                    try attention(row, "The contact has not supplied a finished reply. Its original message remains available; it was not sent again.", receipt: cached)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Read failure is safe to retry; a delivery failure is not.
                // The lifecycle below records ambiguity before this boundary.
                if Date().timeIntervalSince(row.operationStartedAt ?? row.updatedAt) > 24 * 60 * 60 {
                    try? attention(row, "The contact's reply could not be recovered within a day. The original message has not been repeated.")
                } else {
                    _ = try? store.update(id: row.id, operationID: row.operationID) {
                        if $0.nextReadAt == readingUntil || $0.nextReadAt == row.nextReadAt {
                            $0.nextReadAt = Date().addingTimeInterval(60)
                        }
                    }
                }
            }
        }
    }

    /// Her one wake for what resolved (ResidentWake): only while no turn of
    /// hers runs, in her own conversation. A promise's reply returns to the
    /// conversation it was made in. It quotes an agent's words only with
    /// that agent's authority; otherwise it
    /// is hers. At most once: a turn that fails is not rerun.
    private func wakeHer() async throws -> Bool {
        let now = Date()
        guard ResidentWake.shared.arrivalsDue(dataRoot: dataRoot).map({ $0 <= now }) == true else { return false }
        // The person's quiet hours hold what reaches him, not her work (User 10-12).
        let nextFreeAt: @Sendable (Date, Date) -> Date? = { now, activity in
            let due = activity.addingTimeInterval(StudioWanderLane.quietInterval)
            return due > now ? due : nil
        }
        guard await ChatTurnSteering.shared.residentWakeIsFree(dataRoot: dataRoot, nextFreeAt: nextFreeAt) else { return false }
        var items = ResidentWake.pendingItems(dataRoot: dataRoot, now: now)
        let pending = items.filter { $0.key?.hasPrefix("carry.") == true }
        var carriedItems: [String: DeskItem] = [:]
        let deskRevision = SwiftNativeDeskStore.currentRevision
        if !pending.isEmpty {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            let context = HerScreen.queueContext(dataRoot: dataRoot, now: now, ownTurn: true)
            let ready = MyQueueReady.ready(items: state.items, context: context, dataRoot: dataRoot)
            for arrival in pending {
                guard let key = arrival.key else { continue }
                let handle = String(key.dropFirst(6))
                guard let item = ready.first(where: { $0.handle == handle }),
                      item.step?.session == arrival.session,
                      arrival.filedAt == nil || arrival.filedAt == (item.step?.filedAt ?? item.openedAt) else {
                    ResidentWake.shared.withdraw(dataRoot: dataRoot, key: key)
                    items.removeAll { $0.id == arrival.id }
                    continue
                }
                carriedItems[handle] = item
                if let index = items.firstIndex(where: { $0.id == arrival.id }) {
                    // What this offer says is the item as it is now: that is what a later change is measured from.
                    let offered = ResidentWake.carriedArrival(item, crossing: arrival.at)
                    items[index].line = offered.line
                    items[index].materialFingerprint = offered.materialFingerprint
                    items[index].at = now
                }
            }
        }
        guard !items.isEmpty else { return false }
        let session = ResidentWake.session
        let carried = items.first { $0.key?.hasPrefix("carry.") == true }
        // Carried work has one external slot; other arrivals may share its wake.
        items.removeAll { $0.key?.hasPrefix("carry.") == true && $0.id != carried?.id }
        var route: AgentBridgeCompletionRoute?
        if let key = carried?.key, let item = carriedItems[String(key.dropFirst(6))], item.step?.owedToPerson(dataRoot: dataRoot) == true {
            let revision = (try? ResidentWake.routeRevision(rows: HumanConversationIndex.rows(dataRoot: dataRoot), session: item.step?.session)) ?? .null
            do {
                guard let id = item.step?.session, NativeAgentChatSessionID.normalizedPathComponent(id) == id else {
                    throw StandingBotsError.invalidValue("The promise has no recorded conversation to reply to.")
                }
                if item.step?.replyRoute == nil, let ref = item.refs.last(where: {
                    if case .step = $0.kind { return true }; return false
                }) {
                    var originating: TurnEnvelope?
                    // Creation predates condition refreshes; a later message cannot move the promise's door.
                    if let before = DeskClock.parseISO(item.openedAt) {
                        do { originating = try await HumanConversationReader.read(sessionID: id, dataRoot: dataRoot, replyBefore: before).route }
                        catch is CancellationError { throw CancellationError() }
                        catch { nativeLog("Legacy promise route could not be proven: %@", error.localizedDescription) }
                    }
                    let repaired = HumanConversationReader.routeAvailable(originating) ? originating! : TurnEnvelope(surface: "chat")
                    try await SwiftNativeDeskStore(dataRoot: dataRoot).updateRef(item.handle, refId: ref.refId,
                        cachedFields: ["replyRoute": repaired.persistedMetadata()])
                    // The Desk write signals another admission with fresh readiness and provenance.
                    return false
                }
                guard let envelope = TurnEnvelope.fromPersistedMetadata(item.step?.replyRoute),
                      HumanConversationReader.routeAvailable(envelope) else {
                    throw StandingBotsError.invalidValue("The promise's recorded reply route is unavailable. Restore that route before replying.")
                }
                let saved = envelope.replyRoute
                route = AgentBridgeCompletionRoute(surface: saved.surface, sessionId: id,
                    destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
                    replyTo: saved.replyTo, correlationId: saved.correlationId, turnSessionId: session,
                    requesterUserId: saved.requesterUserId)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let reason: String
                switch error {
                case StandingBotsError.invalidValue(let detail): reason = detail
                default: reason = error.localizedDescription
                }
                let marker = "Waiting to return this promise: "
                try await SwiftNativeDeskStore(dataRoot: dataRoot).appendNoteIfAbsent(item.handle,
                    marker: marker + reason, text: marker + reason)
                try ResidentWake.shared.waitForRoute(dataRoot: dataRoot, key: key, revision: revision)
                return false
            }
        }
        do {
            try await ResidentWake.openSession(dataRoot: dataRoot)
            let (context, agents) = await Self.wakeMessage("",
                agents: Array(Set(items.compactMap(\.agent))).sorted(), items: items, dataRoot: dataRoot)
            let execution: (response: ChatResponse, items: [ResidentWake.Item], completion: CodexCompletionTranscriptBinding?)? = try await TurnAdmission.shared.run(sessionID: session) {
                    guard let wake = await ChatTurnSteering.shared.claimResidentWake(dataRoot: dataRoot, items: items,
                        deskRevision: deskRevision, nextFreeAt: nextFreeAt) else { return nil }
                    let admitted = wake.items.first { $0.key?.hasPrefix("carry.") == true }
                    let step = admitted?.key.flatMap { carriedItems[String($0.dropFirst(6))]?.step }
                    let taint = PeerDataTaint(restoring: step?.peers ?? [], elevated: step?.elevated ?? [])
                    if let step { taint.keep(line: step.words) }
                    for agent in agents { taint.mark(peer: agent) }
                    let reply = admitted == nil ? nil : route
                    let completion = reply.flatMap { _ in admitted }.map { arrival in
                        let id = "carried-reply:" + arrival.id
                        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
                        return CodexCompletionTranscriptBinding(deliveryId: id, requestDigest: digest, model: "", reasoningEffort: nil)
                    }
                    let responseRunID = completion.map { CausalTransitionEvidence.opaqueIdentity($0.deliveryId) }
                    if let completion, let responseRunID {
                        guard try await lifecycle.claim(deliveryId: completion.deliveryId, requestDigest: completion.requestDigest,
                            sessionId: session, responseRunId: responseRunID, route: reply, principal: "self", source: session) == .start else {
                            throw StandingBotsError.invalidValue("This carried reply already has a recorded attempt; it was not sent again.")
                        }
                    }
                    var text = wake.text + context
                    if reply != nil { text += "\nYour reply will return to the conversation this promise was made in. Say what you did or why it waits." }
                    let agent = "self"
                    var origin = ChatMessageOrigin(surface: session, agent: agent, authored: .agent)
                    origin.peerSources = taint.checkpointSources
                    origin.elevatedPeerSources = taint.elevatedSources
                    let request = TurnRequest(message: text, sessionID: session, surface: "chat",
                        envelope: TurnEnvelope(surface: "chat", agent: agent, deliveryRoute: reply?.chatToolReplyRoute,
                            declaredRemote: false, workIdentity: admitted?.key),
                        verifiedSessionID: session, replyRoute: reply?.chatToolReplyRoute,
                        origin: origin, pinnedRunID: responseRunID, codexCompletion: completion, threadKind: .builder)
                    do {
                        let response = try await PeerDataTaint.$current.withValue(taint) {
                            try await request.chat(on: clients.bridgeChatClient())
                        }
                        if let completion {
                            try await lifecycle.cacheResponse(response, deliveryId: completion.deliveryId, requestDigest: completion.requestDigest)
                        }
                        return (response, wake.items, completion)
                    } catch {
                        if let completion {
                            try await lifecycle.markOutcomeUnknown(deliveryId: completion.deliveryId, requestDigest: completion.requestDigest,
                                detail: "Resident continuation interrupted; never rerun automatically")
                        }
                        throw error
                    }
            }
            guard let execution else { return false }
            let response = execution.response
            if let route, let completion = execution.completion {
                let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
                let result = await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: completion.deliveryId, requestDigest: completion.requestDigest,
                    text: answer, attachments: response.attachments ?? [], route: route, client: clients.bridgeChatClient(),
                    sender: completionSender, lifecycle: lifecycle)
                if result.status != "completed" {
                    throw StandingBotsError.invalidValue("Carried reply delivery is not confirmed: " + (result.reason ?? result.status))
                }
            }
            // Phase 5 E1: a reach wakes alone; her answer is the message, or "pass".
            if let reach = execution.items.first(where: \.isReach) {
                await clients.deliverReach(
                    reply: ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters),
                    itemID: reach.id, turnID: response.runId)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            FileHandle.standardError.write(Data("AgentConversationContinuation: resident wake did not finish; not rerun: \(error.localizedDescription)\n".utf8))
        }
        return true
    }

    /// The wake's words: a step another conversation is working stays theirs
    /// (desk.3402), so preparation reads who holds each one; and the
    /// conversation it came from, as the chat page reads
    /// it, its latest turns. Quoting those records never steers the wake.
    static func wakeMessage(_ text: String, agents: [String], items: [ResidentWake.Item],
                            dataRoot: URL) async -> (text: String, agents: [String]) {
        let session = ResidentWake.session
        var text = text
        for item in items {
            guard let key = item.key, key.hasPrefix("queue:") || key.hasPrefix("carry."),
                  let by = try? await SwiftNativeDeskStore(dataRoot: dataRoot).heldBy(
                    String(key.dropFirst(6)), session: session) else { continue }
            text += "\n• Held: \(item.line.prefix(80)) is held by \(by), which is working it. Leave it to that one."
        }
        var sources: [String] = []
        for id in items.compactMap(\.session) where id != session && !sources.contains(id) { sources.append(id) }
        // Whose words it quotes: each quoted row's own stamp, read through the
        // one per-line path (never the session's owner).
        for id in sources.prefix(2) {
            guard let read = try? await HumanConversationReader.read(sessionID: id, dataRoot: dataRoot), read.complete,
                  !read.messages.isEmpty else { continue }
            let recent = ContactThread.project(read.messages.suffix(8).map {
                ContactThread.Line(($0.extras?.objectValue ?? [:]), role: $0.role, text: $0.content, timestamp: $0.timestamp)
            }, mark: { PeerDataTaint.markConsumed(peer: $0, line: $1) })
            text += "\n\n[Context: the latest turns of \"\(read.title)\" (\(id)), the conversation "
                + "this came from; records, not a request]\n"
                + recent.map { $0.role + ": " + String($0.text.prefix(600)) }.joined(separator: "\n")
        }
        // Newly quoted context is separate from the step's restored steer.
        return (text, agents.filter { !PeerTrust.ownerTrusts($0, dataRoot: dataRoot) })
    }

    private func deliver(_ row: AgentConversationRecord, receipt: JSONValue, peer: AgentPeerContact? = nil,
                         bot: (id: UUID, name: String)? = nil, notice: AgentConversationNotice? = nil) async throws {
        // A waiter on this send takes the answer first, whoever sent it; a
        // helper's outcome then returns as its own receipt, not a model turn.
        if notice == nil, try store.offerReplyToInlineWait(row, receipt: receipt) { return }
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
        // A contact's reply wakes her in the contact's own session, as Dot's does
        // (User 10-01); her answer still reaches the chat and door that asked.
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
            // It carries the delegate's own output, so it arrives with exactly
            // the delegate's authority: the tag its own reply gets on its bridge
            // lane (agent-authored), never the person's. The envelope names the
            // lane too, so no person-only gate reads it as the person.
            turnSurface = "chat"
            turnEnvelope = TurnEnvelope(surface: turnSurface, agent: row.agent,
                verifiedUserId: peer?.id,
                deliveryRoute: route.chatToolReplyRoute, declaredRemote: false)
            origin = ChatMessageOrigin(surface: BridgeLane.bridgeSurfaceName(forSender: row.agent), agent: row.agent,
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
                // The turn puts it in her hands: the glance and arrivals don't repeat it.
                _ = try store.update(id: row.id, operationID: row.operationID, touch: notice == nil) {
                    if notice == nil { $0.phase = "ready"; $0.deliveryState = "delivering"; $0.receipt = receipt }
                    $0.shownInline = $0.operationID + ":" + $0.phase
                }
            }) { runID, binding in
                let client = clients.bridgeChatClient()
                // Consume the saved reply's run: no second row, and history
                // excludes that same run while its full text starts this turn.
                let request = TurnRequest(message: incoming, sessionID: session, surface: turnSurface,
                    suppressUserAppend: retainedReply != nil,
                    envelope: turnEnvelope, verifiedSessionID: session, replyRoute: route.chatToolReplyRoute,
                    origin: origin, pinnedRunID: runID, codexCompletion: binding, threadKind: .agent,
                    ownedSessionID: peer.map { ContactThread.session(owner: $0.id) })
                let response = try await TurnAdmission.shared.run(sessionID: session, runID: runID, waitForCapacity: true) {
                    try await request.chat(on: client)
                }
                if notice == nil { _ = try? store.update(id: row.id, operationID: row.operationID) { $0.deliveryRunID = response.runId } }
                return response
            }
        } catch is TurnAdmission.Full {
            if notice != nil {
                // Not started: not in her hands yet either.
                _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
                    if $0.shownInline == $0.operationID + ":" + $0.phase { $0.shownInline = nil }
                    $0.nextReadAt = Date().addingTimeInterval(30)
                }
                return
            }
            _ = try store.update(id: row.id, operationID: row.operationID) {
                $0.phase = "waiting"
                // Retry admission using this exact frozen reply/digest;
                // rereading the peer could change the claimed payload.
                $0.deliveryState = "delivering"
                $0.automaticRead = true
                $0.nextReadAt = Date().addingTimeInterval(30)
            }
            return
        } catch {
            if let notice {
                // At most once: never rerun. Said in the log, and the thread
                // is not marked as in her hands.
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
            try await finish(row, delivered: result?.status == "completed" || result?.status == "sent_unconfirmed", runID: row.deliveryRunID, sessionID: session,
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
    /// Thrown by a turn that found, under admission, that it is no longer owed.
    struct NotStarted: Error {}

    /// One answer to the door that asked, once: claimed in the contacts' ledger,
    /// her turn run (`run`, under its own admission) and cached, then delivered
    /// after admission is released. Every contact's reply and Grok's hand-over.
    func answer(_ deliveryID: String, digest: String, session: String, route: AgentBridgeCompletionRoute, principal: String,
                runID: String? = nil, notify: Bool = true, start: () throws -> Void = {},
                run: (_ runID: String, _ binding: CodexCompletionTranscriptBinding) async throws -> ChatTurnRuntime.ChatResponse)
        async throws -> Answered {
        let runID = runID ?? CausalTransitionEvidence.opaqueIdentity(deliveryID)
        let response: ChatTurnRuntime.ChatResponse
        switch try await lifecycle.claim(deliveryId: deliveryID, requestDigest: digest, sessionId: session, responseRunId: runID,
                                        route: route, principal: principal, source: principal) {
        case .cached(let cached): response = cached
        case .settled(let result): return .settled(result)
        case .inProgress, .outcomeUnknown, .conflict: return .held
        case .start:
            try start()
            do {
                response = try await run(runID, CodexCompletionTranscriptBinding(deliveryId: deliveryID, requestDigest: digest,
                    model: "", reasoningEffort: nil, isTerminalCompletion: notify))
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
            } catch let error where error is TurnAdmission.Full || error is NotStarted {
                try await lifecycle.markNotStarted(deliveryId: deliveryID, requestDigest: digest)
                throw error
            } catch {
                try? await lifecycle.markOutcomeUnknown(deliveryId: deliveryID, requestDigest: digest,
                    detail: "Resident continuation interrupted; never rerun automatically")
                throw error
            }
        }
        return .delivered(await AgentBridgeCompletionRouter.deliverAnswer(deliveryId: deliveryID, requestDigest: digest,
            text: ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters),
            attachments: response.attachments ?? [], route: route, client: clients.bridgeChatClient(),
            sender: completionSender, lifecycle: lifecycle, notifyRequestedResult: notify), runID: response.runId)
    }

    /// The event is hers now: clear it, leaving the thread's own state (a
    /// stalled send is still owed its answer) as it is.
    private func told(_ row: AgentConversationRecord, _ notice: AgentConversationNotice, handed: Bool = true) throws {
        _ = try store.update(id: row.id, operationID: row.operationID, touch: false) {
            if $0.notice == notice { $0.notice = nil }
            if !handed, $0.shownInline == $0.operationID + ":" + $0.phase { $0.shownInline = nil }
            $0.nextReadAt = nil
        }
    }

    /// Only explicitly requested runs have bookmarks. Scheduled bot history is
    /// never scanned or turned into unsolicited Agent turns.
    private func handleBotRun(_ row: AgentConversationRecord) async throws -> Bool {
        guard NativeAgentChatSessionID.normalizedPathComponent(row.scopeSessionID) != nil,
              let input = row.readInput, let agent = string(input["agent"]), agent.hasPrefix("bot:"),
              let botID = UUID(uuidString: String(agent.dropFirst(4))),
              row.agent == "bot-run:" + botID.uuidString,
              let request = string(input["message_id"]), let requestID = UUID(uuidString: request) else {
            try attention(row, "This requested check has lost its exact return reference. No run was repeated.")
            return false
        }
        _ = try store.update(id: row.id, operationID: row.operationID) { $0.nextReadAt = Date().addingTimeInterval(30) }
        // Asked from the helper's own conversation (Run once on its page): its
        // result is already its own reply there, so it settles with no agent
        // turn — her turn never runs inside a helper's session (10-24: she
        // answered inside a helper's session and the helper then remembered it as its own).
        let askedByItself = row.scopeSessionID.lowercased() == "bot-" + botID.uuidString.lowercased()
        if row.deliveryState == "delivering", let receipt = row.receipt {
            if askedByItself { try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID) }
            else { try await deliver(row, receipt: receipt, bot: (botID, row.name)) }
            return true
        }
        let shelf = ShelfStore(dataRoot: dataRoot)
        func exactEntry() throws -> ShelfEntry? {
            do {
                let found = try shelf.entry(requestID)
                guard found.botId == botID else { throw StandingBotsError.corruptStore("bot result identity mismatch") }
                return shelf.reconciling([found]).first ?? found
            } catch StandingBotsError.notFound(let missing) where missing == requestID { return nil }
        }
        var entry = try exactEntry()
        if entry == nil {
            switch try BotRunQueue(dataRoot: dataRoot).presence(bot: botID, requestID: requestID) {
            case .queued, .running, .deadlineExceeded: return false
            case .absent:
                // Completion may have landed between the first shelf read and
                // the queue/claim check. Reread after proving no live writer.
                entry = try exactEntry()
            }
        }
        // A request rejected before its turn (or lost on restart) still owes
        // an exact saved outcome. Never repeat the helper to obtain one.
        if entry == nil {
            let bot = try BotDefinitionStore(dataRoot: dataRoot).get(botID)
            let at = row.operationStartedAt ?? row.updatedAt
            let detail = "This requested check is no longer queued or running and saved no result. It was interrupted or rejected; its effects are unknown. No run was repeated."
            var interrupted = ShelfEntry(id: requestID, botId: botID, briefVersion: bot.briefVersion,
                runAt: at, coverageStart: at, coverageEnd: at, headline: "Requested check interrupted",
                findings: "", changedSinceLastGood: "", uncertainties: [detail], runHealth: .partial,
                spend: ShelfSpend(tokens: nil, seconds: 0))
            interrupted.status = .interrupted
            interrupted.statusDetail = detail
            interrupted.sessionID = bot.sessionID
            do { try shelf.append(interrupted) }
            catch StandingBotsError.alreadyExists { }
            entry = try exactEntry()
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
        // Preserve useful exact references even for unusually large Unicode
        // replies; the complete answer remains with the shelf owner.
        if (try? JSONEncoder().encode(JSONValue.object(fields)).count) ?? Int.max > 90 * 1024 {
            if let reply = string(fields["reply"]) { fields["reply"] = .string(String(reply.prefix(4000))) }
            fields["reply_truncated"] = .bool(true)
        }
        let receipt = AgentConversationStore.cacheReceipt(.object(fields))
        _ = try store.update(id: row.id, operationID: row.operationID) { $0.receipt = receipt }
        if askedByItself { try await finish(row, delivered: true, runID: nil, sessionID: row.scopeSessionID) }
        else { try await deliver(row, receipt: receipt, bot: (botID, row.name)) }
        return true
    }

    /// A saved helper outcome needs delivery, not a second model's judgment
    /// about whether to say anything. Use the peer reply's claim/cache/router
    /// and transcript writer, and the same arrival signal for her attention.
    private func deliverBotResult(_ row: AgentConversationRecord, receipt: JSONValue,
                                  bot: (id: UUID, name: String)) async throws {
        guard case .object(let fields) = receipt,
              let request = string(fields["message_id"]), let requestID = UUID(uuidString: request) else {
            throw StandingBotsError.invalidValue("The requested result has no exact shelf entry.")
        }
        let entry = try ShelfStore(dataRoot: dataRoot).entry(requestID)
        guard entry.botId == bot.id else { throw StandingBotsError.corruptStore("bot result identity mismatch") }
        let status = string(fields["status"]) ?? entry.runtimeStatus.rawValue
        let name = bot.name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let read: JSONValue = .object(["action": .string("bot.reply"), "args": .object([
            "id": .string(requestID.uuidString), "bot_id": .string(bot.id.uuidString)])])
        // This line is the app's receipt. Helper-authored prose remains on its
        // shelf, read under its own provenance rather than quoted as her words.
        let line = name + ": " + status + " · " + (try read.serialize(pretty: false))
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
                // The peer's asking-chat writer is idempotent by delivery ID.
                // The result-delivery identity also lets the router attach its
                // notification intent to this actual row without a model turn.
                try await clients.bridgeChatClient().appendAnswerForAskingChat(sessionID: row.scopeSessionID,
                    text: line, attachments: [], surface: row.sourceSurface, deliveryID: "requested-result:" + deliveryID,
                    mechanicalRow: .botReceipt)
                ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                    id: "reply:" + row.operationID, line: line, thread: row.id, session: row.scopeSessionID)])
                return ChatResponse(runId: runID, model: "native", output: line,
                    sessionId: row.scopeSessionID, providerCallCount: 0)
            }
        let result: AgentBridgeCompletionDelivery?
        switch answered {
        case .delivered(let delivery, _), .settled(let delivery?): result = delivery
        case .settled(nil), .held:
            try attention(row, "Result delivery is already claimed or has an unknown outcome. Its saved result remains available; no helper run or delivery turn was repeated.", receipt: receipt)
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

    private func finish(_ row: AgentConversationRecord, delivered: Bool, runID: String?, sessionID: String, sentUnconfirmed: Bool = false) async throws {
        // Agent can already have answered and advanced this conversation while
        // the old human-facing completion is delivered. Never overwrite it.
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

    private func readReply(input: [String: JSONValue], tools: any ToolDispatchClient,
                           row: AgentConversationRecord, peer: AgentPeerContact) async throws -> JSONValue {
        try await AgentConversationContext.$isInternalRead.withValue(true) {
            try await ChatToolSessionContext.$envelope.withValue(envelope(peer: peer, route: nil)) {
                try await ChatToolSessionContext.$verifiedSessionId.withValue(row.scopeSessionID) {
                    // Reads re-enter the app action's gate.
                    let first = try await tools.dispatch(tool: "agent_read", input: input, surface: AgentBridgeSurface.id)
                    guard peer.transport == .nativeAgent, case .object(var fields) = first,
                          case .object(var evidence)? = fields["remote_evidence"],
                          var body = string(fields["reply"]) else { return first }
                    // The wire pages long replies. Keep that bookkeeping below
                    // the conversation rather than asking Agent to turn pages.
                    for _ in 0..<3 where evidence["has_more"] == .bool(true) {
                        try Task.checkCancellation()
                        guard let offset = evidence["next_offset"] else { break }
                        var page = input; page["offset"] = offset
                        let next = try await tools.dispatch(tool: "agent_read", input: page, surface: AgentBridgeSurface.id)
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
            }
        }
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
