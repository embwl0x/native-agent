import Foundation
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import Darwin
import CoreFoundation
import ProviderRouting

enum AgentContactTaskState: String, Codable, Sendable {
    case submitted, working, inputRequired = "input-required", completed, failed, canceled
    var terminal: Bool { self == .completed || self == .failed || self == .canceled }
}

struct AgentContactTask: Codable, Sendable {
    let id: String
    let context: String
    let owner: String
    var state: AgentContactTaskState = .submitted
    var text = ""
    var parts: [AgentContactPart] = []
    var detail: String?
    var failure: ProviderFailure.Report?
    var updated = Date()
    var canonicalSession: String?
    var canonicalRunID: String?
    var acceptedOutputModes: [String]?
}

enum AgentContactEvent: Sendable {
    case snapshot(AgentContactTask)
    case status(AgentContactTask, final: Bool)
    case artifact(task: AgentContactTask, parts: [AgentContactPart], append: Bool, last: Bool)
}

struct AgentContactTurn: Sendable {
    let taskID: String
    let context: String
    let requestID: String
    let principal: AgentBridgePrincipal
    let parts: [AgentContactPart]
    var bindRun: @Sendable (String, String) async throws -> Void = { _, _ in }
}

enum AgentContactProgress: Sendable {
    case working
    case text(String)
    case waiting
    case approval(String)
}

struct AgentContactOutcome: Sendable {
    var state: AgentContactTaskState
    var parts: [AgentContactPart]
    var detail: String? = nil
    var failure: ProviderFailure.Report? = nil
}

/// Retained A2A task projection, not a second chat engine. Execution, tools,
/// approvals, transcripts and cancellation settlement belong to the shared
/// chat client. Network subscribers never own the turn's lifetime.
actor AgentContactTasks {
    typealias Runner = @Sendable (AgentContactTurn, @escaping @Sendable (AgentContactProgress) async -> Void) async throws -> AgentContactOutcome
    private struct Record {
        var task: AgentContactTask
        var worker: Task<Void, Never>?
        var cancelling = false
        var approvals: Set<String> = []
        var acceptedOutputModes = ["*/*"]
        var subscribers: [UUID: AsyncStream<AgentContactEvent>.Continuation] = [:]
        var waiters: [UUID: CheckedContinuation<AgentContactTask, Error>] = [:]
    }
    private let runner: Runner
    private let claims: AgentPeerReplayClaimStore
    private let dataRoot: URL
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var pushConfigs: [String: [String: AgentContactPushConfig]] = [:]
    private var pushDeliveries: [String: Task<Void, Never>] = [:]
    private let capacity: Int
    private let inbox: SwiftNativeApprovalInbox
    private var approvalObservation: Task<Void, Never>?
    private var receiptObservation: AgentContactReceiptObservation?

    init(dataRoot: URL, capacity: Int = 128, runner: @escaping Runner) {
        self.dataRoot = dataRoot
        self.claims = AgentPeerReplayClaimStore(dataRoot: dataRoot)
        self.capacity = capacity
        self.runner = runner
        self.inbox = SwiftNativeApprovalInbox(root: dataRoot)
    }

    deinit { approvalObservation?.cancel() }

    private func observeApprovals() async {
        guard approvalObservation == nil else { return }
        let events = await ApprovalLifecycleBus.shared.events()
        guard approvalObservation == nil else { return }
        receiptObservation = AgentContactReceiptObservation { [weak self] in
            Task { await self?.refreshApprovals() }
        }
        approvalObservation = Task { [weak self] in
            for await event in events where event.phase == .resolved {
                guard !Task.isCancelled else { return }
                await self?.refreshApprovals()
            }
        }
    }

    private func refreshApprovals() async {
        for id in Array(records.keys) {
            guard let record = records[id], !record.task.state.terminal,
                  record.worker == nil, !record.approvals.isEmpty else { continue }
            var approvals: [ApprovalRecord] = []
            for approvalID in record.approvals {
                guard let approval = try? await inbox.get(approvalID) else { break }
                approvals.append(approval)
            }
            guard approvals.count == record.approvals.count,
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

    func send(_ send: NativeAgentA2AWire.Send, principal: AgentBridgePrincipal, digest: String, protocolName: String = "a2a") async throws -> AgentContactTask {
        let pushConfig: AgentContactPushConfig?
        if let value = send.pushConfig { pushConfig = try await AgentContactPushConfig.parse(value, taskID: send.taskID) }
        else { pushConfig = nil }
        await observeApprovals()
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
                task = AgentContactTask(id: send.taskID, context: send.context, owner: principal.id,
                                        acceptedOutputModes: send.acceptedOutputModes)
                try retain(task)
                order.append(task.id)
            }
        } catch { claims.release(key: key); throw error }
        records[task.id] = Record(task: task, acceptedOutputModes: send.acceptedOutputModes)
        if let pushConfig { pushConfigs[task.id] = [pushConfig.id: pushConfig] }
        notifyPush(task)
        // Retain the original locator before launching work. A process exit or
        // lost response must never authorize executing the same message again.
        claims.recordReceipt(key: key, digest: digest, receipt: ["taskID": task.id])
        let turn = AgentContactTurn(taskID: task.id, context: task.context, requestID: send.request,
                                    principal: principal, parts: send.parts,
                                    bindRun: { session, run in try await self.bindRun(task.id, session: session, run: run) })
        let runner = self.runner
        let worker = Task {
            do {
                let outcome = try await runner(turn) { progress in await self.progress(task.id, progress) }
                self.finish(task.id, outcome: outcome)
            } catch is CancellationError {
                self.finish(task.id, outcome: .init(state: .canceled, parts: []))
            } catch {
                let failure = ProviderFailure.report(error)
                self.finish(task.id, outcome: .init(state: .failed, parts: [],
                    detail: failure?.errorDescription ?? "The reply could not be finished. Work: outcome unknown.", failure: failure))
            }
        }
        records[task.id]?.worker = worker
        return task
    }

    func get(_ id: String, owner: String) throws -> AgentContactTask {
        if let record = records[id] {
            guard record.task.owner == owner else { throw AgentContactFailure.missing }
            return record.task
        }
        guard NativeAgentA2AWire.locator(id) != nil else { throw AgentContactFailure.missing }
        let url = retainedURL(id: id, owner: owner)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AgentContactFailure.missing }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = AgentContactPart.maximumOutputBytes * 2
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              var task = try? JSONDecoder().decode(AgentContactTask.self, from: data),
              task.id == id, task.owner == owner else { throw AgentContactFailure.missing }
        if !task.state.terminal {
            if let reply = try canonicalReply(task) {
                task.state = .completed
                task.parts = reply.compactMap { $0.accepted(in: task.acceptedOutputModes ?? ["*/*"]) }
                task.text = task.parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
                task.detail = nil
            } else {
                task.state = .failed
                task.detail = "The app restarted before the turn finished. Do not resend automatically."
            }
            task.updated = Date()
            try retain(task)
        }
        return task
    }

    private func bindRun(_ id: String, session: String, run: String) throws {
        guard var record = records[id], !record.task.state.terminal else { throw AgentContactFailure.missing }
        record.task.canonicalSession = session
        record.task.canonicalRunID = run
        // Must be durable BEFORE the producer can persist a canonical reply.
        try retain(record.task)
        records[id] = record
    }

    private func canonicalReply(_ task: AgentContactTask) throws -> [AgentContactPart]? {
        guard let session = task.canonicalSession, let run = task.canonicalRunID,
              NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              session.hasPrefix(ClaudeBridge.genericAgentSessionPrefix(owner: task.owner)) else { return nil }
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
        var replies: [String] = []
        for line in data.split(separator: 10) {
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            guard row["sessionId"] as? String == session, row["runId"] as? String == run,
                  row["role"] as? String == "assistant",
                  let metadata = row["metadata"] as? [String: Any],
                  metadata["partial"] as? Bool != true, metadata["cancelled"] as? Bool != true,
                  let outcome = metadata["outcomeObservation"] as? [String: Any],
                  outcome["responsePersistence"] as? String == "persisted",
                  let content = row["content"] as? String else { continue }
            replies.append(content)
        }
        guard replies.count <= 1 else { throw AgentContactFailure(code: -32603, message: "The conversation has ambiguous completion records") }
        return replies.first.map { [.text($0)] }
    }

    private func retainedURL(id: String, owner: String) -> URL {
        let key = AgentPeerReplayClaimStore.digest(Data((owner + "\u{1f}" + id).utf8))
        return dataRoot.appendingPathComponent("agents/a2a-replies/\(key).json")
    }

    private func retain(_ task: AgentContactTask) throws {
        let url = retainedURL(id: task.id, owner: task.owner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(task), to: url)
    }

    func subscribe(_ id: String, owner: String) throws -> AsyncStream<AgentContactEvent> {
        let task = try get(id, owner: owner)
        let subscriberID = UUID()
        let pair = AsyncStream<AgentContactEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        pair.continuation.yield(.snapshot(task))
        if task.state.terminal || (task.state == .inputRequired && records[id]?.worker == nil) {
            pair.continuation.yield(.status(task, final: true))
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
        guard let params = AgentContactPart.object(parameters) as? [String: Any] else {
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
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = format.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { throw invalid("statusTimestampAfter") }
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
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: response))
    }

    func push(operation: String, owner: String, parameters: JSONValue) async throws -> JSONValue {
        guard let params = AgentContactPart.object(parameters) as? [String: Any],
              let taskID = params["taskId"] as? String else { throw AgentContactPushConfig.invalid }
        _ = try get(taskID, owner: owner)
        switch operation {
        case "CreateTaskPushNotificationConfig":
            let config = try await AgentContactPushConfig.parse(parameters, taskID: taskID)
            _ = try get(taskID, owner: owner)
            guard pushConfigs[taskID]?[config.id] == nil else {
                throw AgentContactFailure(code: -32602, message: "That push configuration already exists")
            }
            guard (pushConfigs[taskID]?.count ?? 0) < 8 else {
                throw AgentContactFailure(code: -32004, message: "Too many push notification configurations")
            }
            pushConfigs[taskID, default: [:]][config.id] = config
            return try config.value
        case "GetTaskPushNotificationConfig":
            guard let id = params["id"] as? String, let config = pushConfigs[taskID]?[id] else { throw AgentContactFailure.missing }
            return try config.value
        case "DeleteTaskPushNotificationConfig":
            guard let id = params["id"] as? String, !id.isEmpty else { throw AgentContactPushConfig.invalid }
            pushConfigs[taskID]?.removeValue(forKey: id)
            let key = taskID + ":" + id
            if let delivery = pushDeliveries.removeValue(forKey: key) {
                delivery.cancel()
                // Join an already-started bounded POST before acknowledging deletion.
                await delivery.value
            }
            return .object([:])
        case "ListTaskPushNotificationConfigs":
            let size: Int
            if let raw = params["pageSize"] {
                guard NativeAgentA2AWire.validHistoryLength(raw), let n = raw as? NSNumber,
                      (1...100).contains(n.intValue) else { throw AgentContactPushConfig.invalid }
                size = n.intValue
            } else { size = 50 }
            let cursor: String
            if let token = params["pageToken"] {
                guard let text = token as? String else { throw AgentContactPushConfig.invalid }
                cursor = text
            } else { cursor = "" }
            let configs = (pushConfigs[taskID]?.values.map { $0 } ?? []).sorted { $0.id < $1.id }
            guard cursor.isEmpty || configs.contains(where: { $0.id == cursor }) else { throw AgentContactPushConfig.invalid }
            let remaining = configs.filter { cursor.isEmpty || $0.id > cursor }
            let page = Array(remaining.prefix(size))
            return .object(["configs": .array(try page.map { try $0.value }),
                            "nextPageToken": .string(remaining.count > page.count ? (page.last?.id ?? "") : "")])
        default: throw AgentContactFailure(code: -32601, message: "Unknown push notification operation")
        }
    }

    private func notifyPush(_ task: AgentContactTask) {
        guard let configs = pushConfigs[task.id], !configs.isEmpty else { return }
        // A status event contains only the protocol locator and state. Peers fetch
        // artifacts through their authenticated task API instead of webhook copies.
        let event: [String: Any] = ["taskId": task.id, "contextId": task.context,
                                   "status": ["state": task.state.rawValue]]
        guard let canonical = try? NativeAgentA2AWire.project(event, version: "1.0"),
              let payload = try? JSONSerialization.data(withJSONObject: ["statusUpdate": canonical]) else { return }
        for config in configs.values {
            let key = task.id + ":" + config.id
            let previous = pushDeliveries[key]
            pushDeliveries[key] = Task {
                await previous?.value
                guard !Task.isCancelled, self.pushConfigs[task.id]?[config.id]?.generation == config.generation else { return }
                await config.deliver(payload)
                if task.state.terminal { self.pushDeliveries.removeValue(forKey: key) }
            }
        }
    }

    private func unsubscribe(_ task: String, _ subscriber: UUID) { records[task]?.subscribers.removeValue(forKey: subscriber) }

    func settled(_ id: String, owner: String) async throws -> AgentContactTask {
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
        if records[id]?.worker == nil, task.state == .inputRequired || records[id]?.approvals.isEmpty == false {
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
            record.approvals.insert(approvalID)
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
            guard record.task.text.utf8.count + delta.utf8.count <= 1_048_576 else {
                record.worker?.cancel()
                record.task.detail = "The reply reached its size limit"
                records[id] = record
                return
            }
            let append = !record.task.text.isEmpty
            record.task.text += delta
            event = .artifact(task: record.task, parts: [.text(delta)], append: append, last: false)
        }
        let previousState = records[id]?.task.state
        records[id] = record
        if previousState != record.task.state { notifyPush(record.task) }
        broadcast(id, event)
    }

    private func finish(_ id: String, outcome: AgentContactOutcome) {
        guard var record = records[id], !record.task.state.terminal else { return }
        let parts = outcome.parts.compactMap { $0.accepted(in: record.acceptedOutputModes) }
        record.task.state = record.cancelling ? .canceled : outcome.state
        record.task.detail = outcome.detail ?? record.task.detail
        record.task.failure = outcome.failure
        record.task.updated = Date()
        if !record.cancelling {
            record.task.parts = parts
            record.task.text = parts.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
        }
        record.worker = nil
        do { try retain(record.task) }
        catch {
            record.task.state = .failed
            record.task.detail = "The reply could not be saved. Do not resend automatically."
        }
        records[id] = record
        if !record.cancelling, !parts.isEmpty {
            // Replace the streamed draft with the canonical final artifact.
            broadcast(id, .artifact(task: record.task, parts: parts, append: false, last: true))
        }
        notifyPush(record.task)
        broadcast(id, .status(record.task, final: true))
        let subscribers = records[id]?.subscribers.values.map { $0 } ?? []
        let waiters = records[id]?.waiters.values.map { $0 } ?? []
        records[id]?.subscribers.removeAll(); records[id]?.waiters.removeAll()
        subscribers.forEach { $0.finish() }
        waiters.forEach { $0.resume(returning: record.task) }
        if record.task.state == .inputRequired {
            Task { await self.refreshApprovals() }
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

/// Canonical replay writes its receipt before emitting chatTurnCompleted.
private final class AgentContactReceiptObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(onReceipt: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .chatTurnCompleted, object: nil, queue: nil) { _ in onReceipt() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

extension NativeAgentA2AWire {
    static func project(_ task: AgentContactTask, version: String) throws -> [String: Any] {
        try project(Self.task(task), version: version)
    }

    static func project(_ object: [String: Any], version: String) throws -> [String: Any] {
        guard version == "1.0" else {
            var object = object
            if let parts = object["parts"] as? [[String: Any]] {
                object["parts"] = try parts.map { part in
                    guard part["kind"] as? String == "data" else { return part }
                    var canonical = part; canonical.removeValue(forKey: "kind")
                    let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: canonical))
                    return AgentContactPart.object(try AgentA2AWire.wirePart(value, version: "0.3")) as! [String: Any]
                }
            }
            if let artifacts = object["artifacts"] as? [[String: Any]] { object["artifacts"] = try artifacts.map { try project($0, version: version) } }
            if let artifact = object["artifact"] as? [String: Any] { object["artifact"] = try project(artifact, version: version) }
            return object
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        return AgentContactPart.object(try AgentA2AWire.canonicalObject(value)) as! [String: Any]
    }
    static func task(_ task: AgentContactTask) -> [String: Any] {
        var result: [String: Any] = ["kind": "task", "id": task.id, "contextId": task.context, "status": status(task)]
        let parts = task.parts.isEmpty ? (task.text.isEmpty ? [] : [AgentContactPart.text(task.text)]) : task.parts
        if !parts.isEmpty { result["artifacts"] = [["artifactId": task.id + "-reply", "parts": parts.map(\.wire03)]] }
        return result
    }

    private static func status(_ task: AgentContactTask) -> [String: Any] {
        var status: [String: Any] = ["state": task.state.rawValue, "timestamp": ISO8601DateFormatter().string(from: task.updated)]
        if let detail = task.detail {
            status["message"] = ["kind": "message", "role": "agent", "messageId": task.id + "-status",
                "taskId": task.id, "contextId": task.context, "parts": [["kind": "text", "text": detail]]]
        }
        if let failure = task.failure,
           let data = try? JSONEncoder().encode(failure),
           let value = try? JSONSerialization.jsonObject(with: data) {
            var message = status["message"] as? [String: Any] ?? [:]
            message["metadata"] = ["provider_failure": value]
            status["message"] = message
        }
        return status
    }

    static func event(_ event: AgentContactEvent, id: Any, version: String = "0.3") -> [String: Any] {
        if version == "1.0" {
            let legacy = Self.event(event, id: id)
            let key: String
            switch event {
            case .snapshot: key = "task"
            case .status: key = "statusUpdate"
            case .artifact: key = "artifactUpdate"
            }
            do { return result(id, [key: try project(legacy["result"] as! [String: Any], version: version)]) }
            catch { return Self.error(id, -32603, "The task update could not be encoded") }
        }
        switch event {
        case .snapshot(let task): return result(id, Self.task(task))
        case .status(let task, let final):
            return result(id, ["kind": "status-update", "taskId": task.id, "contextId": task.context, "status": status(task), "final": final])
        case .artifact(let task, let parts, let append, let last):
            let object: [String: Any] = ["kind": "artifact-update", "taskId": task.id, "contextId": task.context,
                "artifact": ["artifactId": task.id + "-reply", "parts": parts.map(\.wire03)], "append": append, "lastChunk": last]
            return result(id, object)
        }
    }
}
