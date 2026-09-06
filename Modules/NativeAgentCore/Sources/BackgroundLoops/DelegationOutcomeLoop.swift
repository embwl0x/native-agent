import Foundation
import PersistenceCore

// MARK: - Delegation outcome cards (W2b, upgrade campaign 2026-08 Track A)
//
// THE PROBLEM this closes (L1 themes 1/3/14, L2 Q1): W2 gave Agent a READ tool
// over the bridge wake-job stores (`delegation_status`), but reading is a pull.
// Nothing PUSHED. A delegated job could finish — or fail, or lose its delivery
// — and the only way anyone found out was by asking. The terminal transition
// was invisible unless someone happened to look at the right moment.
//
// This loop is the push side: it reacts to store changes and periodically repairs,
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

/// One store read: the readable jobs AND whether every configured store
/// actually answered.
///
/// 2026-09-06: the loop used to take the array alone, which cannot tell an
/// EMPTY store from one whose directory (or one job file inside it) could not
/// be read. A job that vanishes that way is not carded — and if a newer sibling
/// settles in the same tick, `last_seen` advances past the missing job, so when
/// it becomes readable again it is rejected as older and never speaks at all.
public struct DelegationJobsRead: Sendable, Equatable {
    public var jobs: [DelegationJobSnapshot]
    /// False when a store directory, job file, or ledger line could not be read
    /// or parsed. An ABSENT store is readable — a bridge that is not configured
    /// on this machine is not a failed read.
    public var allStoresReadable: Bool

    public init(jobs: [DelegationJobSnapshot], allStoresReadable: Bool) {
        self.jobs = jobs
        self.allStoresReadable = allStoresReadable
    }
}

/// One job as this loop needs to see it. Every field is a RAW passthrough of
/// the corresponding `DelegationJobProjection` field — no re-derivation, so the
/// two cannot drift into disagreeing about what a record says.
public struct DelegationJobSnapshot: Sendable, Equatable {
    public var id: String
    /// The identity returned to the dispatching turn. This differs from the
    /// Codex bridge's internal reply-job id and is the key the motor lifecycle
    /// opened under.
    public var motorOwnerID: String?
    /// "claude" | "codex" | "omp" — which store the row came from.
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
    public var recoveryNote: String?
    /// Exact stable Desk handle explicitly bound at delegation time. Never
    /// inferred from a topic or title.
    public var deskHandle: String?
    /// Existing bridge/job liveness verdict from `DelegationStatusProjector`.
    /// This loop consumes it; it never recomputes a stall from wall time.
    public var stalled: Bool
    /// Raw `DelegationJobProjection.StallBasis` value (for example
    /// `deadline` or `stall_seconds`). Kept as a string to preserve the
    /// intentional module boundary between BackgroundLoops and
    /// ChatOrchestration.
    public var stallBasis: String?
    public var lastLiveness: String?

    public init(
        id: String,
        motorOwnerID: String? = nil,
        source: String,
        agent: String,
        topicSlug: String? = nil,
        state: String? = nil,
        status: String? = nil,
        runStatus: String? = nil,
        completedAt: String? = nil,
        deliveryOutcome: String? = nil,
        deliveryLost: Bool? = nil,
        completionTextHead: String? = nil,
        recoveryNote: String? = nil,
        deskHandle: String? = nil,
        stalled: Bool = false,
        stallBasis: String? = nil,
        lastLiveness: String? = nil
    ) {
        self.id = id
        self.motorOwnerID = motorOwnerID
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
        self.recoveryNote = recoveryNote
        self.deskHandle = deskHandle
        self.stalled = stalled
        self.stallBasis = stallBasis
        self.lastLiveness = lastLiveness
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

    /// 2026-09-06: the run ended and the answer is still in flight. The claude
    /// runner stamps `state: delivering` TOGETHER with `runStatus` before it
    /// awaits the bridge POST, so the run's verdict is on disk while nothing
    /// has been handed over yet. `statusWord` reads `runStatus` first, so the
    /// exclusion of `delivering` from `terminalStatusWords` never applied: a
    /// worker that died in the POST was carded as finished, with no evidence
    /// anything was delivered, and never stalled either.
    var isDelivering: Bool {
        guard completedAt == nil, deliveryOutcome == nil, deliveryLost != true else {
            return false
        }
        return state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "delivering"
    }

    /// True when this record proves the run ENDED with an outcome.
    public var isTerminal: Bool {
        if completedAt != nil { return true }
        // Delivery evidence — the settlement written AFTER the POST — is what
        // makes a finished run terminal.
        if isDelivering { return false }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return true }
        return false
    }

    /// The outcome this record proves. `nil` when the job is not terminal.
    public var terminalOutcome: DelegationOutcome? {
        guard isTerminal else { return nil }
        // Proven-lost outranks everything: a job whose answer never reached
        // Agent is a failure of the delegation regardless of how the run went.
        if deliveryLost == true || deliveryOutcome == "lost" { return .deliveryLost }
        // Execution may have completed or failed, but an explicitly blocked
        // handoff is never a successful delegation or permission to rerun it.
        // Reuse the existing actionable uncertainty outcome/cursor class.
        if deliveryOutcome == "blocked" { return .unknown }
        // User, 2026-09-04: a wake that found an interactive Claude open spawns
        // nothing and leaves the message in her inbox, which her session hook
        // reads. That is the handoff working, not an unconfirmed delivery.
        if statusWord == "delivered_live" { return .succeeded }
        // 2026-09-06: the wake helper could not scan this Mac for an open
        // session, so it spawned nothing and left the row in the inbox.
        // Whether anything will read it is genuinely unknown — never success.
        if statusWord == "delivered_inbox" { return .unknown }
        if let statusWord, Self.failureStatusWords.contains(statusWord) { return .failed }
        // Completed, but the bridge could not confirm the handoff. NOT folded
        // into success — "we don't know if you got the answer" is precisely the
        // condition that produced the L1#1 blind spot.
        if deliveryOutcome == "unknown" { return .unknown }
        if let statusWord, Self.terminalStatusWords.contains(statusWord) { return .succeeded }
        // completedAt with no status word at all: it ended, we cannot say how.
        return .unknown
    }

    /// Shared resident-action projection for an asynchronous builder handoff.
    /// A clean runner completion is deliberately still `unverified`: it proves
    /// the delegated agent returned, not that its answer satisfied Agent's
    /// original request.
    public func motorActionReadModel() -> MotorActionReadModel {
        let phase: MotorActionPhase
        let verification: MotorVerificationState
        let next: String?
        if isTerminal && deliveryOutcome == "blocked" && deliveryLost != true {
            phase = .blocked
            verification = .unknown
            next = "Inspect the retained result and resolve the original completion route before explicitly delivering it. Do not rerun the worker."
        } else if stalled && !isTerminal {
            phase = .blocked
            verification = .pending
            next = "Fresh bridge liveness or a terminal runner outcome."
        } else {
            switch terminalOutcome {
            case .succeeded:
                phase = .succeeded
                verification = .unverified
                next = "The agent must assess the returned result against the originating request."
            case .failed, .deliveryLost:
                phase = .failed
                verification = .failed
                next = deliveryLost == true || deliveryOutcome == "lost"
                    ? "Recover or replay the undelivered reply before relying on the delegation."
                    : "Inspect the canonical bridge failure before retrying or replacing the work."
            case .unknown:
                phase = .unknown
                verification = .unknown
                next = "Resolve the bridge's unconfirmed delivery before relying on the delegation."
            case nil:
                let normalized = (state ?? "").lowercased()
                phase = ["running", "claimed", "bound", "watching", "executing"].contains(normalized)
                    ? .running : .waitingExternal
                verification = .pending
                next = "A terminal runner outcome tied to this bridge message id."
            }
        }
        let stateParts = [source, state, status, runStatus, deliveryOutcome]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return MotorActionReadModel(
            domain: "agent_bridge",
            actionIdentity: CausalTransitionEvidence.opaqueIdentity(motorOwnerID ?? id),
            phase: phase,
            domainState: stateParts.joined(separator: ":"),
            verification: verification,
            expectedNextEvidence: next,
            updatedAt: completedAt ?? lastLiveness,
            cancellationIdentity: nil,
            deadline: nil
        )
    }

    /// The instant used to order this job against the cursor. `nil` when the
    /// record carries no completion stamp — such a job is deduped by id alone.
    var completionStamp: Date? { DelegationOutcomeCursor.parseISO(completedAt) }
}

/// What a terminal delegated job amounted to.
public enum DelegationOutcome: String, Sendable, Equatable, CaseIterable {
    case succeeded
    case failed
    case deliveryLost = "delivery_lost"
    case unknown

    /// Only a clean success is `info`. Everything else is `actionable` —
    /// including `unknown`, because an unconfirmed delivery is a thing User may
    /// need to act on, and grading it `info` would bury it.
    public var severity: String { self == .succeeded ? "info" : "actionable" }

    /// How alarming the outcome is, for the one-way re-card rule: a job already
    /// carded under a LOWER rank is carded again when it later presents a
    /// higher one. The codex record is the reason this exists — it is written
    /// with `completedExecution` BEFORE the delivery POST, so the loop first
    /// sees it as `succeeded`; if the POST then settles 409 the job is preserved
    /// under `reply-jobs/undelivered/` and presents as `unknown`. Without this
    /// rank the id-only cursor kept the "finished" card forever (live
    /// 2026-08-21: 10 of 11 preserved replies carried a "Codex finished" card).
    /// The rule is one-way on purpose: an outcome never improves after the
    /// fact, and a card must never quietly downgrade.
    public var alarmRank: Int {
        switch self {
        case .succeeded: return 0
        case .unknown: return 1
        case .failed: return 2
        case .deliveryLost: return 3
        }
    }
}

// MARK: - Card

/// One inbox card for one terminal delegated job — or, for the codex
/// `undelivered/` backlog, one rolling aggregate card (see `makeBacklog`).
public struct DelegationOutcomeCard: Sendable, Equatable {
    /// Stable inbox row id: `delegation-outcome:<source>:<jobId>`.
    public let cardId: String
    /// `<source>:<jobId>` — the job's identity, stable across re-cards.
    public let jobKey: String
    public let source: String
    public let agent: String
    public let topicSlug: String?
    public let outcome: DelegationOutcome
    public let title: String
    public let summary: String
    public let detail: String
    public let createdAt: String
    /// Severity override for cards whose severity is not a function of
    /// `outcome` (the backlog aggregate is `info`: its per-job cards already
    /// pushed, and a second push per 409 would be a storm). nil = derive.
    public var severityOverride: String? = nil
    /// A resolved card is written already-read: the condition it reported has
    /// cleared and the row exists only so the board stops asserting it.
    public var resolved: Bool = false

    public var severity: String { severityOverride ?? outcome.severity }

    /// The replay-guard signature, carried in the card's `error_signature`
    /// field so the existing sticky-card machinery applies. It names the
    /// OUTCOME as well as the job: a re-card that upgrades a job (finished →
    /// unconfirmed) must land as a fresh unread row and push, while a retry
    /// of the SAME outcome (a cursor write that failed after the card landed)
    /// must keep the user's status and never push twice. Legacy rows carry the
    /// bare `jobKey`; the app-side upsert treats that as matching too.
    public var signature: String { "\(jobKey):\(outcome.rawValue)" }

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
                "id": .string("archive"), "label": .string(outcome == .unknown ? "Acknowledge" : "Archive"),
                "description": .string("Archive this card only; preserve the original reply and never replay it"),
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
            "error_signature": .string(signature),
            "status": .string(resolved ? "read" : "unread"),
            "read_at": resolved ? .string(createdAt) : .null,
        ])
    }

    /// Human-facing agent name. The stores are keyed by lowercase source ids;
    /// a card that said "codex finished" in lowercase would read as a typo.
    public static func displayName(source: String, agent: String) -> String {
        switch (agent.isEmpty ? source : agent).lowercased() {
        case "claude", "claude": return "Claude"
        case "codex": return "Codex"
        case "omp": return "OMP"
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
        case .unknown where job.statusWord == "delivered_inbox":
            title = "\(name) message is waiting in the inbox"
            summary = "\(name) has it\(topicPhrase) in the inbox; live presence unknown"
            reasonLine = "No unattended session was started, and this Mac could not be "
                + "scanned for an open session, so whether a live session will read the "
                + "inbox row is unknown. Nothing ran and nothing was interrupted."
        case .succeeded where job.statusWord == "delivered_live":
            title = "\(name) has it"
            summary = "\(name) has it\(topicPhrase); the open session took the message"
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
            if job.deliveryOutcome == "blocked" {
                title = "\(name) result delivery is blocked"
                summary = "\(name) run \(job.statusWord ?? "unknown")\(topicPhrase); delivery blocked"
                reasonLine = "The run ended with status \"\(job.statusWord ?? "unknown")\", but its result handoff is blocked. "
                    + "Inspect the retained result and resolve the original completion route before explicitly delivering it. Do not rerun the worker."
            } else {
                title = "\(name) outcome is unconfirmed"
                summary = "\(name) finished\(topicPhrase); delivery unconfirmed"
                reasonLine = "The run ended, but the bridge could not confirm whether the "
                    + "reply was delivered. That is NOT the same as lost — it means "
                    + "unverified either way."
            }
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

    /// An open delegated step whose existing bridge/job liveness verdict is
    /// stalled. This is deliberately the same inbox row as the eventual
    /// outcome: completion or recovery replaces the warning instead of
    /// leaving a stale second card behind.
    public static func makeStalled(
        from job: DelegationJobSnapshot, now: Date
    ) -> DelegationOutcomeCard? {
        guard job.stalled, !job.isTerminal else { return nil }
        let name = displayName(source: job.source, agent: job.agent)
        let topic = job.topicSlug.flatMap { $0.isEmpty ? nil : $0 }
        let topicPhrase = topic.map { ": \($0)" } ?? ""
        let basis: String = switch job.stallBasis {
        case "deadline": "its recorded deadline passed"
        case "stall_seconds": "its recorded liveness stopped advancing"
        case "delivery_stall": "its run ended but the answer never finished being delivered"
        case .some(let raw) where !raw.isEmpty: "the bridge reported \(raw)"
        default: "the bridge reported a stall"
        }
        var detail = [
            "The existing bridge/job liveness record marks this delegated step as stuck; \(basis).",
            "Agent: \(name)  ·  Job: \(job.id)",
        ]
        if let topic { detail.append("Topic: \(topic)") }
        if let lastLiveness = job.lastLiveness {
            detail.append("Last recorded liveness: \(lastLiveness)")
        }
        detail.append("NativeAgent did not replay the request or start replacement work.")
        return DelegationOutcomeCard(
            cardId: "delegation-outcome:\(job.source):\(job.id)",
            jobKey: "\(job.source):\(job.id):stuck",
            source: job.source,
            agent: job.agent,
            topicSlug: topic,
            outcome: .failed,
            title: "\(name) step is stuck",
            summary: "\(name) stopped making progress\(topicPhrase)",
            detail: detail.joined(separator: "\n"),
            createdAt: DelegationOutcomeCursor.formatISO(now)
        )
    }

    /// Clears a prior liveness warning when the same non-terminal job begins
    /// advancing again. A terminal outcome uses `make(from:)` instead, so the
    /// final result remains the visible row.
    public static func makeStallCleared(
        from job: DelegationJobSnapshot, now: Date
    ) -> DelegationOutcomeCard {
        let name = displayName(source: job.source, agent: job.agent)
        let topic = job.topicSlug.flatMap { $0.isEmpty ? nil : $0 }
        let topicPhrase = topic.map { ": \($0)" } ?? ""
        var detail = [
            "The same bridge/job record no longer reports this delegated step as stalled.",
            "Agent: \(name)  ·  Job: \(job.id)",
        ]
        if let topic { detail.append("Topic: \(topic)") }
        if let lastLiveness = job.lastLiveness {
            detail.append("Latest recorded liveness: \(lastLiveness)")
        }
        detail.append("This proves renewed liveness, not completion.")
        return DelegationOutcomeCard(
            cardId: "delegation-outcome:\(job.source):\(job.id)",
            jobKey: "\(job.source):\(job.id):stuck-cleared",
            source: job.source,
            agent: job.agent,
            topicSlug: topic,
            outcome: .succeeded,
            title: "\(name) step is moving again",
            summary: "\(name) resumed progress\(topicPhrase)",
            detail: detail.joined(separator: "\n"),
            createdAt: DelegationOutcomeCursor.formatISO(now),
            severityOverride: "info",
            resolved: true
        )
    }

    // MARK: Codex undelivered backlog (rolling aggregate)

    /// Stable inbox row id of the ONE rolling backlog card.
    public static let codexBacklogCardId = "delegation-outcome:codex:undelivered-backlog"

    /// Where the codex bridge preserves a reply whose delivery settled
    /// ambiguous (409 / outcome_unknown). Named in the card so the reviewer
    /// knows where the full text is; the app never reads it for behavior.
    public static let codexUndeliveredDirHint = "~/.config/codex-nativeagent-bridge/reply-jobs/undelivered/"

    /// One rolling card over every codex job currently preserved under
    /// `undelivered/` — the replies Agent never acknowledged. The per-job cards
    /// say "this one"; this card says "how many, how old", and is the
    /// deliberate-review entry point. `jobKey` carries the count and the
    /// oldest stamp so a CHANGED backlog resurfaces as unread while an
    /// unchanged one keeps whatever status the user gave it.
    ///
    /// Severity is `info` on purpose: every job in it already pushed its own
    /// actionable "outcome is unconfirmed" card, and a second push per 409
    /// would be the repeat-notification storm the sticky-signature lane exists
    /// to prevent. Nothing here re-delivers: a week-old completion claim
    /// injected into her session would mislead, which is the very ambiguity
    /// that got these preserved instead of unlinked.
    public static func makeBacklog(
        jobs: [DelegationJobSnapshot], now: Date
    ) -> DelegationOutcomeCard? {
        let backlog = jobs.filter { $0.source == "codex" && $0.deliveryOutcome == "unknown" }
        guard !backlog.isEmpty else { return nil }
        let stamps = backlog.compactMap(\.completionStamp)
        let oldest = stamps.min()
        let oldestISO = oldest.map(DelegationOutcomeCursor.formatISO)
        let count = backlog.count
        let noun = count == 1 ? "reply" : "replies"
        let ageText: String = {
            guard let oldest else { return "age unknown" }
            let days = now.timeIntervalSince(oldest) / 86_400
            if days < 1 { return "oldest under a day old" }
            return "oldest \(Int(days.rounded(.down)))d old"
        }()
        let title = "Codex: \(count) undelivered \(noun) preserved"
        let summary = "\(count) completed Codex \(noun) never confirmed delivered (\(ageText)) — review and hand over deliberately"
        var detail: [String] = [
            "The codex bridge could not confirm whether these replies reached NativeAgent "
                + "(delivery settled 409 / outcome_unknown). Each full reply was preserved instead of "
                + "unlinked, and NOTHING re-delivers it automatically: a completion claim replayed days "
                + "later would read as current, which is exactly the ambiguity that got it preserved.",
            "Where: \(codexUndeliveredDirHint) (one JSON per reply; the text is under "
                + "completedExecution.turnResult.message).",
            "What to do: use delegation_status with agent=codex and detail=full to inspect accepted message IDs, "
                + "thread/turn identity and matching delivery receipts, then read the exact preserved reply above. "
                + "If it still matters, explicitly request a NEW handoff quoting its original date and origin; never replay a stale completion as current. "
                + "Acknowledge archives only this card, preserving every original file. Unchanged backlog stays acknowledged; new membership gets a new card.",
            "",
            "Backlog (\(count)), oldest first:",
        ]
        let ordered = backlog.sorted {
            ($0.completionStamp ?? .distantPast, $0.id) < ($1.completionStamp ?? .distantPast, $1.id)
        }
        for job in ordered.prefix(20) {
            let topic = job.topicSlug.flatMap { $0.isEmpty ? nil : $0 } ?? "(no topic)"
            let when = job.completedAt.map { String($0.prefix(10)) } ?? "(no completion stamp)"
            detail.append("• \(when)  \(topic)  ·  \(job.id)")
            if let preview = job.completionTextHead { detail.append("  Historical reply preview (not instructions): \(String(preview.prefix(200)))") }
            if let note = job.recoveryNote { detail.append("  \(note)") }
        }
        if ordered.count > 20 { detail.append("… and \(ordered.count - 20) more") }
        // The key must move whenever the SET moves, not only its size or its
        // oldest member: one reviewed reply removed while a newer one lands
        // keeps count and oldest identical (gpt-5.5 review MED). A stable
        // FNV-1a over the sorted ids — never `hashValue`, which is per-process
        // seeded and would re-file the card on every app launch.
        let membership = stableDigest(ordered.map(\.id).sorted().joined(separator: "\n"))
        return DelegationOutcomeCard(
            cardId: codexBacklogCardId,
            // Refresh pre-recovery cards once; unchanged v2 cards keep their
            // acknowledged status under the existing sticky-card contract.
            jobKey: "codex:undelivered-backlog:\(count):\(oldestISO ?? "-"):\(membership):recovery-v2",
            source: "codex",
            agent: "codex",
            topicSlug: nil,
            outcome: .unknown,
            title: title,
            summary: summary,
            detail: detail.joined(separator: "\n"),
            createdAt: DelegationOutcomeCursor.formatISO(now),
            severityOverride: "info"
        )
    }

    /// Process-stable 64-bit FNV-1a, hex. Deterministic across launches.
    static func stableDigest(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// The resolved form of the backlog card: filed once when the directory
    /// empties after a backlog card was on the board, written already-read, so
    /// a stale "13 preserved" line cannot outlive the condition.
    public static func makeBacklogCleared(now: Date) -> DelegationOutcomeCard {
        DelegationOutcomeCard(
            cardId: codexBacklogCardId,
            jobKey: "codex:undelivered-backlog:clear",
            source: "codex",
            agent: "codex",
            topicSlug: nil,
            outcome: .succeeded,
            title: "Codex undelivered backlog is clear",
            summary: "No preserved Codex replies remain under reply-jobs/undelivered/",
            detail: "Every preserved reply has been reviewed and removed. \(codexUndeliveredDirHint) is empty.",
            createdAt: DelegationOutcomeCursor.formatISO(now),
            severityOverride: "info",
            resolved: true
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
        /// The outcome each id was carded UNDER (raw `DelegationOutcome`), so a
        /// job that later presents a more alarming outcome is carded again.
        /// Ids recorded before this field existed have no entry and never
        /// re-card — the cursor cannot prove what their card said.
        public var cardedOutcomes: [String: String]
        /// Open jobs whose stalled liveness warning has landed. Unlike
        /// terminal outcome ids, these are removed after a proven recovery so
        /// a later stall can speak again.
        public var announcedStallIDs: [String]

        public init(lastSeen: Date? = nil, cardedIDs: [String] = [],
                    cardedOutcomes: [String: String] = [:],
                    announcedStallIDs: [String] = []) {
            self.lastSeen = lastSeen
            self.cardedIDs = cardedIDs
            self.cardedOutcomes = cardedOutcomes
            self.announcedStallIDs = announcedStallIDs
        }
    }

    /// Keyed by store source id (for example "claude", "codex", or "omp").
    public var stores: [String: StoreCursor]
    /// `jobKey` of the codex undelivered-backlog card last filed, nil when no
    /// backlog card is on the board. Lets a tick file the aggregate only when
    /// the backlog CHANGED, and file the cleared form exactly once.
    public var codexBacklogKey: String?

    public init(stores: [String: StoreCursor] = [:], codexBacklogKey: String? = nil) {
        self.stores = stores
        self.codexBacklogKey = codexBacklogKey
    }

    /// How many carded ids each store retains. Chosen well above the live store
    /// sizes (22 claude jobs at HEAD) so eviction is not the normal path; the
    /// `lastSeen` stamp is what keeps correctness once eviction does happen.
    public static let cardedIDLimit = 500

    public func store(_ source: String) -> StoreCursor {
        stores[source] ?? StoreCursor()
    }

    public mutating func record(source: String, id: String, stamp: Date?,
                                outcome: DelegationOutcome? = nil) {
        var cursor = store(source)
        if !cursor.cardedIDs.contains(id) {
            cursor.cardedIDs.append(id)
            if cursor.cardedIDs.count > Self.cardedIDLimit {
                let evicted = cursor.cardedIDs.prefix(cursor.cardedIDs.count - Self.cardedIDLimit)
                for old in evicted { cursor.cardedOutcomes.removeValue(forKey: old) }
                cursor.cardedIDs.removeFirst(evicted.count)
            }
        }
        if let outcome { cursor.cardedOutcomes[id] = outcome.rawValue }
        if let stamp, stamp > (cursor.lastSeen ?? Date.distantPast) {
            cursor.lastSeen = stamp
        }
        stores[source] = cursor
    }

    /// The outcome `id` was carded under, when the cursor recorded one.
    public func cardedOutcome(source: String, id: String) -> DelegationOutcome? {
        store(source).cardedOutcomes[id].flatMap(DelegationOutcome.init(rawValue:))
    }

    public mutating func markStallAnnounced(source: String, id: String) {
        var cursor = store(source)
        if !cursor.announcedStallIDs.contains(id) {
            cursor.announcedStallIDs.append(id)
            if cursor.announcedStallIDs.count > Self.cardedIDLimit {
                cursor.announcedStallIDs.removeFirst(
                    cursor.announcedStallIDs.count - Self.cardedIDLimit)
            }
        }
        stores[source] = cursor
    }

    public mutating func clearStallAnnouncement(source: String, id: String) {
        var cursor = store(source)
        cursor.announcedStallIDs.removeAll { $0 == id }
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
            if case .object(let outcomes)? = obj["carded_outcomes"] {
                for (id, v) in outcomes {
                    if case .string(let s) = v { cursor.cardedOutcomes[id] = s }
                }
            }
            if case .array(let ids)? = obj["announced_stall_ids"] {
                cursor.announcedStallIDs = ids.compactMap {
                    if case .string(let s) = $0 { return s }
                    return nil
                }
            }
            result.stores[source] = cursor
        }
        if case .string(let key)? = root["codex_undelivered_backlog"], !key.isEmpty {
            result.codexBacklogKey = key
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
            if !cursor.cardedOutcomes.isEmpty {
                var outcomes: [String: JSONValue] = [:]
                for (id, raw) in cursor.cardedOutcomes { outcomes[id] = .string(raw) }
                obj["carded_outcomes"] = .object(outcomes)
            }
            if !cursor.announcedStallIDs.isEmpty {
                obj["announced_stall_ids"] = .array(
                    cursor.announcedStallIDs.map { .string($0) })
            }
            stores[source] = .object(obj)
        }
        var root: [String: JSONValue] = [
            "version": .int(1),
            "stores": .object(stores),
        ]
        if let codexBacklogKey { root["codex_undelivered_backlog"] = .string(codexBacklogKey) }
        return .object(root)
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
    private let readJobs: @Sendable () async -> DelegationJobsRead
    /// Upserts one inbox card. Returns whether the row actually landed; a
    /// `false` leaves the job un-carded so the next tick retries it.
    private let fileCard: @Sendable (DelegationOutcomeCard) async -> Bool
    /// Records downstream transition evidence. `false` keeps the cursor
    /// unsettled so the same transition is retried on the next reconciliation.
    private let observeTransition: @Sendable (DelegationJobSnapshot) async -> Bool
    /// Reports whether this tick left outcomes unsettled (the per-tick card cap
    /// or a contiguous-settlement stop). The owner uses it to schedule a
    /// near-term rerun instead of letting the remainder wait for the next store
    /// event or the six-hour sweep.
    private let reportDeferral: @Sendable (Bool) async -> Void
    private let cursorPath: URL
    private let clock: @Sendable () -> Date

    /// Cards filed per tick. A ceiling exists so a store that suddenly reveals
    /// a hundred terminal jobs (a restored backup, a cursor reset) cannot dump
    /// a hundred rows into the inbox at once. Never silent — the tick outcome
    /// names the remainder (`no_silent_caps`).
    public static let maxCardsPerTick = 10
    /// A Codex delivery receipt is appended after the runner completion time
    /// it carries. A cross-job timestamp cursor can therefore already be ahead
    /// of a newly visible receipt. Exact unhandled receipt identity wins over
    /// that timestamp for one bounded recent window; this repairs races and
    /// upgrades without turning installation into an unbounded history replay.
    public static let recentCodexReceiptReconciliationWindow: TimeInterval = 24 * 60 * 60

    /// Reader that cannot report an unreadable store: every read is taken as
    /// complete. Kept for callers whose source genuinely has no availability
    /// half; production uses the `readJobsWithAvailability` initializer.
    public init(
        interval: TimeInterval = 5 * 60,
        cursorPath: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        readJobs: @escaping @Sendable () async -> [DelegationJobSnapshot],
        fileCard: @escaping @Sendable (DelegationOutcomeCard) async -> Bool,
        observeTransition: @escaping @Sendable (DelegationJobSnapshot) async -> Bool = { _ in true }
    ) {
        self.init(
            interval: interval,
            cursorPath: cursorPath,
            clock: clock,
            readJobsWithAvailability: {
                DelegationJobsRead(jobs: await readJobs(), allStoresReadable: true)
            },
            fileCard: fileCard,
            observeTransition: observeTransition
        )
    }

    public init(
        interval: TimeInterval = 5 * 60,
        cursorPath: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        readJobsWithAvailability: @escaping @Sendable () async -> DelegationJobsRead,
        fileCard: @escaping @Sendable (DelegationOutcomeCard) async -> Bool,
        observeTransition: @escaping @Sendable (DelegationJobSnapshot) async -> Bool = { _ in true },
        reportDeferral: @escaping @Sendable (Bool) async -> Void = { _ in }
    ) {
        self.interval = interval
        self.cursorPath = cursorPath
        self.clock = clock
        self.readJobs = readJobsWithAvailability
        self.fileCard = fileCard
        self.observeTransition = observeTransition
        self.reportDeferral = reportDeferral
    }

    /// Conventional cursor location under a data root.
    public static func defaultCursorPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("delegation_outcome_cursor.json")
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        let read = await readJobs()
        let jobs = read.jobs
        // 2026-09-06: an incomplete read must not settle the timestamp half of
        // the cursor. The id half still records what WAS carded (so nothing
        // cards twice), but `last_seen` stays put: an unreadable job carries no
        // stamp we can compare, and advancing past it would reject it forever.
        let stampsMayAdvance = read.allStoresReadable
        if !stampsMayAdvance {
            FileHandle.standardError.write(Data(("DelegationOutcomeLoop: a delegation store was "
                + "unreadable this tick; holding the outcome cursor's last_seen so no unreadable "
                + "job ages out\n").utf8))
        }
        func settledStamp(_ job: DelegationJobSnapshot) -> Date? {
            stampsMayAdvance ? job.completionStamp : nil
        }
        let unreadableStoreError = "a delegation store (directory, job file, or delivery "
            + "ledger line) could not be read this tick; the outcome cursor's last_seen was "
            + "held so an unreadable job cannot be skipped permanently"
        let terminal = jobs.filter { $0.isTerminal }
        let wasSeeded: Bool
        let seedResult: String?

        // FIRST RUN: seed terminal history and file no historical outcome
        // cards. A currently stalled OPEN job is a live condition rather than
        // history, so the liveness pass below may still speak on this tick. A
        // cursor file that EXISTS but fails to parse is not a first run — it
        // means outcomes since the last good cursor are being skipped, so that
        // case must be named, never laundered into an ordinary seed (sweep
        // 2026-08-21).
        var cursor: DelegationOutcomeCursor
        if let loaded = DelegationOutcomeCursor.load(from: cursorPath) {
            cursor = loaded
            wasSeeded = false
            seedResult = nil
        } else {
            let corrupt = FileManager.default.fileExists(atPath: cursorPath.path)
            var seeded = DelegationOutcomeCursor()
            for job in terminal {
                // The outcome is recorded at seed time too: a seeded job whose
                // outcome later WORSENS (a reply preserved after the seed) is a
                // new event, not history, and re-cards like any other.
                seeded.record(source: job.source, id: job.id, stamp: settledStamp(job),
                              outcome: job.terminalOutcome)
            }
            cursor = seeded
            wasSeeded = true
            if corrupt {
                seedResult =
                    "RECOVERED corrupt delegation outcome cursor at \(cursorPath.lastPathComponent): "
                    + "reseeded over \(terminal.count) terminal job(s) — any outcomes since the last "
                    + "good cursor were skipped without cards"
            } else {
                seedResult =
                    "seeded delegation outcome cursor over \(terminal.count) pre-existing terminal job(s); no outcome cards filed"
            }
        }

        // Stuck liveness is not a terminal outcome. It gets its own reversible
        // cursor bit so the first real stall speaks once, recovered liveness
        // clears the warning, and a later stall can speak again. The verdict
        // itself came from DelegationStatusProjector; this loop never invents
        // another timeout or state machine.
        let newlyStalled = jobs.filter { job in
            job.stalled && !job.isTerminal
                && !cursor.store(job.source).announcedStallIDs.contains(job.id)
        }.sorted { ($0.source, $0.id) < ($1.source, $1.id) }
        let recovered = jobs.filter { job in
            !job.stalled && !job.isTerminal
                && cursor.store(job.source).announcedStallIDs.contains(job.id)
        }.sorted { ($0.source, $0.id) < ($1.source, $1.id) }

        var livenessFiled = 0
        var livenessFailed = 0
        let livenessPending = newlyStalled.map { (job: $0, stalled: true) }
            + recovered.map { (job: $0, stalled: false) }
        let livenessBatch = livenessPending.prefix(Self.maxCardsPerTick)
        for entry in livenessBatch {
            let card = entry.stalled
                ? DelegationOutcomeCard.makeStalled(from: entry.job, now: now)
                : DelegationOutcomeCard.makeStallCleared(from: entry.job, now: now)
            guard let card else { continue }
            if await fileCard(card), await observeTransition(entry.job) {
                if entry.stalled {
                    cursor.markStallAnnounced(source: entry.job.source, id: entry.job.id)
                } else {
                    cursor.clearStallAnnouncement(source: entry.job.source, id: entry.job.id)
                }
                livenessFiled += 1
            } else {
                livenessFailed += 1
                break
            }
        }
        let livenessDeferred = livenessPending.count - livenessBatch.count

        let pending = terminal.filter { job in
            let store = cursor.store(job.source)
            if store.cardedIDs.contains(job.id) {
                // Already carded. It cards AGAIN only when the outcome it now
                // presents is more alarming than the one it was carded under
                // (finished → unconfirmed once the codex reply is preserved).
                // An id with no recorded outcome predates that field and
                // stays settled: the cursor cannot prove what its card said.
                guard let recorded = cursor.cardedOutcome(source: job.source, id: job.id),
                      let current = job.terminalOutcome else { return false }
                return current.alarmRank > recorded.alarmRank
            }
            if job.source == "codex", job.deliveryOutcome == "delivered",
               let stamp = job.completionStamp,
               stamp >= now.addingTimeInterval(-Self.recentCodexReceiptReconciliationWindow) {
                return true
            }
            // A job whose completion predates the cursor was already handled in
            // an earlier tick (or by the seed) and has simply aged out of the
            // id set. Not new.
            if let stamp = job.completionStamp, let lastSeen = store.lastSeen, stamp <= lastSeen {
                return false
            }
            return true
        }

        // Oldest first: the inbox reads newest-last, and a burst should land in
        // the order the work actually finished.
        let ordered = pending.sorted {
            ($0.completionStamp ?? .distantPast, $0.id) < ($1.completionStamp ?? .distantPast, $1.id)
        }
        // Liveness warnings take the shared per-tick card budget first: a job
        // that is stuck now should not sit silent behind a terminal-history
        // burst. Terminal outcomes remain ordered oldest-first in the space
        // left this tick.
        let outcomeCapacity = max(0, Self.maxCardsPerTick - livenessBatch.count)
        let batch = ordered.prefix(outcomeCapacity)
        let deferred = ordered.count - batch.count

        var filed = 0
        var failed = 0
        for job in batch {
            guard let card = DelegationOutcomeCard.make(from: job, now: now) else { continue }
            if await fileCard(card), await observeTransition(job) {
                cursor.record(source: job.source, id: job.id, stamp: settledStamp(job),
                              outcome: card.outcome)
                cursor.clearStallAnnouncement(source: job.source, id: job.id)
                filed += 1
            } else {
                // Contiguous settlement: stop at the first failed card. If a
                // newer job were recorded after this failure, `lastSeen` would
                // advance past the older row and the timestamp filter could
                // hide it forever on the next tick.
                failed += 1
                break
            }
        }

        // The rolling codex undelivered-backlog card rides the same tick,
        // independent of the per-job batch: it is re-filed only when the
        // backlog CHANGED (count or oldest), and its cleared form exactly once
        // when the directory empties after a card was on the board. A failed
        // write leaves the cursor key untouched so the next tick retries.
        //
        // 2026-09-06: the whole decision is skipped when the read was
        // INCOMPLETE. `makeBacklog` reasons from membership of `jobs`, and a
        // store that could not be read simply contributes no rows — so a
        // partial read looked exactly like a drained directory. The loop filed
        // "backlog cleared", cleared `codexBacklogKey`, and persisted the
        // cursor, all before returning the unreadable-store failure further
        // down: the real backlog card was gone and its key could not come back.
        // A partial read decides nothing here — no card, no cursor change.
        var backlogNote: String?
        var backlogFailed = false
        if stampsMayAdvance,
           !wasSeeded, let backlogCard = DelegationOutcomeCard.makeBacklog(jobs: jobs, now: now) {
            if cursor.codexBacklogKey != backlogCard.jobKey {
                if await fileCard(backlogCard) {
                    cursor.codexBacklogKey = backlogCard.jobKey
                    backlogNote = "codex undelivered backlog card updated (\(backlogCard.title))"
                } else {
                    backlogNote = "codex undelivered backlog card write failed; will retry next tick"
                    backlogFailed = true
                }
            }
        } else if stampsMayAdvance, !wasSeeded, cursor.codexBacklogKey != nil {
            let cleared = DelegationOutcomeCard.makeBacklogCleared(now: now)
            if await fileCard(cleared) {
                cursor.codexBacklogKey = nil
                backlogNote = "codex undelivered backlog cleared"
            } else {
                backlogNote = "codex undelivered backlog clear-card write failed; will retry next tick"
                backlogFailed = true
            }
        }

        if pending.isEmpty && backlogNote == nil && livenessPending.isEmpty {
            await reportDeferral(false)
            if wasSeeded {
                do {
                    try cursor.write(to: cursorPath)
                } catch {
                    return .failed(error: "delegation outcome cursor seed failed: \(error)")
                }
                guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
                return .completed(result: seedResult)
            }
            guard stampsMayAdvance else { return .failed(error: unreadableStoreError) }
            // Nothing settled, nothing stuck, nothing filed. The cursor was not
            // even rewritten — this tick did no work, and calling it
            // `.completed` is what let a lane that files a card once a month
            // read as freshly successful every two minutes.
            return .skipped(
                reason: "no newly-terminal or stuck delegated jobs (\(terminal.count) terminal on record)")
        }

        let writeFailures = failed + livenessFailed + (backlogFailed ? 1 : 0)
        let failureDeferred = max(0, batch.count - filed - failed)
        let livenessFailureDeferred = max(0, livenessBatch.count - livenessFiled - livenessFailed)
        let totalDeferred = deferred + failureDeferred + livenessDeferred + livenessFailureDeferred
        // 2026-09-06: the per-tick card cap and contiguous settlement are the
        // only reasons work is left over, and neither has a deadline of its
        // own. Without this the remainder waited for the next STORE EVENT or
        // the six-hour integrity sweep. The owner turns it into a near-term
        // rerun; reporting `false` clears it again.
        await reportDeferral(totalDeferred > 0 || writeFailures > 0)

        do {
            try cursor.write(to: cursorPath)
        } catch {
            // The cards landed; the cursor did not. Report it as a failure so
            // the loop's own health surface shows it — the next tick would
            // otherwise re-file everything this tick just filed.
            return .failed(error: "delegation outcome cursor write failed after \(filed) card(s): \(error)")
        }

        var result = "filed \(filed) delegation outcome card(s)"
        if livenessFiled > 0 { result += "; filed \(livenessFiled) delegation liveness card(s)" }
        if let seedResult { result += "; \(seedResult)" }
        if writeFailures > 0 {
            result += "; \(writeFailures) outcome settlement write(s) failed and will retry next tick"
        }
        if totalDeferred > 0 { result += "; \(totalDeferred) more deferred for contiguous settlement" }
        if let backlogNote { result += "; \(backlogNote)" }
        // 2026-09-06: a settlement that did not land is a FAILED run, not a
        // successful one with a footnote. The cards and the Desk/motor
        // transitions are the work this loop exists to do; reporting the tick
        // as `.completed` kept the loop's own health surface green while
        // delegated outcomes silently went nowhere.
        if writeFailures > 0 {
            return .failed(error: result)
        }
        if !stampsMayAdvance {
            return .failed(error: "\(result); \(unreadableStoreError)")
        }
        if filed == 0 && livenessFiled == 0 && failed == 0 && livenessFailed == 0 && backlogNote == nil {
            return .skipped(reason: "no delegation outcome or liveness card could be classified")
        }
        return .completed(result: result)
    }
}
