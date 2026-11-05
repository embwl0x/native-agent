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
import Experiences
import Foundation
import NativeAgentShared
import ToolRegistry
import NativeAgentCore
import PersistenceCore
import StandingBots
import Transcripts
import os

// Blueprint: | `ResidentWakeRuntime.swift` | Resident wakes share one scheduler and reply routes. |

/// Resident arrivals belong to the resident wake boundary; contact queues do not own their admission, deadline or turn. The runtime shares one scheduler.
public struct ResidentWakeRuntime: Sendable {
    let dataRoot: URL
    let clients: any AgentContactClients
    let completionSender: any AgentBridgeCompletionSending

    init(dataRoot: URL, clients: any AgentContactClients, completionSender: any AgentBridgeCompletionSending) {
        self.dataRoot = dataRoot
        self.clients = clients
        self.completionSender = completionSender
        ResidentWake.shared.turnEnded(dataRoot: dataRoot)
    }

    private var lifecycle: CodexCompletionLifecycle {
        CodexCompletionLifecycle(receiptURL: dataRoot.appendingPathComponent("agent-conversations/completions.jsonl"),
            ownerInstanceId: CodexCompletionLifecycle.processOwnerInstanceId, dataRoot: dataRoot)
    }

    public func nextDeadline(after now: Date) -> Date? {
        NetworkSense.isUp ? ResidentWake.shared.nextDeadline(dataRoot: dataRoot, after: now) : nil
    }

    /// Addressed news enters its conversation; unaddressed news shares one resident wake. Promises retain their reply route,
    /// quoted peer words keep peer authority, and failed turns must not rerun.
    @discardableResult
    public func tick() async throws -> Bool {
        let now = Date()
        guard NetworkSense.isUp else { return false }
        // Only carried steps without an outside moment mean "when I'm free". Read that meaning from their current Desk condition.
        let nextFreeAt: @Sendable (Date, Date) -> Date? = { now, activity in
            let due = activity.addingTimeInterval(StudioWanderLane.quietInterval)
            return due > now ? due : nil
        }
        var items = ResidentWake.pendingItems(dataRoot: dataRoot, now: now)
        let pending = items.filter { $0.key?.hasPrefix("carry.") == true }
        var carriedItems: [String: DeskItem] = [:]
        var quietItems: Set<String> = []
        let deskRevision = SwiftNativeDeskStore.currentRevision
        if !pending.isEmpty {
            let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
            let context = try AgentScreen.queueContext(dataRoot: dataRoot, now: now, ownTurn: true)
            let ready = MyQueueReady.ready(items: state.items, context: context)
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
                switch MyQueue.entry(item).flatMap(MyQueue.when) {
                case .nextTurn?, .ownTurn?, .quiet?: quietItems.insert(arrival.id)
                default: break
                }
                if let index = items.firstIndex(where: { $0.id == arrival.id }) {
                    // Compare later changes against the offered item’s current state.
                    let offered = ResidentWake.carriedArrival(item, crossing: arrival.at, dataRoot: dataRoot)
                    items[index].line = offered.line
                    // Refreshing wording must preserve the habit’s findings.
                    items[index].habitReceipt = arrival.habitReceipt
                    items[index].materialFingerprint = offered.materialFingerprint
                    items[index].at = now
                }
            }
        }
        if items.contains(where: { quietItems.contains($0.id) }) {
            let due = nextFreeAt(now, await ChatTurnSteering.shared.turnActivityOrSeed(for: dataRoot, at: now))
            let busy = ChatTurnSteering.hasOpenResidentTurn(dataRoot: dataRoot)
            if busy || due != nil {
                items.removeAll { quietItems.contains($0.id) }
                if items.isEmpty {
                    if !busy, let due { ResidentWake.shared.wait(dataRoot: dataRoot, until: due, items: quietItems) }
                    return false
                }
            }
        }
        guard !items.isEmpty else { return false }
        let carried = items.first { $0.key?.hasPrefix("carry.") == true }
        // Carried work has one external slot; other arrivals may share its conversation or wake.
        items.removeAll { $0.key?.hasPrefix("carry.") == true && $0.id != carried?.id }
        let conversations = try SessionConversation(dataRoot: dataRoot, includingArchived: true)
        if let session = items.compactMap(\.session).first(where: {
            $0 != ResidentWake.session && !conversations.isHelper($0)
        }) {
            // Claim only this conversation's news. Other conversations and unaddressed arrivals keep their own place in the ledger.
            let offered = items.filter { $0.session == session }
            guard deskRevision == SwiftNativeDeskStore.currentRevision,
                  let wake = ResidentWake.shared.claim(dataRoot: dataRoot, prepared: offered, conversation: session) else { return false }
            do {
                try await returnToConversation(wake.items, session: session, kind: conversations.kind(session), carriedItems: carriedItems)
            } catch is CancellationError { throw CancellationError() }
            catch {
                for item in wake.items {
                    RepairOwed.owe(dataRoot, id: "arrival:" + item.id, kind: .message, operation: "home.arrival:" + item.id,
                        owner: ResidentWake.url(dataRoot).path,
                        words: "The arrival for \(session) could not finish: \(error.localizedDescription). It was not returned through another line.",
                        lever: "Repair the named conversation or delivery evidence, then read the kept arrival on Home; do not repeat its work.")
                }
            }
            return true
        }
        guard ResidentWake.shared.arrivalsDue(dataRoot: dataRoot).map({ $0 <= now }) == true else { return false }
        guard await ChatTurnSteering.shared.residentWakeIsFree(dataRoot: dataRoot) else { return false }
        let session = ResidentWake.session
        var route: AgentBridgeCompletionRoute?
        if let key = carried?.key, let item = carriedItems[String(key.dropFirst(6))], item.step?.owedToPerson == true {
            let revision = (try? ResidentWake.routeRevision(rows: HumanConversationIndex.rows(dataRoot: dataRoot), session: item.step?.session)) ?? .null
            do {
                guard let id = item.step?.session, NativeAgentChatSessionID.normalizedPathComponent(id) == id else {
                    throw StandingBotsError.invalidValue("The promise has no recorded conversation to reply to.")
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
            let ingress = TurnRequest(message: "", sessionID: session, surface: "chat",
                envelope: TurnEnvelope(surface: "chat", agent: "self", declaredRemote: false),
                verifiedSessionID: session,
                origin: ChatMessageOrigin(surface: session, agent: "self", authored: .agent), threadKind: .builder).turn()
            let execution: (response: ChatResponse, turn: Turn, items: [ResidentWake.Item],
                completion: CodexCompletionTranscriptBinding?)? = try await TurnAdmission.shared.runAlone(
                    dataRoot: dataRoot, sessionID: session, turn: ingress) { admittedTurn in
                    guard let wake = await ChatTurnSteering.shared.claimResidentWake(dataRoot: dataRoot, items: items,
                        deskRevision: deskRevision, quietItems: quietItems, nextFreeAt: nextFreeAt, turn: admittedTurn) else { return nil }
                    let (context, agents) = await Self.wakeMessage("",
                        agents: Array(Set(wake.items.compactMap(\.agent))).sorted(), items: wake.items, dataRoot: dataRoot)
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
                        origin: origin, pinnedRunID: responseRunID, codexCompletion: completion, threadKind: .builder,
                        careWakes: wake.items.compactMap { item in
                            guard let careID = item.careID, let watch = item.thread else { return nil }
                            return CognitiveCareWake(careID: careID, watch: watch, at: item.at)
                        })
                    do {
                        // Carried intentions already own their person-facing pacing.
                        var turn = admittedTurn
                        turn.envelope = request.envelope ?? nil
                        turn.origin = origin
                        turn.userText = text
                        turn.fileAccess = request.fileAccess
                        turn.rows.codexCompletion = completion
                        turn.careWakes = request.careWakes ?? []
                        if let responseRunID { turn.run = responseRunID }
                        turn.speechInitiative = admitted == nil ? .scheduled : .intention
                        turn.peerSteering = taint
                        let client = clients.bridgeChatClient(didWrite: { url in
                            if let work = admitted?.key {
                                PhysiologySelfWriteRegistry.shared.stampAfterTick(
                                    loopId: PhysiologySelfWriteRegistry.intentionWriteID(work, url))
                            }
                        })
                        let response = try await request.chat(on: client, holding: turn)
                        if let completion {
                            try await lifecycle.cacheResponse(response, deliveryId: completion.deliveryId, requestDigest: completion.requestDigest)
                        }
                        return (response, turn, wake.items, completion)
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
                let result = await AgentBridgeCompletionRouter.deliverAnswer(turn: execution.turn, deliveryId: completion.deliveryId, requestDigest: completion
                    .requestDigest,
                    text: answer, attachments: response.attachments ?? [], route: route, client: clients.bridgeChatClient(),
                    sender: completionSender, lifecycle: lifecycle)
                if result.status != "completed" {
                    throw StandingBotsError.invalidValue("Carried reply delivery is not confirmed: " + (result.reason ?? result.status))
                }
            }
            // Reach wakes run alone because the answer itself is the message or pass verdict.
            if let reach = execution.items.first(where: \.isReach) {
                await clients.deliverReach(
                    reply: ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters),
                    itemID: reach.id, turnID: response.runId, turn: execution.turn)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            FileHandle.standardError.write(Data("ResidentWakeRuntime: resident wake did not finish; not rerun: \(error.localizedDescription)\n".utf8))
        }
        return true
    }

    /// An addressed arrival uses the same admitted chat, completion ledger and gated delivery owners as a contact continuation.
    private func returnToConversation(_ items: [ResidentWake.Item], session: String, kind: ChatThreadKind?,
                                      carriedItems: [String: DeskItem]) async throws {
        guard let first = items.first, let kind, NativeAgentChatSessionID.normalizedPathComponent(session) == session else {
            throw StandingBotsError.invalidValue("The arrival's recorded conversation is unavailable. Restore its session record before returning it.")
        }
        let carried = items.first { $0.key?.hasPrefix("carry.") == true }
        let step = carried?.key.flatMap { carriedItems[String($0.dropFirst(6))]?.step }
        let taint = PeerDataTaint(restoring: step?.peers ?? [], elevated: step?.elevated ?? [])
        if let step { taint.keep(line: step.words) }
        for agent in items.compactMap(\.agent) where !PeerTrust.ownerTrusts(agent, dataRoot: dataRoot) { taint.mark(peer: agent) }
        var fileAccess = "auto"
        // A line's commissioning turn owns its steering and file ceiling; moving its news cannot discard either.
        for item in items where item.id.hasPrefix("job:") {
            guard let id = item.thread else { throw StandingBotsError.invalidValue("The job arrival has no recorded job identity.") }
            let job = try AgentJobStore(dataRoot: dataRoot).job(id)
            guard item.id == "job:" + job.id + ":" + job.state.rawValue, job.commission.session == session else {
                throw StandingBotsError.invalidValue("The job arrival no longer matches its commissioning conversation and outcome.")
            }
            for peer in job.peers ?? [] { taint.mark(peer: peer) }
            for peer in job.elevated ?? [] { taint.elevate(peer: peer) }
            if let raw = job.fileAccess {
                guard let mode = ICloudChatFileAccessPolicy.Mode(raw) else {
                    throw StandingBotsError.invalidValue("The job's recorded file-access ceiling is unreadable.")
                }
                switch mode {
                case .none: fileAccess = "none"
                case .readOnly: if fileAccess != "none" { fileAccess = "read_only" }
                case .auto, .workspace, .full: break
                }
            }
        }
        let contact: AgentPeerContact?
        if kind == .agent {
            let matches = try AgentPeerStore(dataRoot: dataRoot).list().filter { session.hasPrefix(ContactThread.prefix(owner: $0.id)) }
            guard matches.count == 1, let peer = matches.first else {
                throw StandingBotsError.invalidValue("The arrival's contact is missing or ambiguous; restore its saved identity before returning its news.")
            }
            contact = peer
        } else { contact = nil }
        func destination() async throws -> AgentBridgeCompletionRoute {
            if let contact {
                return AgentBridgeCompletionRoute(surface: AgentConversationStore.heldReplySurface, sessionId: session,
                    destinationId: contact.id, threadId: "mcp-" + contact.id)
            }
            let saved: ChatToolSessionContext.ReplyRoute
            if step?.owedToPerson == true {
                guard let envelope = TurnEnvelope.fromPersistedMetadata(step?.replyRoute), HumanConversationReader.routeAvailable(envelope) else {
                    throw StandingBotsError.invalidValue("The promise's recorded reply route is unavailable. Restore that route before replying.")
                }
                saved = envelope.replyRoute
            } else {
                guard let destination = try await HumanConversationReader.readForSessionDelivery(sessionID: session, dataRoot: dataRoot) else {
                    throw StandingBotsError.invalidValue("The conversation has no available reply route. Restore its recorded door before returning its news.")
                }
                saved = destination
            }
            return AgentBridgeCompletionRoute(surface: saved.surface, sessionId: session,
                destinationId: saved.destinationId, threadId: saved.threadId, sourceKey: saved.sourceKey,
                replyTo: saved.replyTo, correlationId: saved.correlationId, requesterUserId: saved.requesterUserId)
        }
        let text = items.map(\.renderedLine).joined(separator: "\n")
        let deliveryID = "resident-arrival:" + first.id
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let runID = CausalTransitionEvidence.opaqueIdentity(deliveryID)
        let binding = CodexCompletionTranscriptBinding(deliveryId: deliveryID, requestDigest: digest, model: "", reasoningEffort: nil)
        var origin = ChatMessageOrigin(surface: ResidentWake.session, agent: "self", authored: .agent)
        origin.peerSources = taint.checkpointSources
        origin.elevatedPeerSources = taint.elevatedSources
        let request = TurnRequest(message: text, sessionID: session, fileAccess: fileAccess, surface: "chat", suppressUserAppend: true,
            envelope: TurnEnvelope(surface: "chat", agent: "self", declaredRemote: false, workIdentity: carried?.key),
            verifiedSessionID: session, origin: origin,
            pinnedRunID: runID, codexCompletion: binding, threadKind: kind)
        var turn = request.turn()
        turn.peerSteering = taint
        turn.speechInitiative = carried == nil ? .scheduled : .intention
        func claim(_ route: AgentBridgeCompletionRoute?) async throws {
            guard try await lifecycle.claim(deliveryId: deliveryID, requestDigest: digest, sessionId: session,
                responseRunId: runID, route: route, principal: "self", source: ResidentWake.session) == .start else {
                throw StandingBotsError.invalidValue("This arrival already has a recorded attempt; it was not run or delivered again.")
            }
        }
        let client = clients.bridgeChatClient(didWrite: { url in
            if let work = carried?.key {
                PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: PhysiologySelfWriteRegistry.intentionWriteID(work, url))
            }
        })
        let admitted = try await TurnAdmission.admittedRun(turn: turn, arrival: request.arrival(.hidden),
            dataRoot: dataRoot, waitForCapacity: true) { turn in
            // An open turn answers through its own door. Resolve a new reply route only if this arrival runs on its own.
            let target = try await destination()
            try await claim(target)
            var turn = turn
            turn.envelope = turn.envelope?.withDeliveryRoute(target.chatToolReplyRoute)
            do {
                let response = try await request.chat(on: client, holding: turn)
                try await lifecycle.cacheResponse(response, deliveryId: deliveryID, requestDigest: digest)
                return (response, turn, target)
            } catch {
                try await lifecycle.markOutcomeUnknown(deliveryId: deliveryID, requestDigest: digest,
                    detail: "Conversation arrival interrupted; never rerun automatically: " + error.localizedDescription)
                throw error
            }
        }
        switch admitted {
        case .steered(let reading):
            try await claim(nil)
            try await lifecycle.recordDelivery(.init(status: "steered", surface: "chat",
                delivery: "read_in_turn:" + reading.turnID, artifactCount: 0, attempts: 0,
                reason: "The agent's turn in progress read it; that turn's reply answers it."), deliveryId: deliveryID, requestDigest: digest)
        case .ran(let (response, heldTurn, target)):
            if let contact {
                try await AgentContactHeldAnswer.complete(dataRoot: dataRoot, peer: contact, session: session,
                    deliveryID: deliveryID, requestDigest: digest, response: response, client: client, turn: heldTurn, lifecycle: lifecycle)
                break
            }
            let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
            let result = await AgentBridgeCompletionRouter.deliverAnswer(turn: heldTurn, deliveryId: deliveryID, requestDigest: digest,
                text: answer, attachments: response.attachments ?? [], route: target, client: client,
                sender: completionSender, lifecycle: lifecycle)
            guard result.status == "completed" else {
                throw StandingBotsError.invalidValue("Arrival reply delivery is not confirmed: " + (result.reason ?? result.status))
            }
        }
        guard ResidentWake.shared.accept(dataRoot: dataRoot, items: items) else {
            throw PersistenceCoreError.ioFailure("The conversation's arrival acceptance could not be saved.")
        }
    }

    /// Preparation reads each step’s holder and source conversation so work in another conversation stays theirs. Quoted records provide context without
    /// steering the wake.
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
        // Whose words it quotes: each quoted row's own stamp, read through the one per-line path (never the session's owner).
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

}

/// Holding needs no open turn: persist the contact's one send row, then hand delivery to the conversation store every door drains.
public enum AgentContactHeldAnswer {
    package static func complete(dataRoot: URL, peer: AgentPeerContact, session: String, deliveryID: String, requestDigest: String,
                                 response: ChatResponse, client: SwiftNativeChatOrchestrationClient, turn: Turn,
                                 lifecycle: CodexCompletionLifecycle) async throws {
        let outcome: Result<Void, Error> = await settle {
            do {
                guard response.terminalState == .completed else {
                    throw StandingBotsError.invalidValue("The contact's arrival turn did not complete; its saved partial answer was not held as a result.")
                }
                if !response.isSilentCompletion {
                    try await hold(dataRoot: dataRoot, peer: peer, session: session, deliveryID: deliveryID,
                        response: response, reusingCompletion: true, client: client, turn: turn)
                }
                try await lifecycle.recordDelivery(.init(status: "completed", surface: AgentConversationStore.heldReplySurface,
                    delivery: response.isSilentCompletion ? "silence" : "held_for_contact", artifactCount: response.isSilentCompletion ? 0 : 1,
                    attempts: 0, reason: response.isSilentCompletion ? "The agent chose to end silently." : "The contact's held exchange owns delivery."),
                    deliveryId: deliveryID, requestDigest: requestDigest)
                return .success(())
            } catch { return .failure(error) }
        }
        try outcome.get()
    }

    public static func hold(dataRoot: URL, peer: AgentPeerContact, session: String, deliveryID: String,
                            response: ChatResponse, reusingCompletion: Bool = false,
                            client: SwiftNativeChatOrchestrationClient, turn: Turn) async throws {
        guard !deliveryID.isEmpty, session.hasPrefix(ContactThread.prefix(owner: peer.id)) else {
            throw StandingBotsError.invalidValue("A held answer requires its delivery identity and exact contact conversation.")
        }
        let sendID = AgentBridgeCompletionRouter.stableUUID(deliveryID)
        let store = AgentConversationStore(dataRoot: dataRoot)
        let existing = try store.recordsUnlocked().filter { (($0.exchanges ?? []) + ($0.releasing ?? [])).contains { $0.id == sendID } }
        if !existing.isEmpty {
            guard existing.count == 1, existing[0].agent == "peer:" + peer.id else {
                throw StandingBotsError.invalidValue("The held answer's identity belongs to an ambiguous contact record.")
            }
            return
        }
        if let cut = response.workingCommentaryCharacters, cut < 0 || cut > response.output.count {
            throw StandingBotsError.invalidValue("The answer's commentary boundary is unreadable; nothing was held.")
        }
        let paths = try (response.attachments ?? []).map { attachment -> String in
            guard let path = attachment.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                throw StandingBotsError.invalidValue("A held answer attachment has no saved file reference; nothing was held.")
            }
            return path
        }
        let answer = ChatResponse.answerOnly(response.output, workingCommentaryCharacters: response.workingCommentaryCharacters)
        let text = AgentConversationStore.heldText(answer, filePaths: paths)
        try AgentConversationStore.validateHeldText(text)
        let saved = try ContactThread.lines(dataRoot: dataRoot, owner: peer.id).filter { $0.sendID == sendID && $0.mine }
        if saved.isEmpty {
            try await client.appendAgentConversationSend(sessionID: session, text: text, clientUserMessageID: sendID,
                reusingCompletionID: reusingCompletion ? deliveryID : nil, turn: turn)
        }
        try store.holdReply(peer: peer, session: session, sendID: sendID, text: text)
    }
}

