import Foundation
import Desk
import PersistenceCore
import StandingBots
import WorkshopExecution
import TurnTrace
import TrustCenter
import TriggerScheduler
import ToolExecution
// Blueprint: | `DeskContinuationScheduler.swift` | `DeskContinuationScheduler` actor; `nextDeadline`, `runDue`; checkpointed runs retain their process-resume owner; `prompt` calls the editable `turn-continuation` seed through L0, then inserts native checkpoint evidence into typed cue slots without sending receipt/partial-reply text into JavaScript; claims, verification and CAS stay native; resumable work obeys the originating DataRootLife, reads stopped/restored across lives and resumes fresh only on explicit request |

public actor DeskContinuationScheduler {
    public static let ownerReceiptChanged = Notification.Name("NativeAgent.desk.ownerReceiptChanged")
    /// A domain's answer about one pending step. `waiting`: its owner is still
    /// working. `unknown`: no verified receipt — the continuation stops and asks.
    public enum Verdict: Sendable { case settled(String), waiting, unknown(String) }
    public typealias Resume = @Sendable (DeskItem, DeskContinuation) async throws -> Void
    public typealias Verify = @Sendable (DeskContinuation.Step, DeskContinuation) async throws -> Verdict
    private let store: SwiftNativeDeskStore
    private let dataRoot: URL
    private let isAllowed: @Sendable () async -> Bool
    private let verify: Verify
    private let resume: Resume
    public private(set) var failure: String?

    public init(dataRoot: URL, isAllowed: @escaping @Sendable () async -> Bool,
                verify: @escaping Verify, resume: @escaping Resume) {
        self.dataRoot = dataRoot
        store = SwiftNativeDeskStore(dataRoot: dataRoot)
        self.isAllowed = isAllowed
        self.verify = verify
        self.resume = resume
    }

    private func eligible(_ item: DeskItem, checkpoints: inout [String: Result<Set<String>, Error>]) -> Bool {
        guard !item.requiresOwnerInput, let record = item.continuation else { return false }
        if let sessionId = record.sessionID {
            do {
                let runs: Result<Set<String>, Error>
                if let cached = checkpoints[sessionId] { runs = cached }
                else {
                    // Each checkpoint is read on its own: one damaged file never hides the
                    // readable ones, and a damaged file might be this run's, so it counts.
                    runs = Result {
                        var ids = Set<String>()
                        for turnId in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
                            do { if let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId) { ids.insert(checkpoint.runId) } }
                            catch { ids.insert(record.runID) }
                        }
                        return ids
                    }
                    checkpoints[sessionId] = runs
                }
                if try runs.get().contains(record.runID) { return false }
            } catch {
                failure = "Repair the turn checkpoint before resuming this task: \(error.localizedDescription)"
                return false
            }
        }
        if record.reason == "reply_ready" { return item.status != .canceled && record.pending.isEmpty }
        guard !item.status.isTerminal else { return false }
        switch record.state {
        case .ready: return true
        case .running: return record.processID != DeskContinuationScope.processID
        // A stopped continuation asked on the task; reopening it re-checks.
        case .blocked: return item.status != .blocked
        case .complete, .canceled, .stopped: return false
        }
    }

    /// When the task is actionable by Desk sequencing — its own and every
    /// ancestor's blockers and deferrals respected. Nil while a blocker or
    /// cycle holds it; a deferral only moves the date.
    private func dueDate(_ item: DeskItem, in state: DeskState, now: Date,
                         checkpoints: inout [String: Result<Set<String>, Error>],
                         plans: inout [Date: DeskSequencing.Plan]) -> Date? {
        guard let record = item.continuation, eligible(item, checkpoints: &checkpoints) else { return nil }
        if record.reason == "reply_ready" { return record.nextRunAt }
        var at = now
        var cursor: DeskItem? = item
        var seen: Set<String> = []
        while let current = cursor, seen.insert(current.handle).inserted {
            if let until = current.deferUntil.flatMap(DeskSequencing.parseDeferStamp), until > at { at = until }
            cursor = current.parent.flatMap { parent in state.items.first { $0.handle == parent } }
        }
        if plans[at] == nil { plans[at] = DeskSequencing.compute(state, now: at) }
        guard plans[at]?.byHandle[item.handle]?.isReady == true else { return nil }
        // The owner receipt, rather than a retry date, makes a waiting step
        // actionable. This also retires dates saved by the old minute poll.
        return record.reason == "waiting_for_owner_receipt" ? at : max(record.nextRunAt, at)
    }

    public func nextDeadline(after date: Date) async -> Date? {
        failure = nil
        guard await isAllowed() else { return nil }
        do {
            let state = try await store.liveState()
            var checkpoints: [String: Result<Set<String>, Error>] = [:]
            var plans: [Date: DeskSequencing.Plan] = [:]
            let now = Date()
            return state.items.compactMap { item -> Date? in
                // Bot/workshop invalidations re-check these receipts. A
                // waiting owner has no crossing of its own; an ancestor's
                // deferral still does.
                let due = dueDate(item, in: state, now: now, checkpoints: &checkpoints, plans: &plans)
                if item.continuation?.reason == "waiting_for_owner_receipt",
                   let due, due <= now { return nil }
                return due
            }.map { max(date, $0) }.min()
        } catch { failure = error.localizedDescription; return nil }
    }

    public func runDue() async -> [String] {
        failure = nil
        guard await isAllowed() else { return [] }
        do {
            let state = try await store.liveState()
            var checkpoints: [String: Result<Set<String>, Error>] = [:]
            var plans: [Date: DeskSequencing.Plan] = [:]
            let now = Date()
            for item in state.items.sorted(by: { $0.handle < $1.handle }) {
                guard dueDate(item, in: state, now: now, checkpoints: &checkpoints, plans: &plans)
                    .map({ $0 <= Date() }) == true,
                    var record = item.continuation else { continue }
                let expected = record.revision
                var unresolved: [DeskContinuation.Step] = []
                var unknown: [DeskContinuation.Step] = []
                for var step in record.pending {
                    let verdict: Verdict
                    // Reopening a stopped task settles nothing: every pending step
                    // is re-checked through its domain, except a read by its
                    // tool's declared class, which changed nothing to verify.
                    if Self.declaredRead(step, dataRoot: dataRoot) { verdict = .settled("interrupted read; no effects") }
                    else if step.owner == "helper" { verdict = try helperReceipt(step) }
                    else { verdict = try await verify(step, record) }
                    switch verdict {
                    case .settled(let receipt):
                        step.result = receipt
                        step.owner = nil
                        record.settled.append(step)
                    case .waiting:
                        unresolved.append(step)
                    case .unknown(let receipt):
                        step.result = receipt
                        unresolved.append(step)
                        unknown.append(step)
                    }
                }
                let pendingUnchanged = record.pending == unresolved
                record.pending = unresolved
                record.revision = UUID().uuidString
                if !unresolved.isEmpty {
                    // A wake can race the owner's completion, or be this record's
                    // own write. Keep a still-waiting receipt unchanged, so the
                    // Desk invalidation cannot manufacture another retry.
                    if unknown.isEmpty, pendingUnchanged, record.state == .ready,
                       record.reason == "waiting_for_owner_receipt" { continue }
                    record.state = unknown.isEmpty ? .ready : .blocked
                    record.reason = !unknown.isEmpty
                        ? "domain_verification_required: " + unknown.prefix(3)
                            .map { "\($0.tool) \($0.id)" }.joined(separator: ", ")
                        : "waiting_for_owner_receipt"
                    try await store.setContinuation(item.handle, expectedRevision: expected, record: record)
                    continue
                }
                if record.reason != "reply_ready" {
                    guard record.resumeCount < 8 else {
                        record.state = .blocked
                        record.reason = "continuation_budget_exhausted"
                        try await store.setContinuation(item.handle, expectedRevision: expected, record: record)
                        return []
                    }
                    record.resumeCount += 1
                    record.runID = UUID().uuidString
                    record.response = nil
                }
                record.state = .running
                record.processID = DeskContinuationScope.processID
                try await store.setContinuation(item.handle, expectedRevision: expected, record: record,
                                                requiresActive: record.reason != "reply_ready")
                do { try await resume(item, record) }
                catch {
                    if let current = try await store.continuation(item.handle),
                       current.revision == record.revision, current.state == .running {
                        var stopped = current
                        stopped.state = .blocked
                        stopped.reason = "continuation_dispatch_failed"
                        stopped.revision = UUID().uuidString
                        try await store.setContinuation(item.handle, expectedRevision: current.revision, record: stopped)
                    }
                    throw error
                }
                // Preserve the one-dispatch cap when several owner receipts
                // settle together. Only a successful dispatch earns this wake;
                // an unchanged waiting/failed receipt never retries itself.
                let nextNow = Date()
                if !Task.isCancelled, state.items.contains(where: { other in
                    other.handle != item.handle && dueDate(other, in: state, now: nextNow,
                        checkpoints: &checkpoints, plans: &plans).map { $0 <= nextNow } == true
                }) {
                    NotificationCenter.default.post(name: SwiftNativeTriggerScheduler.dueWorkRemaining, object: dataRoot)
                }
                return ["desk_continuation:\(item.handle)"]
            }
            return []
        } catch {
            failure = error.localizedDescription
            return []
        }
    }

    private func helperReceipt(_ step: DeskContinuation.Step) throws -> Verdict {
        guard let ownerID = step.ownerID, let botID = UUID(uuidString: ownerID),
              let requestID = step.requestID, let request = UUID(uuidString: requestID) else {
            return .unknown("helper run has no exact request reference")
        }
        let queue = BotRunQueue(dataRoot: dataRoot)
        guard try queue.presence(bot: botID, requestID: request) == .absent else { return .waiting }
        let entry: ShelfEntry
        do { entry = try ShelfStore(dataRoot: dataRoot).entry(request) }
        catch StandingBotsError.notFound { return .unknown("helper request \(requestID) has no queued request, live claim, or result") }
        guard entry.botId == botID, entry.id == request else { throw DeskContinuationError.unsafe }
        guard entry.runtimeStatus == .completed,
              !entry.uncertainties.contains("Run receipt pending finalization.") else {
            return .unknown("helper request \(requestID) ended \(entry.runtimeStatus.rawValue)")
        }
        return .settled("helper request \(requestID) completed")
    }

    /// The caller binds its originating app door. Checkpoint verification,
    /// claims and reply routing remain native; the part supplies only words.
    private enum Cue: Codable, Sendable { case text(String), remainingWork, settled, lastReply }

    public static func prompt(item: DeskItem, record: DeskContinuation, dataRoot: URL) async throws -> String {
        // A receipt or partial answer may quote Git output or a handoff.
        // Those bytes never enter JavaScript (parts decision 13).
        switch await Parts(root: dataRoot).call(id: "turn-continuation",
            input: .object(["handle": .string(item.handle)]), as: [Cue].self) {
        case .success(let cue):
            return cue.map { segment in
                switch segment {
                case .text(let text): return text
                case .remainingWork: return record.remainingWork
                case .settled: return record.settled.suffix(12).map { "\($0.id) \($0.tool): \($0.result ?? "")" }.joined(separator: "\n")
                case .lastReply: return String(record.lastReply.prefix(4000))
                }
            }.joined()
        case .failure(let error): throw error
        }
    }

    /// A read only when its whole input reads: a saved input that does not
    /// parse (a truncated checkpoint) is unknown, and goes to its domain.
    static func declaredRead(_ step: DeskContinuation.Step, dataRoot: URL) -> Bool {
        guard case .object(let input)? = try? JSONValue.parse(Data(step.input.utf8)) else { return false }
        return PermissionLaw.judge(tool: step.tool, input: input, policy: [:], dataRoot: dataRoot).toolClass == .read
    }
}
