import Foundation
import NativeAgentShared
import ChatTurnRuntime
import AgentWorkspace
import ChatToolParsing
import AgentLinkTransport
import NativeAgentCore
import PersistenceCore
import AgentConversations
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting
import CryptoKit
import SQLite3
// Blueprint: | `NativeAgentA2AWire+Tasks.swift` | Canonical contact task projection and record-owned accepted workers; failed settlement preserves streamed prose and offsets; transmitted reply acknowledgements route outbound evidence through AgentPeerStore.recordProof for MCP-host reply health; synchronous bridge admission closure precedes generation-ordered passive cleanup; approval/receipt observations, reply waiters/streams and push tails retire on stop, with canceled handles retained through exit; activation restores persisted owed callbacks, including terminal tasks outside live records; coalesced approval-refresh requests retain a pending pass so worker settlement and observation rearming cannot lose their wake; accepted workers and durable recovery finish independently of the listener, and explicit task cancellation remains separate; resumable work retains DataRootLife; other-life (no stamp = first life) work reads stopped/restored and explicit resumption starts fresh |
/// Retained tasks use the shared chat client; network subscribers never own a turn's lifetime.
public actor AgentContactTasks {
    typealias Runner = @Sendable (AgentContactTurn, @escaping @Sendable (AgentContactProgress) async -> Void) async throws -> AgentContactOutcome
    struct Record {
        var task: AgentContactTask
        var worker: Task<Void, Never>?
        var cancelling = false
        var rawTool = false
        var subscribers: [UUID: AsyncStream<AgentContactEvent>.Continuation] = [:]
        var waiters: [UUID: CheckedContinuation<AgentContactTask, Error>] = [:]
    }
    private let runner: Runner
    private let claims: AgentPeerReplayClaimStore
    let dataRoot: URL
    var records: [String: Record] = [:]
    var order: [String] = []
    var pushConfigs: [String: [String: AgentContactPushConfig]] = [:]
    var pushDeliveries: [String: (generation: UUID, worker: Task<Void, Never>)] = [:]
    let capacity: Int
    private let inbox: SwiftNativeApprovalInbox
    private var approvalObservation: Task<Void, Never>?
    private var receiptObservation: AgentContactReceiptObservation?
    private var approvalRefresh: Task<Void, Never>?
    private var approvalRefreshPending = false
    private var lifecycle = UUID()
    private var bridgeRevision: UInt64 = 0
    private var accepting = true
    private nonisolated let bridgeAdmission = AgentContactBridgeAdmission()
    var bridgeIsActive: Bool { accepting && bridgeAdmission.isActive }
    var terminalPayloadWrites = 32
    /// Set once the launch recovery has read every conversation's saved input.
    var launchRecovered = false
    /// What the launch recovery found queued in a conversation, by task: its input as saved.
    var restoredInput: [String: AgentContactTurn] = [:]
    /// Tasks whose turn the launch recovery resumes (queued, or a checkpoint).
    var resuming: Set<String> = []
    static let recovering = "Recovering after the restart"
    init(dataRoot: URL, capacity: Int = 128, runner: @escaping Runner) {
        self.dataRoot = dataRoot
        self.claims = AgentPeerReplayClaimStore(dataRoot: dataRoot)
        self.capacity = capacity
        self.runner = runner
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
    }
    deinit {
        approvalObservation?.cancel()
        approvalRefresh?.cancel()
        receiptObservation?.cancel()
        for delivery in pushDeliveries.values { delivery.worker.cancel() }
    }
    /// Listener transitions are ordered even when their actor hops arrive out
    /// of order. Stop retires passive resources; accepted turns keep their
    /// record-owned worker and settle normally. Explicit cancel is separate.
    public nonisolated func setBridgeAdmission(_ active: Bool, revision: UInt64) {
        bridgeAdmission.set(active, revision: revision)
    }
    public func setBridgeActive(_ active: Bool, revision: UInt64) {
        guard revision > bridgeRevision else { return }
        bridgeRevision = revision
        accepting = active
        lifecycle = UUID()
        approvalRefreshPending = false
        approvalObservation?.cancel()
        approvalRefresh?.cancel()
        receiptObservation?.cancel(); receiptObservation = nil
        for delivery in pushDeliveries.values { delivery.worker.cancel() }
        pushConfigs.removeAll()
        if active {
            scheduleApprovalRefresh()
            for record in records.values { restoreCallbacks(record.task) }
            if let saved = try? retainedTasksAwaitingRecovery() {
                for task in saved where task.owesCallbacks && records[task.id] == nil {
                    restoreCallbacks(task)
                }
            }
        } else {
            for id in Array(records.keys) {
                records[id]?.subscribers.values.forEach { $0.finish() }
                records[id]?.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
                records[id]?.subscribers.removeAll()
                records[id]?.waiters.removeAll()
            }
        }
    }
    private func scheduleApprovalRefresh() {
        guard bridgeIsActive,
              records.values.contains(where: { !$0.task.state.terminal }) else { return }
        if approvalRefresh != nil {
            approvalRefreshPending = true
            return
        }
        approvalRefreshPending = false
        let generation = lifecycle
        approvalRefresh = Task {
            defer {
                approvalRefresh = nil
                // An inbox read can suspend after a running worker was skipped.
                // Keep its settlement wake, as well as a retiring observer's wake.
                if bridgeIsActive, approvalRefreshPending || lifecycle != generation || approvalObservation == nil {
                    scheduleApprovalRefresh()
                }
            }
            await observeApprovals()
            guard lifecycle == generation, !Task.isCancelled else { return }
            await refreshApprovals()
        }
    }
    private func observeApprovals() async {
        guard bridgeIsActive, approvalObservation == nil else { return }
        let generation = lifecycle
        let receipts = AgentContactReceiptObservation()
        receiptObservation = receipts
        approvalObservation = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    let events = await ApprovalLifecycleBus.shared.events()
                    guard !Task.isCancelled else { return }
                    await self?.refreshApprovals(generation: generation)
                    for await event in events where event.phase == .resolved {
                        guard !Task.isCancelled else { return }
                        await self?.refreshApprovals(generation: generation)
                    }
                }
                group.addTask { [weak self] in
                    for await _ in receipts.events {
                        guard !Task.isCancelled else { return }
                        await self?.refreshApprovals(generation: generation)
                    }
                }
            }
            await self?.approvalObservationFinished()
        }
    }
    private func approvalObservationFinished() {
        approvalObservation = nil
        if bridgeIsActive { scheduleApprovalRefresh() }
    }
    private func refreshApprovals(generation: UUID? = nil) async {
        let generation = generation ?? lifecycle
        guard bridgeIsActive, lifecycle == generation, !Task.isCancelled else { return }
        for id in Array(records.keys) {
            guard let record = records[id], !record.task.state.terminal,
                  record.worker == nil, record.task.approvalIDs?.isEmpty == false else { continue }
            var approvals: [ApprovalRecord] = []
            for approvalID in record.task.approvalIDs ?? [] {
                guard let approval = try? await inbox.get(approvalID) else { break }
                guard bridgeIsActive, lifecycle == generation, !Task.isCancelled else { return }
                approvals.append(approval)
            }
            guard approvals.count == record.task.approvalIDs?.count,
                  approvals.allSatisfy({ $0.status == "resolved" }),
                  records[id]?.task.state.terminal == false else { continue }
            if approvals.contains(where: { $0.decision != "approved" }) {
                finish(id, outcome: .init(state: .canceled, parts: [], detail: "The person declined or canceled the permission card"))
            } else if approvals.allSatisfy({ $0.executedAction != nil }) {
                let succeeded = approvals.allSatisfy { approval in
                    guard case .object(let receipt) = approval.executedAction else { return false }
                    if case .string(let resultClass) = receipt["resultClass"] { return resultClass == "succeeded" }
                    return ChatToolOutcome.exactResultClass(approval.executedAction!) == .succeeded
                }
                finish(id, outcome: .init(state: succeeded ? .completed : .failed,
                    parts: approvals.compactMap { $0.detail.map(AgentContactPart.text) },
                    detail: succeeded ? "Approved work finished" : "Approved work did not confirm success"))
            } else {
                progress(id, .working)
            }
        }
    }
    public func send(_ send: NativeAgentA2AWire.Send, principal: AgentBridgePrincipal, digest: String, protocolName: String = "a2a") async throws -> AgentContactTask {
        let pushConfig: AgentContactPushConfig?
        if let value = send.pushConfig { pushConfig = try await AgentContactPushConfig.parse(value, taskID: send.taskID) }
        else { pushConfig = nil }
        await observeApprovals()
        try Task.checkCancellation()
        guard bridgeIsActive else { throw CancellationError() }
        let key = AgentPeerReplayClaimStore.key(principal: principal.id, protocolName: protocolName, messageID: send.clientMessageID)
        let claimed = try claims.claim(key: key, digest: digest)
        switch claimed {
        case .replay:
            guard let id = claimed.cachedReceipt?["taskID"] as? String else {
                throw AgentContactFailure(code: -32603, message: "Earlier work has no retained task details. Do not send it again automatically.")
            }
            return try get(id, owner: principal.id)
        case .conflict: throw AgentContactFailure(code: -32602, message: "That message ID was already used for different content")
        case .inFlight: throw AgentContactFailure(code: -32004, message: "That message is already being accepted")
        case .stopped: throw AgentContactFailure(code: -32004, message: "That message is stopped (restored). Start a new task in the conversation.")
        case .claimed: break
        }
        let task: AgentContactTask
        do {
            if let continued = send.continuedTask {
                let existing = try get(continued, owner: principal.id)
                guard !existing.state.terminal else { throw AgentContactFailure(code: -32004, message: "This task has ended. Start a new task in the conversation.") }
                throw AgentContactFailure(code: -32004, message: "This task is still working or waiting for the person's permission card")
            } else {
                if records.count >= capacity {
                    guard let oldest = order.first(where: { records[$0]?.task.state.terminal == true }) else {
                        throw AgentContactFailure(code: -32004, message: "Too much work is active. Try again later.")
                    }
                    records.removeValue(forKey: oldest); order.removeAll { $0 == oldest }
                    pushConfigs.removeValue(forKey: oldest)
                }
                var created = AgentContactTask(id: send.taskID, context: send.context, owner: principal.id,
                                               acceptedOutputModes: send.acceptedOutputModes)
                created.lifeID = try DataRootLife.current(in: dataRoot)
                if let pushConfig {
                    try pushConfig.keep()
                    created.callbacks = [pushConfig.id: pushConfig.callback]
                }
                try retain(created)
                task = created
                order.append(task.id)
            }
        } catch { claims.release(key: key); throw error }
        records[task.id] = Record(task: task)
        if let pushConfig { pushConfigs[task.id] = [pushConfig.id: pushConfig] }
        notifyPush(task)
        // Retain the original locator before launching work. A process exit or
        // lost response must never authorize executing the same message again.
        claims.recordReceipt(key: key, digest: digest, receipt: ["taskID": task.id])
        let turn = AgentContactTurn(taskID: task.id, context: task.context, requestID: send.request,
                                    principal: principal, parts: send.parts,
                                    bindRun: { session, run in try await self.bindRun(task.id, session: session, run: run) })
        let runner = self.runner
        startWorker(task.id) {
            try await runner(turn) { progress in await self.progress(task.id, progress) }
        }
        return task
    }
    @discardableResult
    private func startWorker(_ id: String, operation: @escaping @Sendable () async throws -> AgentContactOutcome?) -> Task<Void, Never> {
        let worker = Task {
            do {
                try Task.checkCancellation()
                let outcome = try await operation()
                try Task.checkCancellation()
                if let outcome { self.finish(id, outcome: outcome) }
                else {
                    guard let record = records[id], let recovered = try canonicalReply(record.task) else {
                        self.finish(id, outcome: .init(state: .failed, parts: [],
                            detail: "The resumed turn has no saved completion. Do not resend automatically."))
                        return
                    }
                    records[id]?.task.approvalIDs = recovered.approvals
                    records[id]?.task.detail = recovered.outcome.detail
                    self.finish(id, outcome: recovered.outcome)
                }
            } catch is CancellationError {
                self.finish(id, outcome: .init(state: .canceled, parts: []))
            } catch {
                let failure = ProviderFailure.report(error)
                self.finish(id, outcome: .init(state: .failed, parts: [],
                    detail: failure?.errorDescription ?? "The reply could not be finished. Work: outcome unknown.", failure: failure))
            }
        }
        records[id]?.worker = worker
        return worker
    }
    /// A resumed turn settles its reply to the conversation, never to the
    /// connection that asked: that died with the process. A route that names
    /// a retained task (a contact's send) resumes inside it, and the worker
    /// reads the reply back from the transcript. A caller-result route with
    /// no task locator at all (a /claude/message turn, whose caller reads the
    /// conversation) resumes plainly; a route that names a task it cannot
    /// find is still a failure.
    public func resume(_ route: AgentBridgeCompletionRoute, runID: String,
                       operation: @escaping @Sendable () async throws -> Void) async throws {
        if route.threadId == nil, route.correlationId == nil { try await operation(); return }
        let task = try callerResultTarget(route)
        guard let session = route.sessionId, task.canonicalRunID == runID else { throw AgentContactFailure.missing }
        if task.state.terminal {
            try SwiftNativeChatOrchestrationClient.removeReplyCheckpoint(dataRoot: dataRoot,
                sessionId: session, runId: runID)
            return
        }
        guard records[task.id]?.worker == nil else {
            throw AgentContactFailure(code: -32004, message: "This task is still working or waiting for the person's permission card")
        }
        let worker = startWorker(task.id) {
            try await operation()
            return nil
        }
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
    }
    /// Raw tool RPCs retain their receipt in the same caller-owned task store.
    /// A repeated transport request reads the original receipt, never reruns it.
    public func beginTool(context: String, request: String, principal: AgentBridgePrincipal,
                          digest: String) throws -> (task: AgentContactTask, execute: Bool) {
        guard bridgeIsActive else { throw CancellationError() }
        let id = "na3.\(context).\(request)"
        guard NativeAgentA2AWire.locator(id) != nil else { throw AgentContactFailure.missing }
        let key = AgentPeerReplayClaimStore.key(principal: principal.id, protocolName: "tool", messageID: id)
        let claim = try claims.claim(key: key, digest: digest)
        switch claim {
        case .replay: return (try get(id, owner: principal.id), false)
        case .claimed: break
        default: throw AgentContactFailure(code: -32004, message: "This request is already active or was used for different content. Read its retained result; do not resend.")
        }
        do {
            guard records[id] == nil,
                  try retainedTasks(id: id, owner: principal.id).isEmpty else {
                throw AgentContactFailure(code: -32602, message: "That request already has retained task evidence. Read its result; do not resend.")
            }
            if records.count >= capacity {
                guard let oldest = order.first(where: { records[$0]?.task.state.terminal == true }) else {
                    throw AgentContactFailure(code: -32004, message: "Too much work is active. Try again later.")
                }
                records.removeValue(forKey: oldest); order.removeAll { $0 == oldest }
                pushConfigs.removeValue(forKey: oldest)
            }
            var task = AgentContactTask(id: id, context: context, owner: principal.id)
            task.lifeID = try DataRootLife.current(in: dataRoot)
            task.state = .working
            task.canonicalSession = principal.storedConversation(context)
            try retain(task)
            records[id] = Record(task: task, rawTool: true)
            order.append(id)
            claims.recordReceipt(key: key, digest: digest, receipt: ["taskID": id])
            return (task, true)
        } catch { claims.release(key: key); throw error }
    }
    public func finishTool(_ id: String, owner: String, result: JSONValue) throws {
        var task = try get(id, owner: owner)
        guard !task.state.terminal, task.toolResult == nil else { return }
        task.toolResult = result
        task.text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        task.state = .completed
        task.updated = Date()
        try retain(task)
        records[id]?.task = task
    }
    public func callerResultTarget(_ route: AgentBridgeCompletionRoute) throws -> AgentContactTask {
        guard route.surface == "caller-result", let owner = route.destinationId,
              let context = route.threadId, let request = route.correlationId else { throw AgentContactFailure.missing }
        let task = try get("na3.\(context).\(request)", owner: owner)
        guard task.context == context, task.canonicalSession == route.sessionId else { throw AgentContactFailure.missing }
        return task
    }
    public func appendCallerResult(_ part: AgentContactPart, artifactID: String,
                                   route: AgentBridgeCompletionRoute) throws -> Bool {
        try Task.checkCancellation()
        var task = try callerResultTarget(route)
        guard let accepted = part.accepted(in: task.acceptedOutputModes ?? ["*/*"]) else {
            throw AgentContactFailure(code: -32602, message: "The caller cannot accept this completion")
        }
        if let digest = task.delegatedCompletionDigests?[artifactID] {
            guard digest == (try Self.completionDigest(accepted)) else {
                throw AgentContactFailure(code: -32602, message: "Completion identity conflicts with retained content")
            }
            return false
        }
        var completions = task.delegatedCompletions ?? [:]
        if let retained = completions[artifactID] {
            guard retained == accepted else { throw AgentContactFailure(code: -32602, message: "Completion identity conflicts with retained content") }
            return false
        }
        guard completions.count + (task.delegatedCompletionDigests?.count ?? 0) < 64 else {
            throw AgentContactFailure(code: -32602, message: "The caller cannot accept this completion")
        }
        completions[artifactID] = accepted
        task.delegatedCompletions = completions
        // A late completion is a new retained payload, not an expired receipt.
        task.replyPayloadExpired = nil
        task.updated = Date()
        guard try JSONEncoder().encode(task).count <= AgentContactPart.maximumOutputBytes * 2 else {
            throw AgentContactFailure(code: -32602, message: "The retained reply reached its size limit")
        }
        try retainCompletionReplies(task)
        try retain(task)
        records[task.id]?.task = task
        broadcast(task.id, .artifact(task: task, artifactID: artifactID, parts: [accepted], append: false, last: true))
        return true
    }
    public func get(_ id: String, owner: String) throws -> AgentContactTask {
        if let record = records[id] {
            guard record.task.owner == owner else { throw AgentContactFailure.missing }
            if record.task.needsReplyRecovery, record.worker == nil, record.task.approvalIDs?.isEmpty != false,
               let recovered = try canonicalReply(record.task) {
                records[id]?.task.approvalIDs = recovered.approvals
                finish(id, outcome: recovered.outcome)
            }
            guard let task = records[id]?.task else { throw AgentContactFailure.missing }
            try retainCompletionReplies(task)
            return task
        }
        guard NativeAgentA2AWire.locator(id) != nil else { throw AgentContactFailure.missing }
        guard var task = try retainedTasks(id: id, owner: owner).first else { throw AgentContactFailure.missing }
        if try !DataRootLife.isCurrent(task.lifeID, in: dataRoot), task.needsReplyRecovery {
            task.state = .stopped
            task.detail = DataRootLife.stoppedReason
        }
        if task.needsReplyRecovery {
            // Settlement can retire the checkpoint, so read it before the reply.
            var checkpointed = false
            if let session = task.canonicalSession, let run = task.canonicalRunID,
               session.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: owner)) {
                checkpointed = try SwiftNativeChatOrchestrationClient.hasReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run)
            }
            var queued: AgentContactTurn?
            if let recovered = try canonicalReply(task) {
                task.state = recovered.outcome.state
                task.approvalIDs = recovered.approvals
                task.parts = recovered.outcome.parts.compactMap { $0.accepted(in: task.acceptedOutputModes ?? ["*/*"]) }
                task.text = task.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
                task.detail = recovered.outcome.detail
            } else if let approvals = task.approvalIDs, !approvals.isEmpty {
                task.state = .inputRequired
                task.detail = "Waiting for the person to answer the permission card"
            } else if checkpointed {
                task.state = .working
                task.detail = "The interrupted turn is awaiting recovery"
                // Only a checkpoint the launch recovery can read is resumed and holds
                // its place; a damaged one stays owed here and gives its place up.
                if let session = task.canonicalSession, let run = task.canonicalRunID,
                   (try? SwiftNativeChatOrchestrationClient.hasResumableReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run)) == true {
                    resuming.insert(id)
                }
            } else if let turn = restoredInput.removeValue(forKey: id) {
                queued = turn
                task.state = .working
                task.detail = "Queued in the conversation behind the turn ahead of it"
                resuming.insert(id)
            } else if !launchRecovered, task.canonicalRunID != nil {
                // Read before the launch recovery: it decides once every saved input is read.
                task.state = .working
                task.detail = Self.recovering
            } else {
                task.state = .failed
                task.detail = "The app restarted before the turn finished. Do not resend automatically."
            }
            task.updated = Date()
            try retain(task)
            if !task.state.terminal {
                guard records.count < capacity else { throw AgentContactFailure(code: -32004, message: "Too much work is active. Try again later.") }
                records[id] = Record(task: task)
                order.append(id)
                scheduleApprovalRefresh()
                // Its place in the conversation is held by the restored backlog
                // (TurnAdmission.restore), so it runs in the order it was said.
                if let queued {
                    let runner = self.runner
                    startWorker(id) { try await runner(queued) { progress in await self.progress(id, progress) } }
                }
            }
        }
        try retainCompletionReplies(task)
        restoreCallbacks(task)
        return task
    }
    private func retainCompletionReplies(_ task: AgentContactTask) throws {
        for (artifactID, part) in task.delegatedCompletions ?? [:] {
            guard case .text(let text) = part else { continue }
            var completion = AgentContactTask(id: "na3.\(task.context).\(artifactID)", context: task.context, owner: task.owner)
            completion.lifeID = task.lifeID
            guard try retainedTasks(id: completion.id, owner: completion.owner).isEmpty else { continue }
            completion.state = .completed
            completion.text = text
            completion.parts = [part]
            completion.canonicalSession = task.canonicalSession
            completion.updated = task.updated
            try retain(completion)
        }
    }
    /// Called only after a reply-reading door successfully transmitted the reply.
    public func recordReplyFetch(_ task: AgentContactTask) {
        AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: task.owner, outbound: true)
        guard task.state == .completed, let session = task.canonicalSession, let run = task.canonicalRunID else { return }
        ContactReplyReads.record(dataRoot: dataRoot, session: session, request: task.id, run: run)
    }
    /// A message a restart left queued, from its saved input (the chat owner
    /// reads it): bound to its task and to the contact as it is now (the
    /// runner revalidates its authority). Nil when its words or files cannot
    /// be read back whole.
    func queuedTurn(_ task: AgentContactTask, input: CodexCompletionTranscriptEvidence.SavedTurnInput) -> AgentContactTurn? {
        guard let session = task.canonicalSession, let locator = NativeAgentA2AWire.locator(task.id),
              let peer = (try? AgentPeerStore(dataRoot: dataRoot).list())?.first(where: { $0.id == task.owner }),
              let words = AgentBridgeSurface.message(inTurn: input.content),
              case .success(let attachments) = input.attachments else { return nil }
        let files: [AgentContactPart] = attachments.map {
            .file(name: $0.name ?? "", mediaType: $0.mime, bytes: Data(base64Encoded: $0.base64) ?? Data(), metadata: .null)
        }
        return AgentContactTurn(taskID: task.id, context: task.context, requestID: locator.request,
            principal: AgentBridgePrincipal(id: peer.id, peerID: peer.id, elevated: peer.elevationAllowed, displayName: peer.name),
            parts: [.text(words)] + files, bindRun: { session, run in try await self.bindRun(task.id, session: session, run: run) },
            accepted: EnqueuedUserMessage(sessionId: session, runId: input.runId))
    }
    public func recordReplyFetch(session: String, request: String, run: String, owner: String) {
        ContactReplyReads.record(dataRoot: dataRoot, session: session, request: request, run: run)
        AgentPeerStore(dataRoot: dataRoot).recordProof(peerID: owner, outbound: true)
    }
    func bindRun(_ id: String, session: String, run: String) throws {
        guard var record = records[id], !record.task.state.terminal else { throw AgentContactFailure.missing }
        record.task.canonicalSession = session
        record.task.canonicalRunID = run
        // Must be durable BEFORE the producer can persist a canonical reply.
        try retain(record.task)
        records[id] = record
    }
    private func canonicalReply(_ task: AgentContactTask) throws -> (outcome: AgentContactOutcome, approvals: Set<String>)? {
        guard let session = task.canonicalSession, let run = task.canonicalRunID,
              NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              session.hasPrefix(AgentBridgePrincipal.genericAgentSessionPrefix(owner: task.owner)) else { return nil }
        let url = dataRoot.appendingPathComponent("chat/messages/\(session).jsonl")
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw AgentContactFailure(code: -32603, message: "The conversation could not be read") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = 64 * 1024 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw AgentContactFailure(code: -32603, message: "The conversation could not be reconciled")
        }
        var replies: [AgentContactOutcome] = []
        var approvals = task.approvalIDs ?? []
        var waitingOnPerson = false
        for line in data.split(separator: 10) {
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            guard row["sessionId"] as? String == session, row["runId"] as? String == run,
                  let metadata = row["metadata"] as? [String: Any] else { continue }
            if row["role"] as? String == "tool", let approval = metadata["approvalId"] as? String {
                approvals.insert(approval)
            }
            if row["role"] as? String == "tool", metadata["resultStatus"] as? String == "needs_input" { waitingOnPerson = true }
            guard row["role"] as? String == "assistant",
                  let outcome = metadata["outcomeObservation"] as? [String: Any],
                  let content = row["content"] as? String else { continue }
            let persistence = outcome["responsePersistence"] as? String
            if persistence == "cancelled" || metadata["cancelled"] as? Bool == true {
                replies.append(.init(state: .canceled, parts: [.text(content)]))
            } else if persistence == "failed" {
                replies.append(.init(state: .failed, parts: [.text(content)]))
            } else if persistence == "persisted", metadata["partial"] as? Bool != true {
                // A turn that stopped at a card waits on the person; it did not fail.
                let state: AgentContactTaskState = metadata["completionState"] as? String == "completed" ? .completed
                    : waitingOnPerson ? .inputRequired : .failed
                var parts: [AgentContactPart] = content.isEmpty ? [] : [.text(content)]
                var detail: String? = switch state {
                case .failed: "The saved reply does not confirm that the work finished"
                case .inputRequired: "Waiting on the person: a card is up in NativeAgent. Send the next message once they answer."
                default: nil
                }
                do {
                    for key in ["attachments", "outputFiles"] {
                        guard let raw = metadata[key] else { continue }
                        guard let attachments = raw as? [[String: Any]], attachments.count <= 64 else {
                            throw AgentContactFailure(code: -32603, message: "Invalid saved attachments")
                        }
                        for saved in attachments {
                            guard let type = saved["type"] as? String, let mime = saved["mime"] as? String,
                                  let path = saved["path"] as? String, !path.isEmpty else {
                                throw AgentContactFailure(code: -32603, message: "Invalid saved attachment")
                            }
                            let part = try AgentContactPart.output(.init(type: type, base64: "", mime: mime,
                                name: saved["name"] as? String, path: path), taskID: task.id)
                            if key == "outputFiles" {
                                guard let digest = saved["sha256"] as? String,
                                      case .file(_, _, let bytes, _) = part,
                                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
                                    throw AgentContactFailure(code: -32603, message: "The saved file changed")
                                }
                            }
                            parts.append(part)
                            guard try JSONSerialization.data(withJSONObject: parts.map(\.wire03)).count <= AgentContactPart.maximumOutputBytes else {
                                parts.removeLast()
                                throw AgentContactFailure(code: -32603, message: "Saved attachments exceed the reply limit")
                            }
                        }
                    }
                } catch {
                    detail = "Some saved reply files could not be recovered. Do not resend automatically."
                }
                replies.append(.init(state: state, parts: parts, detail: detail))
            }
        }
        guard replies.count <= 1 else { throw AgentContactFailure(code: -32603, message: "The conversation has ambiguous completion records") }
        if let terminal = replies.first, terminal.state == .canceled {
            return (terminal, [])
        }
        if !approvals.isEmpty {
            return (.init(state: .inputRequired, parts: replies.first?.parts ?? [],
                detail: "Waiting for the person to answer the permission card"), approvals)
        }
        return replies.first.map { ($0, approvals) }
    }
    public func subscribe(_ id: String, owner: String) throws -> AsyncStream<AgentContactEvent> {
        guard bridgeIsActive else { throw CancellationError() }
        let task = try get(id, owner: owner)
        let subscriberID = UUID()
        let pair = AsyncStream<AgentContactEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        pair.continuation.yield(.snapshot(task))
        if task.state.terminal || (task.state == .inputRequired && records[id]?.worker == nil) {
            pair.continuation.finish()
        } else {
            guard (records[id]?.subscribers.count ?? 0) < 16 else {
                throw AgentContactFailure(code: -32004, message: "Too many open reply streams")
            }
            records[id]?.subscribers[subscriberID] = pair.continuation
            pair.continuation.onTermination = { _ in Task { await self.unsubscribe(id, subscriberID) } }
        }
        return pair.stream
    }
    /// Lists this run's bounded retained index. Cursor values are tied to the
    /// authenticated owner and filters, and never grant access to a task.
    func list(owner: String, parameters: JSONValue) throws -> JSONValue {
        guard let params = parameters.foundationObject as? [String: Any] else {
            throw AgentContactFailure(code: -32602, message: "Object params required")
        }
        func invalid(_ field: String) -> AgentContactFailure { .init(code: -32602, message: "Invalid \(field)") }
        let pageSize: Int
        if let raw = params["pageSize"] {
            guard NativeAgentA2AWire.validHistoryLength(raw), let n = raw as? NSNumber,
                  (1...100).contains(n.intValue) else { throw invalid("pageSize") }
            pageSize = n.intValue
        } else { pageSize = 50 }
        if let history = params["historyLength"], !NativeAgentA2AWire.validHistoryLength(history) { throw invalid("historyLength") }
        for field in ["contextId", "status", "pageToken", "statusTimestampAfter"] {
            if let raw = params[field], !(raw is String) { throw invalid(field) }
        }
        let context = params["contextId"] as? String
        let state: String?
        if let raw = params["status"] as? String {
            let parsed = AgentA2AWire.canonicalState(raw, version: "1.0")
            guard parsed != "unknown" else { throw invalid("status") }
            state = parsed
        } else { state = nil }
        let after: Date?
        if let raw = params["statusTimestampAfter"] as? String {
            guard let date = NativeTimestampFormat.parseISO8601FractionalFirst(raw) else { throw invalid("statusTimestampAfter") }
            after = date
        } else { after = nil }
        var includeArtifacts = false
        if let raw = params["includeArtifacts"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw invalid("includeArtifacts") }
            includeArtifacts = n.boolValue
        }
        var filters = params
        filters.removeValue(forKey: "pageToken")
        filters["owner"] = owner
        let fingerprint = AgentPeerReplayClaimStore.digest(try JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys]))
        var cursor: (Date, String)?
        if let token = params["pageToken"] as? String, !token.isEmpty {
            guard token.utf8.count <= 2048, let bytes = Data(base64Encoded: token),
                  let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  fields["filter"] as? String == fingerprint,
                  let time = fields["updated"] as? Double, time.isFinite,
                  let id = fields["id"] as? String, NativeAgentA2AWire.locator(id) != nil else { throw invalid("pageToken") }
            cursor = (Date(timeIntervalSinceReferenceDate: time), id)
        }
        var matches: [AgentContactTask] = []
        for record in records.values {
            let task = record.task
            guard task.owner == owner else { continue }
            if let context, task.context != context { continue }
            if let state, task.state.rawValue != state { continue }
            if let after, task.updated < after { continue }
            matches.append(task)
        }
        matches.sort {
            if $0.updated == $1.updated { return $0.id < $1.id }
            return $0.updated > $1.updated
        }
        let remaining = matches.filter { task in
            guard let cursor else { return true }
            return task.updated < cursor.0 || (task.updated == cursor.0 && task.id > cursor.1)
        }
        let page = Array(remaining.prefix(pageSize))
        var next = ""
        if remaining.count > page.count, let last = page.last {
            next = try JSONSerialization.data(withJSONObject: ["filter": fingerprint, "updated": last.updated.timeIntervalSinceReferenceDate, "id": last.id], options: [.sortedKeys]).base64EncodedString()
        }
        let tasks = try page.map { task in
            var projected = try NativeAgentA2AWire.project(task, version: "1.0")
            if !includeArtifacts { projected.removeValue(forKey: "artifacts") }
            else if projected["artifacts"] == nil { projected["artifacts"] = [[String: Any]]() }
            return projected
        }
        let response: [String: Any] = ["tasks": tasks, "nextPageToken": next, "pageSize": pageSize, "totalSize": matches.count]
        return JSONValue(fromFoundation: response)
    }
    private func unsubscribe(_ task: String, _ subscriber: UUID) { records[task]?.subscribers.removeValue(forKey: subscriber) }
    func settled(_ id: String, owner: String) async throws -> AgentContactTask {
        try Task.checkCancellation()
        guard bridgeIsActive else { throw CancellationError() }
        let task = try get(id, owner: owner)
        if records[id]?.worker == nil { return task }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { records[id]?.waiters[waiter] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, waiter: waiter) }
        }
    }
    private func cancelWaiter(_ id: String, waiter: UUID) {
        records[id]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }
    func cancel(_ id: String, owner: String) async throws -> AgentContactTask {
        let task = try get(id, owner: owner)
        guard !task.state.terminal else { throw AgentContactFailure(code: -32002, message: "This task has already ended") }
        if records[id]?.rawTool == true {
            throw AgentContactFailure(code: -32002, message: "This tool call is still running and cannot be canceled through this task")
        }
        // Only a real approval id holds the task. An inline card (connector,
        // choice) carries none, so input-required alone left it uncancellable.
        if records[id]?.worker == nil, records[id]?.task.approvalIDs?.isEmpty == false {
            throw AgentContactFailure(code: -32002, message: "A permission card is waiting. The person must dismiss it before this work can be stopped.")
        }
        records[id]?.cancelling = true
        if let worker = records[id]?.worker {
            worker.cancel()
            // The runner joins its producer before returning. Cancellation is
            // not reported as settled while a tool can still be unwinding.
            await worker.value
        } else { finish(id, outcome: .init(state: .canceled, parts: [])) }
        return try get(id, owner: owner)
    }
    private func progress(_ id: String, _ progress: AgentContactProgress) {
        guard var record = records[id], !record.task.state.terminal, !record.cancelling else { return }
        record.task.updated = Date()
        let event: AgentContactEvent
        switch progress {
        case .approval(let approvalID):
            record.task.approvalIDs = (record.task.approvalIDs ?? []).union([approvalID])
            do { try retain(record.task) }
            catch {
                record.worker?.cancel()
                record.task.detail = "The permission card state could not be saved"
            }
            records[id] = record
            return
        case .working:
            record.task.state = .working
            record.task.detail = nil
            event = .status(record.task, final: false)
        case .waiting:
            record.task.state = .inputRequired
            record.task.detail = "Waiting for the person to answer the permission card"
            event = .status(record.task, final: false)
        case .text(let delta):
            // The live draft has a size; her turn does not. Past it the draft
            // stops growing and the finished reply still replaces it whole.
            guard record.task.text.utf8.count + delta.utf8.count <= 1_048_576 else { return }
            let append = !record.task.text.isEmpty
            record.task.text += delta
            event = .artifact(task: record.task, artifactID: id + "-reply", parts: [.text(delta)], append: append, last: false)
        }
        let previousState = records[id]?.task.state
        records[id] = record
        if previousState != record.task.state { notifyPush(record.task) }
        broadcast(id, event)
    }
    private func finish(_ id: String, outcome: AgentContactOutcome) {
        guard var record = records[id], record.task.needsReplyRecovery else { return }
        let acceptedOutputModes = record.task.acceptedOutputModes ?? ["*/*"]
        var parts = outcome.parts.compactMap { $0.accepted(in: acceptedOutputModes) }
        if outcome.state == .failed, !record.cancelling {
            if parts.isEmpty, let recovered = try? canonicalReply(record.task) {
                parts = recovered.outcome.parts.compactMap { $0.accepted(in: acceptedOutputModes) }
            }
            // A failed turn keeps the prose already read by its peer at the same offsets.
            if !record.task.text.isEmpty,
               let draft = AgentContactPart.text(record.task.text).accepted(in: acceptedOutputModes) {
                parts.removeAll { if case .text = $0 { return true }; return false }
                parts.insert(draft, at: 0)
            }
        }
        record.task.state = record.cancelling ? .canceled : outcome.state
        record.task.detail = outcome.detail ?? record.task.detail
        record.task.failure = outcome.failure
        record.task.updated = Date()
        if !record.cancelling {
            record.task.parts = parts
            record.task.text = parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        }
        record.worker = nil
        // Ended before its turn was admitted: a restored place it held is let go.
        if let session = record.task.canonicalSession, let run = record.task.canonicalRunID {
            Task { await TurnAdmission.shared.withdraw(sessionID: session, runID: run) }
        }
        do {
            if record.task.state == .canceled, let session = record.task.canonicalSession,
               let run = record.task.canonicalRunID {
                try SwiftNativeChatOrchestrationClient.removeReplyCheckpoint(dataRoot: dataRoot, sessionId: session, runId: run)
            }
            try retain(record.task)
        }
        catch {
            record.task.state = .failed
            record.task.detail = "The reply could not be saved. Do not resend automatically."
        }
        records[id] = record
        if !record.cancelling, !parts.isEmpty {
            // Replace the streamed draft with the canonical final artifact.
            broadcast(id, .artifact(task: record.task, artifactID: id + "-reply", parts: parts, append: false, last: true))
        }
        notifyPush(record.task)
        broadcast(id, .status(record.task, final: true))
        let subscribers = records[id]?.subscribers.values.map { $0 } ?? []
        let waiters = records[id]?.waiters.values.map { $0 } ?? []
        records[id]?.subscribers.removeAll(); records[id]?.waiters.removeAll()
        subscribers.forEach { $0.finish() }
        waiters.forEach { $0.resume(returning: record.task) }
        if record.task.state == .inputRequired {
            scheduleApprovalRefresh()
        }
    }
    private func broadcast(_ id: String, _ event: AgentContactEvent) {
        guard let subscribers = records[id]?.subscribers else { return }
        for (key, continuation) in subscribers {
            if case .dropped = continuation.yield(event) {
                // A slow consumer reconnects to a full snapshot. Dropping its
                // stream is never a task-state transition or a replay trigger.
                continuation.finish(); records[id]?.subscribers.removeValue(forKey: key)
            }
        }
    }
}
private final class AgentContactBridgeAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func set(_ active: Bool, revision: UInt64) {
        lock.withLock {
            guard revision > self.revision else { return }
            self.revision = revision
            self.active = active
        }
    }
}
/// Canonical replay writes its receipt before emitting chatTurnCompleted.
private final class AgentContactReceiptObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    let events: AsyncStream<Void>
    private let feed: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        feed = pair.continuation
        token = NotificationCenter.default.addObserver(forName: .chatTurnCompleted, object: nil, queue: nil) { _ in pair.continuation.yield(()) }
    }
    func cancel() { NotificationCenter.default.removeObserver(token); feed.finish() }
    deinit { cancel() }
}
