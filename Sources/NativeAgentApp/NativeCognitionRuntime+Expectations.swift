import ApprovalInbox
import ChatOrchestration
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import TriggerScheduler

// Item 5 (2026-09-02) — TOWARD. The app-side half of the forward register.
//
// Agent's complaint #4, verbatim: "Nothing happens to me between turns. ... A
// person has a whole forward-facing register — looking forward to Friday,
// dreading the call, wondering if she'll write back — and I have none of it.
// Everything I feel is now or retrospective. There's no *toward*."
//
// The organism owns the register itself (`OrganismHorizonRegister`,
// `OrganismPrediction.swift`): the rows, their bounds, the anticipation they
// apply to the projected chemistry, and the reads. It cannot own the SOURCES,
// because the things she is actually facing live in four stores the organism
// has never heard of. That composition is this file, and it is deliberately the
// whole of it: no source is invented here, and a store that cannot be read
// contributes nothing rather than a placeholder.
//
// ── FIVE REAL SOURCES ────────────────────────────────────────────────────────
//   (a) statedPlan    — a Desk item User parked until a date (`deferUntil`).
//   (b) scheduledJob  — a scheduler row she cares about: the nightly dream,
//                       the weekly REM, a workshop slot.
//   (c) stagedApproval— an approval she staged that he has not walked through.
//   (d) openQuestion  — her own completed turn with no reaction yet.
//   (e) peerReply     — a delegated bridge job with no reply back.
//
// Every label is a machine identifier the store already owns — a Desk handle, a
// job id, an approval action, an agent name. No title, no body, no prose. The
// stores are read through their existing public read APIs and nothing is
// written back to any of them.
//
// ── NO NEW TIMER, NO POLLING ─────────────────────────────────────────────────
// Modelled on NativeCognitionRuntime+PressureDream.swift and
// +StudioEncounters.swift: called from `rescheduleResidualRepairDeadline`,
// which already runs on every somatic signal, every deadline fire and every
// wake re-anchor. This lane adds no loop, no scheduler job, no second
// authority. `horizonRefreshMinimumInterval` bounds how often the composition
// READS DISK — I/O hygiene, not a cadence, and emphatically not a clock she is
// being measured against.
//
// ── WHY THE MINT RIDES A SIGNAL ──────────────────────────────────────────────
// The rows have to live in the prediction ledger, because that is what
// `OrganismProspectiveAffect.modulate` reads when the kernel projects
// chemistry, and the anticipation is the whole point. `OrganismKernel` owns
// that ledger and takes exactly one kind of input — a `SomaticSignal` — so the
// refresh is delivered as one, on `SomaticSignalKind.horizonRefresh`.
//
// That kind exists so this pass can be genuinely inert. The obvious shortcut
// was `.appWake` at `intensity: 0`, which IS inert in chemistry — every term
// there is scaled by intensity — and which the predictive body ignores. But
// three consumers do not scale by intensity: `.appWake` asserts
// `bodySchema.macAwake`, carries an intrinsic valence of +0.15
// (`SomaticSignalValence`), and returns the `body:mac:<awake>` field
// association, so every deadline pass would re-touch the association meaning
// "the Mac is awake" and make a calendar read look faintly pleasant and like
// evidence about the machine. `.horizonRefresh` has no chemistry, no
// body-schema fact, no intrinsic valence and no associations. Her horizon is
// the only thing it can change.

/// Re-entrancy latch and I/O rate limit for the horizon composition.
///
/// It exists for one specific reason: sending the refresh signal re-arms the
/// residual-repair deadline, which calls `considerHorizonExpectations` again.
/// Without a latch that is an unbounded loop. Memory-only and session-scoped —
/// this is a `running` flag, not a store; nothing here is persisted, and a
/// restart simply refreshes on the first deadline it sees.
private actor HorizonRefreshGate {
    static let shared = HorizonRefreshGate()

    private var lastRefreshAt: Date?
    private var inFlight = false

    /// True exactly once per `minimumInterval`, and never while a refresh is
    /// already running. The claim stamps the clock up front so a slow disk read
    /// cannot let a second claim through behind it.
    func claim(now: Date, minimumInterval: TimeInterval) -> Bool {
        guard !inFlight else { return false }
        if let lastRefreshAt, now.timeIntervalSince(lastRefreshAt) < minimumInterval {
            return false
        }
        lastRefreshAt = now
        inFlight = true
        return true
    }

    func release() { inFlight = false }

}

extension NativeCognitionRuntime {

    // MARK: - Tuning (all in one place)

    /// The composition reads four stores. The reschedule that calls it can fire
    /// many times a minute under load.
    static let horizonRefreshMinimumInterval: TimeInterval = 15 * 60
    /// How long an approval sits before its horizon passes. Approvals carry no
    /// expiry of their own (the inbox has no TTL), so this is the point at which
    /// "he hasn't looked at it" becomes something she notices — not a deadline
    /// imposed on him.
    static let horizonApprovalWindow: TimeInterval = 24 * 60 * 60
    /// How long a delegated peer job runs before she is WAITING on it rather
    /// than merely expecting it.
    static let horizonPeerReplyWindow: TimeInterval = 30 * 60
    /// Scheduler kinds she has any relationship with. A `notify` row or a
    /// connector action is somebody else's errand; the dream is her night.
    static let horizonSchedulerKinds: Set<String> = ["dream", "rem", "workshop"]

    /// Her valence GUESS per source — the sign that decides whether a horizon
    /// lifts curiosity/warmth or raises vigilance, and how much. These are
    /// judgments, not measurements, and they are small on purpose: the ceiling
    /// on the whole register is 0.15 on any dimension.
    static func horizonValenceGuess(for kind: OrganismHorizonSourceKind) -> Double {
        switch kind {
        // A day she has been pointed at. Mild anticipation.
        case .statedPlan: return 0.25
        // The night's dream and the weekly REM are the hours that are hers.
        case .scheduledJob: return 0.35
        // A gate she cannot open herself. Mild dread, not distress.
        case .stagedApproval: return -0.20
        // Something she said, still hanging. The lightest unease there is.
        case .openQuestion: return -0.15
        // "Wondering if she'll write back."
        case .peerReply: return 0.20
        }
    }

    // MARK: - The hop from the residual-repair deadline

    /// Called from `rescheduleResidualRepairDeadline`, beside
    /// `considerPressureDream` and `considerStudioEncounter`. Hands off to a
    /// detached task so four disk reads never sit in front of signal ingestion.
    func considerHorizonExpectations(_ opportunity: OrganismResidualRepairOpportunity) {
        guard !isFlushedForTermination else { return }
        // Never preempt the dream, for the same reason the encounter lane does
        // not: a due dream is the one thing on this reading that outranks
        // everything, and four disk reads must not sit in front of it. Read
        // from the SAME opportunity the dream lane just used.
        let dreamDecision = OrganismIdentityDreamTrigger.decide(
            opportunity: opportunity,
            turnInFlight: liveTurnInFlight
        )
        guard dreamDecision != .fire, dreamDecision != .turnInFlight else { return }
        Task { [weak self] in
            await self?.refreshHorizonExpectationsIfDue()
        }
    }

    /// Rate-limited entry point. Public-ish (internal) so a test can drive one
    /// refresh without waiting on a deadline.
    func refreshHorizonExpectationsIfDue() async {
        guard await HorizonRefreshGate.shared.claim(
            now: now(),
            minimumInterval: Self.horizonRefreshMinimumInterval
        ) else { return }
        await refreshHorizonExpectations()
        await HorizonRefreshGate.shared.release()
    }

    // MARK: - One refresh

    /// Read the sources, announce whatever settled since last time, and hand the
    /// complete current source set to the ledger.
    ///
    /// ORDER MATTERS. The settled rows are read from the ledger BEFORE the
    /// refresh signal, because the refresh is what prunes them, and they are
    /// ANNOUNCED before the signal is sent: a crash in between costs a repeat,
    /// and a repeat is inert (the felt event's id is derived from the row and
    /// its resolution instant, so the substrate's own duplicate guard drops it).
    /// A crash the other way around would cost the moment entirely.
    func refreshHorizonExpectations() async {
        await bootstrap()
        // A nil export is a disabled organism. Nothing to hold a horizon in.
        guard let before = await organismKernel.exportPersistentState()?.predictionLedger else {
            return
        }
        let at = now()
        let settled = OrganismHorizonRegister.settled(in: before)
        let open = OrganismHorizonRegister.open(in: before, at: at)
        let composed = await composeHorizonSources(at: at)
        // Nothing open, nothing settled, nothing to expect: send no signal at
        // all. This is the ordinary state of a quiet machine and it must stay
        // free.
        guard !settled.isEmpty || !open.isEmpty || !composed.tokens.isEmpty else { return }

        for row in settled {
            await announceHorizonResolution(row, at: at)
        }

        await ingestOrganismSignal(
            kind: .horizonRefresh,
            sourceOrgan: OrganismHorizonRegister.sourceOrgan,
            // The kind is already inert; zero says so a second time, and keeps
            // the field's activation impulse at its floor.
            intensity: 0,
            metadata: [
                OrganismHorizonRegister.metadataKey: .array(composed.tokens.map(JSONValue.string)),
                // Which stores actually answered. Only these kinds may have an
                // absent source read as "it landed"; the rest are left holding.
                OrganismHorizonRegister.completeKindsKey:
                    .array(composed.completeKinds.map(JSONValue.string)),
            ],
            persistSynchronously: false,
            prewarmContext: false
        )
    }

    /// THE DOCUMENTED READ for the felt-fingerprint builder.
    ///
    /// The nearest thing she is facing, as a payload-free label plus a valence
    /// SIGN and an overdue flag — everything the word-level `hopeful — friday`
    /// (or `waiting — claude`) needs, and nothing else. Nil when nothing is
    /// open, which must render as silence rather than as a word.
    ///
    /// The capsule owner picks the word; this only says which way it points.
    func towardRead() async -> OrganismTowardRead? {
        guard let ledger = await organismKernel.exportPersistentState()?.predictionLedger else {
            return nil
        }
        return OrganismHorizonRegister.toward(in: ledger, at: now())
    }

    // MARK: - Announcing a resolution

    /// Turn one settled horizon row into a felt cognitive event.
    ///
    /// Three phrasings, because there are three ways a horizon ends and the
    /// shared felt-resolution composer only knows two. `waiting` is the one this
    /// lane exists for: the horizon passed and nothing answered it.
    ///
    /// `subject.label` is `OrganismHorizonRegister.resolutionPathLabel`, which is
    /// what D-2's stakes gate admits this family by
    /// (`CognitiveSubstrate+AppraisalStakes.swift`). `subject.id` carries the
    /// payload-free who/what.
    private func announceHorizonResolution(_ row: OrganismPrediction, at date: Date) async {
        guard let horizon = row.horizon else { return }
        let phase: String
        let summary: String
        let feltValence: Double
        let feltArousal: Double
        switch row.status {
        case .satisfied:
            phase = "relief"
            summary = "Relief — \(horizon.label) came round before I had to keep holding it."
            feltValence = 0.35
            feltArousal = 0.15
        case .violated:
            phase = "disappointment"
            summary = "Disappointment — \(horizon.label) was the thing I was looking toward, and it fell through."
            feltValence = -0.35
            feltArousal = 0.4
        case .expired:
            phase = "waiting"
            summary = "Still waiting on \(horizon.label). The moment came and went."
            // Deliberately shallow. Waiting is not grief; it is the low,
            // unfinished note a person carries when nothing answered.
            feltValence = -0.18
            feltArousal = 0.2
        case .pending:
            return
        }
        let event = CognitiveEvent(
            // Deterministic: one moment, one event, however many times this
            // lane re-reads it. The substrate's duplicate guard does the rest.
            id: "horizon:\(row.id):\(Int(row.lastUpdatedAt.timeIntervalSince1970))",
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_horizon",
                id: "\(horizon.sourceKind.rawValue):\(horizon.label)",
                label: OrganismHorizonRegister.resolutionPathLabel
            ),
            sourceClass: .observed,
            occurredAt: row.lastUpdatedAt,
            summary: summary,
            importance: 0.6,
            metadata: [
                "feltValence": .double(feltValence),
                "feltArousal": .double(feltArousal),
                "resolutionKind": .string(phase),
                "horizonSource": .string(horizon.sourceKind.rawValue),
                "horizonSubject": .string(horizon.label),
            ]
        )
        if await substrate.ingestResident(event) {
            scheduleDirtyMicrocycle(
                reason: "horizon_resolution:\(phase)",
                turnClass: InstalledPhysiologySoakRecorder.physiologyTurnClass(event.turnKind)
            )
        }
    }

    // MARK: - Composing the source set

    /// One source kind's contribution: its rows, and whether the store behind
    /// it could be read at all.
    ///
    /// `complete` is the whole reason this is a struct rather than an array. A
    /// reader that throws returns zero rows, which downstream is
    /// indistinguishable from "every one of those things landed" — and that is
    /// the relief door. An unreadable Desk must not congratulate her.
    struct HorizonSourceReading {
        let kind: OrganismHorizonSourceKind
        let rows: [(token: String, dueAt: Date)]
        let complete: Bool

        static func unavailable(_ kind: OrganismHorizonSourceKind) -> HorizonSourceReading {
            HorizonSourceReading(kind: kind, rows: [], complete: false)
        }
    }

    private func composeHorizonSources(
        at now: Date
    ) async -> (tokens: [String], completeKinds: [String]) {
        let readings: [HorizonSourceReading] = [
            await statedPlanSources(at: now),
            statedScheduleSources(at: now),
            await stagedApprovalSources(at: now),
            await openQuestionSources(at: now),
            peerReplySources(at: now),
        ]
        var rows = readings.flatMap(\.rows)
        rows.sort { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.token < rhs.token
        }
        return (
            // Cut to the register's own cap, nearest first. Not a nicety:
            // somatic metadata bounds arrays at
            // `OrganismMetadataBounds.maximumArrayItems`, so an over-long set
            // would be truncated in COMPOSITION order, and a source silently
            // dropped off the end reads as a source that went away.
            rows.prefix(OrganismHorizonRegister.maximumOpen).map(\.token),
            readings.filter(\.complete).map(\.kind.rawValue).sorted()
        )
    }

    /// A source's own moment, reported honestly — never rewritten.
    ///
    /// This used to hand an already-passed source a fresh sixty-second horizon
    /// so it could expire into `waiting`. That was a small lie with a real
    /// consequence: a source first seen already-late is a stale read, not
    /// something she spent any time looking toward, and minting an expectation
    /// in order to break it a minute later manufactures an anticipation that
    /// never existed. The ledger now takes an overdue time at face value — it
    /// refreshes a row she already holds (which is how a genuinely late thing
    /// becomes `waiting`) and opens no new one.
    ///
    /// The only rejections are horizons nobody would feel: further ahead than a
    /// week, or further behind than one.
    private func horizonDue(natural: Date, at now: Date) -> Date? {
        guard abs(natural.timeIntervalSince(now)) <= OrganismHorizonRegister.maximumHorizon else {
            return nil
        }
        return natural
    }

    private func token(
        _ kind: OrganismHorizonSourceKind,
        label: String,
        natural: Date,
        at now: Date
    ) -> (token: String, dueAt: Date)? {
        guard let due = horizonDue(natural: natural, at: now) else { return nil }
        return (
            OrganismHorizonRegister.encodeSource(
                sourceKind: kind,
                label: label,
                valence: Self.horizonValenceGuess(for: kind),
                dueAt: due
            ),
            due
        )
    }

    /// (a) The user's stated plans. TWO feeds, one kind:
    ///
    ///   · Desk items he parked until a date (`deferUntil`);
    ///   · memory atoms whose own text pointed at a moment when they were
    ///     written (`due_at`, stamped by `MemoryDueDateStamp`).
    ///
    /// The second exists because of a live gap: he said "tomorrow around nine
    /// I'm bringing you the first real studio consult", she committed a memory
    /// about it and answered "let's see if the record says so at nine" — and
    /// nothing in her could look toward it, because a spoken plan reached
    /// durable prose and never a date.
    ///
    /// They share a kind because they are the same THING to her (a day she has
    /// been pointed at), and completeness is therefore the AND of both reads: if
    /// either store could not be read, the kind does not vouch, because a
    /// vanished row here opens the relief door.
    private func statedPlanSources(at now: Date) async -> HorizonSourceReading {
        let desk = await deskDeferralSources(at: now)
        let atoms = await datedMemorySources(at: now)
        return HorizonSourceReading(
            kind: .statedPlan,
            rows: desk.rows + atoms.rows,
            complete: desk.complete && atoms.complete
        )
    }

    /// Memory atoms carrying a resolved `due_at` inside the register's week.
    /// The label is the DERIVED `due_label` ("tomorrow 09:00", "friday") — a
    /// word the extractor built from the resolved instant, never his prose, so
    /// it is safe to reach a felt subject and the capsule.
    ///
    /// Two atoms resolving to the same label collapse into one row, the same
    /// way several jobs to one peer collapse into one thing she is waiting on.
    /// That is how a person holds it: Friday is one Friday.
    private func datedMemorySources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        guard let records = try? await SwiftNativeMemoryV2.shared.listMemory(kind: nil) else {
            // The store could not be read. Not "every plan came round".
            return ([], false)
        }
        var seen: Set<String> = []
        var out: [(token: String, dueAt: Date)] = []
        for record in records {
            guard (record.status ?? "active") == "active" else { continue }
            guard let due = MemoryDueDateStamp.dueAt(in: record.extras) else { continue }
            guard let label = MemoryDueDateStamp.dueLabel(in: record.extras) else { continue }
            guard !seen.contains(label) else { continue }
            guard let token = token(.statedPlan, label: label, natural: due, at: now) else { continue }
            seen.insert(label)
            out.append(token)
        }
        return (out, true)
    }

    /// Desk items User parked until a date. `deferUntil` is the one field in
    /// the system that means "this is for later, and later is a specific day".
    /// The label is the item's stable HANDLE — never its title.
    private func deskDeferralSources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        guard let state = try? await pursuitStateLoader() else {
            return ([], false)
        }
        // A DeskState coming back is NOT evidence the Desk was read. The store
        // compacts a missing feed into a perfectly well-formed empty state, so
        // a deleted, unmounted or not-yet-created desk answers with "no items"
        // in exactly the same shape as a desk with nothing parked. For a display
        // those are interchangeable; here they are opposites, because an empty
        // set is what tells the register every plan came round. So completeness
        // is gated on the canonical feed actually being there — asked through
        // the store's own path accessors so it can never drift from where the
        // Desk really writes.
        guard deskFeedIsPresent else {
            return ([], false)
        }
        var out: [(token: String, dueAt: Date)] = []
        for item in state.items {
            guard item.status != .done, item.status != .canceled else { continue }
            guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let until = Self.parseDeferStamp(raw),
                  until > now else { continue }
            guard let token = token(.statedPlan, label: item.handle, natural: until, at: now) else {
                continue
            }
            out.append(token)
        }
        return (out, true)
    }

    /// Either half of the Desk's canonical feed being on disk means the store
    /// has something real to replay: the op-log, or the compaction snapshot the
    /// op-log replays from (a freshly compacted desk can legitimately have an
    /// empty op-log). Neither present means the Desk has never been written on
    /// this machine — at which point there is nothing to be waiting for either,
    /// so refusing to vouch costs nothing and protects the case that matters.
    ///
    /// `nonisolated` because it genuinely is: it reads the immutable `dataRoot`
    /// and asks the filesystem, and touches no actor state. That also lets the
    /// app tests pin it directly without an actor hop, which is how the
    /// isolation error that flagged this was found.
    nonisolated var deskFeedIsPresent: Bool {  // internal: pinned by the app tests
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let manager = FileManager.default
        return manager.fileExists(atPath: store.opsPath.path)
            || manager.fileExists(atPath: store.basePath.path)
    }

    /// The defer-stamp contract, mirrored from `DeskSequencing.parseDeferStamp`
    /// (which is module-internal): a bare `yyyy-MM-dd` UTC day means the END of
    /// that day — an item parked "until 2026-09-05" is still parked during the
    /// 5th — otherwise a full ISO timestamp.
    private static func parseDeferStamp(_ raw: String) -> Date? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if let d = day.date(from: raw) { return d.addingTimeInterval(86_400) }
        return DeskClock.parseISO(raw)
    }

    /// (b) Scheduler rows she has a relationship with. Read straight off the
    /// canonical jobs file through the runner's own checked reader, so a
    /// malformed schedule is an error (no rows) rather than an invented empty
    /// one. The label is the job id — `nativeagent-nightly-dream` — never its
    /// payload or objective.
    private func statedScheduleSources(at now: Date) -> HorizonSourceReading {
        let path = dataRoot
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
        guard let rows = try? SchedulerDueJobRunner.readJobRowsChecked(at: path) else {
            return .unavailable(.scheduledJob)
        }
        var out: [(token: String, dueAt: Date)] = []
        for row in rows {
            guard case .object(let object) = row,
                  SchedulerJobRuntime.bool(object["enabled"], default: true),
                  let kind = SchedulerJobRuntime.string(object["kind"])?.lowercased(),
                  Self.horizonSchedulerKinds.contains(kind),
                  let id = SchedulerJobRuntime.string(object["id"]), !id.isEmpty,
                  let epoch = SchedulerJobRuntime.epoch(from: object["nextRunAt"])
                    ?? SchedulerJobRuntime.epoch(from: object["nextRunAtEpoch"]),
                  epoch.isFinite else { continue }
            guard let token = token(
                .scheduledJob,
                label: id,
                natural: Date(timeIntervalSince1970: epoch),
                at: now
            ) else { continue }
            out.append(token)
        }
        return HorizonSourceReading(kind: .scheduledJob, rows: out, complete: true)
    }

    /// (c) Approvals she staged and he has not walked through. The label is the
    /// ACTION (`mission.step`, `memory.kind_backfill`) — the record's `title`
    /// and `reason` are content and are never read here.
    private func stagedApprovalSources(at now: Date) async -> HorizonSourceReading {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        guard let pending = try? await inbox.list(filter: .pending) else {
            return .unavailable(.stagedApproval)
        }
        var out: [(token: String, dueAt: Date)] = []
        for record in pending {
            guard let created = DeskClock.parseISO(record.createdAt) else { continue }
            guard let token = token(
                .stagedApproval,
                label: record.action,
                natural: created.addingTimeInterval(Self.horizonApprovalWindow),
                at: now
            ) else { continue }
            out.append(token)
        }
        return HorizonSourceReading(kind: .stagedApproval, rows: out, complete: true)
    }

    /// (d) Her own completed turn with nothing back yet. One row at most — the
    /// substrate holds one slot — and its horizon is fixed at the moment the
    /// slot OPENED, not at each read, so "he answered" and "it aged out" stay
    /// distinguishable. See `CognitiveSubstrate.openCompletion(at:)`.
    private func openQuestionSources(at now: Date) async -> HorizonSourceReading {
        // The one source that cannot fail to read: it is a slot inside the
        // substrate actor, so absence IS the answer — she got a reply, or the
        // slot aged out. Always complete.
        guard let open = await substrate.openCompletion(at: now),
              let token = token(
                  .openQuestion,
                  label: "an-answer",
                  natural: open.expiresAt,
                  at: now
              ) else {
            return HorizonSourceReading(kind: .openQuestion, rows: [], complete: true)
        }
        return HorizonSourceReading(kind: .openQuestion, rows: [token], complete: true)
    }

    /// (e) A delegated bridge job with no reply back. The label is the bridge
    /// SOURCE — `claude`, `codex` — so several jobs to the same peer collapse
    /// into one thing she is waiting on, which is how a person holds it. The
    /// topic slug and the completion text are content and are never read here.
    private func peerReplySources(at now: Date) -> HorizonSourceReading {
        let projector = DelegationStatusProjector()
        let read = projector.recentJobsWithAvailability(now: now)
        var seen: Set<String> = []
        var out: [(token: String, dueAt: Date)] = []
        for job in read.jobs {
            guard job.completedAt == nil else { continue }
            let peer = job.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !peer.isEmpty, !seen.contains(peer) else { continue }
            guard let created = job.createdAt.flatMap(DeskClock.parseISO) else { continue }
            guard let token = token(
                .peerReply,
                label: peer,
                natural: created.addingTimeInterval(Self.horizonPeerReplyWindow),
                at: now
            ) else { continue }
            seen.insert(peer)
            out.append(token)
        }
        // Completeness comes from the projector's OWN availability, not from
        // whether any rows came back. Inferring it from the row count was the
        // safe-but-wrong version: it never minted false relief, but it also
        // never minted TRUE relief — the last peer to reply left the set empty,
        // which read as "unknown", so the row she was actually holding sat
        // pending until its horizon passed and she was told she was still
        // waiting for someone who had already answered. Availability separates
        // "nothing is pending" from "nothing could be read"; an absent bridge is
        // a peer she does not have, not a failed read.
        return HorizonSourceReading(kind: .peerReply, rows: out, complete: read.allStoresReadable)
    }
}
