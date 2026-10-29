import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `Browser+OperationStore.swift` | SwiftNativeBrowserClient's checked run-array schema, lifecycle writes and terminal vocabulary shared by reconciliation; derived receipts use appendPathOwnedJSONL, transition traces use TurnTracePersistLane with checked deduplication; local backup/export/raw phone sync excluded, PrivacyMap lists Browser Runs |

/// Canonical Browser lifecycle commands. WebKit/AppKit remain effect adapters;
/// every durable lifecycle transition enters through this boundary.
/// runs.json is the browser's JSON operation array, deliberately excluded from
/// local backup, export and phone sync; PrivacyMap lists Browser Runs.
public enum BrowserOperationInitialState: String, Sendable {
    case dryRun = "dry_run"
    case waitingApproval = "waiting_approval"
    case running
}

public enum BrowserOperationTerminalState: String, Sendable {
    case succeeded
    case failed
    case denied
    case canceled
}

public struct BrowserOperationStart: Sendable {
    public let id: String
    public let url: String
    public let domain: String
    public let initialState: BrowserOperationInitialState
    public let approvalId: String?
    public let captureSource: Bool
    public let captureScreenshot: Bool
    public let deadlineSeconds: Int?

    public init(
        id: String,
        url: String,
        domain: String,
        initialState: BrowserOperationInitialState,
        approvalId: String? = nil,
        captureSource: Bool = false,
        captureScreenshot: Bool = false,
        deadlineSeconds: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.domain = domain
        self.initialState = initialState
        self.approvalId = approvalId
        self.captureSource = captureSource
        self.captureScreenshot = captureScreenshot
        self.deadlineSeconds = deadlineSeconds
    }
}

public struct BrowserOperationCompletion: Sendable {
    public let id: String
    public let requestDigest: String
    public let state: BrowserOperationTerminalState
    public let opened: Bool
    public let sourceReceipt: JSONValue
    public let screenshotReceipt: JSONValue

    public init(
        id: String,
        requestDigest: String,
        state: BrowserOperationTerminalState,
        opened: Bool,
        sourceReceipt: JSONValue = .null,
        screenshotReceipt: JSONValue = .null
    ) {
        self.id = id
        self.requestDigest = requestDigest
        self.state = state
        self.opened = opened
        self.sourceReceipt = sourceReceipt
        self.screenshotReceipt = screenshotReceipt
    }
}

public enum BrowserOperationCommand: Sendable {
    case start(BrowserOperationStart)
    case complete(BrowserOperationCompletion)
    case cancel(id: String?)
    case recoverStrandedRunning
}

public struct BrowserOperationCommandResult: Sendable {
    public let run: JSONValue?
    public let didTransition: Bool
    public let recoveredCount: Int

    public init(run: JSONValue?, didTransition: Bool, recoveredCount: Int = 0) {
        self.run = run
        self.didTransition = didTransition
        self.recoveredCount = recoveredCount
    }
}

public enum BrowserOperationStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidIdentity
    case invalidURL
    case invalidDomain
    case invalidDeadline
    case invalidRequestDigest
    case conflictingIdempotencyKey
    case runNotFound
    case invalidTransition
    case corruptRunsDocument
    case invalidTransitionMetadata(runID: String)
    case capacityExceeded

    public var errorDescription: String? {
        if case .invalidTransitionMetadata(let runID) = self {
            return "Browser run \(runID) has invalid or exhausted transition metadata; canonical bytes retained."
        }
        return nil
    }
}

/// Cancellation committed even though its derived receipt could not be written.
public struct BrowserCancellationProjectionError: Error, LocalizedError {
    public let run: JSONValue
    public let underlyingError: any Error
    public var errorDescription: String? { underlyingError.localizedDescription }
}

private struct PendingBrowserReceipt: Sendable {
    let runID: String
    let projectionID: String
    let publicRun: JSONValue
}

extension SwiftNativeBrowserClient {
    /// Stable identity for one operation request. This binds idempotency to the
    /// requested effect without exposing URL/domain in shared motor projections.
    public static func browserRequestDigest(for start: BrowserOperationStart) -> String {
        CausalTransitionEvidence.opaqueIdentity([
            "browser.open_url",
            start.url,
            start.domain.lowercased(),
            start.initialState.rawValue,
            "visible",
            start.approvalId ?? "no-approval",
            start.captureSource ? "source" : "no-source",
            start.captureScreenshot ? "screenshot" : "no-screenshot",
            String(start.deadlineSeconds ?? 0),
        ].joined(separator: "|"))
    }

    /// Sole canonical Browser command boundary. The runs row is committed
    /// first under one lock; receipt/trace feeds are idempotent derived
    /// projections and can be resumed after a crash. A running start returns
    /// its committed claim before projecting; its effect owner must receive
    /// that claim and install settlement even when an older feed is damaged.
    public func executeBrowserOperation(
        _ command: BrowserOperationCommand
    ) async throws -> BrowserOperationCommandResult {
        let result: BrowserOperationCommandResult
        switch command {
        case .start(let request):
            result = try await commitStart(request)
            // Running rows have no start receipt. Terminal settlement drains
            // pending projections and reports any derived-feed failures then.
            if request.initialState == .running { return result }
        case .complete(let completion):
            result = try await commitCompletion(completion)
        case .cancel(let requestedID):
            result = try await commitCancel(requestedID: requestedID)
        case .recoverStrandedRunning:
            result = try await recoverStrandedRunning()
        }
        do {
            try await projectPendingBrowserReceipts()
        } catch {
            if case .cancel = command, let run = result.run,
               run.objectValue?["status"]?.stringValue == "canceled" {
                throw BrowserCancellationProjectionError(run: run, underlyingError: error)
            }
            throw error
        }
        return result
    }

    private func commitStart(
        _ request: BrowserOperationStart
    ) async throws -> BrowserOperationCommandResult {
        let identity = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty, identity.utf8.count <= 200 else {
            throw BrowserOperationStoreError.invalidIdentity
        }
        guard let parsed = try? BrowserActionRoutes.ValidBrowserURL(request.url) else {
            throw BrowserOperationStoreError.invalidURL
        }
        let domain = request.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, domain.utf8.count <= 253, domain == parsed.domain else {
            throw BrowserOperationStoreError.invalidDomain
        }
        if let deadline = request.deadlineSeconds, !(1...86_400).contains(deadline) {
            throw BrowserOperationStoreError.invalidDeadline
        }
        let digest = Self.browserRequestDigest(for: request)
        let timestamp = Self.nowISO(now())

        return try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            if let index = rows.firstIndex(where: { $0.objectValue?["id"]?.stringValue == identity }) {
                guard rows[index].objectValue?["requestDigest"]?.stringValue == digest else {
                    throw BrowserOperationStoreError.conflictingIdempotencyKey
                }
                return BrowserOperationCommandResult(run: Self.externalRun(rows[index]), didTransition: false)
            }

            var row: [String: JSONValue] = [
                "id": .string(identity),
                "url": .string(request.url),
                "domain": .string(domain),
                "status": .string(request.initialState.rawValue),
                "dryRun": .bool(request.initialState == .dryRun),
                "visible": .bool(true),
                "opened": .bool(false),
                "approvalId": request.approvalId.map(JSONValue.string) ?? .null,
                "sourceReceipt": request.captureSource
                    ? .object(["url": .string(request.url), "captureSource": .bool(true)])
                    : .null,
                "screenshotReceipt": .null,
                "createdAt": .string(timestamp),
                "updatedAt": .string(timestamp),
                "requestDigest": .string(digest),
                "verificationStatus": .string(
                    request.initialState == .running ? "pending" : "not_required"
                ),
            ]
            if let seconds = request.deadlineSeconds, request.initialState == .running {
                row["deadlineSeconds"] = .int(Int64(seconds))
                row["deadlineAt"] = .string(Self.nowISO(now().addingTimeInterval(TimeInterval(seconds))))
            }
            if request.initialState == .dryRun {
                try Self.stageProjection(on: &row, status: request.initialState.rawValue, at: timestamp)
            }
            let canonical = JSONValue.object(row)
            rows.append(canonical)
            rows = try Self.prunedCanonicalRuns(rows)
            try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: self.runsPath)
            return BrowserOperationCommandResult(run: Self.externalRun(canonical), didTransition: true)
        }
    }

    private func commitCompletion(
        _ completion: BrowserOperationCompletion
    ) async throws -> BrowserOperationCommandResult {
        guard !completion.requestDigest.isEmpty else {
            throw BrowserOperationStoreError.invalidRequestDigest
        }
        let timestamp = Self.nowISO(now())
        return try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            guard let index = rows.firstIndex(where: { $0.objectValue?["id"]?.stringValue == completion.id }),
                  case .object(var row) = rows[index] else {
                throw BrowserOperationStoreError.runNotFound
            }
            guard rows[index].objectValue?["requestDigest"]?.stringValue == completion.requestDigest else {
                throw BrowserOperationStoreError.conflictingIdempotencyKey
            }
            let current = rows[index].objectValue?["status"]?.stringValue ?? ""
            let cancelPending = current == "canceled" && row["completedAt"] == nil
            if Self.terminalStatuses.contains(current), !cancelPending {
                return BrowserOperationCommandResult(run: Self.externalRun(rows[index]), didTransition: false)
            }
            guard current == "running" || current == "waiting_approval" || cancelPending else {
                throw BrowserOperationStoreError.invalidTransition
            }

            let state: BrowserOperationTerminalState = cancelPending ? .canceled : completion.state
            row["status"] = .string(state.rawValue)
            row["opened"] = .bool(completion.opened)
            row["sourceReceipt"] = completion.sourceReceipt
            row["screenshotReceipt"] = completion.screenshotReceipt
            if case .object(let receipt) = completion.sourceReceipt,
               receipt["outcomeKind"] == .string("outcome_unknown") {
                row["outcomeKind"] = .string("outcome_unknown")
                if !completion.opened { row["opened"] = .null }
            }
            row["updatedAt"] = .string(timestamp)
            row["completedAt"] = .string(timestamp)
            row["verificationStatus"] = .string(
                state == .succeeded && completion.opened ? "satisfied"
                    : state == .failed ? "failed" : "not_required"
            )
            if state == .canceled {
                row["canceledAt"] = .string(timestamp)
            } else if completion.state == .denied {
                row["deniedAt"] = .string(timestamp)
            }
            row.removeValue(forKey: "deadlineAt")
            try Self.stageProjection(on: &row, status: state.rawValue, at: timestamp)
            rows[index] = .object(row)
            try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: self.runsPath)
            return BrowserOperationCommandResult(run: Self.externalRun(rows[index]), didTransition: true)
        }
    }

    private func commitCancel(requestedID: String?) async throws -> BrowserOperationCommandResult {
        let timestamp = Self.nowISO(now())
        let normalized = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            let index = rows.firstIndex { candidate in
                let identityMatches = normalized == nil || normalized?.isEmpty == true
                    || candidate.objectValue?["id"]?.stringValue == normalized
                guard identityMatches else { return false }
                let status = candidate.objectValue?["status"]?.stringValue ?? ""
                return status == "running" || status == "waiting_approval" || status == "dry_run"
            }
            guard let index, case .object(var row) = rows[index] else {
                let notFound: JSONValue = .object([
                    "id": normalized.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null,
                    "status": .string("not_found"),
                    "createdAt": .string(timestamp),
                ])
                return BrowserOperationCommandResult(run: notFound, didTransition: false)
            }
            let executing = rows[index].objectValue?["status"]?.stringValue == "running"
            row["status"] = .string("canceled")
            row["canceledAt"] = .string(timestamp)
            row["updatedAt"] = .string(timestamp)
            row["verificationStatus"] = .string("not_required")
            row.removeValue(forKey: "deadlineAt")
            // An executing owner still owes its evidence and one terminal
            // projection. A request cannot claim that nothing opened.
            if executing { row["opened"] = .null }
            if !executing {
                row["completedAt"] = .string(timestamp)
                try Self.stageProjection(on: &row, status: "canceled", at: timestamp)
            }
            rows[index] = .object(row)
            try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: self.runsPath)
            return BrowserOperationCommandResult(run: Self.externalRun(rows[index]), didTransition: true)
        }
    }

    private func recoverStrandedRunning() async throws -> BrowserOperationCommandResult {
        let currentDate = now()
        let timestamp = Self.nowISO(currentDate)
        return try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            var recovered = 0
            var last: JSONValue?
            for index in rows.indices {
                // This command is a launch/restart assertion: no process-local
                // WebKit task can survive it. Any persisted running row is
                // therefore stranded even when its wall-clock deadline has not
                // elapsed. Never reopen an outcome-unknown external effect.
                let status = rows[index].objectValue?["status"]?.stringValue
                guard status == "running" || (status == "canceled" && rows[index].objectValue?["completedAt"]?.stringValue == nil),
                      case .object(var row) = rows[index] else { continue }
                let terminal = status == "canceled" ? "canceled" : "failed"
                row["status"] = .string(terminal)
                row["opened"] = .null
                row["errorCode"] = .string("restart_stranded_running")
                row["outcomeKind"] = .string("outcome_unknown")
                row["verificationStatus"] = .string("failed")
                row["completedAt"] = .string(timestamp)
                row["updatedAt"] = .string(timestamp)
                row.removeValue(forKey: "deadlineAt")
                try Self.stageProjection(on: &row, status: terminal, at: timestamp)
                rows[index] = .object(row)
                last = rows[index]
                recovered += 1
            }
            if recovered > 0 {
                try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: self.runsPath)
            }
            return BrowserOperationCommandResult(
                run: last.map(Self.externalRun),
                didTransition: recovered > 0,
                recoveredCount: recovered
            )
        }
    }

    /// Resumes receipt/trace projection from canonical pending transition IDs.
    /// Feeds and traces land before one checkpoint removes only the captured IDs.
    private func projectPendingBrowserReceipts() async throws {
        let pending: [PendingBrowserReceipt] = try await withCanonicalRunsLock {
            try await self.readCanonicalRuns().flatMap(Self.pendingProjections)
        }
        guard !pending.isEmpty else { return }
        try await appendDerivedOnce(pending, to: receiptsPath, label: "Browser.receipts") { projection in
            var receipt = (projection.publicRun.objectValue ?? [:])
            receipt["transitionId"] = .string(projection.projectionID)
            return .object(receipt)
        }
        try await appendDerivedOnce(pending, to: nativeActionsReceiptsPath, label: "Browser.actionReceipts") { projection in
            let run = projection.publicRun
            return .object([
                "id": .string(projection.runID), "transitionId": .string(projection.projectionID),
                "actionId": .string("browser.open_url"), "name": .string("Visible Browser URL"),
                "kind": .string("browser"), "status": .string(run.objectValue?["status"]?.stringValue ?? "unknown"),
                "dryRun": .bool(run.objectValue?["dryRun"]?.boolValue ?? false),
                "approvalId": run.objectValue?["approvalId"]?.stringValue.map(JSONValue.string) ?? .null,
                "output": run, "createdAt": .string(run.objectValue?["createdAt"]?.stringValue ?? Self.nowISO(self.now())),
            ])
        }
        for projection in pending {
            let publicRun = projection.publicRun
            let status = publicRun.objectValue?["status"]?.stringValue ?? "unknown"
            let createdAt = publicRun.objectValue?["createdAt"]?.stringValue ?? Self.nowISO(now())
            let domain = publicRun.objectValue?["domain"]?.stringValue ?? "browser"
            let url = publicRun.objectValue?["url"]?.stringValue ?? ""
            let dryRun = publicRun.objectValue?["dryRun"]?.boolValue ?? false

            try await TurnTracePersistLane(standalonePath: tracesPath).appendChecked(
                TurnTraceEvent(kind: "browser.action", title: domain, status: status, payload: .object([
                    "url": .string(url),
                    "status": .string(status),
                    "dryRun": .bool(dryRun),
                ]), id: projection.projectionID, createdAt: createdAt), transitionId: projection.projectionID)
        }
        let projected = Set(pending.map(\.projectionID))
        try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            for index in rows.indices {
                guard case .object(var object) = rows[index],
                      case .array(let entries)? = object["projectionOutbox"] else { continue }
                let remaining = entries.filter { !projected.contains($0.objectValue?["id"]?.stringValue ?? "") }
                guard remaining.count != entries.count else { continue }
                if remaining.isEmpty { object.removeValue(forKey: "projectionOutbox") }
                else { object["projectionOutbox"] = .array(remaining) }
                rows[index] = .object(object)
            }
            try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: self.runsPath)
        }
    }

    private func appendDerivedOnce(
        _ pending: [PendingBrowserReceipt],
        to path: URL,
        label: String,
        value: @escaping @Sendable (PendingBrowserReceipt) -> JSONValue
    ) async throws {
        guard !pending.isEmpty else { return }
        let work: @Sendable () async throws -> Void = {
            // A missing feed is empty; unreadable or malformed evidence cannot
            // establish that an append-before-checkpoint transition is absent.
            let read = try await SwiftNativePersistenceCore.tailJSONLReadReceipt(
                path, limit: JSONLLineCaps.actionReceipts, maxBytes: nil
            )
            guard read.malformedJSONRowCount == 0, !read.truncatedToByteWindow,
                  read.rows.allSatisfy({ if case .object = $0 { return true }; return false }),
                  read.physicalRowsScanned > 0 || read.bytesRead == 0 else {
                throw PersistenceCoreError.ioFailure("Browser projection cannot deduplicate \(path.path): its receipt feed is malformed or incomplete; existing bytes retained.")
            }
            var seen = Set(read.rows.compactMap { $0.objectValue?["transitionId"]?.stringValue })
            for projection in pending where !seen.contains(projection.projectionID) {
                try await appendPathOwnedJSONL(value(projection), to: path, logLabel: label)
                seen.insert(projection.projectionID)
            }
        }
        try await SwiftNativePersistenceCore.withFileLock(path, work)
    }

    private func readCanonicalRuns() async throws -> [JSONValue] {
        try await Self.readCanonicalRuns(at: runsPath)
    }

    static func readCanonicalRuns(
        at runsPath: URL, malformed: any Error = BrowserOperationStoreError.corruptRunsDocument
    ) async throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: runsPath.path) else { return [] }
        let raw = try await SwiftNativePersistenceCore.readJSON(runsPath, ifMissing: .null)
        guard case .array(let rows) = raw,
              rows.allSatisfy({
                  if case .object(let row) = $0, case .string? = row["status"] { return true }
                  return false
              }) else {
            throw malformed
        }
        for case .object(let row) in rows {
            // Missing counters belong to pre-counter rows. Present metadata
            // must leave room for the next transition; preserve bad bytes.
            guard let value = row["transitionSequence"] else { continue }
            guard case .int(let sequence) = value, sequence >= 0, sequence < Int64.max else {
                throw BrowserOperationStoreError.invalidTransitionMetadata(
                    runID: row["id"]?.stringValue ?? "<missing id>")
            }
        }
        return rows.map { value in
            guard case .object(var row) = value else { return value }
            if row["projectionOutbox"] == nil, value.objectValue?["projectionState"]?.stringValue == "pending",
               let id = value.objectValue?["projectionId"]?.stringValue {
                row["projectionOutbox"] = .array([.object(["id": .string(id), "run": externalRun(value)])])
            }
            for key in ["projectionId", "projectionState", "projectedAt"] { row.removeValue(forKey: key) }
            return .object(row)
        }
    }

    package static func terminalRun(id: String, at path: URL) async throws -> JSONValue? {
        guard !id.isEmpty else { return nil }
        let rows = try await readCanonicalRuns(at: path)
        guard let row = rows.first(where: { $0.objectValue?["id"]?.stringValue == id }),
              let status = row.objectValue?["status"]?.stringValue, terminalStatuses.contains(status),
              status != "canceled" || row.objectValue?["completedAt"]?.stringValue != nil else { return nil }
        return row
    }

    private func withCanonicalRunsLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Every persistence conformer uses the same path lock.
        return try await SwiftNativePersistenceCore.withFileLock(runsPath, operation)
    }

    private static let terminalStatuses: Set<String> = [
        "succeeded", "failed", "denied", "canceled", "cancelled",
    ]

    /// A dry run remains cancellable for compatibility, but it has no live
    /// external effect and is safe to evict at the bounded-history edge once
    /// its derived projections have landed.
    private static let evictableStatuses = terminalStatuses.union(["dry_run"])

    private static func stageProjection(
        on row: inout [String: JSONValue], status: String, at timestamp: String
    ) throws {
        let runID = row["id"]?.stringValue ?? "browser"
        let sequence: Int64
        if let value = row["transitionSequence"] {
            guard case .int(let previous) = value, previous >= 0 else {
                throw BrowserOperationStoreError.invalidTransitionMetadata(runID: runID)
            }
            let (next, overflow) = previous.addingReportingOverflow(1)
            guard !overflow, next < Int64.max else {
                throw BrowserOperationStoreError.invalidTransitionMetadata(runID: runID)
            }
            sequence = next
        } else {
            sequence = 1
        }
        row["transitionSequence"] = .int(sequence)
        let projectionID = CausalTransitionEvidence.opaqueIdentity(
            "browser|\(runID)|\(sequence)|\(status)|\(timestamp)"
        )
        // The outbox stores the transition snapshot, not a pointer back to the
        // mutable run row. A later cancel can therefore append its own
        // transition without rewriting evidence that has not projected yet.
        let snapshot = externalRun(.object(row))
        var outbox: [JSONValue]
        if case .array(let existing)? = row["projectionOutbox"] {
            outbox = existing
        } else {
            outbox = []
        }
        outbox.append(.object([
            "id": .string(projectionID),
            "run": snapshot,
        ]))
        row["projectionOutbox"] = .array(outbox)
    }

    private static func pendingProjections(_ row: JSONValue) -> [PendingBrowserReceipt] {
        let runID = row.objectValue?["id"]?.stringValue ?? "browser"
        if case .object(let object) = row,
           case .array(let outbox)? = object["projectionOutbox"] {
            return outbox.compactMap { entry in
                guard let id = entry.objectValue?["id"]?.stringValue,
                      case .object(let fields) = entry,
                      let snapshot = fields["run"] else { return nil }
                return PendingBrowserReceipt(
                    runID: runID,
                    projectionID: id,
                    publicRun: externalRun(snapshot)
                )
            }
        }
        return []
    }

    private static func prunedCanonicalRuns(_ rows: [JSONValue]) throws -> [JSONValue] {
        guard rows.count > 200 else { return rows }
        var overflow = rows.count - 200
        var retained: [JSONValue] = []
        retained.reserveCapacity(min(rows.count, 200))
        for row in rows {
            let status = row.objectValue?["status"]?.stringValue ?? ""
            let isEvictable = evictableStatuses.contains(status)
                && (status != "canceled" || row.objectValue?["completedAt"]?.stringValue != nil)
            let hasPendingProjection = !pendingProjections(row).isEmpty
            if overflow > 0, isEvictable, !hasPendingProjection {
                overflow -= 1
                continue
            }
            retained.append(row)
        }
        guard overflow == 0 else { throw BrowserOperationStoreError.capacityExceeded }
        return retained
    }

    private static func externalRun(_ value: JSONValue) -> JSONValue {
        var object = (value.objectValue ?? [:])
        object.removeValue(forKey: "projectionState")
        object.removeValue(forKey: "projectionId")
        object.removeValue(forKey: "projectedAt")
        object.removeValue(forKey: "transitionSequence")
        object.removeValue(forKey: "projectionOutbox")
        return .object(object)
    }

}
