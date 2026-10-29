import Privacy
import SwarmRuns
import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TrustCenter

// Blueprint: | `WorkshopExecution+Runner.swift` | SwiftNativeWorkshopRunner canonical execution.json ownership, safe execution IDs, queue admission, planning, cancellation and timeline receipts |

// MARK: - SwiftNative impl

public actor SwiftNativeWorkshopRunner {
    private let root: URL
    private let planner: any WorkshopPlannerLLM
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> String
    private static let logger = ModuleLog(subsystem: "com.nativeagent.workshop", category: "runner")

    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        planner: (any WorkshopPlannerLLM)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.root = root
        self.planner = planner ?? StubWorkshopPlannerLLM()
        self.now = now
        self.uuid = uuid
    }

    public nonisolated var executionRecordsRoot: URL {
        root
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
    }

    public nonisolated func workshopExecutionDir(_ id: String) -> URL {
        executionRecordsRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The sole live record: execution.json. Legacy files stay untouched.
    public nonisolated func executionRecordPath(_ id: String) -> URL {
        ExecutionRecordFile.canonicalPath(in: workshopExecutionDir(id))
    }

    public nonisolated func timelinePath(_ id: String) -> URL {
        ExecutionRecordFile.timelinePath(in: workshopExecutionDir(id))
    }

    public nonisolated func receiptsDir(_ id: String) -> URL {
        ExecutionRecordFile.receiptsPath(in: workshopExecutionDir(id))
    }

    /// Execution ids are persisted as directory names. Keep every public
    /// lookup/mutation rooted to one canonical directory component.
    /// Record readers also require the stored id to equal that component;
    /// payload identity must never redirect execution or receipt ownership.
    nonisolated static func isSafeExecutionID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.contains("\0")
    }

    /// Activity feed at `<root>/activity/events.jsonl`.
    nonisolated var activityPath: URL {
        SwiftNativePersistenceCore.activityEventsPath(dataRoot: root)
    }

    /// Read checked Trust authority before submission; damaged saved policy
    /// refuses work. A missing store receives the owner's bootstrap defaults.
    private func workshopExecutionsAllowed() async throws -> Bool {
        // Reuse the authority owner's checked read: only a missing file may
        // bootstrap. A damaged saved policy is unavailable, not permission to
        // submit work or fall through to a legacy update path. The checked
        // projection preserves valid saved Workshop/Developer Mode values.
        let trust = SwiftNativeTrustCenter(dataRoot: root, clock: now)
        do {
            return Self.workshopPolicyAllows(try await trust.loadTrustPolicyChecked())
        } catch {
            throw WorkshopExecutionError.persistenceFailure(
                "saved trust policy is unavailable: \(error)"
            )
        }
    }

    /// Shared policy: truthy developerMode allows; absent block/enabled allows; malformed blocks deny; otherwise use enabled's truthiness.
    public static func workshopPolicyAllows(_ policy: [String: JSONValue]) -> Bool {
        if policy["developerMode"]?.isTruthy == true { return true }
        // Read both workshopPolicy and the persisted missionPolicy spelling through the shared vocabulary.
        let mpRaw = WorkshopPolicyBlockVocabulary.block(policy)
        if mpRaw == nil {
            return true   // missionPolicy absent → merged default enabled=true
        }
        guard case .object(let mp)? = mpRaw else {
            return false  // missionPolicy present but malformed → deny
        }
        guard let enabled = mp["enabled"] else {
            return true   // enabled key absent → merged default enabled=true
        }
        return enabled.isTruthy
    }

    /// Admission capacity is max-active + max-pending (defaults 3 + 32), counting queued, running and approval-blocked work.
    private static func workshopExecutionSlotsCap() throws -> Int {
        // Persisted ..._MISSIONS environment names retain precedence over ..._EXECUTIONS through ExecutionEnvVocabulary.
        let active = WorkshopExecutorLoop.defaultMaxActive()
        let pending = max(0, Int(
            ExecutionEnvVocabulary.value(canonical: "NATIVE_AGENT_MAX_PENDING_EXECUTIONS") ?? ""
        ) ?? 32)
        let capacity = active.addingReportingOverflow(pending)
        guard !capacity.overflow else {
            throw WorkshopExecutionError.invalidRequest("Workshop active and pending execution capacity exceeds the supported integer range; correct NATIVE_AGENT_MAX_PENDING_EXECUTIONS")
        }
        return capacity.partialValue
    }

    /// Refuse a full queue or unreadable capacity evidence before admitting work.
    private func assertSlotAvailable() async throws {
        let cap = try Self.workshopExecutionSlotsCap()
        let active = Self.activeRecords(try await scanAllQueueWorkshopExecutionsChecked().map(\.record))
        if let corrupt = active.first(where: { $0.status == "corrupt" }) {
            throw WorkshopExecutionError.persistenceFailure(String(describing: corrupt.result))
        }
        let activeCount = active.count + (try liveReservationCount())
        if activeCount >= cap {
            // Preserve the serialized busy reason.
            throw WorkshopExecutionError.workshopExecutionsBusy("missions_busy: too many active or pending Workshop executions")
        }
    }

    /// In-flight submit reservations: queue subdirs holding `.reserved` with
    /// no execution.json yet. Each occupies a slot so concurrent submitters
    /// can't overshoot the cap between admission and the durable write.
    /// Age-out: a reservation older than 10 minutes is a crashed submit
    /// (planning happens BEFORE reservation; only file IO remains) — ignore
    /// it rather than leak the slot forever.
    private nonisolated func liveReservationCount() throws -> Int {
        let fm = FileManager.default
        let subdirs = try fm.contentsOfDirectory(
            at: executionRecordsRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var count = 0
        for dir in subdirs {
            let marker = dir.appendingPathComponent(".reserved")
            guard fm.fileExists(atPath: marker.path),
                  !ExecutionRecordFile.exists(in: dir, fileManager: fm) else {
                continue
            }
            let mtime = (try marker.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if Date().timeIntervalSince(mtime) < 600 { count += 1 }
        }
        return count
    }

    /// Append the canonical Activity event under its file lock, redacting title/detail text and payload recursively.
    private func recordActivity(
        kind: String,
        title: String,
        detail: String = "",
        status: String,
        executionId: String?,
        payload: JSONValue
    ) async {
        let event = SwiftNativePersistenceCore.activityEvent(
            id: uuid(),
            kind: kind,
            title: NativeAgentSecretRedactor.redactText(title),
            detail: NativeAgentSecretRedactor.redactText(detail),
            status: status,
            executionId: executionId,
            payload: NativeAgentSecretRedactor.redactValue(payload),
            createdAt: Self.isoTimestamp(now())
        )
        do {
            try await SwiftNativePersistenceCore.appendActivityEvent(
                event, to: activityPath, logLabel: "Workshop"
            )
        } catch {
            // An Activity failure cannot unwind an already durable execution write.
            Self.logger("record_activity append failed: \(String(describing: error))", level: .info)
        }
    }

    private func planningInput(_ spec: WorkshopExecutionSpec) -> JSONValue {
        var input: [String: JSONValue] = ["text": .string(String(spec.objective.prefix(2000))), "context": .string(String(spec.title.prefix(160)))]
        if let handle = spec.deskHandle { input["desk_handle"] = .string(handle) }
        if let outputs = spec.expectedOutputs { input["expected_outputs"] = .array(outputs.map(JSONValue.string)) }
        return .object(input)
    }

    private func planningFailure(_ error: Error, spec: WorkshopExecutionSpec) -> ToolFailureError {
        ToolFailureError("Workshop planner failed; no substitute plan was queued: \(error.localizedDescription)",
            effects: .none, nextCall: ToolFailureError.call("app", ["action": .string("workshop.submit"), "args": planningInput(spec)]))
    }

    // MARK: submit

    public func submit(spec: WorkshopExecutionSpec) async throws -> WorkshopExecutionEnqueueResult {
        try Task.checkCancellation()
        let lifeID = try DataRootLife.current(in: root)

        // Check Trust before objective validation so disabled work always reports forbidden.
        guard try await workshopExecutionsAllowed() else {
            throw WorkshopExecutionError.forbidden("Workshop execution is disabled by trust policy")
        }

        let trimmed = spec.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("missing_objective")
        }

        let id = uuid()
        guard Self.isSafeExecutionID(id) else {
            throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
        }
        try FileManager.default.createDirectory(at: executionRecordsRoot, withIntermediateDirectories: true)
        let admissionLock = executionRecordsRoot.appendingPathComponent(".admission")
        let prior = try await SwiftNativePersistenceCore.withFileLock(admissionLock) { [self] in
            try await getWorkshopExecution(id)
        }
        if let prior {
            return WorkshopExecutionEnqueueResult(status: prior.status, executionId: id, record: prior)
        }
        try await assertSlotAvailable()

        // Build the Workshop execution record.
        let titleTrunc = String(spec.title.prefix(160))
        let objectiveTrunc = String(spec.objective.prefix(2000))
        let nowStr = Self.isoTimestamp(now())

        let plan: (steps: [WorkshopExecutionStep], providerCallCount: Int?, binding: WorkshopCompiledFileCopyBinding?)
        do {
            plan = try await planner.plan(
                spec: WorkshopExecutionSpec(
                    title: titleTrunc,
                    objective: objectiveTrunc,
                    triggerSource: spec.triggerSource,
                    trustRequired: spec.trustRequired,
                    deskHandle: spec.deskHandle,
                    projectSpaceId: spec.projectSpaceId,
                    expectedOutputs: spec.expectedOutputs
                ), dataRoot: root, now: now()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ToolFailureError {
            throw error
        } catch {
            throw planningFailure(error, spec: spec)
        }

        // Reject cancellation after planning and before persisting work.
        try Task.checkCancellation()

        // Recheck capacity and reserve under the admission lock; planning stays outside it and executor claims use their own lock.
        let existing = try await SwiftNativePersistenceCore.withFileLock(admissionLock) { [self] () async throws -> WorkshopExecutionRecord? in
            if let record = try await ExecutionRecordFile.read(at: executionRecordPath(id)).record {
                guard record.id == id else {
                    throw WorkshopExecutionError.persistenceFailure("execution identity mismatch")
                }
                return record
            }
            guard !FileManager.default.fileExists(atPath: workshopExecutionDir(id).path) else {
                throw WorkshopExecutionError.invalidRequest("execution admission is already in progress")
            }
            try await assertSlotAvailable()
            // .reserved counts admission until execution.json lands; remove on success, delete the directory on failure, age out after a crash.
            try FileManager.default.createDirectory(
                at: workshopExecutionDir(id), withIntermediateDirectories: true)
            do {
                try Data("reserved \(nowStr)".utf8)
                    .write(to: workshopExecutionDir(id).appendingPathComponent(".reserved"))
            } catch {
                try? FileManager.default.removeItem(at: workshopExecutionDir(id))
                throw error
            }
            return nil
        }
        if let existing {
            return WorkshopExecutionEnqueueResult(status: existing.status, executionId: id, record: existing)
        }

        let dir = workshopExecutionDir(id)
        let receipts = receiptsDir(id)
        let timeline = timelinePath(id)
        let executionRecordJSON = executionRecordPath(id)
        // Every failure between reservation and durable execution.json frees the reserved directory.
        func freeReservationAndRethrow(_ error: Error) throws -> Never {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        var record = WorkshopExecutionRecord(
            id: id,
            lifeID: lifeID,
            deskHandle: spec.deskHandle,
            projectSpaceId: spec.projectSpaceId,
            title: titleTrunc,
            objective: objectiveTrunc,
            createdAt: nowStr,
            status: "queued",
            plan: plan.steps,
            stepsCompleted: [],
            receiptsDir: receipts.path,
            triggerSource: spec.triggerSource,
            trustRequired: spec.trustRequired,
            expectedOutputs: (spec.expectedOutputs ?? []).map(JSONValue.string),
            currentStepId: "",
            updatedAt: nowStr,
            result: .null,
            rerunCount: 0,
            planningProviderCallCount: plan.providerCallCount,
            planningRemovableOrchestrationProviderCallCount: plan.providerCallCount
        )
        do {
        if let binding = plan.binding {
            record.compiledOperationBinding = try JSONValue.parse(JSONEncoder().encode(binding))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)


        // Write the timeline first, so an interrupted enqueue has no execution record.
        let timelineEvent: JSONValue = .object([
            "event": .string("enqueued"),
            "title": .string(titleTrunc),
            "trigger_source": .string(spec.triggerSource),
            "ts": .string(nowStr),
        ])
        do {
            try await appendTimelineLocked(timelineEvent, to: timeline)
        } catch {
            throw WorkshopExecutionError.persistenceFailure("timeline append failed: \(error)")
        }
        // cancel between timeline append and execution.json write should NOT
        // land execution.json — and must free the admission reservation.
        if Task.isCancelled { throw CancellationError() }

        do {
            try await ExecutionRecordFile.write(record, to: executionRecordJSON)
        } catch {
            throw WorkshopExecutionError.persistenceFailure("execution.json write failed: \(error)")
        }
        // Reservation fulfilled — execution.json is the counted artifact now.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".reserved"))
        } catch {
            try freeReservationAndRethrow(error)
        }

        // Attempt the non-fatal Activity append after the durable write and before checking cancellation.
        await recordActivity(
            kind: "mission",
            title: "Workshop task created",
            detail: titleTrunc,
            status: "ok",
            executionId: id,
            payload: .object(["executionId": .string(id)])
        )

        try Task.checkCancellation()

        // WorkshopExecutorLoop claims queued work on its next admitted background drain.
        return WorkshopExecutionEnqueueResult(status: "queued", executionId: id, record: record)
    }

    // MARK: cancel
    //
    // Hold the execution-file lock across read, mutation and write so cancel
    // cannot race another execution mutation.
    public func cancel(executionId: String) async throws -> WorkshopExecutionRecord {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WorkshopExecutionError.invalidRequest("empty missionId")
        }
        // Execution ids become a single directory component below the
        // selected Workshop root. Refuse path syntax at the canonical owner,
        // not only at a CLI wrapper, so every cancel caller stays root-bound.
        guard Self.isSafeExecutionID(trimmed) else {
            throw WorkshopExecutionError.invalidRequest("executionId must be a single path component")
        }
        let executionRecordJSON = executionRecordPath(trimmed)
        let timeline = timelinePath(trimmed)
        let nowStr = Self.isoTimestamp(now())

        // Reject a missing execution before acquiring its lock. File-lock
        // acquisition creates the lock's parent directory on some backends;
        // without this preflight, a typo in a cancel command could leave an
        // empty Workshop execution directory and lock artifact behind.
        guard FileManager.default.fileExists(atPath: executionRecordJSON.path) else {
            throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)")
        }

        let record: WorkshopExecutionRecord
        let didCancel: Bool
        do {
            let update = try await ExecutionRecordFile.update(at: executionRecordJSON, id: trimmed) { record in
                guard !record.isTerminal else { return false }
                record.status = "cancelled"
                record.updatedAt = nowStr
                return true
            }
            guard let saved = update.record else {
                throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)")
            }
            record = saved
            didCancel = update.applied
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("cancel execution.json write failed: \(error)")
        }

        // Append the event only after the durable transition and lock release.
        if didCancel {
            let event: JSONValue = .object([
                "event": .string("cancelled"),
                "ts": .string(nowStr),
            ])
            do {
                try await appendTimelineLocked(event, to: timeline)
            } catch {
                // The durable state transition already landed; a failed
                // timeline append must not unwind the cancel. Log + proceed.
                Self.logger("cancel timeline append failed: \(String(describing: error))", level: .info)
            }
        }
        return record
    }

    private func appendTimelineLocked(_ event: JSONValue, to timeline: URL) async throws {
        try await ExecutionRecordFile.appendTimeline(event, to: timeline)
    }

    // Reads use the same on-disk layout submit() writes:
    //     <root>/workshop/executions/<id>/execution.json
    //     <root>/workshop/executions/<id>/timeline.jsonl
    // The compatibility record shape is preserved under Workshop ownership.
    // Reads remain lock-free, matching the prior behavior.

    /// `TaskQueue.get`. Reads
    /// <queue>/<id>/execution.json, returns nil when absent, malformed, or
    /// carrying an id that does not match its containing directory.
    public func getWorkshopExecution(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        guard Self.isSafeExecutionID(executionId) else { return nil }
        let record = try await ExecutionRecordFile.read(at: executionRecordPath(executionId)).record
        return record?.id == executionId ? record : nil
    }

    /// Raw single-execution projection without `timeline` (the caller attaches
    /// it); nil when absent. Keeps the plan's wire representation verbatim.
    public func getWorkshopExecutionWireJSON(_ executionId: String) async throws -> JSONValue? {
        guard Self.isSafeExecutionID(executionId) else { return nil }
        let raw = try await ExecutionRecordFile.read(at: executionRecordPath(executionId)).raw
        guard case .object(let obj) = raw,
              case .string(let gotId)? = obj["id"], gotId == executionId else {
            return nil
        }
        return raw
    }

    /// Raw timeline events retain file order; missing file → []; malformed lines skip.
    public func readTimeline(_ executionId: String) async throws -> [JSONValue] {
        guard Self.isSafeExecutionID(executionId) else {
            throw WorkshopExecutionError.invalidRequest(
                "executionId must be a single path component"
            )
        }
        return try await ExecutionRecordFile.readTimeline(at: timelinePath(executionId))
    }

    /// Queue members have execution.json; retired-only directories are excluded.
    /// Failed reads and invalid canonical records remain visible as corrupt and block admission.
    package func scanAllQueueWorkshopExecutions() async -> [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] {
        do {
            return try await scanAllQueueWorkshopExecutionsChecked()
        } catch {
            let raw: [String: JSONValue] = [
                "id": .string("queue-unavailable"),
                "title": .string("Workshop queue unavailable"),
                "status": .string("unavailable"),
                "result": .object(["error": .string(error.localizedDescription)]),
            ]
            return [(Self.recordFromJSON(raw), raw)]
        }
    }

    /// Absent canonical records are not queue members; failed reads cannot prove inactivity.
    private func scanAllQueueWorkshopExecutionsChecked() async throws -> [(record: WorkshopExecutionRecord, raw: [String: JSONValue])] {
        try await Self.readQueueRecords(dataRoot: root).compactMap { _, raw, record in
            guard case .object(let obj) = raw else { return nil }
            return (record, obj)
        }
    }

    static func readQueueRecords(dataRoot: URL) async throws -> [(id: String, raw: JSONValue, record: WorkshopExecutionRecord)] {
        let fm = FileManager.default
        let queueRoot = dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: queueRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        var out: [(id: String, raw: JSONValue, record: WorkshopExecutionRecord)] = []
        for sub in entries {
            let isDir = try sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            guard isDir else { continue }
            let mp = ExecutionRecordFile.canonicalPath(in: sub)
            let read = await Self.readQueueRecord(mp, id: sub.lastPathComponent)
            if let record = read.record { out.append((sub.lastPathComponent, read.raw, record)) }
        }
        return out
    }

    /// A read-only projection: never persist invented execution state over bad bytes.
    static func readQueueRecord(
        _ path: URL, id: String
    ) async -> (raw: JSONValue, record: WorkshopExecutionRecord?) {
        do {
            let read = try await ExecutionRecordFile.read(at: path)
            if read.raw == .null, !FileManager.default.fileExists(atPath: path.path) { return read }
            let raw = read.raw
            guard case .object(let obj) = raw else {
                throw WorkshopExecutionError.persistenceFailure("Execution record must be an object")
            }
            guard case .string(let gotId)? = obj["id"], gotId == id else {
                throw WorkshopExecutionError.persistenceFailure("Execution record id must match its directory: \(id)")
            }
            return read
        } catch {
            let diagnostic: [String: JSONValue] = [
                "id": .string(id),
                "title": .string(id),
                "status": .string("corrupt"),
                "result": .object(["error": .string(error.localizedDescription)]),
            ]
            return (.object(diagnostic), Self.recordFromJSON(diagnostic))
        }
    }

    /// `TaskQueue.list_all`: all queue Workshop executions sorted
    /// by created_at DESC.
    public func listAll() async -> [WorkshopExecutionRecord] {
        await scanAllQueueWorkshopExecutions().sorted { $0.record.createdAt > $1.record.createdAt }.map(\.record)
    }

    /// One observed set for the status tool's active/recent sections. Each
    /// record is read once, so a transition cannot put that record in both
    /// sections. This is not an atomic cross-record snapshot: independent
    /// executions can still change while the directory scan is in progress.
    public func listStatusSnapshot() async -> (active: [WorkshopExecutionRecord], recent: [WorkshopExecutionRecord]) {
        let records = await scanAllQueueWorkshopExecutions().map(\.record)
        return (Self.activeRecords(records), Self.recentRecords(records))
    }

    private nonisolated static func activeRecords(_ records: [WorkshopExecutionRecord]) -> [WorkshopExecutionRecord] {
        let live: Set<String> = ["queued", "running", "blocked_on_approval", "blocked_on_reconciliation", "corrupt", "unavailable"]
        return records.filter { live.contains($0.status) }
    }

    private nonisolated static func recentRecords(_ records: [WorkshopExecutionRecord]) -> [WorkshopExecutionRecord] {
        let filtered = records.filter(\.isTerminal)
        return Array(filtered.sorted { $0.updatedAt > $1.updatedAt }.prefix(20))
    }

    /// Canonical queue records, sorted by creation time; retired flat history is untouched.
    public func listWorkshopExecutions() async throws -> [JSONValue] {
        // Checked records preserve the canonical wire representation, including diagnostic defaults.
        let queue = try await scanAllQueueWorkshopExecutionsChecked()
            .sorted { $0.record.createdAt > $1.record.createdAt }
            .map { $0.record.toJSON() }
        return queue
    }

    /// Same shape as TriggerScheduler.isoTimestamp.
    public static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }
}
