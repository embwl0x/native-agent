// NativeCognitionRuntime+StandingViews.swift
// Personality depth, item 7 — the held tier's runtime seam (2026-09-02).
//
// Its own file rather than a rider on another lane's: the tool side
// (SwiftToolDispatcher+StandingViewTools.swift) reaches the live mind by
// conditionally casting the dispatcher's existing `providerLifecycleObserver`,
// exactly as `inner_state` does, and the conformance that makes that cast
// succeed belongs beside the tier it serves.

import ChatOrchestration
import CognitiveSubstrate
import Foundation
import PersistenceCore

/// Item 7 (2026-09-02) — the held tier's seam, on the same wire and for the
/// same reason: the runtime is the one object that owns the substrate, so the
/// dispatcher's existing `providerLifecycleObserver` reference is all the tool
/// lane needs. The SEAT is not re-checked here — `StudioCanonSeatGate` already
/// proved it at the dispatcher, and the substrate refuses an incomplete one
/// again on the way in.
extension NativeCognitionRuntime: StandingViewHolding {
    func standingViewsForHolding() async -> [CognitiveStandingView] {
        await bootstrap()
        return await substrate.standingViewSnapshot().filter { $0.status != .retired }
    }

    /// 2026-09-06: carries the persistence outcome for the same reason release
    /// does — a hold whose artifact never reached the store must not report as
    /// done, since the view comes back `.proposed` on the next restore.
    func holdStandingViewChecked(
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
    func releaseStandingViewChecked(
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
