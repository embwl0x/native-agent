import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import NativeAgentShared
import Synchronization
// Blueprint: | `Browser+OperationStore.swift` | Canonical run/outbox owner with row-scoped validation, byte-preserved damaged rows and owner-scoped recovery admission; checked transition projections; local backup/export/raw phone sync excluded, PrivacyMap lists Browser Runs |

/// Canonical Browser lifecycle commands. WebKit/AppKit remain effect adapters;
/// every durable lifecycle transition enters through this boundary.
/// runs.json is the browser's JSON operation array, deliberately excluded from
/// local backup, export and phone sync; PrivacyMap lists Browser Runs.
public enum BrowserOperationInitialState: String, Sendable {
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
    case invalidCanonicalRun(runID: String, field: String)
    case capacityExceeded
    case recoveryUnavailable(String)

    public var errorDescription: String? {
        if case .recoveryUnavailable(let cause) = self {
            return "browser_operation_recovery_unavailable: Browser actions are unavailable: \(cause). Preserve and repair native_power/browser/runs.json and the named projection feed under the app data root, reconcile unknown effects by observing the existing page, then restart NativeAgent to recover. Do not reopen an uncertain URL; other surfaces remain available."
        }
        if case .corruptRunsDocument = self {
            return "The canonical browser runs document is unreadable or is not an array; original bytes retained."
        }
        if case .invalidCanonicalRun(let runID, let field) = self {
            return "Browser run \(runID) has invalid \(field); canonical bytes retained."
        }
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

/// Completion is durable even if its derived evidence is unavailable. Carry
/// the actual outcome to approval settlement; it must never label a completed
/// effect failed merely because its receipt projection failed.
public struct BrowserCompletionProjectionError: Error, LocalizedError {
    public let run: JSONValue
    public let underlyingError: any Error
    public var errorDescription: String? {
        "Browser completion committed; its receipt projection is unavailable: \(underlyingError.localizedDescription). Inspect the canonical run before repeating the action."
    }
}

private struct PendingBrowserReceipt: Sendable {
    let runID: String
    let projectionID: String
    let publicRun: JSONValue
}

extension SwiftNativeBrowserClient {
    private enum Recovery: Sendable { case ready, unavailable(String) }
    private static let recovery = Mutex<[URL: Recovery]>([:])

    public var recoveryIssue: String? {
        switch Self.recovery.withLock({ $0[runsPath.standardizedFileURL] }) {
        case .ready: return nil
        case .unavailable(let cause): return BrowserOperationStoreError.recoveryUnavailable(cause).localizedDescription
        case nil: return BrowserOperationStoreError.recoveryUnavailable("Startup recovery has not completed").localizedDescription
        }
    }

    private static func recoveryRefusal(_ message: String) -> ToolFailureError {
        ToolFailureError(message, effects: .none, owner: "browser_operation_recovery",
            code: "browser_operation_recovery_unavailable", status: .refused,
            instruction: "Preserve and repair the named browser run or projection feed, reconcile unknown effects by observing the existing page without reopening its URL, then restart NativeAgent.", recovery: .repair)
    }

    /// Read-only diagnostics use the same canonical row validation as admission.
    public func canonicalRunIssues() async throws -> [String] {
        let snapshot = try await Self.readCanonicalSnapshot(at: runsPath)
        return snapshot.failures.keys.sorted().compactMap { snapshot.failures[$0] }
    }

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
    /// projections and can be resumed after a crash. A start returns
    /// its committed claim before projecting; its effect owner must receive
    /// that claim and install settlement even when an older feed is damaged.
    public func executeBrowserOperation(
        _ command: BrowserOperationCommand
    ) async throws -> BrowserOperationCommandResult {
        let result: BrowserOperationCommandResult
        switch command {
        case .start(let request):
            // Starts have no receipt. Terminal settlement drains
            // pending projections and reports any derived-feed failures then.
            return try await commitStart(request)
        case .complete(let completion):
            result = try await commitCompletion(completion)
        case .cancel(let requestedID):
            result = try await commitCancel(requestedID: requestedID)
        case .recoverStrandedRunning:
            do {
                let recovered = try await recoverStrandedRunning()
                try await projectPendingBrowserReceipts()
                let snapshot = try await Self.readCanonicalSnapshot(at: runsPath)
                if let issue = snapshot.admissionIssue {
                    throw PersistenceCoreError.ioFailure(issue)
                }
                Self.recovery.withLock { $0[runsPath.standardizedFileURL] = .ready }
                return recovered
            } catch {
                Self.recovery.withLock { $0[runsPath.standardizedFileURL] = .unavailable(error.localizedDescription) }
                throw error
            }
        }
        do {
            try await projectPendingBrowserReceipts()
        } catch {
            if case .complete = command, let run = result.run {
                throw BrowserCompletionProjectionError(run: run, underlyingError: error)
            }
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
            if let issue = self.recoveryIssue { throw Self.recoveryRefusal(issue) }
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            if let issue = snapshot.admissionIssue {
                throw Self.recoveryRefusal(BrowserOperationStoreError.recoveryUnavailable(issue).localizedDescription)
            }
            var rows = snapshot.rows
            if let index = rows.firstIndex(where: { $0.objectValue?["id"]?.stringValue == identity }) {
                try snapshot.requireValid(index)
                guard rows[index].objectValue?["requestDigest"]?.stringValue == digest else {
                    throw BrowserOperationStoreError.conflictingIdempotencyKey
                }
                return BrowserOperationCommandResult(run: try Self.externalRun(rows[index]), didTransition: false)
            }

            var row: [String: JSONValue] = [
                "id": .string(identity),
                "url": .string(request.url),
                "domain": .string(domain),
                "status": .string(request.initialState.rawValue),
                "dryRun": .bool(false),
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
            let canonical = JSONValue.object(row)
            rows.append(canonical)
            rows = try Self.prunedCanonicalRuns(rows, preserving: snapshot)
            try self.writeCanonicalRuns(rows, preserving: snapshot)
            return BrowserOperationCommandResult(run: try Self.externalRun(canonical), didTransition: true)
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
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            var rows = snapshot.rows
            guard let index = rows.firstIndex(where: { $0.objectValue?["id"]?.stringValue == completion.id }),
                  case .object(var row) = rows[index] else {
                if let issue = snapshot.admissionIssue { throw PersistenceCoreError.ioFailure(issue) }
                throw BrowserOperationStoreError.runNotFound
            }
            try snapshot.requireValid(index)
            guard rows[index].objectValue?["requestDigest"]?.stringValue == completion.requestDigest else {
                throw BrowserOperationStoreError.conflictingIdempotencyKey
            }
            let current = rows[index].objectValue?["status"]?.stringValue ?? ""
            let cancelPending = current == "canceled" && row["completedAt"] == nil
            if Self.terminalStatuses.contains(current), !cancelPending {
                return BrowserOperationCommandResult(run: try Self.externalRun(rows[index]), didTransition: false)
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
            try self.writeCanonicalRuns(rows, preserving: snapshot)
            return BrowserOperationCommandResult(run: try Self.externalRun(rows[index]), didTransition: true)
        }
    }

    private func commitCancel(requestedID: String?) async throws -> BrowserOperationCommandResult {
        let timestamp = Self.nowISO(now())
        let normalized = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await withCanonicalRunsLock {
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            var rows = snapshot.rows
            if let normalized, !normalized.isEmpty,
               let index = rows.firstIndex(where: { $0.objectValue?["id"]?.stringValue == normalized }) {
                try snapshot.requireValid(index)
            }
            let index = rows.firstIndex { candidate in
                let identityMatches = normalized == nil || normalized?.isEmpty == true
                    || candidate.objectValue?["id"]?.stringValue == normalized
                guard identityMatches else { return false }
                guard !snapshot.isDamaged(candidate) else { return false }
                let status = candidate.objectValue?["status"]?.stringValue ?? ""
                return status == "running" || status == "waiting_approval"
            }
            guard let index, case .object(var row) = rows[index] else {
                if let issue = snapshot.admissionIssue { throw PersistenceCoreError.ioFailure(issue) }
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
            try self.writeCanonicalRuns(rows, preserving: snapshot)
            return BrowserOperationCommandResult(run: try Self.externalRun(rows[index]), didTransition: true)
        }
    }

    private func recoverStrandedRunning() async throws -> BrowserOperationCommandResult {
        let currentDate = now()
        let timestamp = Self.nowISO(currentDate)
        return try await withCanonicalRunsLock {
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            var rows = snapshot.rows
            var recovered = 0
            var last: JSONValue?
            for index in rows.indices {
                guard snapshot.failures[index] == nil else { continue }
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
                try self.writeCanonicalRuns(rows, preserving: snapshot)
            }
            return BrowserOperationCommandResult(
                run: try last.map(Self.externalRun),
                didTransition: recovered > 0,
                recoveredCount: recovered
            )
        }
    }

    /// Resumes receipt/trace projection from canonical pending transition IDs.
    /// Feeds and traces land before one checkpoint removes only the captured IDs.
    private func projectPendingBrowserReceipts() async throws {
        let pending: [PendingBrowserReceipt] = try await withCanonicalRunsLock {
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            return try snapshot.rows.enumerated().filter { snapshot.failures[$0.offset] == nil }
                .flatMap { try Self.pendingProjections($0.element) }
        }
        guard !pending.isEmpty else { return }
        try await appendDerivedOnce(pending, to: receiptsPath, label: "Browser.receipts") { projection in
            guard case .object(var receipt) = projection.publicRun else {
                throw BrowserOperationStoreError.corruptRunsDocument
            }
            receipt["transitionId"] = .string(projection.projectionID)
            return .object(receipt)
        }
        try await appendDerivedOnce(pending, to: nativeActionsReceiptsPath, label: "Browser.actionReceipts") { projection in
            let run = projection.publicRun
            let fields = try JSONRow(run)
            return .object([
                "id": .string(projection.runID), "transitionId": .string(projection.projectionID),
                "actionId": .string("browser.open_url"), "name": .string("Visible Browser URL"),
                "kind": .string("browser"), "status": .string(try fields.string("status")),
                "dryRun": .bool(false),
                "approvalId": try fields.optionalString("approvalId").map(JSONValue.string) ?? .null,
                "output": run, "createdAt": .string(try fields.string("createdAt")),
            ])
        }
        for projection in pending {
            let fields = try JSONRow(projection.publicRun)
            let status = try fields.string("status")
            let createdAt = try fields.string("createdAt")
            let domain = try fields.string("domain")
            let url = try fields.string("url")

            try await TurnTracePersistLane(standalonePath: tracesPath).appendChecked(
                TurnTraceEvent(kind: "browser.action", title: domain, status: status, payload: .object([
                    "url": .string(url),
                    "status": .string(status),
                    "dryRun": .bool(false),
                ]), id: projection.projectionID, createdAt: createdAt), transitionId: projection.projectionID)
        }
        let projected = Set(pending.map(\.projectionID))
        try await withCanonicalRunsLock {
            let snapshot = try await Self.readCanonicalSnapshot(at: self.runsPath)
            var rows = snapshot.rows
            for index in rows.indices {
                guard snapshot.failures[index] == nil else { continue }
                guard case .object(var object) = rows[index],
                      case .array(let entries)? = object["projectionOutbox"] else { continue }
                let remaining = try entries.filter { entry in
                    guard let id = entry.objectValue?["id"]?.stringValue else {
                        throw BrowserOperationStoreError.corruptRunsDocument
                    }
                    return !projected.contains(id)
                }
                guard remaining.count != entries.count else { continue }
                if remaining.isEmpty { object.removeValue(forKey: "projectionOutbox") }
                else { object["projectionOutbox"] = .array(remaining) }
                rows[index] = .object(object)
            }
            try self.writeCanonicalRuns(rows, preserving: snapshot)
        }
    }

    private func appendDerivedOnce(
        _ pending: [PendingBrowserReceipt],
        to path: URL,
        label: String,
        value: @escaping @Sendable (PendingBrowserReceipt) throws -> JSONValue
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
                try await appendPathOwnedJSONL(try value(projection), to: path, logLabel: label)
                seen.insert(projection.projectionID)
            }
        }
        try await SwiftNativePersistenceCore.withFileLock(path, work)
    }

    static func readCanonicalRuns(
        at runsPath: URL, malformed: any Error = BrowserOperationStoreError.corruptRunsDocument
    ) async throws -> [JSONValue] {
        let snapshot = try await readCanonicalSnapshot(at: runsPath, malformed: malformed)
        return snapshot.rows.enumerated().map { index, value in
            guard let issue = snapshot.failures[index] else { return value }
            return .object([
                "id": value.objectValue?["id"]?.stringValue.map(JSONValue.string) ?? .null,
                "name": .string(snapshot.name(index)), "status": .string("unavailable"),
                "error": .string(issue), "canonicalRow": .int(Int64(index + 1)),
                "blocksNewEffects": .bool(snapshot.uncertainRows.contains(index)),
                "outcomeKind": .string("outcome_unknown"),
            ])
        }
    }

    private struct CanonicalRuns: Sendable {
        let rows: [JSONValue]
        let rawRows: [Data]
        let failures: [Int: String]
        let uncertainRows: Set<Int>

        func name(_ index: Int) -> String {
            if let id = rows[index].objectValue?["id"]?.stringValue, !id.isEmpty { return id }
            return "<row \(index + 1): missing id>"
        }
        func requireValid(_ index: Int) throws {
            if let issue = failures[index] { throw PersistenceCoreError.ioFailure(issue) }
        }
        func isDamaged(_ row: JSONValue) -> Bool { failures.keys.contains { rows[$0] == row } }
        var admissionIssue: String? {
            let issues = uncertainRows.sorted().compactMap { failures[$0] }
            return issues.isEmpty ? nil : issues.joined(separator: "\n")
        }
    }

    private static func readCanonicalSnapshot(
        at path: URL, malformed: any Error = BrowserOperationStoreError.corruptRunsDocument
    ) async throws -> CanonicalRuns {
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch let error as CocoaError where error.isFileAbsent {
            return CanonicalRuns(rows: [], rawRows: [], failures: [:], uncertainRows: [])
        }
        // The canonical writer emits UTF-8. A different document encoding
        // cannot be byte-spliced into that writer's output without corruption.
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw PersistenceCoreError.ioFailure("Browser runs at \(path.path) must be UTF-8 JSON; original bytes retained.")
        }
        let raw: JSONValue
        do { raw = try JSONValue.parse(data) }
        catch { throw PersistenceCoreError.ioFailure("Cannot decode \(path.path): \(error.localizedDescription); original bytes retained.") }
        guard case .array(let rows) = raw else { throw malformed }
        let rawRows = try rawArrayRows(data, count: rows.count)
        var identityCounts: [String: Int] = [:]
        var projectionCounts: [String: Int] = [:]
        for value in rows {
            if let id = value.objectValue?["id"]?.stringValue { identityCounts[id, default: 0] += 1 }
            if case .array(let entries)? = value.objectValue?["projectionOutbox"] {
                for entry in entries {
                    if let id = entry.objectValue?["id"]?.stringValue { projectionCounts[id, default: 0] += 1 }
                }
            }
        }
        var failures: [Int: String] = [:]
        var uncertainRows = Set<Int>()
        for (index, value) in rows.enumerated() {
            do {
                let row = try validateRun(value, canonical: true)
                guard let id = row["id"]?.stringValue, identityCounts[id] == 1 else {
                    throw BrowserOperationStoreError.invalidCanonicalRun(runID: row["id"]?.stringValue ?? "<missing id>", field: "duplicate identity")
                }
                for pending in try pendingProjections(value) {
                    let snapshot = try validateRun(pending.publicRun, canonical: false)
                    guard projectionCounts[pending.projectionID] == 1,
                          ["id", "url", "domain", "requestDigest", "createdAt", "approvalId"].allSatisfy({ snapshot[$0] == row[$0] }),
                          let status = snapshot["status"]?.stringValue, terminalStatuses.contains(status),
                          snapshot["completedAt"]?.stringValue != nil else {
                        throw BrowserOperationStoreError.invalidCanonicalRun(runID: id, field: "projection snapshot or duplicate projection identity")
                    }
                }
            } catch {
                let row = value.objectValue
                let id = row?["id"]?.stringValue
                let name = id.flatMap { $0.isEmpty ? nil : $0 } ?? "<row \(index + 1): missing id>"
                failures[index] = "Browser run \(name) (row \(index + 1)) unavailable: \(error.localizedDescription) Original row bytes retained; repair this run in \(path.path) and reconcile its effects before repeating it."
                // Only explicit, parseable terminal evidence can exclude an
                // in-flight effect. Missing or ambiguous identity cannot.
                let terminal = row?["status"]?.stringValue.map(terminalStatuses.contains) == true
                let completed = row?["completedAt"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) != nil
                if !terminal || !completed || id == nil || id?.isEmpty == true || id.flatMap({ identityCounts[$0] }) != 1 {
                    uncertainRows.insert(index)
                }
            }
        }
        return CanonicalRuns(rows: rows, rawRows: rawRows, failures: failures, uncertainRows: uncertainRows)
    }

    /// Locate original top-level JSON values after parsing the complete JSON.
    /// Strings/escapes and nested arrays/objects cannot split an element.
    private static func rawArrayRows(_ data: Data, count: Int) throws -> [Data] {
        let bytes = Array(data)
        var rows: [Data] = []
        var depth = 0, start: Int?
        var quoted = false, escaped = false
        for (index, byte) in bytes.enumerated() {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if depth == 1, byte == 44 || byte == 93 {
                if let begin = start { rows.append(Data(bytes[begin..<index])); start = nil }
                if byte == 93 { depth -= 1 }
                continue
            }
            if depth == 1, start == nil, ![9, 10, 13, 32].contains(byte) { start = index }
            if byte == 34 { quoted = true }
            else if byte == 91 || byte == 123 { depth += 1 }
            else if byte == 93 || byte == 125 { depth -= 1 }
        }
        guard rows.count == count else { throw BrowserOperationStoreError.corruptRunsDocument }
        return rows
    }

    /// Only valid siblings change. Damaged values are spliced from their exact
    /// original byte ranges, including unknown fields, rather than re-encoded.
    private func writeCanonicalRuns(_ rows: [JSONValue], preserving snapshot: CanonicalRuns) throws {
        var damaged = snapshot.failures.keys.sorted()
        var data = Data("[\n".utf8)
        for (index, row) in rows.enumerated() {
            if index > 0 { data.append(contentsOf: ",\n".utf8) }
            if let offset = damaged.firstIndex(where: { snapshot.rows[$0] == row }) {
                data.append(snapshot.rawRows[damaged.remove(at: offset)])
            } else {
                data.append(try row.serializedData(pretty: true))
            }
        }
        guard damaged.isEmpty else { throw BrowserOperationStoreError.corruptRunsDocument }
        data.append(contentsOf: "\n]\n".utf8)
        try SwiftNativePersistenceCore.atomicWrite(data, to: runsPath)
    }

    /// Validate the writer's current shape before any reader can interpret
    /// missing evidence as a receipt or a completed projection.
    private static func validateRun(_ value: JSONValue, canonical: Bool) throws -> [String: JSONValue] {
        guard case .object(let row) = value else { throw BrowserOperationStoreError.corruptRunsDocument }
        let id = row["id"]?.stringValue ?? "<missing id>"
        func require(_ condition: Bool, _ field: String) throws {
            guard condition else { throw BrowserOperationStoreError.invalidCanonicalRun(runID: id, field: field) }
        }
        try require(id != "<missing id>" && !id.isEmpty && id.utf8.count <= 200
            && id == id.trimmingCharacters(in: .whitespacesAndNewlines), "id")
        guard let rawURL = row["url"]?.stringValue else {
            throw BrowserOperationStoreError.invalidCanonicalRun(runID: id, field: "url")
        }
        let parsed = try BrowserActionRoutes.ValidBrowserURL(rawURL)
        try require(row["domain"]?.stringValue == parsed.domain, "domain")
        let status = row["status"]?.stringValue
        try require(status == "running" || status == "waiting_approval" || status.map(terminalStatuses.contains) == true, "status")
        try require(row["dryRun"] == .bool(false) && row["visible"] == .bool(true), "dryRun/visible")
        try require(row["opened"]?.boolValue != nil || row["opened"] == .null, "opened")
        try require(row["approvalId"] == .null || row["approvalId"]?.stringValue?.isEmpty == false, "approvalId")
        for field in ["sourceReceipt", "screenshotReceipt"] {
            try require(row[field] == .null || row[field]?.objectValue != nil, field)
        }
        try require(row["requestDigest"]?.stringValue.map(isDigest) == true, "requestDigest")
        try require(row["verificationStatus"]?.stringValue.map { ["pending", "not_required", "satisfied", "failed"].contains($0) } == true, "verificationStatus")
        for field in ["createdAt", "updatedAt", "completedAt", "canceledAt", "deniedAt", "deadlineAt"] {
            if row[field] != nil || field == "createdAt" || field == "updatedAt" {
                try require(row[field]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) != nil, field)
            }
        }
        if let seconds = row["deadlineSeconds"] {
            guard case .int(let count) = seconds, (1...86_400).contains(count) else {
                throw BrowserOperationStoreError.invalidCanonicalRun(runID: id, field: "deadlineSeconds")
            }
        }
        if let status, terminalStatuses.contains(status), status != "canceled" || row["completedAt"] != nil {
            try require(row["completedAt"]?.stringValue != nil, "completedAt")
        }
        if status == "canceled" { try require(row["canceledAt"]?.stringValue != nil, "canceledAt") }
        if status == "denied" { try require(row["deniedAt"]?.stringValue != nil, "deniedAt") }
        try require(["projectionId", "projectionState", "projectedAt"].allSatisfy { row[$0] == nil }, "retired projection fields")
        if canonical {
            if let counter = row["transitionSequence"] {
                guard case .int(let sequence) = counter, sequence > 0, sequence < Int64.max else {
                    throw BrowserOperationStoreError.invalidTransitionMetadata(runID: id)
                }
            } else {
                try require(status == "running" || status == "waiting_approval"
                    || (status == "canceled" && row["completedAt"] == nil), "transitionSequence")
            }
            if let entries = row["projectionOutbox"] {
                guard case .array(let outbox) = entries, case .int(let sequence)? = row["transitionSequence"],
                      Int64(outbox.count) <= sequence else {
                    throw BrowserOperationStoreError.invalidCanonicalRun(runID: id, field: "projectionOutbox")
                }
            }
        } else {
            try require(row["transitionSequence"] == nil && row["projectionOutbox"] == nil, "projection snapshot")
        }
        return row
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    package static func terminalRun(id: String, at path: URL) async throws -> JSONValue? {
        guard !id.isEmpty else { return nil }
        let rows = try await readCanonicalRuns(at: path)
        guard let row = rows.first(where: { $0.objectValue?["id"]?.stringValue == id }),
              let status = row.objectValue?["status"]?.stringValue else {
            try requireIdentifiableRuns(rows)
            return nil
        }
        if status == "unavailable" {
            throw PersistenceCoreError.ioFailure(row.objectValue?["error"]?.stringValue ?? "Browser run \(id) unavailable")
        }
        guard terminalStatuses.contains(status),
              status != "canceled" || row.objectValue?["completedAt"]?.stringValue != nil else { return nil }
        return row
    }

    /// Without a matching row, unnamed damage cannot establish absence.
    static func requireIdentifiableRuns(_ rows: [JSONValue]) throws {
        for row in rows where row.objectValue?["status"] == .string("unavailable") {
            if row.objectValue?["id"]?.stringValue?.isEmpty != false {
                throw PersistenceCoreError.ioFailure(row.objectValue?["error"]?.stringValue ?? "An unidentified browser run is unavailable")
            }
        }
    }

    private func withCanonicalRunsLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Every persistence conformer uses the same path lock.
        return try await SwiftNativePersistenceCore.withFileLock(runsPath, operation)
    }

    private static let terminalStatuses: Set<String> = [
        "succeeded", "failed", "denied", "canceled",
    ]

    private static func stageProjection(
        on row: inout [String: JSONValue], status: String, at timestamp: String
    ) throws {
        guard let runID = row["id"]?.stringValue else { throw BrowserOperationStoreError.invalidIdentity }
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
        let snapshot = try externalRun(.object(row))
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

    private static func pendingProjections(_ row: JSONValue) throws -> [PendingBrowserReceipt] {
        guard case .object(let object) = row, let runID = object["id"]?.stringValue else {
            throw BrowserOperationStoreError.corruptRunsDocument
        }
        guard let entries = object["projectionOutbox"] else { return [] }
        guard case .array(let outbox) = entries else { throw BrowserOperationStoreError.corruptRunsDocument }
        return try outbox.map { entry in
            guard case .object(let fields) = entry, Set(fields.keys) == ["id", "run"],
                  let id = fields["id"]?.stringValue, isDigest(id),
                  let snapshot = fields["run"], case .object = snapshot else {
                throw BrowserOperationStoreError.invalidCanonicalRun(runID: runID, field: "projectionOutbox entry")
            }
            return PendingBrowserReceipt(runID: runID, projectionID: id, publicRun: snapshot)
        }
    }

    private static func prunedCanonicalRuns(_ rows: [JSONValue], preserving snapshot: CanonicalRuns) throws -> [JSONValue] {
        guard rows.count > 200 else { return rows }
        var overflow = rows.count - 200
        var retained: [JSONValue] = []
        retained.reserveCapacity(min(rows.count, 200))
        for row in rows {
            if snapshot.isDamaged(row) { retained.append(row); continue }
            let status = row.objectValue?["status"]?.stringValue ?? ""
            let isEvictable = terminalStatuses.contains(status)
                && (status != "canceled" || row.objectValue?["completedAt"]?.stringValue != nil)
            let hasPendingProjection = try !pendingProjections(row).isEmpty
            if overflow > 0, isEvictable, !hasPendingProjection {
                overflow -= 1
                continue
            }
            retained.append(row)
        }
        guard overflow == 0 else { throw BrowserOperationStoreError.capacityExceeded }
        return retained
    }

    private static func externalRun(_ value: JSONValue) throws -> JSONValue {
        var object = try JSONRow(value).fields
        object.removeValue(forKey: "transitionSequence")
        object.removeValue(forKey: "projectionOutbox")
        return .object(object)
    }

}
