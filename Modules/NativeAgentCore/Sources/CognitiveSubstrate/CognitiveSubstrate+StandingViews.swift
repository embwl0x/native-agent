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
        // Maintenance may be atomically retiring this exact proposal while
        // suspended in SQLite. Preserve call order: an explicit review waits
        // for that bounded transition instead of observing its provisional
        // in-memory status and silently becoming a no-op if the commit fails.
        // R-F3: parks on the shared continuation gate rather than spinning.
        await waitForMaintenanceTransition()
        guard configuration.enabled, var view = standingViews[id] else { return nil }
        guard view.status == .proposed else { return view }
        let now = dependencies.now()
        view.status = approved ? .active : .retired
        view.updatedAt = now
        standingViews[id] = view
        // Cap math + in-memory demotions happen HERE, before any await, so memory is
        // always consistent even if persistence below never completes.
        let demoted = approved ? demoteOverflowActiveStandingViews(at: now, protecting: id) : []
        markDirty(at: now)

        if approved {
            await persistStandingView(view)
        } else {
            await deleteArtifactRecord(id: view.id)
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
            await deleteArtifactRecord(id: retired.id)
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
        return standingViews[id]
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
    func repairStandingViewCapIfNeeded() async {
        let now = dependencies.now()
        let active = standingViews.values
            .filter { $0.status == .active }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard active.count > Self.maximumActiveStandingViews else { return }
        let overflow = active.count - Self.maximumActiveStandingViews
        var demoted: [CognitiveStandingView] = []
        for var view in active.prefix(overflow) {
            view.status = .retired
            view.updatedAt = now
            standingViews[view.id] = view
            demoted.append(view)
        }
        for retired in demoted {
            await deleteArtifactRecord(id: retired.id)
            _ = await recordTimelineEvent(
                kind: .proposalResolution,
                title: "Standing view retired (cap)",
                summary: "retired (capacity): \(retired.body)",
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

    /// The Inner line from the most-recently-updated ACTIVE standing view, or nil when none
    /// is active. A settled view beats a fresh reflection takeaway — the capsule uses this in
    /// place of the transient takeaway seed line (never in addition to it), so a `.proposed`
    /// or `.retired` view NEVER surfaces and the total Inner-line count stays ≤ 1.
    func activeStandingViewInnerLine() -> String? {
        guard let view = standingViews.values
            .filter({ $0.status == .active })
            .sorted(by: { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            })
            .first else { return nil }
        let text = capsuleLineText(view.body, maxCharacters: 180)
        guard !text.isEmpty else { return nil }
        return "- Inner: \(text)"
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
        await persistArtifact(
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
