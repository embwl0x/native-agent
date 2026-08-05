import Foundation

// MARK: - Applying an observation verdict to the desk
//
// `DeskObservationEvaluator` decides; this applies. Split on purpose: the
// decision half is pure and exhaustively testable against a synthetic reality,
// and only this half touches the op-log.
//
// ORDERING, AND WHY IT IS NOT THE OBVIOUS ONE. The receipt note must land
// BEFORE the close, so evidence exists on the record even if the close is
// abandoned. But `appendNote` bumps the item's `updatedAt`, which is the very
// token the CAS close compares — writing the receipt first with the
// evaluation-time token would make every auto-resolve lose its own race and
// close nothing, forever. So the sequence is:
//
//   1. re-read under fresh state; bail unless the item is still live AND still
//      at the evaluation-time `updatedAt` (someone edited it => re-evaluate
//      next pass rather than act on a stale verdict),
//   2. append the receipt (dedup-guarded, so a retried pass does not stack
//      duplicate receipts),
//   3. re-read the item's NEW `updatedAt` and CAS-close against that.
//
// If step 3 loses, the receipt stays behind as an orphan — which is the right
// failure: a note saying "reality reports this merged" on a still-open item is
// informative, and the next pass closes it. The inverse failure (a close with
// no evidence) is the one that is not allowed to happen.
//
// Drift never mutates status. It appends one marker-prefixed note per distinct
// contradiction and then shuts up. Both stuck states are closed:
//   • stuck ON — a contradiction reality withdraws gets an explicit
//     `DeskDriftClear` note, because the surface reads the tail of the note
//     trail and a withdrawn contradiction produces silence, not a new flag;
//   • stuck OFF — dedupe is scoped to the TRAILING RUN of drift notes, so a
//     flag buried behind a later human note (and therefore invisible on the
//     surface) is re-raised rather than deduped into permanent silence.

/// What actually happened when a verdict met the live desk.
public struct DeskObservationOutcome: Sendable, Equatable {
    /// Items closed, with receipts attached.
    public var resolved: [String] = []
    /// Items whose close was abandoned because they moved mid-pass. Not an
    /// error — the next pass re-evaluates them against fresh state.
    public var skippedRaced: [String] = []
    /// Drift notes newly written this pass (handle + signature).
    public var flagged: [String] = []
    /// Drift already on the item; counted, not rewritten.
    public var flagsDeduped: Int = 0
    /// Drift flags WITHDRAWN this pass (handle + the signature withdrawn).
    public var cleared: [String] = []
    /// Deferred drifts NOT written because their premise did not survive the
    /// pass — the blocker they announce never actually closed. A distinct bucket
    /// from `skippedRaced`: nothing raced on THIS item, and folding the two
    /// together reported one blocker's lost race as two raced handles.
    public var premiseFailed: [String] = []
    /// Handles named by the verdict that no longer exist. Surfaced rather than
    /// swallowed — a verdict referencing a vanished item means the caller is
    /// working from a stale state read.
    public var missingHandles: [String] = []

    public init() {}

    public var isEmpty: Bool {
        resolved.isEmpty && skippedRaced.isEmpty && flagged.isEmpty
            && cleared.isEmpty && premiseFailed.isEmpty && missingHandles.isEmpty
    }

    /// One-line summary for the background loop's log.
    public var summary: String {
        "resolved=\(resolved.count) raced=\(skippedRaced.count) flagged=\(flagged.count) "
            + "cleared=\(cleared.count) deduped=\(flagsDeduped) "
            + "premise_failed=\(premiseFailed.count) missing=\(missingHandles.count)"
    }
}

public enum DeskObservationApplier {
    /// Apply a verdict. Every write goes through the store's own validated,
    /// locked op path — this function holds no lock of its own and therefore
    /// never widens the desk's critical section.
    @discardableResult
    public static func apply(
        _ verdict: DeskObservationVerdict,
        to store: SwiftNativeDeskStore
    ) async throws -> DeskObservationOutcome {
        var outcome = DeskObservationOutcome()
        guard !verdict.isEmpty else { return outcome }

        // Drift first: a flag on an item that is about to auto-resolve should
        // be part of that item's record, not appended after it went terminal
        // (notes on terminal items are legal but read as afterthoughts).
        //
        // Except for the drifts whose premise is about OTHER items this pass is
        // still changing — those wait for `applyDeferredDrifts` below, after the
        // resolves have actually happened or actually failed.
        var deferred: [DeskDrift] = []
        for drift in verdict.drifts {
            if case .afterResolves = drift.timing {
                deferred.append(drift)
                continue
            }
            let state = try await store.liveState()
            guard let item = state.items.first(where: { $0.handle == drift.handle }) else {
                outcome.missingHandles.append(drift.handle)
                continue
            }
            // Same CAS discipline as the close, for the same reason: a card whose
            // GitHub ref was just removed, or that just had `github` added to its
            // refresh sources, is no longer the card this verdict judged, and
            // flagging it would announce a contradiction that no longer exists.
            // The fingerprint excludes notes, so the applier's OWN earlier
            // appends in this same pass stay transparent.
            if let expected = drift.materialFingerprint,
               DeskObservationEvaluator.verdictFingerprint(item, in: state) != expected {
                outcome.skippedRaced.append(drift.handle)
                continue
            }
            let marker = "\(DeskObservationEvaluator.driftMarker)[\(drift.signature)]"
            // Dedupe against the TRAILING RUN of drift notes, not the whole
            // history. The surface derives its flag from the tail, so a drift
            // buried behind a later human note is invisible — and a
            // whole-history dedupe would then refuse to re-raise it, leaving a
            // contradiction that is still true and permanently unsayable. The
            // run, rather than just `notes.last`, is what keeps two drifts on
            // one item from re-appending each other every single poll.
            //
            // `hasPrefix`, not `contains`: a note that merely QUOTES a drift
            // marker (a paste of a previous digest, Agent summarizing the board
            // back to User) must not suppress a real flag. Only a note the
            // applier itself authored starts with the marker.
            let trailingDrifts = item.notes
                .reversed()
                .prefix { DeskObservationEvaluator.driftKind(inNote: $0.text) != nil }
            if trailingDrifts.contains(where: { $0.text.hasPrefix(marker) }) {
                outcome.flagsDeduped += 1
                continue
            }
            _ = try await store.appendNote(drift.handle, text: drift.noteText)
            outcome.flagged.append("\(drift.handle):\(drift.signature)")
        }

        // Withdrawals. Re-checked against LIVE state rather than trusted from the
        // verdict: the tail must still be the drift note we are withdrawing, or
        // something already moved it and there is nothing to clear.
        for clear in verdict.driftClears {
            let state = try await store.liveState()
            guard let item = state.items.first(where: { $0.handle == clear.handle }) else {
                outcome.missingHandles.append(clear.handle)
                continue
            }
            if let expected = clear.materialFingerprint,
               DeskObservationEvaluator.verdictFingerprint(item, in: state) != expected {
                outcome.skippedRaced.append(clear.handle)
                continue
            }
            guard let last = item.notes.last,
                  DeskObservationEvaluator.signature(inNote: last.text) == clear.clearedSignature else {
                continue
            }
            _ = try await store.appendNote(clear.handle, text: clear.noteText)
            outcome.cleared.append("\(clear.handle):\(clear.clearedSignature)")
        }

        for resolve in verdict.autoResolves {
            let state = try await store.liveState()
            guard let item = state.items.first(where: { $0.handle == resolve.handle }) else {
                outcome.missingHandles.append(resolve.handle)
                continue
            }
            // Still live, and still the item we judged? Compare SUBSTANCE, not
            // the timestamp: our own drift note (and, below, our own receipt)
            // bumps `updatedAt` without changing anything the verdict rests on,
            // while any real edit — a retitle, a status change, User re-parking
            // it — changes the fingerprint and aborts the close. An earlier cut
            // waived the timestamp check whenever this pass had flagged the
            // item, which also waived it for a concurrent human edit that
            // happened to land in the same window.
            guard !item.status.isTerminal else { continue }
            guard DeskObservationEvaluator.verdictFingerprint(item, in: state) == resolve.materialFingerprint else {
                outcome.skippedRaced.append(resolve.handle)
                continue
            }

            let receiptMarker = "\(DeskObservationEvaluator.receiptMarker) auto-resolved"
            let alreadyReceipted = item.notes.contains {
                $0.text.hasPrefix(receiptMarker) && resolve.refKeys.allSatisfy($0.text.contains)
            }
            if !alreadyReceipted {
                _ = try await store.appendNote(resolve.handle, text: resolve.receiptNote)
            }

            // Re-read for the post-receipt token; the note we just wrote moved it.
            let afterReceipt = try await store.liveState()
            guard let fresh = afterReceipt.items.first(where: { $0.handle == resolve.handle }),
                  !fresh.status.isTerminal else { continue }
            // The receipt append must not have raced with a real edit either.
            guard DeskObservationEvaluator.verdictFingerprint(fresh, in: afterReceipt) == resolve.materialFingerprint else {
                outcome.skippedRaced.append(resolve.handle)
                continue
            }

            let closed = try await store.closeItemIfUnchanged(
                resolve.handle,
                expectedUpdatedAt: fresh.updatedAt,
                outcomeSummary: resolve.outcomeSummary
            )
            if closed {
                outcome.resolved.append(resolve.handle)
            } else {
                // Receipt is on the record; the close lost the race. Next pass.
                outcome.skippedRaced.append(resolve.handle)
            }
        }

        try await applyDeferredDrifts(deferred, to: store, outcome: &outcome)
        return outcome
    }

    /// The second drift phase. Runs AFTER the auto-resolves, so a flag whose
    /// premise is about another item ("your blocker resolved", "your sub-items
    /// are still open") is written only if that premise survived the pass.
    ///
    /// Two guards, not one. `requiring` is the positive form: the note ASSERTS
    /// those blockers closed, so it may only be written once they actually have —
    /// a resolve that lost its CAS race must not leave behind a note claiming it
    /// won. The fingerprint re-check is the negative form: it folds in the
    /// open-child count, so a parent whose last open child just closed fails the
    /// check and its "sub-items are still open" flag is refused.
    private static func applyDeferredDrifts(
        _ drifts: [DeskDrift],
        to store: SwiftNativeDeskStore,
        outcome: inout DeskObservationOutcome
    ) async throws {
        guard !drifts.isEmpty else { return }
        let resolved = Set(outcome.resolved)
        for drift in drifts {
            guard case let .afterResolves(requiring) = drift.timing else { continue }
            guard requiring.allSatisfy(resolved.contains) else {
                outcome.premiseFailed.append(drift.handle)
                continue
            }
            let state = try await store.liveState()
            guard let item = state.items.first(where: { $0.handle == drift.handle }) else {
                outcome.missingHandles.append(drift.handle)
                continue
            }
            if let expected = drift.materialFingerprint,
               DeskObservationEvaluator.verdictFingerprint(item, in: state) != expected {
                outcome.skippedRaced.append(drift.handle)
                continue
            }
            let marker = "\(DeskObservationEvaluator.driftMarker)[\(drift.signature)]"
            let trailingDrifts = item.notes
                .reversed()
                .prefix { DeskObservationEvaluator.driftKind(inNote: $0.text) != nil }
            if trailingDrifts.contains(where: { $0.text.hasPrefix(marker) }) {
                outcome.flagsDeduped += 1
                continue
            }
            _ = try await store.appendNote(drift.handle, text: drift.noteText)
            outcome.flagged.append("\(drift.handle):\(drift.signature)")
        }
    }
}
