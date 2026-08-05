// v1 — Autonomous-execution-depth foundation.
//
// Persistence + escalation primitives for executions that run unattended for
// hours and periodically checkpoint state or escalate to the user when blocked.
// v1 is the storage layer ONLY: checkpoints + escalations + inbox card.
// v2 will add the self-correction loop, multi-execution orchestration, and
// execution resume from a chosen checkpoint.
//
// Layout (under PersistenceCore.defaultDataRoot()):
//
//   <root>/missions/<missionId>/checkpoints.jsonl   — append-only checkpoint log
//   <root>/missions/<missionId>/escalations.jsonl   — append-only escalation log
//   <root>/notifications/inbox.jsonl                — surface the escalation as
//                                                     a NotificationInboxItem in
//                                                     the LIVE inbox (A5.2 cutover
//                                                     2026-07-23; was the dead
//                                                     <root>/inbox/ silo)
//
// NOTE on the executions root: the existing SwiftNativeWorkshopRunner writes its
// queue under <root>/missions/QUEUE/<id>/ (note the extra "queue" dir). This
// new subsystem writes one level higher, under <root>/missions/<id>/, so the
// checkpoints/escalations log does NOT interleave inside the runner's queue
// dir. A future v2 may unify the layout; for v1 the separation is intentional
// so this subsystem can land without touching the runner's existing file
// layout.
//
// Fail-closed contract: every persistence error throws
// `WorkshopCheckpointError.persistenceFailure`. No silent no-op writes — a
// crash between an escalation file write and the inbox card write surfaces as
// a thrown error so the caller can retry or escalate to a different channel.

import Foundation
import PersistenceCore

// MARK: - Types

public struct WorkshopCheckpoint: Codable, Sendable, Equatable {
    public var id: String                  // UUID per checkpoint
    public var executionId: String
    public var ts: String                  // ISO-8601
    public var phase: String               // free-form: "investigating", "blocked", "needs_input", ...
    public var progress: Double?           // 0.0 to 1.0 if quantifiable
    public var summary: String             // one-line "what just happened"
    public var detail: String?             // multi-line context for resume
    public var nextStep: String?           // what the Workshop execution intends to do next
    public var blockingQuestion: String?   // if non-nil, the execution is waiting for the user

    enum CodingKeys: String, CodingKey {
        case id, ts, phase, progress, summary, detail, nextStep, blockingQuestion
        case executionId = "missionId" // compatibility wire ID
    }

    public init(
        id: String,
        executionId: String,
        ts: String,
        phase: String,
        progress: Double? = nil,
        summary: String,
        detail: String? = nil,
        nextStep: String? = nil,
        blockingQuestion: String? = nil
    ) {
        self.id = id
        self.executionId = executionId
        self.ts = ts
        self.phase = phase
        self.progress = progress
        self.summary = summary
        self.detail = detail
        self.nextStep = nextStep
        self.blockingQuestion = blockingQuestion
    }
}

public enum WorkshopEscalationReason: String, Codable, Sendable {
    case userInputRequired = "user_input_required"
    case budgetExceeded = "budget_exceeded"
    case toolUnavailable = "tool_unavailable"
    case repeatedFailure = "repeated_failure"
    case unexpectedState = "unexpected_state"
}

public struct WorkshopEscalation: Codable, Sendable, Equatable {
    public var id: String
    public var executionId: String
    public var ts: String
    public var reason: WorkshopEscalationReason
    public var question: String              // what to ask the user
    public var checkpoint: WorkshopCheckpoint // snapshot at escalation time

    enum CodingKeys: String, CodingKey {
        case id, ts, reason, question, checkpoint
        case executionId = "missionId" // compatibility wire ID
    }

    public init(
        id: String,
        executionId: String,
        ts: String,
        reason: WorkshopEscalationReason,
        question: String,
        checkpoint: WorkshopCheckpoint
    ) {
        self.id = id
        self.executionId = executionId
        self.ts = ts
        self.reason = reason
        self.question = question
        self.checkpoint = checkpoint
    }
}

public enum WorkshopCheckpointError: Error, LocalizedError, Equatable {
    case invalidWorkshopExecutionId(String)
    case invalidEscalation(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkshopExecutionId(let s):  return "invalid missionId: \(s)"
        case .invalidEscalation(let s): return "invalid escalation: \(s)"
        case .persistenceFailure(let s): return "persistence failure: \(s)"
        }
    }
}

// MARK: - Checkpoint store

/// Append-only JSONL store for Workshop execution checkpoints. Cross-process safe via
/// `withFileLock` on the checkpoints.jsonl path — matches the canonical
/// pattern used by `SwiftNativeWorkshopRunner.appendTimelineLocked`.
public actor SwiftNativeWorkshopCheckpointStore {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence ?? SwiftNativePersistenceCore()
    }

    public nonisolated func workshopExecutionDir(executionId: String) -> URL {
        dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(executionId, isDirectory: true)
    }

    public nonisolated func checkpointsPath(executionId: String) -> URL {
        workshopExecutionDir(executionId: executionId).appendingPathComponent("checkpoints.jsonl")
    }

    /// gpt-5.5 cross-feature review NEEDS_FIX: missionId becomes a path
    /// component, so it MUST be a safe single segment. Without this guard a
    /// caller can pass `../escape`, `queue/<id>`, or paths containing `/`,
    /// `\`, NUL, `.`, `..` and traverse outside the intended execution directory
    /// OR collide with the runner's `workshop/executions/<id>/` slot.
    /// Existing runner IDs are UUIDs and don't trigger this — but the public
    /// API must enforce.
    internal nonisolated static func validateWorkshopExecutionIdAsSafeComponent(_ rawId: String) throws -> String {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw WorkshopCheckpointError.invalidWorkshopExecutionId("missionId must be non-empty")
        }
        if id == "." || id == ".." {
            throw WorkshopCheckpointError.invalidWorkshopExecutionId("missionId cannot be '.' or '..'")
        }
        if id.contains("/") || id.contains("\\") || id.contains("\0") {
            throw WorkshopCheckpointError.invalidWorkshopExecutionId(
                "missionId cannot contain path separators or NUL: \(id)"
            )
        }
        // Reject any control character (CR/LF/tab etc.) — JSONL append would
        // tear the line and downstream readers would silently skip rows.
        if id.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw WorkshopCheckpointError.invalidWorkshopExecutionId(
                "missionId cannot contain control characters: \(id)"
            )
        }
        return id
    }

    /// Append a checkpoint. Throws on validation or persistence failure
    /// (fail-closed: no silent no-op).
    public func appendCheckpoint(_ checkpoint: WorkshopCheckpoint) async throws {
        let executionId = try Self.validateWorkshopExecutionIdAsSafeComponent(checkpoint.executionId)
        let path = checkpointsPath(executionId: executionId)
        let payload: JSONValue
        do {
            payload = try encodeToJSONValue(checkpoint)
        } catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "encode checkpoint failed: \(error)"
            )
        }
        do {
            // Parent dir ensure happens inside appendJSONL too, but we ensure
            // here so a flock attempt on a missing parent doesn't fail twice.
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await withLockedWrite(path: path) { [persistence] in
                try await persistence.appendJSONL(payload, to: path)
            }
        } catch let e as WorkshopCheckpointError {
            throw e
        } catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "appendJSONL checkpoint failed: \(error)"
            )
        }
    }

    /// Read all checkpoints for an execution in chronological (file) order.
    /// Missing file -> []. FAIL-CLOSED on a malformed line: this store is the
    /// SOLE writer of checkpoints.jsonl in v1 (no foreign producer to be
    /// tolerant of), so a record we cannot decode means corruption, and
    /// `latestCheckpoint` returning a stale earlier record would be a silent
    /// no-op the brief explicitly forbids. (gpt-5.5 review finding —
    /// BLOCKING 2 + follow-up BLOCKING: `PersistenceCore.readJSONL`
    /// itself silent-drops syntactically malformed lines via
    /// `compactMap { try? parse }`, so we MUST bypass it and read raw bytes
    /// here to keep the fail-closed contract end-to-end.)
    public func readCheckpoints(executionId: String) async throws -> [WorkshopCheckpoint] {
        let safe = try Self.validateWorkshopExecutionIdAsSafeComponent(executionId)
        let path = checkpointsPath(executionId: safe)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try readFailClosedJSONL(path)
    }

    public func latestCheckpoint(executionId: String) async throws -> WorkshopCheckpoint? {
        try await readCheckpoints(executionId: executionId).last
    }

    /// Internal flock'd writer. Mirrors `SwiftNativeWorkshopRunner.appendTimelineLocked`.
    /// `withFileLock` is a PersistenceCoreProtocol EXTENSION
    /// (PersistenceCore+FileLock.swift:4), so this locks for EVERY conformer —
    /// the old downcast to `SwiftNativePersistenceCore` silently ran the write
    /// unlocked for any other impl (L7, 2026-08-01).
    private func withLockedWrite(
        path: URL,
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await persistence.withFileLock(path) {
            try await body()
        }
    }
}

// MARK: - Escalator

/// Persists a Workshop execution escalation + writes a NotificationInboxItem card so the user
/// sees a question in his inbox. Inbox card shape mirrors
/// `NotificationInboxItem.toJSONValue()` in
/// `NotificationInbox/NotificationInbox.swift`. Items.jsonl + index.json
/// writes mirror `ProactiveInboxStore.surface` in
/// `TriggerScheduler/TriggerScheduler.swift` — the inline duplication is
/// deliberate: the WorkshopExecution module cannot import TriggerScheduler (TS depends
/// on Workshop; importing would be a dep cycle).
public actor SwiftNativeWorkshopEscalator {
    private let dataRoot: URL
    private let persistence: any PersistenceCoreProtocol
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> String

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        uuid: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.now = now
        self.uuid = uuid
    }

    public nonisolated func workshopExecutionDir(executionId: String) -> URL {
        dataRoot
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
            .appendingPathComponent(executionId, isDirectory: true)
    }

    public nonisolated func escalationsPath(executionId: String) -> URL {
        workshopExecutionDir(executionId: executionId).appendingPathComponent("escalations.jsonl")
    }

    /// A5.2 cutover (2026-07-23): escalation cards now land in the LIVE inbox
    /// (`notifications/inbox.jsonl`) that the Mac UI, getInboxItems and the iOS
    /// snapshot actually read. The old `<root>/inbox/` silo was dead — nothing
    /// user-facing read it, so "Workshop needs your input" cards silently
    /// dropped. Status now lives per-line (unread/read) in the live store, so
    /// the separate `index.json` overlay is gone.
    public nonisolated var liveInboxPath: URL {
        dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
    }

    /// Persist an escalation and write an inbox card. Returns the new
    /// escalation id. Fail-closed: any persistence error throws.
    @discardableResult
    public func escalate(
        executionId: String,
        reason: WorkshopEscalationReason,
        question: String,
        checkpoint: WorkshopCheckpoint
    ) async throws -> String {
        // gpt-5.5 cross-feature review NEEDS_FIX: same path-safety guard as
        // SwiftNativeWorkshopCheckpointStore. Without this, an attacker (or a
        // misbehaving caller) could pass `../escape` and write the escalation
        // outside the missions/ namespace.
        let trimmedWorkshopExecutionId = try SwiftNativeWorkshopCheckpointStore.validateWorkshopExecutionIdAsSafeComponent(executionId)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            throw WorkshopCheckpointError.invalidEscalation("question must be non-empty")
        }
        let nowStr = formatISO8601(now())
        let escalationId = uuid()
        let escalation = WorkshopEscalation(
            id: escalationId,
            executionId: trimmedWorkshopExecutionId,
            ts: nowStr,
            reason: reason,
            question: trimmedQuestion,
            checkpoint: checkpoint
        )

        // 1) Persist escalations.jsonl under the cross-process lock.
        let escPath = escalationsPath(executionId: trimmedWorkshopExecutionId)
        let escPayload: JSONValue
        do {
            escPayload = try encodeToJSONValue(escalation)
        } catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "encode escalation failed: \(error)"
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: escPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await withLockedWrite(path: escPath) { [persistence] in
                try await persistence.appendJSONL(escPayload, to: escPath)
            }
        } catch let e as WorkshopCheckpointError {
            throw e
        } catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "appendJSONL escalation failed: \(error)"
            )
        }

        // 2) Surface the inbox card.
        //
        // Card shape mirrors NotificationInboxItem.toJSONValue():
        //   id, created_at, source, severity, title, summary, detail,
        //   related_mission_id, related_approval_id, related_paths,
        //   related_groups, actions, status, read_at
        //
        // Severity: brief asked for "warning" but the existing inbox vocab is
        // info|important|actionable (see NotificationInbox.swift L87). Use
        // "actionable" — the closest existing tier that triggers the user's
        // attention.
        let cardId = uuid()
        let detailText: String = {
            let head = "reason: \(reason.rawValue)"
            let body = checkpoint.summary
            if body.isEmpty { return head }
            return head + "\n\n" + body
        }()
        let card: JSONValue = .object([
            "id":                  .string(cardId),
            "created_at":          .string(nowStr),
            "source":              .string("workshop"),
            "severity":            .string("actionable"),
            "title":               .string("Workshop needs your input: \(trimmedWorkshopExecutionId)"),
            "summary":             .string(trimmedQuestion),
            "detail":              .string(detailText),
            "related_mission_id":  .string(trimmedWorkshopExecutionId),
            "related_approval_id": .null,
            "related_paths":       .null,
            "related_groups":      .null,
            "actions":             .array([
                .object(["id": .string("view"),    "label": .string("View")]),
                .object(["id": .string("approve"), "label": .string("Approve")]),
                .object(["id": .string("reject"),  "label": .string("Reject")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss")]),
            ]),
            "status":  .string("unread"),
            "read_at": .null,
        ])

        do {
            try FileManager.default.createDirectory(
                at: liveInboxPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // A5.2: append the card to the LIVE inbox the UI/getInboxItems/iOS
            // snapshot read, through the shared capped writer (1000-line budget,
            // its own flock). Status lives per-line, so there is no separate
            // index.json overlay to keep consistent. Fail-closed: any error
            // throws, same as the old silo write.
            try await appendJSONLCapped(
                card,
                to: liveInboxPath,
                using: persistence,
                maxLines: JSONLLineCaps.notificationInbox,
                logLabel: "WorkshopEscalator.inbox"
            )
        } catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "inbox card surface failed: \(error)"
            )
        }

        return escalationId
    }

    /// Read all escalations for a Workshop execution in file order. Missing file -> [].
    /// FAIL-CLOSED on malformed lines (parse OR decode). See
    /// readCheckpoints' comment for why we bypass PersistenceCore.readJSONL.
    public func readEscalations(executionId: String) async throws -> [WorkshopEscalation] {
        // gpt-5.5 cross-feature review-2 STILL-NEEDS-FIX: same path-traversal
        // guard the writers got. Read path was missed in round 1.
        let safe = try SwiftNativeWorkshopCheckpointStore.validateWorkshopExecutionIdAsSafeComponent(executionId)
        let path = escalationsPath(executionId: safe)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try readFailClosedJSONL(path)
    }

    /// Same flock helper shape as the checkpoint store — uniform for every
    /// conformer, not just SwiftNative (L7, 2026-08-01).
    private func withLockedWrite(
        path: URL,
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await persistence.withFileLock(path) {
            try await body()
        }
    }
}

// MARK: - File-private helpers

/// ISO-8601 with fractional seconds. Pure Swift-side format; no Python parity
/// is required for these files (they are new, not shared with the daemon).
fileprivate func formatISO8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

/// Encode any Encodable to a JSONValue by round-tripping through JSON bytes.
/// Uses JSONEncoder's default (alphabetical-ish) key order; `JSONValue.parse`
/// re-keys internally, so consumers that read by name are unaffected.
fileprivate func encodeToJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONValue.parse(data)
}

/// Decode any Decodable from a JSONValue by serializing to compact bytes and
/// running JSONDecoder.
fileprivate func decodeFromJSONValue<T: Decodable>(_ value: JSONValue) throws -> T {
    let data = try value.serializedData(pretty: false)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Fail-closed JSONL reader. Bypasses `PersistenceCore.readJSONL` because
/// that helper uses `compactMap { try? parse }` and silently drops
/// syntactically malformed/torn lines — which would defeat the brief's
/// fail-closed contract for the checkpoint + escalation logs. Here every
/// parse failure AND every decode failure throws
/// `WorkshopCheckpointError.persistenceFailure` with the offending line
/// number.
///
/// Blank lines (including the trailing newline `appendJSONL` writes) are
/// skipped. The caller has already confirmed the file exists.
fileprivate func readFailClosedJSONL<T: Decodable>(_ path: URL) throws -> [T] {
    let data: Data
    do { data = try Data(contentsOf: path) }
    catch {
        throw WorkshopCheckpointError.persistenceFailure(
            "read \(path.lastPathComponent) failed: \(error)"
        )
    }
    guard let text = String(data: data, encoding: .utf8) else {
        throw WorkshopCheckpointError.persistenceFailure(
            "\(path.lastPathComponent) is not valid UTF-8"
        )
    }
    var out: [T] = []
    // split on universal newlines; each non-blank line must parse + decode.
    let rawLines = text.split(whereSeparator: { $0.isNewline })
    out.reserveCapacity(rawLines.count)
    for (i, raw) in rawLines.enumerated() {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        let parsed: JSONValue
        do { parsed = try JSONValue.parse(Data(line.utf8)) }
        catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "parse \(path.lastPathComponent) line \(i) failed: \(error)"
            )
        }
        do { out.append(try decodeFromJSONValue(parsed) as T) }
        catch {
            throw WorkshopCheckpointError.persistenceFailure(
                "decode \(path.lastPathComponent) line \(i) failed: \(error)"
            )
        }
    }
    return out
}
