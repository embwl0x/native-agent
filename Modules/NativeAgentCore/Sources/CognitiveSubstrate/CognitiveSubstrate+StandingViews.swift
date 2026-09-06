// CognitiveSubstrate+StandingViews.swift
// Wave E — STANDING VIEWS (proposal-shaped). See docs/build_plans/cognition-wave-e-standing-views.md
//
// Human mechanism: the subconscious settles repeated felt experience into durable
// dispositions — standing views of the world that then color perception without being
// re-derived each time. Her translation: reflection proposes a VIEW she has formed; User
// approves it (all autonomy stays proposal-shaped); the active set is small (≤5), evolves
// slowly, and surfaces as at most ONE Inner line in her capsule. Views are grounded in felt
// evidence — the mood valence + top felt workspace nodes at formation.

import Foundation
import NativeAgentCore
import PersistenceCore

/// The result of a standing-view lifecycle transition (2026-09-06): the view as
/// it now stands, plus the persistence failure if the transition never reached
/// the store. `nil` failure means the write landed (or persistence is off, which
/// is not a failure). A UI that reports a transition as saved must consult this
/// — the in-memory dict alone cannot tell the difference.
public struct StandingViewTransition: Sendable {
    public var view: CognitiveStandingView?
    public var persistenceFailure: String?
    /// 2026-09-06: true when the verb's OWN write landed and something else in
    /// the same transition did not — a hold that persisted but could not
    /// release the held view it displaced. The caller says what actually
    /// happened instead of claiming the whole change never reached the store.
    public var persistenceFailureIsPartial: Bool

    public init(
        view: CognitiveStandingView?,
        persistenceFailure: String? = nil,
        persistenceFailureIsPartial: Bool = false
    ) {
        self.view = view
        self.persistenceFailure = persistenceFailure
        self.persistenceFailureIsPartial = persistenceFailureIsPartial
    }
}

extension CognitiveStandingView {
    /// Persisted payload. Status lives in BOTH the payload (source of truth for restore,
    /// mirroring the schema/identity proposals) and the artifact `status` column — kept in
    /// sync by `persistStandingView`.
    func toJSON() -> JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "body": .string(body),
            "status": .string(status.rawValue),
            "moodValenceAtFormation": .double(moodValenceAtFormation),
            "evidenceNodeIds": .array(evidenceNodeIds.map { .string($0.uuidString) }),
            "createdAt": .double(createdAt.timeIntervalSince1970),
            "updatedAt": .double(updatedAt.timeIntervalSince1970),
            "lineageId": .string(lineageId),
        ])
    }
}

extension CognitiveSubstrate {
    /// Term match for standing-view surfacing: exact, or the longer term is
    /// the shorter plus a common inflection suffix ("carry"/"carrying").
    /// A bare shared prefix over-matches ("inter" would hit "internal"), so
    /// this is morphology, not stem wildcarding. Static so the rule itself
    /// is pinned by tests.
    static func standingViewTermsMatch(_ queryTerm: String, _ documentTerm: String) -> Bool {
        if queryTerm == documentTerm { return true }
        let inflectionSuffixes: Set<String> = ["s", "es", "ed", "ing", "er", "ers", "ion", "ions"]
        let (short, long) = queryTerm.count < documentTerm.count
            ? (queryTerm, documentTerm) : (documentTerm, queryTerm)
        guard short.count >= appraisalLivedConcernMinimumTermLength,
              long.hasPrefix(short) else { return false }
        return inflectionSuffixes.contains(String(long.dropFirst(short.count)))
    }

    // MARK: - Tuning knobs (the ONE standing-views surface)

    /// At most this many ACTIVE standing views at a time — a small, slowly-evolving set.
    static let maximumActiveStandingViews = 5
    /// At most this many PROPOSED views awaiting User at once — forming a 13th proposal
    /// retires the oldest unresolved one. Keeps total standing_view rows (≤5 active +
    /// ≤12 proposed) far inside the bounded restore window, so proposal churn can never
    /// crowd an active view out of restore (gpt-5.5 delta review, 2026-07-02).
    static let maximumProposedStandingViews = 12
    /// A proposed view left unresolved longer than this retires on the maintenance sweep
    /// (no zombie proposals).
    static let standingViewProposalMaxAge: TimeInterval = 14 * 24 * 60 * 60
    /// At most this many HELD views — the tier she adopts herself. Its own cap,
    /// not a share of the active one: a view the user signed must never be
    /// crowded out by one she adopted, and the two sets are LRU'd separately.
    static let maximumHeldStandingViews = 5

    // MARK: - Formation (called from the reflection parse branch)

    /// Create a `.proposed` standing view from a reflection `view:` candidate, grounded in the
    /// felt evidence available at formation (mood valence + the top felt workspace nodes the
    /// caller already resolved). Deterministic id (so a re-parse of the same receipt+body is
    /// idempotent) and NEVER auto-active — only `resolveStandingView(approved:)` activates.
    /// Records a `.schemaProposal` timeline event (formation IS a proposal being formed, the
    /// same kind schema proposals use). Returns nil on an empty body.
    @discardableResult
    func createStandingView(
        receipt: CognitiveReflectionReceipt,
        body: String,
        evidenceNodeIds: [UUID],
        at now: Date
    ) async -> CognitiveStandingView? {
        let trimmedBody = bounded(body.trimmingCharacters(in: .whitespacesAndNewlines), maxCharacters: 300)
        guard !trimmedBody.isEmpty else { return nil }
        let id = stableArtifactID("reflection_standing_view|\(receipt.id.uuidString)|\(stableDigest(trimmedBody))")
        if let existing = standingViews[id] { return existing }
        let mood = derivedMood(at: now)
        let view = CognitiveStandingView(
            id: id,
            title: bounded(standingViewTitle(from: trimmedBody), maxCharacters: 80),
            body: trimmedBody,
            status: .proposed,
            moodValenceAtFormation: mood.valence,
            evidenceNodeIds: unique(evidenceNodeIds),
            createdAt: now,
            updatedAt: now,
            lineageId: bounded("reflection:\(receipt.id.uuidString)", maxCharacters: 120)
        )
        standingViews[id] = view
        // Bound the awaiting-User set SYNCHRONOUSLY (before any await): a 13th proposal
        // retires the oldest unresolved one so proposal churn stays inside the restore
        // window. The new view is EXCLUDED from the eviction sort (like `protecting:` in
        // the active-cap demotion) — createdAt ties under a frozen/test clock could
        // otherwise self-evict the view this call is about to persist and return
        // (gpt-5.5 final delta, 2026-07-02).
        var displaced: [CognitiveStandingView] = []
        let otherProposed = standingViews.values
            .filter { $0.status == .proposed && $0.id != id }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        if otherProposed.count + 1 > Self.maximumProposedStandingViews {
            for var old in otherProposed.prefix(otherProposed.count + 1 - Self.maximumProposedStandingViews) {
                old.status = .retired
                old.updatedAt = now
                standingViews[old.id] = old
                displaced.append(old)
            }
        }
        markDirty(at: now)
        await persistStandingView(view)
        _ = await recordTimelineEvent(
            kind: .schemaProposal,
            title: view.title.isEmpty ? "Standing view proposed" : view.title,
            summary: view.body,
            artifactId: view.id,
            lineageId: view.lineageId,
            externalEvidenceIds: ["reflection:\(receipt.id.uuidString)"] + view.evidenceNodeIds.map { "node:\($0.uuidString)" }
        )
        for old in displaced {
            await deleteArtifactRecord(id: old.id)
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: "Standing view retired (displaced)",
                summary: "retired (displaced): \(old.body)",
                artifactId: old.id,
                lineageId: old.lineageId,
                externalEvidenceIds: []
            )
        }
        return view
    }

    /// Short title from the first line/clause of the body (≤80 chars). Only for the
    /// Observatory/timeline label — the capsule surfaces the body, not this.
    private func standingViewTitle(from body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        return capsuleLineText(firstLine, maxCharacters: 80)
    }

    // MARK: - Lifecycle

    /// User's approval seam. approved → `.active` (cap-enforced); rejected → `.retired`.
    /// Only a `.proposed` view can transition — re-resolving an already-active/retired view is
    /// a no-op that returns its current state (never re-fires a timeline event). This is the
    /// ONLY path that activates a view; there is no autonomous activation anywhere.
    ///
    /// The activation AND any cap-overflow demotions commit to the in-memory dict in ONE
    /// synchronous segment BEFORE the first await, so a crash/reentrancy mid-persistence can
    /// never leave >cap active views in memory — and `repairStandingViewCapIfNeeded` heals
    /// the store on the next restore if persistence died half-way (gpt-5.5 review,
    /// 2026-07-02). Retired views DELETE their artifact (timeline keeps the history).
    @discardableResult
    public func resolveStandingView(id: UUID, approved: Bool) async -> CognitiveStandingView? {
        await resolveStandingViewChecked(id: id, approved: approved).view
    }

    /// `resolveStandingView`, reporting whether the transition reached the
    /// store (2026-09-06). The in-memory commit deliberately stays BEFORE the
    /// write — the cap invariant above depends on it, and
    /// `repairStandingViewCapIfNeeded` heals a half-written store on restore —
    /// but a swallowed `try?` also meant an approval whose artifact never
    /// landed came back as `.proposed` after a restart while the click had
    /// reported success. The write's failure now travels to the caller.
    @discardableResult
    public func resolveStandingViewChecked(
        id: UUID,
        approved: Bool
    ) async -> StandingViewTransition {
        // Maintenance may be atomically retiring this exact proposal while
        // suspended in SQLite. Preserve call order: an explicit review waits
        // for that bounded transition instead of observing its provisional
        // in-memory status and silently becoming a no-op if the commit fails.
        // R-F3: parks on the shared continuation gate rather than spinning.
        await waitForMaintenanceTransition()
        guard configuration.enabled, var view = standingViews[id] else {
            return StandingViewTransition(view: nil)
        }
        guard view.status == .proposed else { return StandingViewTransition(view: view) }
        let now = dependencies.now()
        view.status = approved ? .active : .retired
        view.updatedAt = now
        standingViews[id] = view
        // Cap math + in-memory demotions happen HERE, before any await, so memory is
        // always consistent even if persistence below never completes.
        let demoted = approved ? demoteOverflowActiveStandingViews(at: now, protecting: id) : []
        markDirty(at: now)

        var persistenceFailure: String?
        do {
            if approved {
                try await persistStandingViewChecked(view)
            } else {
                try await deleteArtifactRecordChecked(id: view.id)
            }
        } catch {
            persistenceFailure = "\(error)"
        }
        _ = await recordTimelineEvent(
            kind: .proposalResolution,
            title: approved ? "Standing view active" : "Standing view retired",
            summary: "\(approved ? "activated" : "retired"): \(view.body)",
            artifactId: view.id,
            lineageId: view.lineageId,
            externalEvidenceIds: []
        )
        for retired in demoted {
            // 2026-09-06: the cap demotions are part of THIS transition. A
            // demotion whose delete never reached the store leaves that view
            // active on disk, so the next restore comes back over the cap while
            // the click reported a clean save. Reported like the primary write;
            // the first failure is the one carried.
            do {
                try await deleteArtifactRecordChecked(id: retired.id)
            } catch {
                persistenceFailure = persistenceFailure
                    ?? "cap demotion of \(retired.id.uuidString) not saved: \(error)"
            }
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: "Standing view retired (cap)",
                summary: "retired (capacity): \(retired.body)",
                artifactId: retired.id,
                lineageId: retired.lineageId,
                externalEvidenceIds: []
            )
        }
        // The SLOW layer (U2b, 2026-07-09): a view SETTLING is a considered outcome —
        // she formed it under a felt mood, and User approving it makes that way of seeing
        // durable. A settled positive view leaves a settled positive undertone. Only
        // approval writes (a rejection retires the view; it settles nothing), and only
        // when the formation mood had genuinely left neutral — otherwise the approval
        // settles a VIEW without a tone. Routes through the shared cap + day-scale decay,
        // so a burst of approvals can no more ratchet her than a burst of reflections.
        if approved {
            await integrateDisposition(tone: standingViewDispositionTone(for: view), at: now)
        }
        return StandingViewTransition(
            view: standingViews[id], persistenceFailure: persistenceFailure)
    }

    // MARK: - Retirement by the user (2026-09-02)

    /// RETIRE A VIEW SHE IS ALREADY LEANING ON. Agent, 2026-09-02: three of her
    /// five active views were three drafts of one phrasing view, and there was
    /// no way to say so — `resolveStandingView` only transitions `.proposed`,
    /// so the ONLY route out of `.active` was LRU demotion by a sixth approval.
    /// A worldview you can enter but not leave is not a worldview, it is a
    /// ratchet, and the one organ that was supposed to break the phrasing loop
    /// was itself stuck inside it.
    ///
    /// Deliberately NOT `resolveStandingView(approved: false)`: a rejection is
    /// a verdict on a PROPOSAL, and reusing it here would make "she proposed
    /// this and I said no" and "I lived with this for a month and I am done
    /// with it" the same row in the timeline. They are different facts about
    /// her development, and the timeline is the record of that.
    ///
    /// Applies to `.active` and `.held` alike — the user never had to sign a
    /// held view, and may still retire one. Idempotent: retiring an
    /// already-retired view (or a `.proposed` one, which belongs to the resolve
    /// route) is a no-op that returns the view unchanged. Lived concerns need
    /// no re-minting call: `livedAppraisalConcerns()` derives them from the
    /// leaning set on every read, so dropping the status IS the re-mint.
    @discardableResult
    public func retireStandingView(id: UUID) async -> CognitiveStandingView? {
        await retireStandingViewChecked(id: id).view
    }

    /// `retireStandingView`, reporting whether the artifact delete reached the
    /// store (2026-09-06) — same reason as `resolveStandingViewChecked`: a
    /// retirement that only happened in memory came back on the next restore
    /// after the click had already said it was done.
    @discardableResult
    public func retireStandingViewChecked(id: UUID) async -> StandingViewTransition {
        await waitForMaintenanceTransition()
        guard configuration.enabled, var view = standingViews[id] else {
            return StandingViewTransition(view: nil)
        }
        guard view.isLeaning else { return StandingViewTransition(view: view) }
        let now = dependencies.now()
        let wasHeld = view.status == .held
        view.status = .retired
        view.updatedAt = now
        standingViews[id] = view
        markDirty(at: now)
        // Same shape as the cap-demotion path: the artifact goes, the timeline
        // keeps the history.
        var persistenceFailure: String?
        do {
            try await deleteArtifactRecordChecked(id: view.id)
        } catch {
            persistenceFailure = "\(error)"
        }
        await recordReceipt(
            kind: wasHeld ? "standing_view.released" : "standing_view.retired",
            payload: .object([
                "id": .string(view.id.uuidString),
                "reason": .string("chosen"),
                "body": .string(bounded(view.body, maxCharacters: 300)),
            ]))
        _ = await recordTimelineEvent(
            kind: .proposalResolution,
            title: "Standing view retired (chosen)",
            summary: "retired (chosen): \(view.body)",
            artifactId: view.id,
            lineageId: view.lineageId,
            externalEvidenceIds: []
        )
        return StandingViewTransition(
            view: standingViews[id], persistenceFailure: persistenceFailure)
    }

    // MARK: - The HELD tier (User, 2026-09-02: "she should be able to have some views of her own")

    /// ADOPT A VIEW HERSELF. No signature, a weaker lean, retirable by the user
    /// who never signed it.
    ///
    /// THE SEAT IS THE WHOLE SAFETY ARGUMENT. `seat` is the same
    /// `StudioCanonTurnProvenance` the canon lane already uses, and the point of
    /// taking it as a parameter rather than deriving it here is that this module
    /// CANNOT derive it: the discriminators live in the chat tool loop's
    /// task-locals. A caller that is not inside her own live local turn cannot
    /// produce a complete one — `StudioCanonSeatGate.liveTurnProvenance` returns
    /// `.notALiveTurn` for the bridge tool runner, every approval executor,
    /// every replay and every background pass, and `.bridgeLane` for a turn
    /// Claude is steering. So "she adopted this" stays a fact about where the
    /// call came from rather than a claim the caller makes.
    ///
    /// An incomplete seat is REFUSED (nil), never downgraded to a proposal: a
    /// silent fallback would let an unseated path mint views forever.
    @discardableResult
    public func holdStandingView(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> CognitiveStandingView? {
        await holdStandingViewChecked(id: id, seat: seat).view
    }

    /// `holdStandingView`, reporting whether the transition reached the store
    /// (2026-09-06) — the same reason as the resolve/release seams: the hold
    /// persisted through the unchecked `persistStandingView`, so a view whose
    /// artifact never landed reported as held and came back `.proposed` after a
    /// restart. The in-memory commit and the cap math deliberately stay BEFORE
    /// the write, exactly as the active path does it.
    @discardableResult
    public func holdStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition {
        await waitForMaintenanceTransition()
        guard configuration.enabled, seat.isComplete, var view = standingViews[id] else {
            return StandingViewTransition(view: nil)
        }
        // Only a PROPOSED view can be held. An active view is already stronger
        // than held (holding it would be a demotion nobody asked for) and a
        // retired one is over.
        guard view.status == .proposed else { return StandingViewTransition(view: view) }
        let now = dependencies.now()
        view.status = .held
        view.updatedAt = now
        standingViews[id] = view
        // Cap math before any await, exactly as the active path does it.
        let released = releaseOverflowHeldStandingViews(at: now, protecting: id)
        markDirty(at: now)
        var persistenceFailure: String?
        var persistenceFailureIsPartial = false
        do {
            try await persistStandingViewChecked(view)
        } catch {
            persistenceFailure = "\(error)"
        }
        await recordReceipt(
            kind: "standing_view.held",
            payload: .object([
                "id": .string(view.id.uuidString),
                "surface": .string(bounded(seat.surface, maxCharacters: 40)),
                "turnId": .string(bounded(seat.turnID, maxCharacters: 120)),
                "body": .string(bounded(view.body, maxCharacters: 300)),
            ]))
        _ = await recordTimelineEvent(
            kind: .proposalResolution,
            title: "Standing view held",
            summary: "held (self-adopted): \(view.body)",
            artifactId: view.id,
            lineageId: view.lineageId,
            externalEvidenceIds: []
        )
        for old in released {
            // 2026-09-06: the cap releases are part of THIS transition, like the
            // active path's demotions — a release whose delete never reached the
            // store leaves that view held on disk while the call reported a
            // clean save. The first failure is the one carried.
            do {
                try await deleteArtifactRecordChecked(id: old.id)
            } catch {
                if persistenceFailure == nil {
                    // The hold itself landed; this is the displaced view that
                    // could not be let go, and it stays held in the store.
                    persistenceFailure = "cap release of \(old.id.uuidString) not saved: \(error)"
                    persistenceFailureIsPartial = true
                }
            }
            await recordReceipt(
                kind: "standing_view.released",
                payload: .object([
                    "id": .string(old.id.uuidString),
                    "reason": .string("capacity"),
                    "body": .string(bounded(old.body, maxCharacters: 300)),
                ]))
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: "Standing view released (cap)",
                summary: "released (capacity): \(old.body)",
                artifactId: old.id,
                lineageId: old.lineageId,
                externalEvidenceIds: []
            )
        }
        // NO DISPOSITION NUDGE. The active path nudges because the user SETTLING
        // a view is a considered outcome; a view she adopts on her own settles
        // nothing yet, and letting it move the slow layer would give her a
        // self-serve lever on her own mood — the exact self-appraisal ratchet
        // design law 3 killed in two other layers.
        return StandingViewTransition(
            view: standingViews[id],
            persistenceFailure: persistenceFailure,
            persistenceFailureIsPartial: persistenceFailureIsPartial)
    }

    /// She lets one of her own views go. Same transition the user's retire makes,
    /// distinguished only by the receipt already written there — a held view's
    /// retirement IS a release whoever asked for it.
    ///
    /// Reports whether the artifact delete reached the store (2026-09-06):
    /// release was the one lifecycle verb still routed through the unchecked
    /// retire, so a released view whose delete never landed said it was let go
    /// and then came back on the next restore.
    @discardableResult
    public func releaseStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition {
        guard seat.isComplete, standingViews[id]?.status == .held else {
            return StandingViewTransition(view: standingViews[id])
        }
        return await retireStandingViewChecked(id: id)
    }

    /// SYNCHRONOUS cap math for the held tier — LRU by `updatedAt`, never
    /// touching `protecting`. Mirrors `demoteOverflowActiveStandingViews`; kept
    /// separate so an overflowing held set can never evict a signed active view.
    private func releaseOverflowHeldStandingViews(at now: Date, protecting: UUID) -> [CognitiveStandingView] {
        let held = standingViews.values
            .filter { $0.status == .held && $0.id != protecting }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let total = held.count + 1
        guard total > Self.maximumHeldStandingViews else { return [] }
        var released: [CognitiveStandingView] = []
        for var view in held.prefix(total - Self.maximumHeldStandingViews) {
            view.status = .retired
            view.updatedAt = now
            standingViews[view.id] = view
            released.append(view)
        }
        return released
    }

    /// −1 / 0 / +1: the felt SIGN of the mood a view was formed under, inert inside the
    /// neutral band. Sign only — the nudge magnitude is the shared per-write constant,
    /// so a view formed in a euphoric moment moves her exactly as far as one formed in a
    /// quietly good one. (A view is a conclusion, not a feeling; it carries direction.)
    func standingViewDispositionTone(for view: CognitiveStandingView) -> Double {
        let valence = view.moodValenceAtFormation
        guard abs(valence) >= Self.dispositionNeutralValenceBand else { return 0 }
        return valence > 0 ? 1 : -1
    }

    /// SYNCHRONOUS cap math: demote the least-recently-updated ACTIVE views beyond the cap
    /// to `.retired` in the in-memory dict, never touching `protecting` (the just-approved
    /// view, which also carries the freshest updatedAt). Returns the demoted views so the
    /// caller can persist/timeline them AFTER the actor state is already consistent.
    private func demoteOverflowActiveStandingViews(at now: Date, protecting: UUID) -> [CognitiveStandingView] {
        let active = standingViews.values
            .filter { $0.status == .active && $0.id != protecting }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        let totalActive = active.count + 1 // + the protected view
        guard totalActive > Self.maximumActiveStandingViews else { return [] }
        let overflow = totalActive - Self.maximumActiveStandingViews
        var demoted: [CognitiveStandingView] = []
        for var view in active.prefix(overflow) {
            view.status = .retired
            view.updatedAt = now
            standingViews[view.id] = view
            demoted.append(view)
        }
        return demoted
    }

    /// Defensive repair after restore: if a half-persisted approval ever left more than the
    /// cap ACTIVE in the store, demote the overflow (LRU) and heal the store by deleting
    /// their artifacts. No-op in the normal case (gpt-5.5 review, 2026-07-02).
    ///
    /// 2026-09-06: it now covers the HELD tier too. A hold persists the newly
    /// held view first and only then deletes the views it displaced, so a
    /// partial failure there leaves cap+1 held on disk — and this repair, which
    /// filtered `.active` only, walked past them on every launch.
    func repairStandingViewCapIfNeeded() async {
        let now = dependencies.now()
        await repairStandingViewCapIfNeeded(
            status: .active, cap: Self.maximumActiveStandingViews, at: now)
        await repairStandingViewCapIfNeeded(
            status: .held, cap: Self.maximumHeldStandingViews, at: now)
    }

    private func repairStandingViewCapIfNeeded(
        status: CognitiveStandingView.Status,
        cap: Int,
        at now: Date
    ) async {
        let overCap = standingViews.values
            .filter { $0.status == status }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard overCap.count > cap else { return }
        let overflow = overCap.count - cap
        var demoted: [CognitiveStandingView] = []
        for var view in overCap.prefix(overflow) {
            view.status = .retired
            view.updatedAt = now
            standingViews[view.id] = view
            demoted.append(view)
        }
        for retired in demoted {
            // 2026-09-06: this repair ran through the swallowing delete, so a
            // store that cannot accept deletes healed nothing and silently
            // re-demoted the same views on every launch. The failure is logged
            // once per launch (the repair itself stays best-effort — there is
            // no caller to report to on the restore path).
            do {
                try await deleteArtifactRecordChecked(id: retired.id)
            } catch {
                if !didLogStandingViewCapRepairFailure {
                    didLogStandingViewCapRepairFailure = true
                    NSLog(
                        "[cognition] standing view cap repair could not delete artifact %@ (%@): %@ "
                            + "— the overflow stays in the store and will be "
                            + "re-demoted on the next launch.",
                        retired.id.uuidString,
                        status.rawValue,
                        "\(error)"
                    )
                }
            }
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: status == .held
                    ? "Standing view released (cap)"
                    : "Standing view retired (cap)",
                summary: status == .held
                    ? "released (capacity): \(retired.body)"
                    : "retired (capacity): \(retired.body)",
                artifactId: retired.id,
                lineageId: retired.lineageId,
                externalEvidenceIds: []
            )
        }
    }

    /// Retire `.proposed` views left unresolved past the max age (no zombie proposals). Rides
    /// the maintenance sweep after Wave D's consolidation. Retirement uses createdAt (a view
    /// is "stale" if it has sat unresolved since it was formed); restore clamps any
    /// future-dated createdAt, so clock skew can't make a proposal immortal.
    /// Await-free lifecycle transition used by the atomic maintenance pass.
    /// Timeline creation remains with the caller so the deletion and its audit
    /// lineage can share one SQLite commit.
    func retireStaleProposedStandingViewsInMemory(at now: Date) -> [CognitiveStandingView] {
        var stale: [CognitiveStandingView] = []
        for var view in standingViews.values
        where view.status == .proposed
            && now.timeIntervalSince(view.createdAt) > Self.standingViewProposalMaxAge {
            view.status = .retired
            view.updatedAt = now
            standingViews[view.id] = view
            stale.append(view)
        }
        return stale.sorted { lhs, rhs in lhs.id.uuidString < rhs.id.uuidString }
    }

    // MARK: - Capsule surfacing (called from innerStateCapsuleLines)

    /// Frozen candidates for the durable `Inner` line. Each candidate carries
    /// the exact concern vocabulary the existing semantic-appraisal matcher
    /// assigned to that view at capture time, so a later frozen render never
    /// rereads live views or affect.
    func standingViewCapsuleCandidates() -> [CognitiveStandingViewCapsuleCandidate] {
        let concerns = appraisalConcerns()
        // Both leaning tiers. `isHeld` rides the candidate so the frozen render
        // can keep held views strictly under the signed ones without rereading
        // live view state.
        return standingViews.values
            .filter({ $0.isLeaning })
            .sorted(by: { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            })
            .compactMap { view in
                let text = capsuleLineText(view.body, maxCharacters: 180)
                guard !text.isEmpty else { return nil }
                let viewText = "\(view.title) \(view.body)"
                let lowered = viewText.lowercased()
                // What this view is ABOUT. Every matched concern's keywords
                // used to be flattened in together, so a view that merely
                // mentions "fix" carried the whole shipped `repair` lexicon
                // and answered to messages it has nothing to say about. Her
                // own distinctive terms are the discriminating signal; the
                // matched-concern lexicon is the FALLBACK for a view too
                // short to have any (it is all a bare "I fix it, I own it"
                // can be recognised by).
                let distinctive = Self.appraisalConcernTerms(in: viewText)
                let effective = distinctive.isEmpty
                    ? concerns.filter { Self.concernMatches($0, in: lowered) }.flatMap(\.keywords)
                    : distinctive
                return CognitiveStandingViewCapsuleCandidate(
                    id: view.id,
                    line: "- Inner: \(text)",
                    concernKeywords: Array(Set(effective)).sorted(),
                    updatedAt: view.updatedAt,
                    isHeld: view.status == .held
                )
            }
    }

    /// Select at most one durable view for this turn. The canary is entirely
    /// presentation-side: disabling it restores the historical newest-active
    /// line, while active views continue to shape appraisal/disposition either
    /// way. With the canary on, unrelated chat falls through to the fresher
    /// reflection takeaway instead of repeating one old worldview every turn.
    func activeStandingViewInnerLine(
        relevantTo userMessage: String,
        candidates frozenCandidates: [CognitiveStandingViewCapsuleCandidate]? = nil,
        relevanceEnabled: Bool? = nil
    ) -> String? {
        activeStandingViewInnerLines(
            relevantTo: userMessage,
            candidates: frozenCandidates,
            relevanceEnabled: relevanceEnabled
        ).first
    }

    /// EVERY view that is relevant to this turn, best match first.
    ///
    /// The capsule used to receive exactly one line from here, so the Inner
    /// line's rotation had nothing to rotate BETWEEN while a standing view was
    /// relevant: the top-ranked view led, rested, and the turn fell through to a
    /// takeaway even though a second, equally on-topic view was sitting right
    /// there. Ranked-all lets rotation move across her actual worldview before
    /// it reaches for a transient seed. Ordering is unchanged for the head of
    /// the list, so a single-candidate install is byte-identical.
    func activeStandingViewInnerLines(
        relevantTo userMessage: String,
        candidates frozenCandidates: [CognitiveStandingViewCapsuleCandidate]? = nil,
        relevanceEnabled: Bool? = nil
    ) -> [String] {
        let candidates = frozenCandidates ?? standingViewCapsuleCandidates()
        guard !candidates.isEmpty else { return [] }
        let enabled = relevanceEnabled ?? configuration.standingViewCapsuleRelevanceEnabled
        // TIERED, ALWAYS. Signed views first, held views after — including on
        // the canary-off path, where relevance is not consulted at all.
        let signed = candidates.filter { !$0.isHeld }
        let held = candidates.filter(\.isHeld)
        guard enabled else { return (signed + held).map(\.line) }
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // Each tier is scored WITHIN ITSELF and the lists are concatenated, so a
        // held view can never outrank a signed one however well it matches the
        // message. (Scoring the two sets together and re-sorting by tier
        // afterwards would let the held set's vocabulary move the idf of the
        // signed set's terms — the tier would change the signed ranking, which
        // is exactly what "ranked below" must not mean.)
        let rankedSigned = Self.relevantCandidates(in: signed, for: userMessage).map(\.line)
        let rankedHeld = held.isEmpty
            ? []
            : Self.relevantCandidates(in: held, for: userMessage).map(\.line)
        return rankedSigned + rankedHeld
    }

    // MARK: - Relevance (BM25)

    /// Substring containment made a single incidental word enough: an
    /// unrelated message that happens to contain "memory" surfaced an old
    /// worldview every turn. Scoring instead asks HOW MUCH of what the
    /// message is about this view actually covers.
    ///
    /// Okapi BM25 over the candidate set (documents = a view's frozen concern
    /// keywords, tf capped at 1 because they are a SET), normalized against
    /// the score a hypothetical average-length view covering EVERY query term
    /// would earn. So the score is a 0…1 idf-weighted coverage fraction with
    /// BM25's length penalty intact — comparable across candidate sets, which
    /// a raw BM25 score is not, and therefore the only form an absolute floor
    /// can be stated against.
    ///
    /// Ties (equal score) keep the incoming order, which is newest-first —
    /// the historical behavior.
    static let standingViewRelevanceFloor = 0.18
    static let standingViewRelevanceK1 = 1.2
    static let standingViewRelevanceB = 0.75
    static let standingViewRelevanceMinimumIDF = 0.5
    static let standingViewRelevanceMaximumIDF = 2.0

    static func bestRelevantCandidate(
        in candidates: [CognitiveStandingViewCapsuleCandidate],
        for userMessage: String
    ) -> CognitiveStandingViewCapsuleCandidate? {
        relevantCandidates(in: candidates, for: userMessage).first
    }

    /// Every candidate clearing the relevance floor, best score first. Ties keep
    /// the INCOMING order (newest-first), which is what `bestRelevantCandidate`
    /// has always done — so the head of this list is bit-for-bit the answer that
    /// function used to compute on its own.
    static func relevantCandidates(
        in candidates: [CognitiveStandingViewCapsuleCandidate],
        for userMessage: String
    ) -> [CognitiveStandingViewCapsuleCandidate] {
        let queryTerms = appraisalConcernTerms(in: userMessage)
        guard !queryTerms.isEmpty else { return [] }
        let documents = candidates.map { Set($0.concernKeywords) }
        let total = documents.count
        guard total > 0 else { return [] }
        let averageLength = Double(documents.reduce(0) { $0 + $1.count }) / Double(total)
        guard averageLength > 0 else { return [] }

        // Term-level, not free substring: "carrying" still reaches a view
        // about "carry", but "simple" can no longer be found inside an
        // unrelated sentence's middle. A bare shared prefix over-matches
        // ("inter" would hit "internal"/"interesting"), so the longer term
        // must be the shorter one plus a common inflection suffix — morphology,
        // not stem wildcarding. The shorter side still clears the 5-character
        // floor, so a 3-letter lexicon entry like "fix" matches only exactly.
        func matches(_ queryTerm: String, _ documentTerm: String) -> Bool {
            CognitiveSubstrate.standingViewTermsMatch(queryTerm, documentTerm)
        }
        func document(_ index: Int, covers term: String) -> Bool {
            documents[index].contains { matches(term, $0) }
        }

        // ln(1 + (N - n + 0.5) / (n + 0.5)), CLAMPED. The active set is ≤5
        // views, and at that corpus size raw idf degenerates: every term a
        // view carries scores ~0.29 while any term absent from all of them
        // scores ~1.4, so a genuinely on-topic message that also mentions one
        // other thing could never clear any floor. The clamp keeps idf's
        // ordering (rarer still outranks common) without letting a
        // one-document corpus decide the outcome by itself.
        func idf(_ term: String) -> Double {
            let containing = Double(documents.indices.reduce(0) {
                $0 + (document($1, covers: term) ? 1 : 0)
            })
            let raw = log(1 + (Double(total) - containing + 0.5) / (containing + 0.5))
            return min(standingViewRelevanceMaximumIDF, max(standingViewRelevanceMinimumIDF, raw))
        }
        let idfByTerm = Dictionary(uniqueKeysWithValues: queryTerms.map { ($0, idf($0)) })
        // The denominator: total query mass. Terms NO view carries stay in it
        // on purpose — a long message mostly about something else cannot be
        // fully "covered" by one incidental hit.
        // Summed over the ORDERED terms, not the dictionary's values: float
        // addition is not associative, and an unordered sum could shift the
        // last bits between runs and flip a candidate sitting on the floor.
        let queryMass = queryTerms.reduce(0.0) { $0 + (idfByTerm[$1] ?? 0) }
        guard queryMass > 0 else { return [] }

        let k1 = standingViewRelevanceK1
        let b = standingViewRelevanceB
        var scored: [(candidate: CognitiveStandingViewCapsuleCandidate, score: Double, order: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            let matched = queryTerms.filter { document(index, covers: $0) }
            guard !matched.isEmpty else { continue }
            let lengthNorm = 1 - b + b * Double(documents[index].count) / averageLength
            // Reference denominator uses |d| = avgdl, where the factor is
            // (k1 + 1) / (1 + k1); the (k1 + 1) cancels, leaving this.
            let lengthFactor = (1 + k1) / (k1 * lengthNorm + 1)
            let score = min(1.0, matched.reduce(0) { $0 + (idfByTerm[$1] ?? 0) } * lengthFactor / queryMass)
            guard score >= standingViewRelevanceFloor else { continue }
            scored.append((candidate, score, index))
        }
        // Decorated sort: Swift's `sorted` is not stable, and tie order is
        // load-bearing here (newest-first was the historical answer).
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.order < rhs.order
            }
            .map(\.candidate)
    }

    /// Compatibility read for non-turn diagnostics. It intentionally retains
    /// the historical newest-active behavior because no user message exists to
    /// establish relevance.
    func activeStandingViewInnerLine() -> String? {
        activeStandingViewInnerLine(relevantTo: "", relevanceEnabled: false)
    }

    // MARK: - Surfaces

    public func standingViewSnapshot() async -> [CognitiveStandingView] {
        standingViews.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Persistence

    /// One artifact per view, kind `"standing_view"`. Status is written to BOTH the artifact
    /// status column and the payload; restore reads the payload (like schema/identity
    /// proposals). Score is clamped to [0,1] by the store, so the (possibly negative) mood
    /// valence is floored — it is telemetry only; prune orders artifacts by updated_at.
    func persistStandingView(_ view: CognitiveStandingView) async {
        try? await persistStandingViewChecked(view)
    }

    /// The same write, surfacing its failure for the lifecycle seams whose
    /// caller needs to know the transition did not reach the store
    /// (2026-09-06).
    func persistStandingViewChecked(_ view: CognitiveStandingView) async throws {
        try await persistArtifactChecked(
            kind: "standing_view",
            id: view.id,
            status: view.status.rawValue,
            score: max(0, view.moodValenceAtFormation),
            payload: view.toJSON()
        )
    }

    /// Restore standing views from `standing_view` artifacts. Clears the dict FIRST so a
    /// re-run of restore never leaves a stale in-memory view behind (mirrors the other
    /// restore helpers). Future-dated timestamps (clock skew) are clamped to `now` so the
    /// stale sweep can never be pushed out indefinitely — and the ids of clamped views are
    /// RETURNED so the caller can persist the repair (an in-memory-only clamp would reset
    /// the view's age on every restart, dodging the sweep forever — gpt-5.5 delta review,
    /// 2026-07-02). Retired views delete their artifact at retire time, so nothing retired
    /// should arrive here — but if one does (legacy row), it restores harmlessly and simply
    /// never surfaces.
    @discardableResult
    func restoreStandingViews(from payloads: [JSONValue]) -> [UUID] {
        standingViews.removeAll(keepingCapacity: true)
        let now = dependencies.now()
        var clamped: [UUID] = []
        for payload in payloads {
            guard case .object(let object) = payload,
                  let id = uuidValue(object["id"]),
                  let title = stringValue(object["title"]),
                  let body = stringValue(object["body"]),
                  let statusRaw = stringValue(object["status"]),
                  let status = CognitiveStandingView.Status(rawValue: statusRaw),
                  let createdAt = dateValue(object["createdAt"]),
                  let updatedAt = dateValue(object["updatedAt"]) else {
                continue
            }
            if createdAt > now || updatedAt > now { clamped.append(id) }
            standingViews[id] = CognitiveStandingView(
                id: id,
                title: title,
                body: body,
                status: status,
                moodValenceAtFormation: doubleValue(object["moodValenceAtFormation"]) ?? 0,
                evidenceNodeIds: uuidArrayValue(object["evidenceNodeIds"]),
                createdAt: min(createdAt, now),
                updatedAt: min(updatedAt, now),
                lineageId: stringValue(object["lineageId"]) ?? ""
            )
        }
        return clamped
    }

    /// Persist the timestamp repairs `restoreStandingViews` made in memory, so a clamped
    /// (formerly future-dated) view keeps its corrected age across restarts. Skips views
    /// that are `.retired` by the time this runs — the cap repair between restore and this
    /// call demotes + DELETES over-cap actives, and re-upserting one here would resurrect
    /// the artifact it just deleted.
    func persistClampedStandingViews(ids: [UUID]) async {
        for id in ids {
            guard let view = standingViews[id], view.status != .retired else { continue }
            await persistStandingView(view)
        }
    }
}
