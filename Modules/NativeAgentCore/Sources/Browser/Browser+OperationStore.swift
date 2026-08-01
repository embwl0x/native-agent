import Foundation
import NativeAgentCore
import PersistenceCore

/// Canonical Browser lifecycle commands. WebKit/AppKit remain effect adapters;
/// every durable lifecycle transition enters through this boundary.
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
    public let visible: Bool
    public let approvalId: String?
    public let captureSource: Bool
    public let captureScreenshot: Bool
    public let deadlineSeconds: Int?

    public init(
        id: String,
        url: String,
        domain: String,
        initialState: BrowserOperationInitialState,
        visible: Bool,
        approvalId: String? = nil,
        captureSource: Bool = false,
        captureScreenshot: Bool = false,
        deadlineSeconds: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.domain = domain
        self.initialState = initialState
        self.visible = visible
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
    case projectPendingReceipts
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

public protocol BrowserOperationCommanding: Sendable {
    func executeBrowserOperation(
        _ command: BrowserOperationCommand
    ) async throws -> BrowserOperationCommandResult
}

public enum BrowserOperationStoreError: Error, Sendable, Equatable {
    case invalidIdentity
    case invalidURL
    case invalidDomain
    case invalidDeadline
    case invalidRequestDigest
    case conflictingIdempotencyKey
    case runNotFound
    case invalidTransition
    case corruptRunsDocument
    case capacityExceeded
}

private struct BrowserPendingProjection: Sendable {
    let runID: String
    let projectionID: String
    let publicRun: JSONValue
}

extension SwiftNativeBrowserClient: BrowserOperationCommanding {
    /// Stable identity for one operation request. This binds idempotency to the
    /// requested effect without exposing URL/domain in shared motor projections.
    public static func browserRequestDigest(for start: BrowserOperationStart) -> String {
        CausalTransitionEvidence.opaqueIdentity([
            "browser.open_url",
            start.url,
            start.domain.lowercased(),
            start.initialState.rawValue,
            start.visible ? "visible" : "hidden",
            start.approvalId ?? "no-approval",
            start.captureSource ? "source" : "no-source",
            start.captureScreenshot ? "screenshot" : "no-screenshot",
            String(start.deadlineSeconds ?? 0),
        ].joined(separator: "|"))
    }

    /// Sole canonical Browser command boundary. The runs row is committed
    /// first under one lock; receipt/trace feeds are idempotent derived
    /// projections and can be resumed after a crash.
    public func executeBrowserOperation(
        _ command: BrowserOperationCommand
    ) async throws -> BrowserOperationCommandResult {
        let result: BrowserOperationCommandResult
        switch command {
        case .start(let request):
            result = try await commitStart(request)
        case .complete(let completion):
            result = try await commitCompletion(completion)
        case .cancel(let requestedID):
            result = try await commitCancel(requestedID: requestedID)
        case .recoverStrandedRunning:
            result = try await recoverStrandedRunning()
        case .projectPendingReceipts:
            result = BrowserOperationCommandResult(run: nil, didTransition: false)
        }
        try await projectPendingBrowserReceipts()
        return result
    }

    private func commitStart(
        _ request: BrowserOperationStart
    ) async throws -> BrowserOperationCommandResult {
        let identity = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty, identity.utf8.count <= 200 else {
            throw BrowserOperationStoreError.invalidIdentity
        }
        guard let components = URLComponents(string: request.url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let urlHost = components.host?.lowercased() else {
            throw BrowserOperationStoreError.invalidURL
        }
        let domain = request.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, domain.utf8.count <= 253, domain == urlHost else {
            throw BrowserOperationStoreError.invalidDomain
        }
        if let deadline = request.deadlineSeconds, !(1...86_400).contains(deadline) {
            throw BrowserOperationStoreError.invalidDeadline
        }
        let digest = Self.browserRequestDigest(for: request)
        let timestamp = Self.nowISO(now())

        return try await withCanonicalRunsLock {
            var rows = try await self.readCanonicalRuns()
            if let index = rows.firstIndex(where: { Self.objectString($0, "id") == identity }) {
                guard Self.objectString(rows[index], "requestDigest") == digest else {
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
                "visible": .bool(request.visible),
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
                Self.stageProjection(on: &row, status: request.initialState.rawValue, at: timestamp)
            }
            let canonical = JSONValue.object(row)
            rows.append(canonical)
            rows = try Self.prunedCanonicalRuns(rows)
            try await self.persistenceCore.writeJSON(.array(rows), to: self.runsPath)
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
            guard let index = rows.firstIndex(where: { Self.objectString($0, "id") == completion.id }),
                  case .object(var row) = rows[index] else {
                throw BrowserOperationStoreError.runNotFound
            }
            guard Self.objectString(rows[index], "requestDigest") == completion.requestDigest else {
                throw BrowserOperationStoreError.conflictingIdempotencyKey
            }
            let current = Self.objectString(rows[index], "status") ?? ""
            if Self.terminalStatuses.contains(current) {
                return BrowserOperationCommandResult(run: Self.externalRun(rows[index]), didTransition: false)
            }
            guard current == "running" || current == "waiting_approval" else {
                throw BrowserOperationStoreError.invalidTransition
            }

            row["status"] = .string(completion.state.rawValue)
            row["opened"] = .bool(completion.opened)
            row["sourceReceipt"] = completion.sourceReceipt
            row["screenshotReceipt"] = completion.screenshotReceipt
            row["updatedAt"] = .string(timestamp)
            row["completedAt"] = .string(timestamp)
            row["verificationStatus"] = .string(
                completion.state == .succeeded && completion.opened ? "satisfied"
                    : completion.state == .failed ? "failed" : "not_required"
            )
            if completion.state == .canceled {
                row["canceledAt"] = .string(timestamp)
            } else if completion.state == .denied {
                row["deniedAt"] = .string(timestamp)
            }
            row.removeValue(forKey: "deadlineAt")
            Self.stageProjection(on: &row, status: completion.state.rawValue, at: timestamp)
            rows[index] = .object(row)
            try await self.persistenceCore.writeJSON(.array(rows), to: self.runsPath)
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
                    || Self.objectString(candidate, "id") == normalized
                guard identityMatches else { return false }
                let status = Self.objectString(candidate, "status") ?? ""
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
            row["status"] = .string("canceled")
            row["opened"] = .bool(false)
            row["canceledAt"] = .string(timestamp)
            row["completedAt"] = .string(timestamp)
            row["updatedAt"] = .string(timestamp)
            row["verificationStatus"] = .string("not_required")
            row.removeValue(forKey: "deadlineAt")
            Self.stageProjection(on: &row, status: "canceled", at: timestamp)
            rows[index] = .object(row)
            try await self.persistenceCore.writeJSON(.array(rows), to: self.runsPath)
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
                guard Self.objectString(rows[index], "status") == "running",
                      case .object(var row) = rows[index] else { continue }
                row["status"] = .string("failed")
                row["opened"] = .bool(false)
                row["errorCode"] = .string("restart_stranded_running")
                row["outcomeKind"] = .string("outcome_unknown")
                row["verificationStatus"] = .string("failed")
                row["completedAt"] = .string(timestamp)
                row["updatedAt"] = .string(timestamp)
                row.removeValue(forKey: "deadlineAt")
                Self.stageProjection(on: &row, status: "failed", at: timestamp)
                rows[index] = .object(row)
                last = rows[index]
                recovered += 1
            }
            if recovered > 0 {
                try await self.persistenceCore.writeJSON(.array(rows), to: self.runsPath)
            }
            return BrowserOperationCommandResult(
                run: last.map(Self.externalRun),
                didTransition: recovered > 0,
                recoveredCount: recovered
            )
        }
    }

    /// Resumes receipt/trace projection from canonical pending transition IDs.
    /// Each target is de-duplicated under its own file lock before the owner row
    /// is marked projected, closing the append-before-checkpoint crash window.
    private func projectPendingBrowserReceipts() async throws {
        let pending: [BrowserPendingProjection] = try await withCanonicalRunsLock {
            try await self.readCanonicalRuns().flatMap(Self.pendingProjections)
        }
        for projection in pending {
            let projectionID = projection.projectionID
            let publicRun = projection.publicRun
            let status = Self.objectString(publicRun, "status") ?? "unknown"
            let createdAt = Self.objectString(publicRun, "createdAt") ?? Self.nowISO(now())
            let runID = projection.runID
            let domain = Self.objectString(publicRun, "domain") ?? "browser"
            let url = Self.objectString(publicRun, "url") ?? ""
            let dryRun = Self.objectBool(publicRun, "dryRun") ?? false
            let approvalID = Self.objectString(publicRun, "approvalId")

            var browserReceipt = Self.objectValue(publicRun)
            browserReceipt["transitionId"] = .string(projectionID)
            try await appendDerivedOnce(
                .object(browserReceipt), projectionID: projectionID,
                to: receiptsPath, label: "Browser.receipts"
            )

            let nativeReceipt: JSONValue = .object([
                "id": .string(runID),
                "transitionId": .string(projectionID),
                "actionId": .string("browser.open_url"),
                "name": .string("Visible Browser URL"),
                "kind": .string("browser"),
                "status": .string(status),
                "dryRun": .bool(dryRun),
                "approvalId": approvalID.map(JSONValue.string) ?? .null,
                "output": publicRun,
                "createdAt": .string(createdAt),
            ])
            try await appendDerivedOnce(
                nativeReceipt, projectionID: projectionID,
                to: nativeActionsReceiptsPath, label: "Browser.actionReceipts"
            )

            let trace: JSONValue = .object([
                "id": .string(projectionID),
                "transitionId": .string(projectionID),
                "kind": .string("browser.action"),
                "title": .string(domain),
                "status": .string(status),
                "payload": .object([
                    "url": .string(url),
                    "status": .string(status),
                    "dryRun": .bool(dryRun),
                ]),
                "createdAt": .string(createdAt),
            ])
            try await appendDerivedOnce(
                trace, projectionID: projectionID,
                to: tracesPath, label: "Browser.trace",
                maxLines: JSONLLineCaps.activityEvents
            )

            try await withCanonicalRunsLock {
                var rows = try await self.readCanonicalRuns()
                guard let index = rows.firstIndex(where: {
                    Self.objectString($0, "id") == runID
                }), case .object(var object) = rows[index] else { return }
                if case .array(let entries)? = object["projectionOutbox"] {
                    let remaining = entries.filter {
                        Self.objectString($0, "id") != projectionID
                    }
                    if remaining.isEmpty {
                        object.removeValue(forKey: "projectionOutbox")
                        object["projectionState"] = .string("projected")
                        object["projectionId"] = .string(projectionID)
                        object["projectedAt"] = .string(Self.nowISO(self.now()))
                    } else {
                        object["projectionOutbox"] = .array(remaining)
                        object["projectionState"] = .string("pending")
                        object["projectionId"] = Self.objectString(
                            remaining.last ?? .null, "id"
                        ).map(JSONValue.string) ?? .null
                        object.removeValue(forKey: "projectedAt")
                    }
                } else {
                    // Compatibility recovery for a pending row written by the
                    // first single-slot implementation.
                    guard Self.objectString(rows[index], "projectionState") == "pending",
                          Self.objectString(rows[index], "projectionId") == projectionID else { return }
                    object["projectionState"] = .string("projected")
                    object["projectedAt"] = .string(Self.nowISO(self.now()))
                }
                rows[index] = .object(object)
                try await self.persistenceCore.writeJSON(.array(rows), to: self.runsPath)
            }
        }
    }

    private func appendDerivedOnce(
        _ value: JSONValue,
        projectionID: String,
        to path: URL,
        label: String,
        maxLines: Int = JSONLLineCaps.actionReceipts
    ) async throws {
        let work: @Sendable () async throws -> Void = {
            let existing = (try? await self.persistenceCore.tailJSONL(
                path, limit: maxLines, maxBytes: nil
            )) ?? []
            guard !existing.contains(where: {
                Self.objectString($0, "transitionId") == projectionID
            }) else { return }
            try await appendJSONLCapped(
                value, to: path, using: self.persistenceCore,
                maxLines: maxLines, logLabel: label, takeLock: false
            )
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        try await persistenceCore.withFileLock(path, work)
    }

    private func readCanonicalRuns() async throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: runsPath.path) else { return [] }
        let raw = await persistenceCore.readJSON(runsPath, defaultValue: .null)
        guard case .array(let rows) = raw else {
            throw BrowserOperationStoreError.corruptRunsDocument
        }
        return rows
    }

    private func withCanonicalRunsLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistenceCore.withFileLock(runsPath, operation)
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
    ) {
        let runID = objectString(.object(row), "id") ?? "browser"
        let sequence: Int64
        if case .int(let previous)? = row["transitionSequence"] {
            sequence = previous + 1
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
        row["projectionId"] = .string(projectionID)
        row["projectionState"] = .string("pending")
        row.removeValue(forKey: "projectedAt")
    }

    private static func pendingProjections(_ row: JSONValue) -> [BrowserPendingProjection] {
        let runID = objectString(row, "id") ?? "browser"
        if case .object(let object) = row,
           case .array(let outbox)? = object["projectionOutbox"] {
            return outbox.compactMap { entry in
                guard let id = objectString(entry, "id"),
                      case .object(let fields) = entry,
                      let snapshot = fields["run"] else { return nil }
                return BrowserPendingProjection(
                    runID: runID,
                    projectionID: id,
                    publicRun: externalRun(snapshot)
                )
            }
        }
        guard objectString(row, "projectionState") == "pending",
              let id = objectString(row, "projectionId") else { return [] }
        return [BrowserPendingProjection(
            runID: runID,
            projectionID: id,
            publicRun: externalRun(row)
        )]
    }

    private static func prunedCanonicalRuns(_ rows: [JSONValue]) throws -> [JSONValue] {
        guard rows.count > 200 else { return rows }
        var overflow = rows.count - 200
        var retained: [JSONValue] = []
        retained.reserveCapacity(min(rows.count, 200))
        for row in rows {
            let status = objectString(row, "status") ?? ""
            let isEvictable = evictableStatuses.contains(status)
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
        var object = objectValue(value)
        object.removeValue(forKey: "projectionState")
        object.removeValue(forKey: "projectionId")
        object.removeValue(forKey: "projectedAt")
        object.removeValue(forKey: "transitionSequence")
        object.removeValue(forKey: "projectionOutbox")
        return .object(object)
    }

    private static func objectValue(_ value: JSONValue) -> [String: JSONValue] {
        guard case .object(let object) = value else { return [:] }
        return object
    }

    private static func objectString(_ value: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = value,
              case .string(let string)? = object[key] else { return nil }
        return string
    }

    private static func objectBool(_ value: JSONValue, _ key: String) -> Bool? {
        guard case .object(let object) = value,
              case .bool(let bool)? = object[key] else { return nil }
        return bool
    }

}
