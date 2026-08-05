// Workshop → MemoryV2 plug (NORTHSTAR clause 1, "one mind").
//
// THE GAP THIS CLOSES (verified 2026-08-02, docs/build_plans/silo-dissolution-findings.md E-3):
// `MemoryRecordDisclosurePolicy` already maps the surface `workshop` → `missions`
// and carries `missions` in BOTH disclosure allowlists — her mind was READY to
// disclose execution memories. Nothing ever wrote one. Every non-test hit for that
// surface was a test fixture, while the live root held 56 completed Workshop
// executions. Dream/REM's only experiential input is the chat transcript, so the
// sole route into her mind was "did it produce a chat turn": every unattended
// execution she ran was work she could not remember doing.
//
// This file is the plug. On every TERMINAL Workshop execution the executor
// records one prose memory of what the execution was, what came of it, and whether
// it actually worked — successes and failures alike.
//
// WHAT THIS IS NOT: a receipt. `workshop/receipts.jsonl` (WorkshopDeskReceiptBridge)
// already holds the machine-readable terminal record and Desk reads it. A memory
// is the thing that has to survive being read back six weeks later out of context,
// so the narrative is prose with no ids in it, and the ids live in metadata.
// A deliberate consequence: re-running the same execution to the same outcome
// produces byte-identical text, which `SwiftNativeMemoryV2.store` collapses into
// a `recall_count` bump on the existing row instead of a second copy. Repetition
// becomes evidence, not clutter.

import Foundation
import MemoryV2
import PersistenceCore

// MARK: - Writer seam

/// One execution memory as retention sees it.
public struct WorkshopExecutionMemoryHandle: Sendable, Equatable {
    public let id: String
    /// ISO-8601, so lexicographic order IS chronological order.
    public let createdAt: String
    /// `workshop:<executionId>` — the only link back from a memory row to the
    /// execution that produced it, and what startup reconciliation matches on.
    public let source: String?

    public init(id: String, createdAt: String, source: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
    }
}

/// The narrow slice of MemoryV2 the Workshop lane needs. Narrow on purpose:
/// Workshop must be able to write and to PRUNE what it wrote, and nothing else.
/// Tests substitute a fake; production uses ``SwiftNativeWorkshopExecutionMemoryWriter``.
public protocol WorkshopExecutionMemoryWriting: Sendable {
    /// Returns the stored record id.
    func writeExecutionMemory(content: String, source: String, metadata: JSONValue) async throws -> String
    /// Every execution memory currently ACTIVE, for the retention sweep.
    func executionMemories(sourcePrefix: String) async throws -> [WorkshopExecutionMemoryHandle]
    /// Retire one execution memory out of the lane WITHOUT minting a content
    /// tombstone — see ``WorkshopExecutionMemory/retentionCap`` for why deletion
    /// is the wrong primitive here.
    func retireExecutionMemory(id: String) async throws
}

/// Production writer over the process-wide MemoryV2 store — the same
/// `memory/memory.sqlite` chat recall, dreams and the consolidator all use.
/// There is no second memory system here; that is the whole point.
public struct SwiftNativeWorkshopExecutionMemoryWriter: WorkshopExecutionMemoryWriting {
    private let memory: SwiftNativeMemoryV2

    public init(memory: SwiftNativeMemoryV2 = .shared) {
        self.memory = memory
    }

    public func writeExecutionMemory(
        content: String,
        source: String,
        metadata: JSONValue
    ) async throws -> String {
        try await memory.store(content: content, source: source, metadata: metadata).id
    }

    /// Bounded query, newest-first, ACTIVE rows only (gpt-5.5 review A4). This
    /// used to be `listMemory(kind:)` — a full active-store scan that decoded
    /// every row's metadata and then filtered in Swift, on the terminal path,
    /// after every successful write. `memoryHandles` reads three columns with a
    /// `source LIKE` predicate and a LIMIT.
    ///
    /// The limit is the cap plus a healthy backlog window: newest-first means
    /// everything past the cap in this window IS the eviction set, and a lane
    /// that somehow got further ahead than the window is caught by the next
    /// write rather than by one unbounded read.
    public func executionMemories(sourcePrefix: String) async throws -> [WorkshopExecutionMemoryHandle] {
        try await memory.memoryHandles(
            sourcePrefix: sourcePrefix,
            limit: WorkshopExecutionMemory.retentionCap + WorkshopExecutionMemory.retentionSweepWindow
        )
        .map { WorkshopExecutionMemoryHandle(id: $0.id, createdAt: $0.createdAt, source: $0.source) }
    }

    /// ARCHIVE, never delete (gpt-5.5 review A2). `deleteMemory` writes a
    /// rejection tombstone for the deleted CONTENT, and a tombstone means "this
    /// claim was rejected" — applying it to a row evicted for AGE poisons the
    /// lane: the next execution that produces the same prose is refused as
    /// `tombstoned`, and she silently stops remembering repeats. Archiving
    /// takes the row out of the active set and out of recall, mints no
    /// denylist entry, and leaves the history walkable.
    public func retireExecutionMemory(id: String) async throws {
        _ = try await memory.archiveMemory(id: id)
    }
}

// MARK: - Pure policy

/// Pure, testable decisions about what a finished execution is worth remembering.
public enum WorkshopExecutionMemory {
    /// `sourceRunId` prefix that marks a memory row as Workshop-written. This is
    /// the only handle retention has on its own rows, so it must stay stable.
    public static let sourcePrefix = "workshop:"

    /// `metadata.kind`. `operational` is a real entry in the MemoryKindStamp
    /// taxonomy with a 60-day recall half-life — execution history should fade in
    /// RANK as it ages rather than compete forever with identity-level facts.
    /// It also sits outside the semantic kind gate in
    /// `MemoryCandidateQuality.rejectionReason`, so an operational narrative is
    /// judged on rules 1-3 (empty / session-state / tool-transcript noise) and
    /// not on the preference-fragment heuristics, which is the correct read.
    public static let memoryKind = "operational"

    /// EVERY ADD HAS A REMOVE. MemoryV2's own removes do not cover this lane on
    /// their own: capacity eviction only fires above 2,000 rows and ranks an
    /// ordinary confirmed row the same as any fact, and the stale-archive pass
    /// (>365d, never recalled) is gated behind TWO human approvals. Left alone,
    /// an execution-per-completion write would slowly crowd User's facts out of a
    /// fixed-size store. So Workshop bounds its OWN rows: newest
    /// `retentionCap` survive, the rest are deleted on the next write, and each
    /// deletion is logged. Sized against the live volume (56 executions on the
    /// real root as of 2026-08-02) so it is roughly a year of history, not a
    /// silent truncation of the recent past.
    /// RETIREMENT IS AN ARCHIVE, NOT A DELETE — see
    /// ``SwiftNativeWorkshopExecutionMemoryWriter/retireExecutionMemory(id:)``.
    public static let retentionCap = 200

    /// How far past the cap ONE READ of the retention sweep looks. This bounds
    /// the QUERY, not the sweep: the sweep repeats the bounded read until the
    /// lane is at or below the cap (`retentionMaxPasses`).
    ///
    /// It used to bound the sweep itself, and that did not converge (gpt-5.5
    /// review, 2026-08-02): with 1,000 active `workshop:` rows the sweep read
    /// 400, archived the 200 oldest OF THAT SLICE, and left ~801 rows behind —
    /// creeping toward the cap only if more writes ever happened, and never
    /// converging if they did not. A cap that only holds when the lane stays
    /// busy is not a cap.
    public static let retentionSweepWindow = 200

    /// Backstop on the converging sweep. Each pass evicts up to
    /// `retentionSweepWindow` rows, so this covers a lane that is
    /// `retentionCap + 64 * retentionSweepWindow` (≈12,800) rows over — far
    /// beyond any real overshoot, and it makes a pathological store (or a
    /// failing archive) bail LOUD rather than spin.
    public static let retentionMaxPasses = 64

    /// Clip for free text lifted out of an execution (result payloads, error
    /// strings). Long enough to carry a real outcome, short enough that a memory
    /// stays a memory. Read-side recall clips at 2000 anyway.
    static let outcomeClip = 320

    public enum Decision: Sendable, Equatable {
        case remember
        /// Machine-readable reason, logged verbatim. Never silent.
        case drop(String)
    }

    /// The ONLY threshold in this lane, and it is deliberately close to zero.
    ///
    /// The temptation is to filter "trivial" executions. Resisted: an execution is
    /// something she was asked to do, and there is no honest way to know from
    /// the record which ones will matter later. The one case with genuinely
    /// nothing to remember is an execution cancelled before a single step ran —
    /// no work happened, so there is no outcome to recall. Everything else is
    /// remembered, and every drop is logged with its reason.
    ///
    /// Note what is NOT filtered: failures. An execution that failed on step one
    /// is the most instructive row in the store.
    public static func decide(_ record: WorkshopExecutionRecord) -> Decision {
        let status = record.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["completed", "failed", "cancelled"].contains(status) else {
            return .drop("non_terminal_status:\(status.isEmpty ? "empty" : status)")
        }
        if status == "cancelled" && record.stepsCompleted.isEmpty {
            return .drop("cancelled_before_any_step_ran")
        }
        if narrative(record, reason: nil).isEmpty {
            return .drop("no_describable_content")
        }
        return .remember
    }

    /// What she should actually remember: what the execution was, what came of it,
    /// and whether it worked. Prose, no identifiers — see the file header for
    /// why the ids stay in metadata.
    public static func narrative(_ record: WorkshopExecutionRecord, reason: String?) -> String {
        let name = executionName(record)
        guard !name.isEmpty else { return "" }
        let status = record.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var sentences: [String] = []

        // 1. What it was, and how it ended.
        switch status {
        case "completed":
            sentences.append("Workshop execution \"\(name)\" completed.")
        case "failed":
            sentences.append("Workshop execution \"\(name)\" failed.")
        case "cancelled":
            sentences.append("Workshop execution \"\(name)\" was cancelled before it finished.")
        default:
            sentences.append("Workshop execution \"\(name)\" ended as \(status).")
        }

        // 2. What it was FOR — only when the objective says more than the title.
        let objective = clip(collapse(record.objective), to: outcomeClip)
        if !objective.isEmpty, collapse(objective).lowercased() != name.lowercased() {
            sentences.append("The objective was: \(sentenceEnding(objective))")
        }

        // 3. How far it got.
        let counts = stepCounts(record)
        if counts.planned > 0 || counts.succeeded > 0 {
            sentences.append("\(counts.succeeded) of \(counts.planned) planned steps succeeded.")
        }

        // 4. Whether it actually worked — the honesty gate's own verdict, which
        //    is the difference between "the steps ran" and "the execution worked".
        if let verification = record.verification {
            switch verification.status {
            case .satisfied:
                sentences.append("The outcome was verified against the execution's own success criterion.")
            case .failed:
                let detail = clip(collapse(verification.detail), to: outcomeClip)
                sentences.append(
                    detail.isEmpty
                        ? "Verification of the declared outcome failed."
                        : "Verification of the declared outcome failed: \(sentenceEnding(detail))"
                )
            case .unverified:
                sentences.append("The outcome could not be verified from local evidence.")
            }
        }

        // 5. The payload — the result on success, the error on failure. The
        //    failure text is the reason the executor passed in (the step error),
        //    falling back to whatever the record carries.
        if status == "failed" || status == "cancelled" {
            let stated = collapse(reason ?? "")
            let why = clip(stated.isEmpty ? resultText(record) : stated, to: outcomeClip)
            if !why.isEmpty {
                sentences.append("What went wrong: \(sentenceEnding(why))")
            }
        } else {
            let outcome = clip(resultText(record), to: outcomeClip)
            if !outcome.isEmpty {
                sentences.append("What came of it: \(sentenceEnding(outcome))")
            }
        }

        // 6. Provenance that changes how much weight it deserves: an execution she
        //    started herself is a different fact from one User asked for.
        let trigger = collapse(record.triggerSource)
        if !trigger.isEmpty {
            sentences.append("It was started by \(trigger).")
        }

        return sentences.joined(separator: " ")
    }

    /// Everything a receipt would carry, kept OUT of the prose and available to
    /// anything that wants to walk back to the execution.
    ///
    /// `permittedSurfaces` is `MemoryRecordDisclosurePolicy.localPrivateSurfaces`
    /// verbatim rather than `["missions"]` alone. A missions-only row would be a
    /// silo with extra steps: she could recall her own work on the Workshop
    /// surface and nowhere else. These rows are User-private — they reach chat,
    /// Telegram, iOS, the agent bridge and executions, and never the
    /// prompt-injectable no-human surfaces (slack) that sit outside
    /// local_private.
    public static func metadata(_ record: WorkshopExecutionRecord, reason: String?) -> JSONValue {
        let counts = stepCounts(record)
        var object: [String: JSONValue] = [
            "kind": .string(memoryKind),
            "permittedSurfaces": .array(
                MemoryRecordDisclosurePolicy.localPrivateSurfaces.sorted().map(JSONValue.string)
            ),
            "tags": .array([.string("workshop"), .string("mission"), .string("execution:\(record.status)")]),
            "workshop_execution_id": .string(record.id),
            "workshop_status": .string(record.status),
            "workshop_trigger_source": .string(record.triggerSource),
            "workshop_steps_planned": .int(Int64(counts.planned)),
            "workshop_steps_succeeded": .int(Int64(counts.succeeded)),
            "observed_at": .string(record.updatedAt.isEmpty ? record.createdAt : record.updatedAt),
        ]
        if let handle = record.deskHandle, !handle.isEmpty {
            object["desk_handle"] = .string(handle)
        }
        if let verification = record.verification {
            object["workshop_verification"] = .string(verification.status.rawValue)
        }
        if let reason, !collapse(reason).isEmpty {
            object["workshop_terminal_reason"] = .string(clip(collapse(reason), to: outcomeClip))
        }
        return .object(object)
    }

    public static func source(for record: WorkshopExecutionRecord) -> String {
        "\(sourcePrefix)\(record.id)"
    }

    // MARK: internals

    static func executionName(_ record: WorkshopExecutionRecord) -> String {
        let title = clip(collapse(record.title), to: 160)
        if !title.isEmpty { return title }
        return clip(collapse(record.objective), to: 160)
    }

    static func stepCounts(_ record: WorkshopExecutionRecord) -> (planned: Int, succeeded: Int) {
        let succeeded = record.stepsCompleted.reduce(into: 0) { total, entry in
            guard case .object(let object) = entry,
                  case .string(let status)? = object["status"] else { return }
            if status.lowercased() == "succeeded" { total += 1 }
        }
        // `plan` is the planned length; a resumed/edited run can complete more
        // rows than it planned, so never report "3 of 2".
        return (max(record.plan.count, record.stepsCompleted.count), succeeded)
    }

    static func resultText(_ record: WorkshopExecutionRecord) -> String {
        switch record.result {
        case .string(let value):
            return collapse(value)
        case .object(let object):
            // The verification-failure shape the executor writes:
            // {"error": "verification_failed", "detail": "..."}.
            if case .string(let detail)? = object["detail"], !collapse(detail).isEmpty {
                return collapse(detail)
            }
            if case .string(let error)? = object["error"] {
                return collapse(error)
            }
            return ""
        default:
            return ""
        }
    }

    static func collapse(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func clip(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Close a lifted fragment as one sentence: strip the trailing punctuation
    /// it may already carry, then add exactly one period — unless the clip
    /// ellipsis is the last character, which already reads as an ending.
    static func sentenceEnding(_ value: String) -> String {
        var out = value
        while out.hasSuffix(".") || out.hasSuffix(" ") {
            out.removeLast()
        }
        if out.isEmpty { return "" }
        return out.hasSuffix("…") ? out : out + "."
    }
}

// MARK: - Logging

/// Severity, because production routes this sink through `Logger.info` and an
/// `info` line is NOT loud (gpt-5.5 review A1). A failed memory write is the
/// one thing in this lane a human must be able to find in a log.
public enum WorkshopExecutionMemoryLogLevel: String, Sendable, Equatable {
    case info
    case error
}

public typealias WorkshopExecutionMemoryLog =
    @Sendable (WorkshopExecutionMemoryLogLevel, String) -> Void

// MARK: - Recorder

/// Applies ``WorkshopExecutionMemory`` to a finished execution: decide, write,
/// then bound the lane. Never throws — a memory failure must not change what a
/// execution's terminal state is — but it is never silent either: every drop,
/// every failure and every retention deletion is logged.
public struct WorkshopExecutionMemoryRecorder: Sendable {
    private let writer: any WorkshopExecutionMemoryWriting
    private let log: WorkshopExecutionMemoryLog
    private let retentionCap: Int

    /// - Parameters:
    ///   - retentionCap: overridable so the retention path can be exercised
    ///     against a REAL store without writing 201 rows. Production always
    ///     takes the default.
    public init(
        writer: any WorkshopExecutionMemoryWriting,
        retentionCap: Int = WorkshopExecutionMemory.retentionCap,
        log: @escaping WorkshopExecutionMemoryLog = { _, message in
            NSLog("%@", message)
        }
    ) {
        self.writer = writer
        self.retentionCap = max(1, retentionCap)
        self.log = log
    }

    /// The recorder's own sink, so the queue in front of it logs to the same
    /// place (production: `Logger.error` for `.error`) instead of silently
    /// falling back to `NSLog`.
    public var logSink: WorkshopExecutionMemoryLog { log }

    /// Returns the written record id, or nil when nothing was written.
    @discardableResult
    public func record(_ record: WorkshopExecutionRecord, reason: String?) async -> String? {
        switch WorkshopExecutionMemory.decide(record) {
        case .drop(let why):
            log(.info, "[workshop-memory] DROPPED execution \(record.id) (status \(record.status)): \(why)")
            return nil
        case .remember:
            break
        }

        let content = WorkshopExecutionMemory.narrative(record, reason: reason)
        let id: String
        do {
            id = try await writer.writeExecutionMemory(
                content: content,
                source: WorkshopExecutionMemory.source(for: record),
                metadata: WorkshopExecutionMemory.metadata(record, reason: reason)
            )
        } catch {
            // Loud, then closed. The execution's terminal state is already durable;
            // what is lost is her recollection of it, and that must be visible.
            // `.error`, not `.info`: production hands this sink to
            // `Logger.info`, so the old severity-less line was invisible at
            // default log level (gpt-5.5 review A1).
            log(.error, "[workshop-memory] ERROR writing execution \(record.id) memory: \(error)")
            return nil
        }
        log(.info, "[workshop-memory] remembered execution \(record.id) (status \(record.status)) as memory \(id)")
        await pruneToCap()
        return id
    }

    /// Every execution memory this lane can currently see, by `source`. The
    /// startup crash-reconciliation read — see
    /// ``WorkshopExecutorLoop/reconcileMissedExecutionMemories(within:maxRecords:)``.
    public func recordedSources() async -> Set<String> {
        do {
            let handles = try await writer.executionMemories(
                sourcePrefix: WorkshopExecutionMemory.sourcePrefix
            )
            return Set(handles.compactMap(\.source))
        } catch {
            log(.error, "[workshop-memory] ERROR listing execution memories for reconciliation: \(error)")
            // An EMPTY set would read as "nothing is remembered" and re-write
            // every recent execution. Nil-shaped failure instead: the caller gets
            // no sources and reconciliation skips, loudly.
            return []
        }
    }

    /// Bounded-lane sweep — see ``WorkshopExecutionMemory/retentionCap``.
    /// ARCHIVES the overflow; it does not delete it (A2).
    ///
    /// CONVERGES IN ONE CALL (gpt-5.5 review, 2026-08-02). Each pass reads a
    /// BOUNDED window (`retentionCap + retentionSweepWindow`) and archives
    /// everything past the cap in it, then reads again; it stops when the lane
    /// is at or below the cap. The single-pass version left ~801 rows behind on
    /// a 1,000-row lane and only ever crept toward the cap on later writes.
    private func pruneToCap() async {
        var pass = 0
        while pass < WorkshopExecutionMemory.retentionMaxPasses {
            pass += 1
            let handles: [WorkshopExecutionMemoryHandle]
            do {
                handles = try await writer.executionMemories(sourcePrefix: WorkshopExecutionMemory.sourcePrefix)
            } catch {
                log(.error, "[workshop-memory] ERROR listing execution memories for retention: \(error)")
                return
            }
            guard handles.count > retentionCap else { return }
            // Newest first; ISO-8601 createdAt makes string order chronological.
            // Tie-break on id so the sweep is deterministic for same-instant rows.
            let ordered = handles.sorted {
                $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt
            }
            let evicted = ordered.dropFirst(retentionCap)
            log(
                .info,
                "[workshop-memory] retention: \(handles.count) execution memories exceeds cap "
                + "\(retentionCap); archiving \(evicted.count) oldest (pass \(pass))"
            )
            var archived = 0
            for handle in evicted {
                do {
                    try await writer.retireExecutionMemory(id: handle.id)
                    archived += 1
                    log(
                        .info,
                        "[workshop-memory] retention: archived execution memory \(handle.id) (created \(handle.createdAt))"
                    )
                } catch {
                    log(.error, "[workshop-memory] ERROR archiving execution memory \(handle.id): \(error)")
                }
            }
            // Nothing came out of the lane this pass — re-reading would return
            // the same rows forever. Stop, loudly; the archive errors above
            // already named each row.
            guard archived > 0 else {
                log(
                    .error,
                    "[workshop-memory] retention: made no progress with \(handles.count) rows over cap "
                    + "\(retentionCap) — lane is NOT bounded; see the archive errors above"
                )
                return
            }
        }
        log(
            .error,
            "[workshop-memory] retention: gave up after \(WorkshopExecutionMemory.retentionMaxPasses) passes; "
            + "the workshop lane is still above cap \(retentionCap)"
        )
    }
}

// MARK: - Off-the-hot-path queue

/// Serialized, fire-and-forget execution-memory writes.
///
/// WHY (gpt-5.5 review A1, BLOCKING): `emitTerminalEvent` used to AWAIT
/// `recorder.record`, and that call does a duplicate scan, a CoreML embed, a
/// SQLite insert, a retention query and up to N archive writes. SQLite busy for
/// its 2s timeout — or a stalled embedder — therefore held the executor's
/// terminal path, so `start()` / approval-resume / the drain loop did not move
/// on to the next queued execution even though the terminal CAS and the Desk
/// receipt had already landed. Her recollection of an execution must never be able
/// to hold up the next one.
///
/// The write is not LOST by being asynchronous: every enqueue is chained onto
/// the previous one (so execution order is preserved and two writes never race
/// the store), the recorder still logs its own failures at `.error`, and
/// ``drain()`` gives shutdown and tests a way to wait for the tail.
///
/// The chained work runs `Task.detached` on purpose: an inheriting `Task {}`
/// inside an actor method would run the slow write ON this actor and re-create
/// the stall one level down.
public actor WorkshopExecutionMemoryQueue {
    /// BACKPRESSURE, not a diagnostic (gpt-5.5 review, 2026-08-02). The queue
    /// used to be unbounded: with the head write hung in embed/SQLite, every
    /// later terminal event spawned another detached task awaiting
    /// `previous?.value`, each RETAINING a whole `WorkshopExecutionRecord`
    /// (plan, every step outcome, the result payload) for as long as the stall
    /// lasted. An unbounded queue in front of a stalled writer is a memory leak
    /// with a nice name.
    ///
    /// 64 is sized off the real lane: the live root held 56 completed
    /// executions TOTAL, so 64 pending writes is far past any honest burst and
    /// hitting it means the writer is wedged, not busy.
    public static let defaultMaxPending = 64

    private let recorder: WorkshopExecutionMemoryRecorder
    private let log: WorkshopExecutionMemoryLog
    private let maxPending: Int
    private var tail: Task<Void, Never>?
    private var enqueued: UInt64 = 0
    private var pending = 0
    private var dropped: UInt64 = 0

    public init(
        recorder: WorkshopExecutionMemoryRecorder,
        maxPending: Int = WorkshopExecutionMemoryQueue.defaultMaxPending,
        log: WorkshopExecutionMemoryLog? = nil
    ) {
        self.recorder = recorder
        self.maxPending = max(1, maxPending)
        self.log = log ?? recorder.logSink
    }

    /// Hand the write off. Returns as soon as it is chained — it never waits
    /// for the store.
    ///
    /// At the bound the write is DROPPED, and dropping is LOUD: the execution's
    /// identity goes into an `.error` line naming what she will not remember.
    /// Dropping the newest is deliberate — the queue is FIFO behind a stalled
    /// writer, so the rows already queued are older executions that would
    /// otherwise be lost too, and evicting them to make room for this one
    /// trades one lost memory for another while hiding the stall.
    public func enqueue(_ record: WorkshopExecutionRecord, reason: String?) {
        guard pending < maxPending else {
            dropped &+= 1
            log(
                .error,
                "[workshop-memory] QUEUE FULL (\(pending) writes pending, cap \(maxPending)) — DROPPED the "
                + "execution memory for \(record.id) (status \(record.status), \(dropped) dropped so far). "
                + "The execution record is durable; her recollection of THIS one is not. "
                + "The memory writer is stalled — check for an earlier [workshop-memory] ERROR."
            )
            return
        }
        let previous = tail
        let recorder = self.recorder
        enqueued &+= 1
        pending += 1
        tail = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            await recorder.record(record, reason: reason)
            await self?.finishOne()
        }
    }

    /// Called by each chained write as it completes — the REMOVE for the add in
    /// `enqueue`. Reentrant on purpose: `drain()` is suspended on `tail.value`
    /// while this runs, so the actor is free.
    private func finishOne() {
        pending = max(0, pending - 1)
    }

    /// Await every write enqueued so far, including any enqueued while this is
    /// waiting. Shutdown + test seam; never called on the terminal path.
    public func drain() async {
        while true {
            let generation = enqueued
            guard let tail else { return }
            await tail.value
            if generation == enqueued {
                self.tail = nil
                return
            }
        }
    }

    /// Sources already in the store — the reconciliation read, delegated so the
    /// executor never has to hold the writer itself.
    public func recordedSources() async -> Set<String> {
        await recorder.recordedSources()
    }

    /// How many writes have been handed off. Diagnostics only.
    public func enqueuedCount() -> UInt64 { enqueued }

    /// Writes chained but not yet finished. Read at shutdown to say how many
    /// memories were abandoned.
    public func pendingCount() -> Int { pending }

    /// Writes refused at the bound. Never silent — see `enqueue`.
    public func droppedCount() -> UInt64 { dropped }
}

// MARK: - Bounded wait

/// One-shot cross-task signal: the first `signal` wins, `wait` returns it.
///
/// Exists because a shutdown drain has to be BOUNDED, and the obvious spellings
/// are not: `withTaskGroup` waits for ALL children, and the drain child awaits
/// `Task.value`, which ignores cancellation — so a "race the drain against a
/// timer" written with a task group never returns while the writer is wedged,
/// which is the exact case it exists to survive.
final class WorkshopExecutionMemoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal(_ result: Bool) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = result
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: result)
    }

    /// Call once.
    func wait() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}
