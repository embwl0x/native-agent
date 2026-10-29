import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `WorkshopExecution+DeskTasks.swift` | `WorkshopDirectedTaskSubmitter` and Desk receipt bridge: Desk-first task identity with canonical Workshop execution and terminal evidence |

/// Result of shadow-submitting a user-directed task through the Workshop. The
/// Desk handle is the durable user-facing identity; `executionId` is only the
/// compatibility executor key while the old queue storage is being absorbed.
public struct WorkshopDirectedTaskResult: Sendable, Equatable {
    public var deskItem: DeskItem
    public var executionId: String
    public var execution: WorkshopExecutionRecord

    public init(deskItem: DeskItem, executionId: String, execution: WorkshopExecutionRecord) {
        self.deskItem = deskItem
        self.executionId = executionId
        self.execution = execution
    }
}

/// Desk-first submission boundary for user-directed multi-step work. It leaves
/// the existing runner intact underneath so consumers can migrate one at a
/// time without breaking the proven executor.
public struct WorkshopDirectedTaskSubmitter: Sendable {
    public let dataRoot: URL
    public let runner: SwiftNativeWorkshopRunner

    public init(dataRoot: URL, runner: SwiftNativeWorkshopRunner) {
        self.dataRoot = dataRoot
        self.runner = runner
    }

    /// `existing` names a live Desk item (stable handle or visible alias) that
    /// this execution IS the next piece of. Supplied, the project keeps the
    /// identity it already has across days — same handle, same notes, same
    /// refs, one more trace — instead of collecting a second "Workshop" item
    /// per run whose history starts empty. Omitted, the old behaviour stands
    /// and a new item is created. A terminal or unknown reference is refused
    /// rather than quietly creating one: reusing a closed project would
    /// reopen finished work.
    public func submit(
        spec: WorkshopExecutionSpec,
        project: String = "Workshop",
        existing: String? = nil
    ) async throws -> WorkshopDirectedTaskResult {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let reference = existing?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item: DeskItem
        if let reference, !reference.isEmpty {
            let state = try await store.liveState()
            guard let live = state.items.first(where: {
                $0.handle == reference || $0.alias == reference
            }) else {
                throw WorkshopExecutionError.invalidRequest(
                    "no live Desk item numbered or handled '\(reference)' — read app desk.read first, or omit desk_handle to open a new one")
            }
            guard !live.status.isTerminal else {
                throw WorkshopExecutionError.invalidRequest(
                    "Desk item \(live.alias) is already closed; omit desk_handle to open a new one")
            }
            item = live
        } else {
            item = try await store.createItem(
                kind: .project,
                project: project,
                title: String(spec.title.prefix(160)),
                summary: String(spec.objective.prefix(600))
            )
        }
        guard let admission = try await store.setStatusIfUnchanged(
            item.handle, expectedUpdatedAt: item.updatedAt, status: .now,
            note: reference?.isEmpty == false
                ? "Workshop run on this item: \(String(spec.objective.prefix(600)))" : nil
        ) else {
            throw WorkshopExecutionError.invalidRequest(
                "Desk item \(item.alias) changed or closed before Workshop admission; read it again before submitting")
        }

        var linkedSpec = spec
        linkedSpec.deskHandle = item.handle
        var acceptedExecutionID: String?
        do {
            let enqueued = try await runner.submit(spec: linkedSpec)
            acceptedExecutionID = enqueued.executionId
            _ = try await store.addRef(
                item.handle,
                ref: DeskRef(kind: .trace(id: enqueued.executionId, kind: "workshop_execution"))
            )
            _ = try? await store.appendNote(
                item.handle,
                text: "Workshop work queued."
            )
            let state = try await store.liveState()
            let current = state.items.first(where: { $0.handle == item.handle }) ?? item
            return WorkshopDirectedTaskResult(
                deskItem: current,
                executionId: enqueued.executionId,
                execution: enqueued.record
            )
        } catch {
            if let acceptedExecutionID {
                throw ToolFailureError(
                    "Workshop execution \(acceptedExecutionID) was accepted for Desk item \(item.handle), but submission linkage/readback failed: \(error.localizedDescription). Inspect this exact execution before retrying; terminal reconciliation repairs its Desk association.",
                    effects: .occurred, owner: "Workshop execution \(acceptedExecutionID), Desk item \(item.handle)",
                    code: "desk_link_failed_after_acceptance", recovery: .reconcile)
            }
            _ = try? await store.setStatusIfUnchanged(
                item.handle,
                expectedUpdatedAt: admission.ts,
                status: .blocked,
                blockedReason: String(error.localizedDescription.prefix(600))
            )
            _ = try? await store.appendNote(
                item.handle,
                text: "Workshop submission refused: \(String(error.localizedDescription.prefix(600)))"
            )
            if let failure = error as? ToolFailureError {
                throw ToolFailureError(failure.message + " Desk item \(item.handle) was retained.",
                    argumentPath: failure.argumentPath, accepted: failure.accepted, effects: .occurred,
                    owner: failure.owner, nextCall: failure.nextCall, tap: failure.tap, personDecides: failure.personDecides)
            }
            throw error
        }
    }
}

/// One multi-step terminal receipt in the Phase-1 Workshop receipt feed. Both
/// single-session pursuits and directed tasks therefore measure from one
/// handle-keyed source instead of maintaining a second global scoreboard log.
public struct WorkshopDirectedTaskReceipt: Sendable, Equatable {
    public var handle: String
    public var executionId: String
    public var status: String
    public var summary: String
    public var createdAt: String
    public var completedAt: String
    public var totalSteps: Int
    public var completedSteps: Int
    public var rerunCount: Int
    public var triggerSource: String
    public var wasStub: Bool
    /// Whether the finished execution's claimed outcome was independently
    /// verified. `nil` is retained for legacy receipts written before this
    /// distinction existed; those keep their historical scoreboard meaning.
    public var verificationStatus: WorkshopVerificationStatus?

    public init(
        handle: String,
        executionId: String,
        status: String,
        summary: String,
        createdAt: String,
        completedAt: String,
        totalSteps: Int,
        completedSteps: Int,
        rerunCount: Int,
        triggerSource: String,
        wasStub: Bool,
        verificationStatus: WorkshopVerificationStatus? = nil
    ) {
        self.handle = handle
        self.executionId = executionId
        self.status = status
        self.summary = summary
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.totalSteps = totalSteps
        self.completedSteps = completedSteps
        self.rerunCount = rerunCount
        self.triggerSource = triggerSource
        self.wasStub = wasStub
        self.verificationStatus = verificationStatus
    }

}

/// desk_settlement.json holds WorkshopDirectedTaskReceipt JSON after the receipt log
/// and Desk both settle. It is locally backed up, exported and listed by PrivacyMap
/// under workshop/; it never syncs to the phone.
public enum WorkshopDeskReceiptBridge {
    public static func recordTerminal(
        _ records: [WorkshopExecutionRecord],
        reason: String? = nil,
        dataRoot: URL
    ) async {
        var prepared: [(WorkshopExecutionRecord, WorkshopDirectedTaskReceipt, URL)] = []
        for record in records where record.isTerminal {
            guard let handle = record.deskHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !handle.isEmpty else { continue }

            let timelinePath = ExecutionRecordFile.timelinePath(in: dataRoot
                .appendingPathComponent("workshop/executions", isDirectory: true)
                .appendingPathComponent(record.id, isDirectory: true))
            let timeline = (try? await ExecutionRecordFile.readTimeline(at: timelinePath)) ?? []
            let wasStub = timeline.contains { row in
                if case .object(let object) = row,
                   case .string("planner_fallback")? = object["event"] { return true }
                return false
            }
            let summary = terminalSummary(record, reason: reason ?? record.terminalReason)
            let receipt = WorkshopDirectedTaskReceipt(
                handle: handle, executionId: record.id, status: record.status, summary: summary,
                createdAt: record.createdAt, completedAt: record.updatedAt,
                totalSteps: record.plan.count, completedSteps: record.stepsCompleted.count,
                rerunCount: record.rerunCount, triggerSource: record.triggerSource, wasStub: wasStub,
                verificationStatus: record.verification?.status
            )
            prepared.append((record, receipt, timelinePath.deletingLastPathComponent()
                .appendingPathComponent("desk_settlement.json")))
        }
        do {
            try await WorkshopReceiptLog(dataRoot: dataRoot).append(prepared.map { $0.1 })
        } catch {
            FileHandle.standardError.write(Data("Workshop receipt settlement failed: \(error)\n".utf8))
            return
        }
        for (record, receipt, settlementPath) in prepared {
            let handle = receipt.handle, summary = receipt.summary
            let receiptJSON = WorkshopReceiptLog.directedJSON(receipt)
            do {
                try await SwiftNativePersistenceCore.withFileLock(settlementPath) {
                    if try await SwiftNativePersistenceCore.readJSON(settlementPath, ifMissing: .null) == receiptJSON {
                        return
                    }
                    let settlement = deskSettlement(for: record, summary: summary)
                    let desk = SwiftNativeDeskStore(dataRoot: dataRoot)
                    // Repair once under Desk's lock. A late repair of an older
                    // accepted execution must not supersede newer linked work.
                    let settled = try await SwiftNativePersistenceCore.withFileLock(desk.opsPath) {
                        guard let item = try await desk.liveState().items.first(where: { $0.handle == handle }) else { return false }
                        let linked = item.refs.compactMap { ref -> String? in
                            if case .trace(let id, "workshop_execution") = ref.kind { return id }
                            return nil
                        }
                        var latest = record
                        guard var latestDate = WorkshopOutcomeScoreboard.parseTimestamp(record.createdAt) else {
                            throw WorkshopExecutionError.persistenceFailure("Accepted execution \(record.id) has an unreadable creation timestamp")
                        }
                        for id in linked where id != record.id {
                            guard SwiftNativeWorkshopRunner.isSafeExecutionID(id) else {
                                throw WorkshopExecutionError.persistenceFailure("Linked execution id is not a safe path component")
                            }
                            let path = ExecutionRecordFile.canonicalPath(in: dataRoot.appendingPathComponent("workshop/executions/\(id)"))
                            // Creation time is immutable; atomic record reads need
                            // no execution lock while the Desk lock is held.
                            guard let other = try await ExecutionRecordFile.read(at: path).record,
                                  other.id == id else {
                                throw WorkshopExecutionError.persistenceFailure("Linked execution \(id) is unavailable; Desk association was preserved")
                            }
                            guard let date = WorkshopOutcomeScoreboard.parseTimestamp(other.createdAt) else {
                                throw WorkshopExecutionError.persistenceFailure("Linked execution \(id) is unavailable; Desk association was preserved")
                            }
                            if date > latestDate || (date == latestDate && linked.last == id) {
                                latest = other
                                latestDate = date
                            }
                        }
                        if !linked.contains(record.id) {
                            _ = try await desk.addRef(handle,
                                ref: DeskRef(kind: .trace(id: record.id, kind: "workshop_execution")))
                        }
                        return try await desk.settleWorkshopExecution(
                            handle, executionId: record.id, note: "[\(settlement.label)] \(summary)",
                            status: settlement.status, summary: settlement.summary, waitingOn: settlement.waitingOn, latestExecutionId: latest.id)
                    }
                    if settled {
                        try await SwiftNativePersistenceCore.writeJSON(receiptJSON, to: settlementPath)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "Workshop Desk settlement failed for \(record.id): \(error)\n".utf8))
            }
        }
    }

    private static func terminalSummary(_ record: WorkshopExecutionRecord, reason: String?) -> String {
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            return String(reason.prefix(600))
        }
        switch record.result {
        case .string(let value) where !value.isEmpty:
            return String(value.prefix(600))
        default:
            return "Workshop task \(record.status) after \(record.stepsCompleted.count)/\(record.plan.count) steps."
        }
    }

    /// Execution state and verification jointly determine Desk state and its evidence.
    private static func deskSettlement(for record: WorkshopExecutionRecord, summary: String)
        -> (status: DeskStatus, label: String, summary: String, waitingOn: String?) {
        switch (record.status.lowercased(), record.verification?.status) {
        case let (_, verification) where record.isSuccessful:
            if verification == .satisfied { return (.done, "completed", summary, nil) }
            // Only a declared postcondition that failed keeps a finished run from closing.
            let held: String
            if let detail = record.verification?.detail, !detail.isEmpty {
                held = "Workshop finished but remains unverified: \(String(detail.prefix(480)))"
            } else { held = "Workshop finished without an exact verification record." }
            if verification == .failed { return (.blocked, "verification_failed", held, "domain verification") }
            return (.done, "execution_completed_unverified", held, nil)
        case ("cancelled", _), ("canceled", _), ("stopped", _):
            return (.canceled, record.status, summary, nil)
        default:
            return (.blocked, record.status, summary, nil)
        }
    }
}
