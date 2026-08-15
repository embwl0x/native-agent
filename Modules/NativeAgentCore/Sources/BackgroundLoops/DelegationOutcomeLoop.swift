import Foundation
import PersistenceCore

// MARK: - Delegation outcome cards (W2b, upgrade campaign 2026-08 Track A)
//
// THE PROBLEM this closes (L1 themes 1/3/14, L2 Q1): W2 gave Agent a READ tool
// over the two wake-job stores (`delegation_status`), but reading is a pull.
// Nothing PUSHED. A delegated job could finish — or fail, or lose its delivery
// — and the only way anyone found out was by asking. The terminal transition
// was invisible unless someone happened to look at the right moment.
//
// This loop is the push side: every ~5 minutes it reads the same two stores,
// finds jobs that became terminal SINCE A DURABLE CURSOR, and files exactly one
// inbox card per newly-terminal job.
//
// ── THREE THINGS THAT WOULD MAKE THIS A NUISANCE, AND HOW EACH IS CLOSED ──
//
// 1. BACKFILL SPAM. The claude store keeps every job record forever (the file
//    IS the O_EXCL dedup marker), so at the moment this ships there are already
//    22 terminal jobs on User's machine. A cursor-less first tick would card all
//    of them. `advanceCursorOnly` seeding: when no cursor exists, the first tick
//    writes the cursor and files NOTHING, and says so in its outcome.
//
// 2. RE-FIRING THE SAME CARD. The cursor carries a bounded per-store set of
//    already-carded job ids alongside the `last_seen` stamp. A job is carded at
//    most once, and the id set is only mutated after the card WRITE SUCCEEDED —
//    a failed inbox write leaves the job un-carded so the next tick retries.
//    This mirrors `fileLoopFailureNotice`'s error-signature contract; the job
//    key IS the signature here, so the card carries it in the same
//    `error_signature` field the inbox already understands.
//
// 3. CALLING A JOB FINISHED THAT ISN'T. The projection's stall verdict treats
//    `delivering` and `spawn_failed` as "the run is over" — correct for a stall
//    question, WRONG for a completion card (a job mid-delivery has not produced
//    an outcome yet). So terminality here is decided independently, from an
//    explicit completion stamp or an explicit terminal status word, never from
//    the stall basis. See `DelegationJobSnapshot.terminalOutcome`.
//
// DEPENDENCY POSTURE: this module does not import ChatOrchestration (it
// doesn't depend on it, and adding that edge would drag the entire tool stack
// into BackgroundLoops). The store read is an injected closure that yields
// `DelegationJobSnapshot` values — a field-for-field mirror of the card-relevant
// half of `DelegationJobProjection` — and the app assembly does the mapping.
// Same seam as `EvolutionProposalRetentionLoop.sweep`.

// MARK: - Snapshot input

/// One job as this loop needs to see it. Every field is a RAW passthrough of
/// the corresponding `DelegationJobProjection` field — no re-derivation, so the
/// two cannot drift into disagreeing about what a record says.
public struct DelegationJobSnapshot: Sendable, Equatable {
    public var id: String
    /// "claude" | "codex" — which store the row came from.
    public var source: String
    public var agent: String
    public var topicSlug: String?
    public var state: String?
    /// Claude's `status` ("completed" / "failed"). Absent on codex records.
    public var status: String?
    /// Claude's `runStatus`; codex's `completedExecution.turnResult.status`.
    public var runStatus: String?
    public var completedAt: String?
    /// "delivered" | "lost" | "unknown" | nil.
    public var deliveryOutcome: String?
    /// Only set when the record ITSELF asserts it (claude's `deliveryLost`).
    public var deliveryLost: Bool?
    public var completionTextHead: String?

    public init(
        id: String,
        source: String,
        agent: String,
        topicSlug: String? = nil,
        state: String? = nil,
        status: String? = nil,
        runStatus: String? = nil,
        completedAt: String? = nil,
        deliveryOutcome: String? = nil,
        deliveryLost: Bool? = nil,
        completionTextHead: String? = nil
    ) {
        self.id = id
        self.source = source
        self.agent = agent
        self.topicSlug = topicSlug
        self.state = state
        self.status = status
        self.runStatus = runStatus
        self.completedAt = completedAt
        self.deliveryOutcome = deliveryOutcome
        self.deliveryLost = deliveryLost
        self.completionTextHead = completionTextHead
    }

    /// Status words that mean the RUN produced an outcome. Deliberately does
    /// NOT include `delivering` (the run ended, the answer is still in flight —
    /// carding it as finished would be premature) or bare `settled` without a
    /// status (the claude runner stamps `state: settled` alongside a status;
    /// a settled record with no status word and no completedAt is a shape we
    /// have never observed, and inventing an outcome for it is exactly the
    /// fabrication this campaign is removing).
    static let terminalStatusWords: Set<String> = [
        "completed", "complete", "succeeded", "success", "ok",
        "failed", "failure", "error", "errored",
        "timeout", "timed_out", "cancelled", "canceled", "aborted",
        "spawn_failed", "refused",
    ]

    static let failureStatusWords: Set<String> = [
        "failed", "failure", "error", "errored",
        "timeout", "timed_out", "cancelled", "canceled", "aborted",
        "spawn_failed", "refused",
    ]

    /// The status word this record actually carries, if any. `runStatus` wins
    /// because on the claude record it is the runner's own verdict while
    /// `status` is the job-file's coarser state; on codex records only
    /// `runStatus` (the turnResult status) exists at all.
    var statusWord: String? {
        let raw = runStatus ?? status
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// True when this record proves the run ENDED with an outcome.
    public var isTerminal: Bool {
        if completedAt != nil { return true }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return true }
        return false
    }

    /// The outcome this record proves. `nil` when the job is not terminal.
    public var terminalOutcome: DelegationOutcome? {
        guard isTerminal else { return nil }
        // Proven-lost outranks everything: a job whose answer never reached
        // Agent is a failure of the delegation regardless of how the run went.
        if deliveryLost == true || deliveryOutcome == "lost" { return .deliveryLost }
        if let statusWord, Self.failureStatusWords.contains(statusWord) { return .failed }
        // Completed, but the bridge could not confirm the handoff. NOT folded
        // into success — "we don't know if you got the answer" is precisely the
        // condition that produced the L1#1 blind spot.
        if deliveryOutcome == "unknown" { return .unknown }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return .succeeded }
        // completedAt with no status word at all: it ended, we cannot say how.
        return .unknown
    }

    /// The instant used to order this job against the cursor. `nil` when the
    /// record carries no completion stamp — such a job is deduped by id alone.
    var completionStamp: Date? { DelegationOutcomeCursor.parseISO(completedAt) }
}

/// What a terminal delegated job amounted to.
public enum DelegationOutcome: String, Sendable, Equatable {
    case succeeded
    case failed
    case deliveryLost = "delivery_lost"
    case unknown

    /// Only a clean success is `info`. Everything else is `actionable` —
    /// including `unknown`, because an unconfirmed delivery is a thing User may
    /// need to act on, and grading it `info` would bury it.
    public var severity: String { self == .succeeded ? "info" : "actionable" }
}

// MARK: - Card

/// One inbox card for one terminal delegated job.
public struct DelegationOutcomeCard: Sendable, Equatable {
    /// Stable inbox row id: `delegation-outcome:<source>:<jobId>`.
    public let cardId: String
    /// `<source>:<jobId>` — the replay-guard signature, carried in the card's
    /// `error_signature` field so the existing sticky-card machinery applies.
    public let jobKey: String
    public let source: String
    public let agent: String
    public let topicSlug: String?
    public let outcome: DelegationOutcome
    public let title: String
    public let summary: String
    public let detail: String
    public let createdAt: String

    public var severity: String { outcome.severity }

    /// Same field set and ordering conventions as `fileDiskHygieneNotice` /
    /// `fileLoopFailureNotice` — an inbox reader must not need to know which
    /// writer produced a row.
    public func toJSON() -> JSONValue {
        var actions: [JSONValue] = [
            .object(["id": .string("view"), "label": .string("View"),
                     "description": .string("See the delegation outcome detail")]),
        ]
        if outcome != .succeeded {
            actions.append(.object([
                "id": .string("archive"), "label": .string("Archive"),
                "description": .string("Archive this card"),
            ]))
        }
        actions.append(.object([
            "id": .string("dismiss"), "label": .string("Dismiss"),
            "description": .string("Dismiss this card"),
        ]))
        return .object([
            "id": .string(cardId),
            "created_at": .string(createdAt),
            "source": .string("delegation_outcome"),
            "severity": .string(severity),
            "title": .string(String(title.prefix(200))),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(String(detail.prefix(2_000))),
            "related_mission_id": .null,
            "related_approval_id": .null,
            "related_paths": .array([]),
            "related_groups": .array([]),
            "actions": .array(actions),
            // The replay guard, in the field the inbox already reads for it.
            "error_signature": .string(jobKey),
            "status": .string("unread"),
            "read_at": .null,
        ])
    }

    /// Human-facing agent name. The stores are keyed by lowercase source ids;
    /// a card that said "codex finished" in lowercase would read as a typo.
    public static func displayName(source: String, agent: String) -> String {
        switch (agent.isEmpty ? source : agent).lowercased() {
        case "claude", "claude": return "Claude"
        case "codex": return "Codex"
        case let other: return other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    public static func make(from job: DelegationJobSnapshot, now: Date) -> DelegationOutcomeCard? {
        guard let outcome = job.terminalOutcome else { return nil }
        let name = displayName(source: job.source, agent: job.agent)
        let topic = job.topicSlug.flatMap { $0.isEmpty ? nil : $0 }
        let topicPhrase = topic.map { ": \($0)" } ?? ""
        let head = job.completionTextHead?.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        let summary: String
        var reasonLine: String?
        switch outcome {
        case .succeeded:
            title = "\(name) finished"
            summary = "\(name) finished\(topicPhrase)"
        case .failed:
            title = "\(name) delegation failed"
            let word = job.statusWord ?? "failed"
            summary = "\(name) failed\(topicPhrase) (\(word))"
            reasonLine = "The run ended with status \"\(word)\"."
        case .deliveryLost:
            title = "\(name) reply was lost"
            summary = "\(name) finished\(topicPhrase) but the reply never arrived"
            reasonLine = "The bridge recorded this job's delivery as LOST — the run's "
                + "answer did not reach NativeAgent. Anything it says below is the "
                + "job record's own copy of the completion text."
        case .unknown:
            title = "\(name) outcome is unconfirmed"
            summary = "\(name) finished\(topicPhrase); delivery unconfirmed"
            reasonLine = "The run ended, but the bridge could not confirm whether the "
                + "reply was delivered. That is NOT the same as lost — it means "
                + "unverified either way."
        }

        var detailLines: [String] = []
        if let reasonLine { detailLines.append(reasonLine) }
        detailLines.append("Agent: \(name)  ·  Job: \(job.id)")
        if let topic { detailLines.append("Topic: \(topic)") }
        if let completedAt = job.completedAt { detailLines.append("Completed: \(completedAt)") }
        if let head, !head.isEmpty {
            detailLines.append("")
            detailLines.append("--- completion text (first \(head.count) characters on record) ---")
            detailLines.append(head)
        } else if outcome == .succeeded {
            // Absence is normal and means DELIVERED — the claude runner nulls
            // completionText once the handoff succeeds. Saying so stops the
            // card reading as "finished with nothing to show for it".
            detailLines.append("")
            detailLines.append("No completion text is retained on the job record. That is "
                + "normal for a delivered job — the runner clears the text once the "
                + "reply reaches NativeAgent.")
        }

        return DelegationOutcomeCard(
            cardId: "delegation-outcome:\(job.source):\(job.id)",
            jobKey: "\(job.source):\(job.id)",
            source: job.source,
            agent: job.agent,
            topicSlug: topic,
            outcome: outcome,
            title: title,
            summary: summary,
            detail: detailLines.joined(separator: "\n"),
            createdAt: DelegationOutcomeCursor.formatISO(now)
        )
    }
}

// MARK: - Durable cursor

/// Per-store "everything terminal at or before this point has been handled"
/// marker, plus the bounded set of job ids already carded.
///
/// Both halves are load-bearing and neither is sufficient alone: the stamp
/// bounds the work (and survives id-set eviction), while the id set catches the
/// records that carry no completion stamp and the equal-timestamp boundary.
public struct DelegationOutcomeCursor: Sendable, Equatable {
    public struct StoreCursor: Sendable, Equatable {
        /// Newest completion stamp already handled. `nil` means unseeded.
        public var lastSeen: Date?
        /// Job ids already carded, newest-last. Bounded by `cardedIDLimit`.
        public var cardedIDs: [String]

        public init(lastSeen: Date? = nil, cardedIDs: [String] = []) {
            self.lastSeen = lastSeen
            self.cardedIDs = cardedIDs
        }
    }

    /// Keyed by store source id ("claude" / "codex").
    public var stores: [String: StoreCursor]

    public init(stores: [String: StoreCursor] = [:]) {
        self.stores = stores
    }

    /// How many carded ids each store retains. Chosen well above the live store
    /// sizes (22 claude jobs at HEAD) so eviction is not the normal path; the
    /// `lastSeen` stamp is what keeps correctness once eviction does happen.
    public static let cardedIDLimit = 500

    public func store(_ source: String) -> StoreCursor {
        stores[source] ?? StoreCursor()
    }

    public mutating func record(source: String, id: String, stamp: Date?) {
        var cursor = store(source)
        if !cursor.cardedIDs.contains(id) {
            cursor.cardedIDs.append(id)
            if cursor.cardedIDs.count > Self.cardedIDLimit {
                cursor.cardedIDs.removeFirst(cursor.cardedIDs.count - Self.cardedIDLimit)
            }
        }
        if let stamp, stamp > (cursor.lastSeen ?? Date.distantPast) {
            cursor.lastSeen = stamp
        }
        stores[source] = cursor
    }

    // MARK: Codable-by-hand (the on-disk shape is snake_case JSON, and a
    // Codable synthesis would silently rename the keys if a field is renamed).

    public static func load(from url: URL) -> DelegationOutcomeCursor? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONValue.parse(data),
              case .object(let root) = parsed,
              case .object(let stores)? = root["stores"] else { return nil }
        var result = DelegationOutcomeCursor()
        for (source, value) in stores {
            guard case .object(let obj) = value else { continue }
            var cursor = StoreCursor()
            if case .string(let iso)? = obj["last_seen"] { cursor.lastSeen = parseISO(iso) }
            if case .array(let ids)? = obj["carded_ids"] {
                cursor.cardedIDs = ids.compactMap {
                    if case .string(let s) = $0 { return s }
                    return nil
                }
            }
            result.stores[source] = cursor
        }
        return result
    }

    public func toJSON() -> JSONValue {
        var stores: [String: JSONValue] = [:]
        for (source, cursor) in self.stores {
            var obj: [String: JSONValue] = [
                "carded_ids": .array(cursor.cardedIDs.map { .string($0) }),
            ]
            if let lastSeen = cursor.lastSeen {
                obj["last_seen"] = .string(Self.formatISO(lastSeen))
            }
            stores[source] = .object(obj)
        }
        return .object([
            "version": .int(1),
            "stores": .object(stores),
        ])
    }

    /// Atomic write — a torn cursor would either re-card everything or skip a
    /// window, and both are user-visible.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try toJSON().serializedData(pretty: false)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        // replaceItemAt REQUIRES an existing destination, so the first write
        // (the seeding tick — the one that matters most) has to move instead.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    /// Both bridge writers emit `new Date().toISOString()`; the no-fraction
    /// variant is the fallback for hand-edited or older records. Same policy as
    /// `DelegationStatusProjector.date` — deliberately duplicated rather than
    /// shared, because sharing it would require the module edge this file
    /// exists to avoid.
    public static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }

    public static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - The loop

public struct DelegationOutcomeLoop: LoopRunner {
    public let loopId: String = "delegation_outcome"
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 120 }

    /// Reads both wake-job stores. Injected — see the dependency note at the
    /// top of this file.
    private let readJobs: @Sendable () async -> [DelegationJobSnapshot]
    /// Upserts one inbox card. Returns whether the row actually landed; a
    /// `false` leaves the job un-carded so the next tick retries it.
    private let fileCard: @Sendable (DelegationOutcomeCard) async -> Bool
    private let cursorPath: URL
    private let clock: @Sendable () -> Date

    /// Cards filed per tick. A ceiling exists so a store that suddenly reveals
    /// a hundred terminal jobs (a restored backup, a cursor reset) cannot dump
    /// a hundred rows into the inbox at once. Never silent — the tick outcome
    /// names the remainder (`no_silent_caps`).
    public static let maxCardsPerTick = 10

    public init(
        interval: TimeInterval = 5 * 60,
        cursorPath: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        readJobs: @escaping @Sendable () async -> [DelegationJobSnapshot],
        fileCard: @escaping @Sendable (DelegationOutcomeCard) async -> Bool
    ) {
        self.interval = interval
        self.cursorPath = cursorPath
        self.clock = clock
        self.readJobs = readJobs
        self.fileCard = fileCard
    }

    /// Conventional cursor location under a data root.
    public static func defaultCursorPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("delegation_outcome_cursor.json")
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        let jobs = await readJobs()
        let terminal = jobs.filter { $0.isTerminal }

        // FIRST RUN: seed and file nothing. Every job visible right now predates
        // this loop's existence; carding them would be a history dump, not a
        // notification.
        guard var cursor = DelegationOutcomeCursor.load(from: cursorPath) else {
            var seeded = DelegationOutcomeCursor()
            for job in terminal {
                seeded.record(source: job.source, id: job.id, stamp: job.completionStamp)
            }
            do {
                try seeded.write(to: cursorPath)
            } catch {
                return .failed(error: "delegation outcome cursor seed failed: \(error)")
            }
            return .completed(result:
                "seeded delegation outcome cursor over \(terminal.count) pre-existing terminal job(s); no cards filed")
        }

        let pending = terminal.filter { job in
            let store = cursor.store(job.source)
            if store.cardedIDs.contains(job.id) { return false }
            // A job whose completion predates the cursor was already handled in
            // an earlier tick (or by the seed) and has simply aged out of the
            // id set. Not new.
            if let stamp = job.completionStamp, let lastSeen = store.lastSeen, stamp <= lastSeen {
                return false
            }
            return true
        }
        guard !pending.isEmpty else {
            return .completed(result: "no newly-terminal delegated jobs (\(terminal.count) terminal on record)")
        }

        // Oldest first: the inbox reads newest-last, and a burst should land in
        // the order the work actually finished.
        let ordered = pending.sorted {
            ($0.completionStamp ?? .distantPast, $0.id) < ($1.completionStamp ?? .distantPast, $1.id)
        }
        let batch = ordered.prefix(Self.maxCardsPerTick)
        let deferred = ordered.count - batch.count

        var filed = 0
        var failed = 0
        for job in batch {
            guard let card = DelegationOutcomeCard.make(from: job, now: now) else { continue }
            if await fileCard(card) {
                cursor.record(source: job.source, id: job.id, stamp: job.completionStamp)
                filed += 1
            } else {
                // Leave it un-carded. The cursor stamp is NOT advanced past it
                // either, because `record` is the only thing that moves it.
                failed += 1
            }
        }

        do {
            try cursor.write(to: cursorPath)
        } catch {
            // The cards landed; the cursor did not. Report it as a failure so
            // the loop's own health surface shows it — the next tick would
            // otherwise re-file everything this tick just filed.
            return .failed(error: "delegation outcome cursor write failed after \(filed) card(s): \(error)")
        }

        var result = "filed \(filed) delegation outcome card(s)"
        if failed > 0 { result += "; \(failed) inbox write(s) failed and will retry next tick" }
        if deferred > 0 { result += "; \(deferred) more deferred by the per-tick cap" }
        if filed == 0 && failed == 0 {
            return .skipped(reason: "no terminal outcome could be classified from \(pending.count) pending job(s)")
        }
        return .completed(result: result)
    }
}
