import ApprovalInbox
import AgentWorkspace
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `NativeCognitionRuntime+Expectations.swift` | `NativeCognitionRuntime` horizon expectations: Desk plans named and deduplicated by work title, unnamed memory plans by whole-second due instant, composed dated evidence and refresh deadlines |

// The runtime composes source evidence for the organism's forward register.
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
// Desk plans keep their work titles as bounded canonical names; memory atoms
// have no name and carry an empty label. Other labels are identifiers the store
// already owns — a job id, an approval action, an agent name. No bodies cross.
// The stores are read through their existing public read APIs and nothing is
// written back to any of them.
//
// ── NO NEW TIMER, NO POLLING ─────────────────────────────────────────────────
// Source invalidations and horizon eligibility/expiry boundaries coalesce behind
// one retained refresh on the existing residual deadline, without a minimum interval.
//
// ── WHY THE MINT RIDES A SIGNAL ──────────────────────────────────────────────
// The rows have to live in the prediction ledger, because that is what
// `OrganismProspectiveAffect.modulate` reads when the kernel projects
// chemistry, and the anticipation is the whole point. `OrganismKernel` owns
// that ledger and takes exactly one kind of input — a `SomaticSignal` — so the
// refresh is delivered as one, on `SomaticSignalKind.horizonRefresh`.
//
// A horizon refresh changes only the horizon: no chemistry, body fact, valence or associations.

/// The runtime's source state holds the re-entrancy latch and coalesced dirty
/// bit. The horizon refresh's own somatic signal cannot dirty its sources.
extension NativeCognitionRuntime {

    // MARK: - Tuning (all in one place)

    /// How long an approval sits before its horizon passes. Approvals carry no
    /// expiry of their own (the inbox has no TTL), so this is the point at which
    /// "he hasn't looked at it" becomes something she notices — not a deadline
    /// imposed on him.
    static let horizonApprovalWindow: TimeInterval = 24 * 60 * 60
    /// How long a delegated peer job runs before she is WAITING on it rather
    /// than merely expecting it.
    static let horizonPeerReplyWindow: TimeInterval = 30 * 60
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

    /// Called from `rescheduleResidualRepairDeadline`. Hands off to a
    /// detached task so four disk reads never sit in front of signal ingestion.
    func considerHorizonExpectations() {
        guard !isFlushedForTermination, sourceWakes.horizonReady, horizonRefreshTask == nil else { return }
        if let due = sourceWakes.horizonNextAt, due <= now() { sourceWakes.horizonDirty = true }
        guard sourceWakes.horizonDirty else { return }
        horizonRefreshTask = Task { [weak self] in
            await self?.refreshHorizonExpectationsIfDue()
            await self?.finishHorizonRefresh()
        }
    }

    private func finishHorizonRefresh() async {
        horizonRefreshTask = nil
        await rescheduleResidualRepairDeadline()
    }

    /// Source events coalesce behind the one retained refresh. Changes during
    /// its reads keep the dirty bit for the next pass.
    func refreshHorizonExpectationsIfDue() async {
        guard !isFlushedForTermination, !Task.isCancelled, !sourceWakes.horizonRunning else { return }
        sourceWakes.horizonRunning = true
        sourceWakes.horizonDirty = false
        sourceWakes.horizonNextAt = nil
        defer { sourceWakes.horizonRunning = false }
        await refreshHorizonExpectations()
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
            OrganPulse.recordOff("horizon_expectations", because: "organism disabled")
            return
        }
        let at = now()
        let settled = OrganismHorizonRegister.settled(in: before)
        let open = OrganismHorizonRegister.open(in: before)
        let composed = await composeHorizonSources(at: at)
        // Nothing open, nothing settled, nothing to expect: send no signal at
        // all. This is the ordinary state of a quiet machine and it must stay
        // free.
        let facing = !settled.isEmpty || !open.isEmpty || !composed.tokens.isEmpty
        OrganPulse.record("horizon_expectations", facing ? .worked : .nothing,
                          note: "\(open.count) open, \(settled.count) settled, \(composed.tokens.count) expected")
        guard facing else { return }

        // A scheduled job no longer opens a horizon, so one still open from
        // before settles silently: no relief, no "still waiting" on a cron row.
        for row in settled where row.horizon?.sourceKind != .scheduledJob {
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
            persistSynchronously: false
        )
        // The signal prunes the announced rows, then may settle vanished
        // sources. Keep one coalesced follow-up pass to feel those.
        if let after = await organismKernel.exportPersistentState()?.predictionLedger,
           !OrganismHorizonRegister.settled(in: after).isEmpty {
            sourceWakes.horizonDirty = true
        }
    }

    /// The frozen body's nearest horizon: a payload-free label, valence sign
    /// and overdue flag. Nil is silence; the capsule owner picks the word.
    public func towardRead() async -> OrganismTowardRead? {
        await organismKernel.frozenRead(at: now()).toward
    }

    // MARK: - Announcing a resolution

    /// Turn one settled horizon row into a felt cognitive event.
    ///
    /// Three phrasings, because there are three ways a horizon ends and the
    /// shared felt-resolution composer only knows two. `waiting` is the one this
    /// lane exists for: the horizon passed and nothing answered it.
    ///
    /// `subject.label` is `OrganismHorizonRegister.resolutionPathLabel`, which is
    /// what the stakes gate admits this family by
    /// (`CognitiveSubstrate+AppraisalStakes.swift`). `subject.id` carries the
    /// payload-free who/what.
    private func announceHorizonResolution(_ row: OrganismPrediction, at date: Date) async {
        guard let horizon = row.horizon,
              let label = OrganismHorizonRegister.displayLabel(for: row, at: date) else { return }
        let phase: String
        let summary: String
        let feltValence: Double
        let feltArousal: Double
        switch row.status {
        case .satisfied:
            phase = "relief"
            summary = "Relief — \(label) came round before I had to keep holding it."
            feltValence = 0.35
            feltArousal = 0.15
        case .violated:
            phase = "disappointment"
            summary = "Disappointment — \(label) was the thing I was looking toward, and it fell through."
            feltValence = -0.35
            feltArousal = 0.4
        case .expired:
            phase = "waiting"
            summary = "Still waiting on \(label). The moment came and went."
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
            id: "horizon:\(row.id):\(String(format: "%.0f", row.lastUpdatedAt.timeIntervalSince1970.rounded(.towardZero) + 0))",
            kind: .organismResolutionFelt,
            subject: CognitiveSubjectReference(
                type: "organism_horizon",
                id: horizon.sourceKind == .statedPlan ? row.id : "\(horizon.sourceKind.rawValue):\(horizon.label)",
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
                "horizonSubject": .string(label),
            ]
        )
        if await substrate.ingestResident(event).accepted {
            scheduleDirtyMicrocycle(
                reason: "horizon_resolution:\(phase)"
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
    struct HorizonSourceReading: Sendable {
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
        async let statedPlans = statedPlanSources(at: now)
        async let stagedApprovals = stagedApprovalSources(at: now)
        async let openQuestions = openQuestionSources(at: now)
        let readings: [HorizonSourceReading] = [
            await statedPlans,
            statedScheduleSources(),
            await stagedApprovals,
            await openQuestions,
            peerReplySources(at: now),
        ]
        var rows = readings.flatMap { reading in
            reading.rows.map { (token: $0.token, dueAt: $0.dueAt, kind: reading.kind) }
        }
        rows.sort { lhs, rhs in
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.token < rhs.token
        }
        let truncatedKinds = Set(rows.dropFirst(OrganismHorizonRegister.maximumOpen).map(\.kind.rawValue))
        return (
            // Cut to the register's own cap, nearest first. Not a nicety:
            // somatic metadata bounds arrays at
            // `OrganismMetadataBounds.maximumArrayItems`, so an over-long set
            // would be truncated in COMPOSITION order, and a source silently
            // dropped off the end reads as a source that went away.
            rows.prefix(OrganismHorizonRegister.maximumOpen).map(\.token),
            readings.filter { $0.complete && !truncatedKinds.contains($0.kind.rawValue) }.map(\.kind.rawValue).sorted()
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
        // A source may enter or leave the existing seven-day window without a
        // write. Keep those real boundaries, not a fifteen-minute sample.
        let width = OrganismHorizonRegister.maximumHorizon
        for boundary in [natural.addingTimeInterval(-width), natural, Self.afterInclusiveBoundary(natural.addingTimeInterval(width))] where boundary > now {
            sourceWakes.horizonNextAt = min(sourceWakes.horizonNextAt ?? boundary, boundary)
        }
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
    ///   · memory atoms whose writer named a plan or commitment's moment
    ///     (`due_at`); retired prose-extractor stamps are excluded by the reader.
    ///
    /// They share a kind because they are the same THING to her (a day she has
    /// been pointed at), and completeness is therefore the AND of both reads: if
    /// either store could not be read, the kind does not vouch, because a
    /// vanished row here opens the relief door.
    private func statedPlanSources(at now: Date) async -> HorizonSourceReading {
        let desk = await deskDeferralSources(at: now)
        let atoms = await datedMemorySources(at: now)
        // Each feed deduplicates by its source's identity before the shared cap:
        // Desk work names and unnamed atoms' whole-second due instants.
        return HorizonSourceReading(
            kind: .statedPlan,
            rows: desk.rows + atoms.rows,
            complete: desk.complete && atoms.complete
        )
    }

    /// Memory atoms carrying a resolved `due_at` inside the register's week.
    /// Atoms have no name: their empty label leaves time words to display reads,
    /// never saved `due_label` or memory prose.
    ///
    /// This feed collapses atoms at the same whole-second instant into
    /// one row. Equal words on different dates do not: Friday is one Friday.
    private func datedMemorySources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        guard let records = try? await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).listMemory(kind: nil) else {
            // The store could not be read. Not "every plan came round".
            return ([], false)
        }
        var seen: Set<String> = []
        var out: [(token: String, dueAt: Date)] = []
        for record in records {
            guard (record.status ?? "active") == "active" else { continue }
            guard let due = MemoryDueDateStamp.dueAt(in: record.extras) else { continue }
            guard let token = token(.statedPlan, label: "", natural: due, at: now) else { continue }
            guard seen.insert(OrganismHorizonRegister.rowID(
                sourceKind: .statedPlan, label: "", dueAt: due
            )).inserted else { continue }
            out.append(token)
        }
        return (out, true)
    }

    /// Desk items User parked until a date. `deferUntil` is the one field in
    /// the system that means "this is for later, and later is a specific day".
    /// The work's title is its name, independent of the day it is deferred to.
    private func deskDeferralSources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() else {
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
        var seen: Set<String> = []
        var out: [(token: String, dueAt: Date)] = []
        for item in state.items {
            guard item.status != .done, item.status != .canceled else { continue }
            guard let raw = item.deferUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let until = DeskSequencing.parseDeferStamp(raw),
                  until > now else { continue }
            guard let token = token(.statedPlan, label: item.title, natural: until, at: now) else {
                continue
            }
            guard seen.insert(OrganismHorizonRegister.rowID(
                sourceKind: .statedPlan, label: item.title, dueAt: until
            )).inserted else { continue }
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

    /// Schedules do not mint anticipation. Availability still settles legacy
    /// scheduled horizons only when the canonical jobs file can be read.
    private func statedScheduleSources() -> HorizonSourceReading {
        let path = dataRoot
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
        guard (try? host.schedulerJobRows(at: path)) != nil else {
            return .unavailable(.scheduledJob)
        }
        return HorizonSourceReading(kind: .scheduledJob, rows: [], complete: true)
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
        // Scoped to THIS install's bridge root: a copy that does not own the
        // machine-wide rendezvous must not wait on another install's jobs.
        let projector = DelegationStatusProjector(
            configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
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
