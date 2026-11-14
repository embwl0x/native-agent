import ApprovalInbox
import AgentWorkspace
import CognitiveSubstrate
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Desk

// Blueprint: | `NativeCognitionRuntime+Expectations.swift` | `NativeCognitionRuntime`. |

// Compose source evidence here while the organism owns its bounded register, prediction ledger and reads.
// Use canonical Desk plans, staged approvals, unanswered completions and peer jobs; unavailable stores cannot invent placeholders.
// Only bounded source names or identifiers cross, never bodies; source stores remain read-only.
// Coalesce invalidations and real horizon boundaries on the existing residual deadline without polling.
// Deliver horizonRefresh through the kernel's somatic input so anticipation updates its canonical ledger alone.

/// Keep reentrancy and coalesced dirtiness here; the refresh signal must not invalidate its own sources.
extension NativeCognitionRuntime {

    // MARK: - Tuning (all in one place)

    /// Approval age supplies an attention horizon because the inbox has no expiry; it imposes no deadline on the person.
    static let horizonApprovalWindow: TimeInterval = 24 * 60 * 60
    static let horizonPeerReplyWindow: TimeInterval = 30 * 60
    /// Small per-source valence guesses guide anticipation, never claim measurement; the whole-register ceiling is 0.15 per dimension.
    static func horizonValenceGuess(for kind: OrganismHorizonSourceKind) -> Double {
        switch kind {
        // A stated future day carries mild anticipation.
        case .statedPlan: return 0.25
        // An approval gate carries mild dread rather than distress.
        case .stagedApproval: return -0.20
        // An unanswered turn carries only light unease.
        case .openQuestion: return -0.15
        case .peerReply: return 0.20
        }
    }

    // MARK: - The hop from the residual-repair deadline

    /// Detach source reads from the residual deadline so disk work cannot delay signal ingestion.
    func considerHorizonExpectations(runNow: Bool = false, reply: MindClockReply? = nil) {
        guard !isFlushedForTermination, sourceWakes.horizonReady, horizonRefreshTask == nil else {
            reply?(.init("held", "Horizon sources are not ready, a refresh is running, or the runtime is stopping.")); return
        }
        if let due = sourceWakes.horizonNextAt, due <= now() { sourceWakes.horizonDirty = true }
        guard runNow || sourceWakes.horizonDirty else { return }
        horizonRefreshTask = Task { [weak self] in
            guard let self else { reply?(.init("unavailable", "The runtime was released.")); return }
            let result = await self.refreshHorizonExpectationsIfDue()
            if let reply { reply(result) } else { await self.beat(.horizon, result) }
            await self.finishHorizonRefresh()
        }
    }

    private func finishHorizonRefresh() async {
        horizonRefreshTask = nil
        await rescheduleResidualRepairDeadline()
    }

    /// Retain one coalesced refresh; events during reads remain dirty for the next pass.
    @discardableResult
    func refreshHorizonExpectationsIfDue() async -> MindClockResult {
        guard !isFlushedForTermination, !Task.isCancelled, !sourceWakes.horizonRunning else { return .waiting("Horizon refresh is running or stopping.") }
        sourceWakes.horizonRunning = true
        sourceWakes.horizonDirty = false
        sourceWakes.horizonNextAt = nil
        defer { sourceWakes.horizonRunning = false }
        return await refreshHorizonExpectations()
    }

    // MARK: - One refresh

    /// Announce settled ledger rows before refresh prunes them so a crash cannot lose their felt moment.
    /// Deterministic IDs make a repeated announcement inert under the substrate's duplicate guard.
    @discardableResult
    func refreshHorizonExpectations() async -> MindClockResult {
        await bootstrap()
        // A disabled organism has no horizon ledger to refresh.
        guard let before = await organismKernel.exportPersistentState()?.predictionLedger else {
            return .off("the organism is disabled")
        }
        let at = now()
        let settled = OrganismHorizonRegister.settled(in: before)
        let open = OrganismHorizonRegister.open(in: before)
        let composed = await composeHorizonSources(at: at)
        // With no open, settled or expected rows, send no signal so a quiet machine stays idle.
        let facing = !settled.isEmpty || !open.isEmpty || !composed.tokens.isEmpty
        let incomplete = OrganismHorizonSourceKind.allCases.map(\.rawValue).filter { !composed.completeKinds.contains($0) }
        let result = MindClockResult(incomplete.isEmpty ? (facing ? "refreshed" : "nothing") : (facing ? "partial" : "unavailable"),
            "\(open.count) open, \(settled.count) settled, \(composed.tokens.count) expected; unreadable or truncated source kinds remain holding.", fields: [
            "open": .int(Int64(open.count)), "settled": .int(Int64(settled.count)),
            "expected": .int(Int64(composed.tokens.count)),
            "completeKinds": .array(composed.completeKinds.map(JSONValue.string)),
            "incompleteKinds": .array(incomplete.map(JSONValue.string))
        ], yield: open.count + settled.count + composed.tokens.count)
        guard facing else { return result }

        for row in settled {
            await announceHorizonResolution(row, at: at)
        }

        await ingestOrganismSignal(
            kind: .horizonRefresh,
            sourceOrgan: OrganismHorizonRegister.sourceOrgan,
            // Keep activation at its floor because horizon refresh must remain chemically inert.
            intensity: 0,
            metadata: [
                OrganismHorizonRegister.metadataKey: .array(composed.tokens.map(JSONValue.string)),
            ],
            persistSynchronously: false
        )
        // Refresh prunes announced rows and expires horizons without verdicts; retain one coalesced follow-up to feel waiting.
        if let after = await organismKernel.exportPersistentState()?.predictionLedger,
           !OrganismHorizonRegister.settled(in: after).isEmpty {
            sourceWakes.horizonDirty = true
        }
        return result
    }

    /// Keep horizon labels payload-free; the capsule owner chooses presentation.
    public func towardRead() async -> OrganismTowardRead? {
        await organismKernel.frozenRead(at: now()).toward
    }

    // MARK: - Announcing a resolution

    /// Distinguish waiting from the other resolution states because expiry without a reply is not a verdict.
    /// Use the register's resolution-path label for stakes admission and retain only opaque subject identity.
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
            // Keep waiting shallow because an unanswered expectation is not grief.
            feltValence = -0.18
            feltArousal = 0.2
        case .pending:
            return
        }
        let event = CognitiveEvent(
            // Derive IDs from the moment and resolution so repeated reads cannot create repeated felt events.
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

    /// Report source availability independently of rows; completeness cannot establish a horizon outcome.
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
            // Cap nearest-first before metadata bounds so truncation cannot choose sources by composition order instead of due time.
            rows.prefix(OrganismHorizonRegister.maximumOpen).map(\.token),
            readings.filter { $0.complete && !truncatedKinds.contains($0.kind.rawValue) }.map(\.kind.rawValue).sorted()
        )
    }

    /// Preserve source time: already-late evidence cannot manufacture anticipation that never existed.
    /// Refresh existing overdue horizons but open no new ones; reject only times outside the register's week.
    private func horizonDue(natural: Date, at now: Date) -> Date? {
        // Keep exact seven-day eligibility boundaries because a source can enter or leave the window without a write.
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

    /// Combine canonical Desk deferrals and memory due_at plans as one kind; completeness requires both source reads.
    private func statedPlanSources(at now: Date) async -> HorizonSourceReading {
        let desk = await deskDeferralSources(at: now)
        let atoms = await datedMemorySources(at: now)
        // Deduplicate each feed by source identity before the shared cap: Desk names and unnamed atoms' whole-second due instants.
        return HorizonSourceReading(
            kind: .statedPlan,
            rows: desk.rows + atoms.rows,
            complete: desk.complete && atoms.complete
        )
    }

    /// Collapse unnamed memory plans by whole-second instant; labels stay empty so prose cannot masquerade as canonical names.
    private func datedMemorySources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        guard let records = try? await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).listMemory(kind: nil) else {
            // An unreadable store cannot prove that every plan came round.
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

    /// Use canonical Desk deferUntil for timing and the work title for identity, independently of the deferred day.
    private func deskDeferralSources(at now: Date) async -> (rows: [(token: String, dueAt: Date)], complete: Bool) {
        // The Desk's own read decides: its op-log and base reads treat only "no such file" as never written (complete and empty);
        // any other failure (permission, I/O, damage) throws, and an unreadable Desk is incomplete.
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() else {
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

    /// Use the approval action as its label; title and reason are content and cannot cross here.
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

    /// Keep the unanswered completion's horizon fixed at slot opening so a reply remains distinguishable from aging out.
    private func openQuestionSources(at now: Date) async -> HorizonSourceReading {
        // The substrate slot inventory is complete, but absence cannot distinguish reply from aging out.
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

    /// Group delegated jobs by bridge source so multiple jobs to one peer form one expectation.
    /// Topic slugs and completion text are content and cannot cross here.
    private func peerReplySources(at now: Date) -> HorizonSourceReading {
        // Scope jobs to this install's bridge root so another install's work cannot create expectations here.
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
        // Separate empty inventory from unreadable evidence; neither supplies an outcome.
        return HorizonSourceReading(kind: .peerReply, rows: out, complete: read.allStoresReadable)
    }
}
