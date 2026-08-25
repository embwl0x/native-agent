import CognitiveSubstrate
import Foundation

/// The narrow executable boundary behind the Cognition Observatory controls.
/// Views own transient spinner/toast state; the runtime remains the canonical
/// cognition/organism owner.  Returning the exact read model makes a completed
/// click distinguishable from a control that merely redrew stale state.
enum CognitionObservatoryActions {
    struct ReflectionOutcome: Sendable {
        var status: CognitiveBackgroundRunOutcome
        var detail: CognitiveObservatoryDetail
    }

    /// The mounted read boundary. Its evidence status distinguishes a quiet
    /// receipt lane from one that was unavailable while the rest of the
    /// Observatory projection was collected.
    static func refreshRead(
        runtime: NativeCognitionRuntime = .shared
    ) async -> CognitiveObservatoryDetailRead {
        await runtime.observatoryDetailRead()
    }

    /// Compatibility projection for action helpers that only need to redraw
    /// their non-receipt fields. New observational consumers must use
    /// `refreshRead` and preserve its explicit evidence state.
    static func refresh(runtime: NativeCognitionRuntime = .shared) async -> CognitiveObservatoryDetail {
        await refreshRead(runtime: runtime).detail
    }

    /// The control receives the runtime's one typed terminal outcome. It never
    /// infers success from whichever receipt happened to arrive during a refresh.
    static func reflectWithOutcome(
        runtime: NativeCognitionRuntime = .shared
    ) async -> ReflectionOutcome {
        let status = await runtime.runManualReflection()
        let detail = await refresh(runtime: runtime)
        return ReflectionOutcome(status: status, detail: detail)
    }

    static func settleBody(runtime: NativeCognitionRuntime = .shared) async -> CognitiveObservatoryDetail {
        _ = await runtime.settleOrganismContinuity()
        return await refresh(runtime: runtime)
    }

    static func settleBodyChecked(runtime: NativeCognitionRuntime = .shared) async -> (outcome: OrganismContinuityApplyOutcome, detail: CognitiveObservatoryDetail) {
        let outcome = await runtime.settleOrganismContinuityChecked()
        return (outcome, await refresh(runtime: runtime))
    }

    static func resetBody(runtime: NativeCognitionRuntime = .shared) async -> CognitiveObservatoryDetail {
        _ = await runtime.resetOrganismContinuity()
        return await refresh(runtime: runtime)
    }

    static func resetBodyChecked(runtime: NativeCognitionRuntime = .shared) async -> (outcome: OrganismContinuityApplyOutcome, detail: CognitiveObservatoryDetail) {
        let outcome = await runtime.resetOrganismContinuityChecked()
        return (outcome, await refresh(runtime: runtime))
    }

    static func reviewReflex(
        runtime: NativeCognitionRuntime = .shared,
        id: String,
        decision: OrganismReflexReviewDecision,
        note: String,
        reviewedBy: String,
        source: String
    ) async -> (outcome: OrganismReflexReviewApplyOutcome, detail: CognitiveObservatoryDetail) {
        let outcome = await runtime.applyOrganismReflexReview(
            id: id,
            decision: decision,
            note: note,
            reviewedBy: reviewedBy,
            source: source
        )
        return (outcome, await refresh(runtime: runtime))
    }

}

/// The shared standing-view action used by the full Cognition Proposals screen
/// and Activity's inline callback. The returned read model is what the full
/// screen renders after a click; no second proposal state owner is introduced.
enum CognitionProposalActions {
    enum ResolveStatus: Sendable, Equatable {
        case applied(CognitiveStandingView.Status)
        case unavailable(String)
    }

    struct ResolveOutcome: Sendable {
        var status: ResolveStatus
        var detail: CognitiveObservatoryDetail
    }

    static func resolve(
        runtime: NativeCognitionRuntime = .shared,
        id: UUID,
        approved: Bool
    ) async -> CognitiveObservatoryDetail {
        _ = await runtime.resolveStandingView(id: id, approved: approved)
        return await runtime.observatoryDetail()
    }

    /// Recheck the candidate at the mutation boundary and report a maintenance
    /// race or a second click explicitly.
    static func resolveWithOutcome(
        runtime: NativeCognitionRuntime = .shared,
        id: UUID,
        approved: Bool
    ) async -> ResolveOutcome {
        let before = await runtime.observatoryDetail()
        guard before.standingViews.first(where: { $0.id == id })?.status == .proposed else {
            return ResolveOutcome(
                status: .unavailable("That standing view is no longer awaiting review."),
                detail: before
            )
        }
        let resolved = await runtime.resolveStandingView(id: id, approved: approved)
        let detail = await runtime.observatoryDetail()
        let expected: CognitiveStandingView.Status = approved ? .active : .retired
        guard resolved?.status == expected,
              detail.standingViews.first(where: { $0.id == id })?.status == expected else {
            return ResolveOutcome(
                status: .unavailable("The standing view changed before the review could be saved."),
                detail: detail
            )
        }
        return ResolveOutcome(status: .applied(expected), detail: detail)
    }
}

/// The exact feedback renderer used by the Observatory controls. Keeping the
/// mapping beside the action outcomes prevents a later UI redraw from silently
/// turning a refused mutation into a success-shaped click.
@MainActor
enum CognitionObservatoryControlFeedback {
    static func publish(_ outcome: CognitiveBackgroundRunOutcome, to toasts: SystemToastCenter) {
        switch outcome {
        case .completed:
            toasts.push(success: "Reflection recorded.")
        case .skipped(let reason):
            toasts.push(info: "Reflection skipped: \(reason)")
        case .failed(let reason):
            toasts.push(error: "Reflection failed: \(reason)")
        }
    }

    static func publish(_ outcome: OrganismContinuityApplyOutcome, action: String, to toasts: SystemToastCenter) {
        switch outcome.status {
        case .applied:
            toasts.push(success: action == "reset" ? "Body state reset and saved." : "Body state settled and saved.")
        case .organismDisabled:
            toasts.push(info: outcome.error ?? "Body kernel is disabled.")
        case .persistenceFailed:
            toasts.push(error: outcome.error ?? "Body state was not saved.")
        }
    }
}

enum CognitionObservatoryPresentation {
    static func receiptEvidenceUnavailableText(_ reason: CognitiveReceiptReadUnavailability) -> String {
        switch reason {
        case .cognitionDisabled:
            return "Observatory receipt evidence is unavailable while cognition is off."
        case .persistenceDisabled:
            return "Observatory receipt evidence is unavailable because cognition persistence is off."
        case .storeUnavailable:
            return "Observatory receipt evidence is unavailable because its store cannot be opened."
        case .readFailed:
            return "Observatory receipt evidence could not be read."
        }
    }

    static func organismIsUnavailable(_ snapshot: OrganismSnapshot) -> Bool {
        !snapshot.enabled
    }

    static func thoughtSeedOverflowLabel(total: Int, visibleLimit: Int = 8) -> String? {
        guard total > visibleLimit else { return nil }
        return "Showing \(visibleLimit) of \(total) thought seeds."
    }

    static func standingViewStatus(_ view: CognitiveStandingView) -> String {
        if view.status == .active {
            return "active lens since \(view.updatedAt.formatted(date: .abbreviated, time: .omitted)) — \(view.evidenceNodeIds.count) felt moments"
        }
        return "proposed — waiting for your call"
    }

    static func timelineDateLabel(_ event: CognitiveDevelopmentalTimelineEvent) -> String {
        "recorded \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
