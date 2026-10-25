// NativeCognitionRuntime+StandingViews.swift
// Personality depth, item 7 — the held tier's runtime seam (2026-09-02).
//
// Its own file rather than a rider on another lane's: the tool side
// (SwiftToolDispatcher+StandingViewTools.swift) reaches the live mind by
// conditionally casting the dispatcher's existing `providerLifecycleObserver`,
// exactly as `inner_state` does, and the conformance that makes that cast
// succeed belongs beside the tier it serves.

import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import PersistenceCore
import Studio

// Blueprint: | `NativeCognitionRuntime+StandingViews.swift` | `NativeCognitionRuntime` standing-view bridge: checked hold/release, resolution/retirement outcomes and proposal projections |

/// Item 7 (2026-09-02) — the held tier's seam, on the same wire and for the
/// same reason: the runtime is the one object that owns the substrate, so the
/// dispatcher's existing `providerLifecycleObserver` reference is all the tool
/// lane needs. The SEAT is not re-checked here — `StudioCanonSeatGate` already
/// proved it at the dispatcher, and the substrate refuses an incomplete one
/// again on the way in.
extension NativeCognitionRuntime: StandingViewHolding {
    public enum StandingViewReviewStatus: Sendable, Equatable {
        case applied(CognitiveStandingView.Status)
        case unavailable(String)
        case notSaved(String)
    }

    public struct StandingViewReviewOutcome: Sendable {
        public var status: StandingViewReviewStatus
        public var detail: CognitiveObservatoryDetail
    }

    /// Recheck at the mutation boundary and after its checked write so a
    /// maintenance race or unsaved in-memory change cannot appear completed.
    public func resolveStandingViewWithOutcome(id: UUID, approved: Bool) async -> StandingViewReviewOutcome {
        let before = await observatoryDetail()
        guard before.standingViews.first(where: { $0.id == id })?.status == .proposed else {
            return StandingViewReviewOutcome(
                status: .unavailable("That standing view is no longer awaiting review."),
                detail: before
            )
        }
        let resolved = await resolveStandingViewChecked(id: id, approved: approved)
        let detail = await observatoryDetail()
        if let failure = resolved.persistenceFailure {
            return StandingViewReviewOutcome(status: .notSaved(failure), detail: detail)
        }
        let expected: CognitiveStandingView.Status = approved ? .active : .retired
        guard resolved.view?.status == expected,
              detail.standingViews.first(where: { $0.id == id })?.status == expected else {
            return StandingViewReviewOutcome(
                status: .unavailable("The standing view changed before the review could be saved."),
                detail: detail
            )
        }
        return StandingViewReviewOutcome(status: .applied(expected), detail: detail)
    }

    public func retireStandingViewWithOutcome(id: UUID) async -> StandingViewReviewOutcome {
        let before = await observatoryDetail()
        guard let current = before.standingViews.first(where: { $0.id == id }),
              current.isLeaning else {
            return StandingViewReviewOutcome(
                status: .unavailable("That standing view is not one you're leaning on."),
                detail: before
            )
        }
        let retired = await retireStandingViewChecked(id: id)
        let detail = await observatoryDetail()
        guard retired.view?.status == .retired,
              detail.standingViews.first(where: { $0.id == id })?.status == .retired else {
            return StandingViewReviewOutcome(
                status: .unavailable("The standing view changed before it could be retired."),
                detail: detail
            )
        }
        if let failure = retired.persistenceFailure {
            return StandingViewReviewOutcome(status: .notSaved(failure), detail: detail)
        }
        return StandingViewReviewOutcome(status: .applied(.retired), detail: detail)
    }

    public func standingViewsForHolding() async -> [CognitiveStandingView] {
        await bootstrap()
        return await substrate.standingViewSnapshot().filter { $0.status != .retired }
    }

    public func proposedStandingViews() async -> [CognitiveStandingView]? {
        await bootstrap()
        guard await substrate.configurationSnapshot().enabled else { return nil }
        return await substrate.standingViewSnapshot().filter { $0.status == .proposed }
    }

    /// 2026-09-06: carries the persistence outcome for the same reason release
    /// does — a hold whose artifact never reached the store must not report as
    /// done, since the view comes back `.proposed` on the next restore.
    public func holdStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition {
        await bootstrap()
        let held = await substrate.holdStandingViewChecked(id: id, seat: seat)
        guard held.view != nil else { return held }
        scheduleDirtyMicrocycle(reason: "standing_view_held")
        publishRuntimeChange(reason: "proposal:standing_view_held")
        return held
    }

    /// 2026-09-06: carries the persistence outcome, like the review seams do —
    /// a release whose artifact delete never reached the store must not report
    /// as done, since the view comes back on the next restore.
    public func releaseStandingViewChecked(
        id: UUID,
        seat: StudioCanonTurnProvenance
    ) async -> StandingViewTransition {
        await bootstrap()
        let released = await substrate.releaseStandingViewChecked(id: id, seat: seat)
        guard released.view != nil else { return released }
        scheduleDirtyMicrocycle(reason: "standing_view_released")
        publishRuntimeChange(reason: "proposal:standing_view_released")
        return released
    }
}
