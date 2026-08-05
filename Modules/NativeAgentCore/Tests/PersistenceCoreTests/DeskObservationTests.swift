import Testing
import Foundation
@testable import PersistenceCore

// MARK: - Desk Wave 5 — reconciling the board against observed reality
//
// The invariants these tests exist to protect:
//   1. NO RECEIPT, NO CLOSE. An observation with empty evidence can never
//      mutate an item; it degrades to a loud drift flag.
//   2. NO UNINVITED CLOSES. Only items declared to follow an external source
//      auto-resolve. A hand-written card that merely links a PR gets flagged,
//      never closed.
//   3. PARTIAL KNOWLEDGE CLOSES NOTHING. Every tracked ref must be observed
//      terminal in the same pass.
//   4. CAS. An item edited mid-pass is skipped, not stomped — and the receipt
//      lands before the close without invalidating its own token.

@Suite("DeskObservation")
struct DeskObservationTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskObs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func iso(_ offsetSeconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: 1_770_000_000 + offsetSeconds))
    }

    private func prRef(_ repo: String = "user/nativeagent", _ number: Int = 41) -> DeskRef {
        DeskRef(kind: .ghPr(repo: repo, number: number, title: "wire it", status: "open", checks: nil))
    }

    private func observed(
        _ key: String = "user/nativeagent#pr#41",
        terminal: Bool = true,
        evidence: String = "merged into main by user",
        status: String = "merged",
        source: String = "github",
        at: TimeInterval = 100
    ) -> DeskObservedRef {
        DeskObservedRef(
            refKey: key, status: status, terminal: terminal, evidence: evidence,
            source: source, observedAt: iso(at), fingerprint: "\(status)-\(at)"
        )
    }

    private func item(
        handle: String = "h1",
        alias: String = "1",
        parent: String? = nil,
        kind: DeskKind = .gh,
        status: DeskStatus = .now,
        refs: [DeskRef] = [],
        cadence: Cadence = Cadence(refreshSources: ["github"]),
        notes: [DeskNote] = [],
        closedAt: String? = nil,
        blockedReason: String? = nil,
        waitingOn: String? = nil,
        blockedOn: [String] = [],
        deferUntil: String? = nil
    ) -> DeskItem {
        DeskItem(
            handle: handle, alias: alias, parent: parent, kind: kind, status: status,
            project: "NativeAgent", title: "ship the thing", refs: refs, cadence: cadence,
            notes: notes, openedAt: iso(0), updatedAt: iso(10), closedAt: closedAt,
            blockedReason: blockedReason, waitingOn: waitingOn,
            blockedOn: blockedOn, deferUntil: deferUntil
        )
    }

    private func state(_ items: [DeskItem]) -> DeskState {
        DeskState(items: items, generatedTs: iso(50))
    }

    private var now: Date { Date(timeIntervalSince1970: 1_770_000_000 + 200) }

    // MARK: - Auto-resolution

    @Test("a tracked item whose PR merged auto-resolves with the receipt attached")
    func resolvesOnTerminalRef() {
        let verdict = DeskObservationEvaluator.evaluate(
            state([item(refs: [prRef()])]), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.count == 1)
        let resolve = try! #require(verdict.autoResolves.first)
        #expect(resolve.handle == "h1")
        #expect(resolve.expectedUpdatedAt == iso(10))
        #expect(resolve.refKeys == ["user/nativeagent#pr#41"])
        #expect(resolve.receiptNote.contains("merged into main by user"))
        #expect(resolve.outcomeSummary.contains("user/nativeagent#pr#41"))
    }

    @Test("an open PR produces no decision at all — board and reality agree")
    func silentWhenAgreeing() {
        let verdict = DeskObservationEvaluator.evaluate(
            state([item(refs: [prRef()])]),
            observations: [observed(terminal: false, evidence: "still open", status: "open")],
            now: now
        )
        #expect(verdict.isEmpty)
    }

    @Test("NO RECEIPT, NO CLOSE: empty evidence flags drift instead of mutating")
    func receiptlessNeverMutates() {
        let verdict = DeskObservationEvaluator.evaluate(
            state([item(refs: [prRef()])]),
            observations: [observed(evidence: "   ")],
            now: now
        )
        #expect(verdict.autoResolves.isEmpty)
        #expect(verdict.drifts.map(\.kind) == [.shippedWithoutReceipt])
    }

    @Test("an item not declared externally tracked is flagged, never closed")
    func untrackedItemIsFlaggedNotClosed() {
        let handWritten = item(kind: .plan, refs: [prRef()], cadence: Cadence())
        let verdict = DeskObservationEvaluator.evaluate(
            state([handWritten]), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.isEmpty)
        #expect(verdict.drifts.map(\.kind) == [.untrackedButShipped])
    }

    @Test("PARTIAL KNOWLEDGE CLOSES NOTHING: one of two refs observed resolves nothing")
    func partialObservationClosesNothing() {
        let two = item(refs: [prRef(), prRef("user/nativeagent", 42)])
        let verdict = DeskObservationEvaluator.evaluate(
            state([two]), observations: [observed()], now: now
        )
        #expect(verdict.isEmpty)
    }

    @Test("both refs terminal resolves; one still open resolves nothing")
    func allRefsMustBeTerminal() {
        let two = item(refs: [prRef(), prRef("user/nativeagent", 42)])
        let stillOpen = DeskObservationEvaluator.evaluate(
            state([two]),
            observations: [observed(), observed("user/nativeagent#pr#42", terminal: false, status: "open")],
            now: now
        )
        #expect(stillOpen.autoResolves.isEmpty)

        let bothDone = DeskObservationEvaluator.evaluate(
            state([two]),
            observations: [observed(), observed("user/nativeagent#pr#42", status: "closed")],
            now: now
        )
        #expect(bothDone.autoResolves.count == 1)
        #expect(bothDone.autoResolves[0].evidence.count == 2)
    }

    @Test("a parent with open children is flagged, not closed")
    func parentWithOpenChildrenIsNotClosed() {
        let parent = item(handle: "p", alias: "1", refs: [prRef()])
        let child = item(handle: "c", alias: "1.1", parent: "p", status: .todo)
        let verdict = DeskObservationEvaluator.evaluate(
            state([parent, child]), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.isEmpty)
        #expect(verdict.drifts.contains { $0.handle == "p" && $0.kind == .blockedButShipped })
    }

    @Test("an item with no external refs is never touched")
    func noRefsNoDecisions() {
        let verdict = DeskObservationEvaluator.evaluate(
            state([item(refs: [DeskRef(kind: .url(url: "https://x", title: nil))])]),
            observations: [observed()], now: now
        )
        #expect(verdict.isEmpty)
    }

    // MARK: - Drift

    @Test("blocked on the desk while reality shipped is flagged alongside the resolve")
    func blockedButShipped() {
        let blocked = item(status: .blocked, refs: [prRef()], blockedReason: "waiting on review")
        let verdict = DeskObservationEvaluator.evaluate(
            state([blocked]), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.count == 1)
        let drift = try! #require(verdict.drifts.first { $0.kind == .blockedButShipped })
        #expect(drift.detail.contains("waiting on review"))
    }

    @Test("parked-until-later work that already landed is flagged and resolved")
    func parkedButShipped() {
        let parked = item(refs: [prRef()], deferUntil: "2099-01-01")
        let verdict = DeskObservationEvaluator.evaluate(
            state([parked]), observations: [observed()], now: now
        )
        #expect(verdict.drifts.contains { $0.kind == .parkedButShipped })
        #expect(verdict.autoResolves.count == 1)
    }

    @Test("a closed item whose PR reopened AFTER the close is flagged")
    func reopenedAfterClose() {
        let closed = item(status: .done, refs: [prRef()], closedAt: iso(50))
        let verdict = DeskObservationEvaluator.evaluate(
            state([closed]),
            observations: [observed(terminal: false, status: "open", at: 100)],
            now: now
        )
        #expect(verdict.drifts.map(\.kind) == [.reopenedAfterClose])
        #expect(verdict.autoResolves.isEmpty)
    }

    @Test("a stale snapshot from BEFORE the close never reopens anything")
    func staleObservationDoesNotReopen() {
        let closed = item(status: .done, refs: [prRef()], closedAt: iso(150))
        let verdict = DeskObservationEvaluator.evaluate(
            state([closed]),
            observations: [observed(terminal: false, status: "open", at: 100)],
            now: now
        )
        #expect(verdict.isEmpty)
    }

    @Test("dependents of an auto-resolved blocker are flagged as no longer blocked")
    func dependentsOfResolvedBlockerFlagged() {
        let blocker = item(handle: "h1", alias: "1", refs: [prRef()])
        let dependent = item(handle: "h2", alias: "2", status: .blocked, blockedOn: ["h1"])
        let verdict = DeskObservationEvaluator.evaluate(
            state([blocker, dependent]), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.map(\.handle) == ["h1"])
        #expect(verdict.drifts.contains { $0.handle == "h2" && $0.refKeys == ["h1"] })
    }

    @Test("drift signature ignores time and detail so a standing contradiction dedupes")
    func driftSignatureIsStable() {
        let a = DeskDrift(handle: "h", kind: .blockedButShipped, refKeys: ["b", "a"], detail: "one", observedAt: iso(1))
        let b = DeskDrift(handle: "h", kind: .blockedButShipped, refKeys: ["a", "b"], detail: "two", observedAt: iso(9))
        #expect(a.signature == b.signature)
        #expect(a.noteText.hasPrefix(DeskObservationEvaluator.driftMarker))
    }

    @Test("evaluation is deterministic and empty observations decide nothing")
    func deterministicAndInert() {
        let items = (1...6).map { item(handle: "h\($0)", alias: "\($0)", refs: [prRef("user/nativeagent", $0)]) }
        let obs = (1...6).map { observed("user/nativeagent#pr#\($0)") }
        let first = DeskObservationEvaluator.evaluate(state(items), observations: obs, now: now)
        let second = DeskObservationEvaluator.evaluate(state(items.reversed()), observations: obs.reversed(), now: now)
        #expect(first == second)
        #expect(first.autoResolves.map(\.handle) == ["h1", "h2", "h3", "h4", "h5", "h6"])
        #expect(DeskObservationEvaluator.evaluate(state(items), observations: [], now: now).isEmpty)
    }

    @Test("ref key canonicalization is case-insensitive on the repo and ignores non-external refs")
    func refKeyCanonicalization() {
        #expect(DeskObservedRef.key(for: DeskRef(kind: .ghPr(repo: "User/NativeAgent", number: 7, title: nil, status: nil, checks: nil))) == "user/nativeagent#pr#7")
        #expect(DeskObservedRef.key(for: DeskRef(kind: .ghIssue(repo: "User/Repo", number: 3, title: nil, status: nil))) == "user/repo#issue#3")
        #expect(DeskObservedRef.key(for: DeskRef(kind: .url(url: "https://x", title: nil))) == nil)
    }

    // MARK: - Applying against a live store

    @Test("apply closes the item, lands the receipt BEFORE the close, and is idempotent")
    func applyClosesWithReceipt() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .gh, project: "NativeAgent", title: "ship it")
        _ = try await store.addRef(created.handle, ref: prRef())
        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: ["github"]))

        let live = try await store.liveState()
        let verdict = DeskObservationEvaluator.evaluate(live, observations: [observed()], now: now)
        #expect(verdict.autoResolves.count == 1)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved == [created.handle])

        let after = try await store.liveState()
        let item = try #require(after.items.first { $0.handle == created.handle })
        #expect(item.status == .done)
        #expect(item.notes.contains { $0.text.hasPrefix(DeskObservationEvaluator.receiptMarker) })
        #expect(item.notes.contains { $0.text.contains("merged into main by user") })

        // Re-applying the same verdict must not re-close or re-receipt.
        let repeated = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(repeated.resolved.isEmpty)
        let final = try await store.liveState()
        let finalItem = try #require(final.items.first { $0.handle == created.handle })
        #expect(finalItem.notes.filter { $0.text.hasPrefix(DeskObservationEvaluator.receiptMarker) }.count == 1)
    }

    @Test("an item edited between evaluation and apply is skipped, not stomped")
    func racedItemIsSkipped() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .gh, project: "NativeAgent", title: "ship it")
        _ = try await store.addRef(created.handle, ref: prRef())
        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: ["github"]))

        let live = try await store.liveState()
        let verdict = DeskObservationEvaluator.evaluate(live, observations: [observed()], now: now)

        // User edits the card after the verdict was computed.
        _ = try await store.updateTitle(created.handle, title: "actually, hold this", summary: nil)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved.isEmpty)
        #expect(outcome.skippedRaced == [created.handle])
        let after = try await store.liveState()
        #expect(after.items.first { $0.handle == created.handle }?.status.isTerminal == false)
    }

    @Test("drift notes are written once and deduped on every later pass")
    func driftNoteDedupes() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        let live = try await store.liveState()
        let verdict = DeskObservationEvaluator.evaluate(live, observations: [observed()], now: now)
        #expect(verdict.drifts.map(\.kind) == [.untrackedButShipped])

        let first = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(first.flagged.count == 1)
        #expect(first.flagsDeduped == 0)

        let second = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(second.flagged.isEmpty)
        #expect(second.flagsDeduped == 1)

        let after = try await store.liveState()
        let item = try #require(after.items.first { $0.handle == created.handle })
        #expect(item.notes.filter { $0.text.hasPrefix(DeskObservationEvaluator.driftMarker) }.count == 1)
        #expect(item.status.isTerminal == false)   // drift NEVER mutates status
    }

    // MARK: - Regressions from the gpt-5.5 adversarial review (2026-08-04)

    @Test("duplicate observations of one ref resolve by RECENCY, not array order")
    func duplicateObservationsAreOrderIndependent() {
        let one = observed(terminal: false, status: "open", at: 300)
        let two = observed(terminal: true, status: "merged", at: 100)
        let forward = DeskObservationEvaluator.evaluate(
            state([item(refs: [prRef()])]), observations: [two, one], now: now
        )
        let backward = DeskObservationEvaluator.evaluate(
            state([item(refs: [prRef()])]), observations: [one, two], now: now
        )
        #expect(forward == backward)
        // The newest observation says it is still open, so nothing resolves.
        #expect(forward.autoResolves.isEmpty)
    }

    @Test("opt-in is per item: another item's source never authorizes this one")
    func sourceMatchingIsPerItem() {
        // This item follows "github" only; ITS ref was observed by "web".
        let followsGitHub = item(handle: "h1", alias: "1", kind: .plan, refs: [prRef()], cadence: Cadence(refreshSources: ["github"]))
        // An unrelated item observed by "github" in the same pass.
        let other = item(handle: "h2", alias: "2", kind: .plan, refs: [prRef("user/other", 9)], cadence: Cadence())
        let verdict = DeskObservationEvaluator.evaluate(
            state([followsGitHub, other]),
            observations: [
                observed(source: "web"),
                observed("user/other#issue#9", source: "github"),
            ],
            now: now
        )
        // h1 must NOT be closed by a lane it did not opt into.
        #expect(verdict.autoResolves.isEmpty)
        #expect(verdict.drifts.contains { $0.handle == "h1" && $0.kind == .untrackedButShipped })
    }

    @Test("dependent-blocker drift carries a deterministic stamp, not a wall-clock read")
    func dependentDriftIsDeterministic() {
        let blocker = item(handle: "h1", alias: "1", refs: [prRef()])
        let dependent = item(handle: "h2", alias: "2", status: .blocked, blockedOn: ["h1"])
        let first = DeskObservationEvaluator.evaluate(state([blocker, dependent]), observations: [observed()], now: now)
        let second = DeskObservationEvaluator.evaluate(state([blocker, dependent]), observations: [observed()], now: now)
        #expect(first == second)
        let drift = try! #require(first.drifts.first { $0.handle == "h2" })
        #expect(drift.observedAt == iso(100))   // the blocker's observation, not "now"
    }

    @Test("chronological max beats lexicographic max across mixed ISO forms")
    func latestStampIsChronological() {
        // Fractional seconds sort AFTER the plain form lexicographically even
        // when they name an EARLIER instant.
        let earlierButLexicallyLarger = "2026-08-04T10:00:00.500Z"
        let later = "2026-08-04T11:00:00Z"
        #expect(DeskObservationEvaluator.latestStamp([earlierButLexicallyLarger, later]) == later)
        #expect(DeskObservationEvaluator.latestStamp(["garbage"]) == nil)
    }

    @Test("a quoted drift marker in a human note does NOT suppress a real flag")
    func quotedMarkerDoesNotSpoofDedupe() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())
        // Agent quotes a previous digest back onto the card.
        _ = try await store.appendNote(
            created.handle,
            text: "digest recap: saw \(DeskObservationEvaluator.driftMarker)[untracked_but_shipped:user/nativeagent#pr#41] earlier"
        )

        let live = try await store.liveState()
        let verdict = DeskObservationEvaluator.evaluate(live, observations: [observed()], now: now)
        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.flagged.count == 1)     // the real flag still lands
        #expect(outcome.flagsDeduped == 0)
    }

    @Test("a real edit landing after this pass's own drift note aborts the close")
    func realEditAfterDriftNoteStillAbortsClose() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .gh, project: "NativeAgent", title: "ship it")
        _ = try await store.addRef(created.handle, ref: prRef())
        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: ["github"]))
        _ = try await store.setStatus(created.handle, status: .blocked, blockedReason: "waiting on review")

        let live = try await store.liveState()
        let verdict = DeskObservationEvaluator.evaluate(live, observations: [observed()], now: now)
        #expect(verdict.autoResolves.count == 1)
        #expect(verdict.drifts.contains { $0.kind == .blockedButShipped })

        // User retitles the card between the verdict and the apply. Both halves of
        // the verdict are now stale: the flag must not be used as a license to
        // close over his edit, AND (review round 2) the flag itself must not be
        // written onto a card that is no longer the one that was judged.
        _ = try await store.updateTitle(created.handle, title: "actually a different thing", summary: nil)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved.isEmpty)
        #expect(outcome.flagged.isEmpty)
        // Once for the refused drift, once for the refused close.
        #expect(outcome.skippedRaced == [created.handle, created.handle])
        let after = try await store.liveState()
        let item = try #require(after.items.first { $0.handle == created.handle })
        #expect(item.status.isTerminal == false)
        #expect(item.notes.isEmpty)
    }

    @Test("a verdict naming a vanished handle is surfaced, not swallowed")
    func missingHandleSurfaces() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let verdict = DeskObservationVerdict(
            autoResolves: [DeskAutoResolve(handle: "ghost", expectedUpdatedAt: iso(10), refKeys: ["k"], evidence: ["e"], observedAt: iso(100), materialFingerprint: "fp")],
            drifts: [DeskDrift(handle: "ghost", kind: .blockedButShipped, refKeys: ["k"], detail: "d", observedAt: iso(100))]
        )
        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.missingHandles == ["ghost", "ghost"])
        #expect(outcome.resolved.isEmpty)
    }

    // MARK: - Wave 5 review round 2 (gpt-5.5 run 8f41ee10468a)

    /// BLOCKING, from review: a drift flag could get stuck ON forever.
    ///
    /// A hand-written card links a PR; the PR merges; the card is flagged
    /// `untracked_but_shipped`. Then the PR REOPENS. No drift kind applies to a
    /// live card pointing at live work, so the pass goes silent — and silence
    /// used to leave the drift note sitting at the tail of the trail, which is
    /// exactly what the projection derives its flag from. The withdrawal note is
    /// what moves the tail.
    @Test("a contradiction reality withdraws is cleared, not left flagged forever")
    func withdrawnDriftIsCleared() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        // .plan + no refreshSources => never auto-closes, only ever flagged.
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        // Pass 1: the PR is merged. Flag raised.
        let flagged = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(flagged.drifts.map(\.kind) == [.untrackedButShipped])
        #expect(flagged.driftClears.isEmpty)
        _ = try await DeskObservationApplier.apply(flagged, to: store)
        let midItem = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(DeskProjection.driftSegment(midItem) != nil, "precondition: the flag renders")

        // Pass 2: the PR is REOPENED. No drift kind fits; the flag must withdraw.
        let reopenedObs = observed(terminal: false, status: "open", at: 300)
        let withdrawn = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [reopenedObs], now: now
        )
        #expect(withdrawn.drifts.isEmpty)
        #expect(withdrawn.driftClears.map(\.handle) == [created.handle])
        let outcome = try await DeskObservationApplier.apply(withdrawn, to: store)
        #expect(outcome.cleared.count == 1)

        let after = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(DeskProjection.driftSegment(after) == nil, "the flag must be gone from the surface")
        #expect(after.notes.last?.text.hasPrefix(DeskObservationEvaluator.clearMarker) == true)

        // Pass 3 on the same reality writes nothing new — the clear self-dedupes.
        let again = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [reopenedObs], now: now
        )
        let repeated = try await DeskObservationApplier.apply(again, to: store)
        #expect(repeated.cleared.isEmpty)
        let finalItem = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(finalItem.notes.filter { $0.text.hasPrefix(DeskObservationEvaluator.clearMarker) }.count == 1)
    }

    /// A STANDING contradiction is re-raised every pass and must never be
    /// cleared by its own dedupe — otherwise the board would flap flag/clear
    /// forever, one note per poll.
    @Test("a standing contradiction is re-raised, never cleared")
    func standingContradictionDoesNotFlap() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        for pass in 0..<3 {
            let verdict = DeskObservationEvaluator.evaluate(
                try await store.liveState(), observations: [observed()], now: now
            )
            #expect(verdict.driftClears.isEmpty, "pass \(pass) must not withdraw a standing flag")
            _ = try await DeskObservationApplier.apply(verdict, to: store)
        }
        let item = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(item.notes.filter { DeskObservationEvaluator.driftKind(inNote: $0.text) != nil }.count == 1)
        #expect(item.notes.filter { $0.text.hasPrefix(DeskObservationEvaluator.clearMarker) }.isEmpty)
    }

    /// Partial knowledge withdraws nothing: a pass that did not observe every one
    /// of an item's refs has no standing to say the contradiction is over.
    @Test("partial observation cannot withdraw a flag")
    func partialObservationDoesNotClear() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "two refs")
        _ = try await store.addRef(created.handle, ref: prRef())
        _ = try await store.addRef(created.handle, ref: prRef("user/nativeagent", 42))
        _ = try await store.appendNote(created.handle, text: DeskDrift(
            handle: created.handle, kind: .untrackedButShipped, refKeys: ["user/nativeagent#pr#41"],
            detail: "d", observedAt: iso(100)
        ).noteText)

        // Only ONE of the two refs is observed this pass.
        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(),
            observations: [observed(terminal: false, status: "open", at: 300)],
            now: now
        )
        #expect(verdict.driftClears.isEmpty)
    }

    /// NEEDS_FIX, from review: the drift append had no CAS. A card whose refs
    /// change between decision and write is no longer the card that was judged.
    @Test("a card edited between evaluation and the drift write is skipped, not annotated")
    func racedDriftIsSkipped() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(verdict.drifts.count == 1)
        #expect(verdict.drifts[0].materialFingerprint != nil, "the evaluator must stamp the guard")

        // User retitles the card before the verdict is applied.
        _ = try await store.updateTitle(created.handle, title: "actually something else", summary: nil)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.flagged.isEmpty)
        #expect(outcome.skippedRaced == [created.handle])
        let item = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(item.notes.isEmpty, "a stale verdict must not annotate a moved card")
    }

    /// NEEDS_FIX, from review: marker parsing accepted any note OPENING with the
    /// marker, so prose like `⚑ drift: discussing [foo:bar]` rendered a drift of
    /// kind `foo`. Only the exact shape the applier writes counts.
    @Test("only a well-formed drift note with a real kind parses as drift")
    func driftMarkerParsingIsStrict() {
        let real = DeskDrift(handle: "h", kind: .parkedButShipped, refKeys: ["k"], detail: "d", observedAt: iso(1))
        #expect(DeskObservationEvaluator.driftKind(inNote: real.noteText) == .parkedButShipped)
        #expect(DeskObservationEvaluator.signature(inNote: real.noteText) == "parked_but_shipped:k")

        for bogus in [
            "⚑ drift: discussing [foo:bar] with User",     // prose, invented kind
            "⚑ drift[not_a_real_kind:k] made up",          // well-shaped, unknown kind
            "⚑ drift[missing_close:k made up",             // no closing bracket
            "⚑ drift[nocolon] made up",                    // no colon
            "⚑ drift[:k] empty kind",                      // empty kind
            "quoting a ⚑ drift[parked_but_shipped:k] note", // marker not at the front
            "✅ drift cleared[parked_but_shipped:k] withdrawn",
        ] {
            #expect(DeskObservationEvaluator.driftKind(inNote: bogus) == nil, "must not parse: \(bogus)")
        }
    }

    // MARK: - Wave 5 review round 3 (gpt-5.5 run b6220d450684)

    /// BLOCKING, from review: the guard did not cover every field a verdict
    /// READS. `untracked_but_shipped` is decided by `isExternallyTracked`, which
    /// reads `kind` and `cadence.refreshSources` — neither of which was in the
    /// fingerprint. A card that opted IN between decision and write would still
    /// be flagged as un-tracked.
    @Test("opting a card into a refresh source mid-pass invalidates the drift verdict")
    func refreshSourceChangeInvalidatesVerdict() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(verdict.drifts.map(\.kind) == [.untrackedButShipped])

        // The card opts in before the verdict lands.
        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: ["github"]))

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.flagged.isEmpty)
        #expect(outcome.skippedRaced == [created.handle])
        let item = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(item.notes.isEmpty, "a card that just opted in must not be told it is un-tracked")

        // Re-evaluated against fresh state it now auto-resolves, receipt and all.
        let redone = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(redone.autoResolves.map(\.handle) == [created.handle])
    }

    /// The mirror: a card that opts OUT mid-pass must not be closed by a verdict
    /// that was decided while it was still opted in.
    @Test("opting a card OUT mid-pass aborts its auto-close")
    func refreshSourceRemovalAbortsClose() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "opted in")
        _ = try await store.addRef(created.handle, ref: prRef())
        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: ["github"]))

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.count == 1)

        _ = try await store.setCadence(created.handle, cadence: Cadence(refreshSources: []))

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved.isEmpty)
        #expect(outcome.skippedRaced == [created.handle])
        let item = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(item.status.isTerminal == false)
    }

    /// NEEDS_FIX, from review: the parent's "sub-items are still open" drift is
    /// decided from CHILD state, which no item-local fingerprint can see. The
    /// guard now folds in the open-child count.
    @Test("a child closing mid-pass invalidates the parent's open-children drift")
    func childClosingInvalidatesParentDrift() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let parent = try await store.createItem(kind: .gh, project: "NativeAgent", title: "campaign")
        _ = try await store.addRef(parent.handle, ref: prRef())
        _ = try await store.setCadence(parent.handle, cadence: Cadence(refreshSources: ["github"]))
        let child = try await store.createItem(kind: .plan, project: "NativeAgent", title: "sub-item", parent: parent.handle)

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(verdict.drifts.map(\.kind) == [.blockedButShipped])
        #expect(verdict.autoResolves.isEmpty, "a parent with an open child is flagged, never closed")

        // The child closes before the verdict lands: the parent no longer has
        // open sub-items, so the flag's premise is gone.
        _ = try await store.setStatus(child.handle, status: .done)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.flagged.isEmpty)
        #expect(outcome.skippedRaced == [parent.handle])
        let item = try #require(try await store.liveState().items.first { $0.handle == parent.handle })
        #expect(item.notes.isEmpty)
    }

    /// NEEDS_FIX, from review: dedupe scanned ALL history while the surface reads
    /// only the tail, so a drift buried behind a later note was both invisible
    /// AND un-re-raisable — permanently unsayable. Dedupe is now scoped to the
    /// trailing run of drift notes.
    @Test("a drift buried behind a later note is re-raised, not deduped into silence")
    func buriedDriftIsReRaised() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let created = try await store.createItem(kind: .plan, project: "NativeAgent", title: "hand-written card")
        _ = try await store.addRef(created.handle, ref: prRef())

        func pass() async throws -> DeskObservationOutcome {
            let verdict = DeskObservationEvaluator.evaluate(
                try await store.liveState(), observations: [observed()], now: now
            )
            return try await DeskObservationApplier.apply(verdict, to: store)
        }

        #expect(try await pass().flagged.count == 1)
        // Standing contradiction, unchanged reality: deduped, no churn.
        #expect(try await pass().flagsDeduped == 1)

        // A human note lands. The flag is now off the tail, so it is off the
        // surface too — and the contradiction is still true.
        _ = try await store.appendNote(created.handle, text: "User: looking at this tomorrow")
        let buried = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(DeskProjection.driftSegment(buried) == nil)

        // Next pass must say it again rather than dedupe against history.
        #expect(try await pass().flagged.count == 1)
        let after = try #require(try await store.liveState().items.first { $0.handle == created.handle })
        #expect(DeskProjection.driftSegment(after) != nil, "a true contradiction must stay sayable")
        // And it settles again immediately — no flag/note flapping per poll.
        #expect(try await pass().flagsDeduped == 1)
    }

    /// Two contradictions on one item must not re-append each other every poll:
    /// the trailing RUN, not just `notes.last`, is what makes the dedupe stable.
    /// Driven through the applier with a two-drift verdict, because the
    /// evaluator's only natural two-drift item (parked AND prose-blocked) also
    /// auto-resolves in the same pass and so never sees a second poll.
    @Test("two drifts on one item settle instead of flapping")
    func twoDriftsOnOneItemSettle() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        // A parent with an open child: flagged, never closed, so it survives to
        // be polled again.
        let parent = try await store.createItem(kind: .gh, project: "NativeAgent", title: "campaign")
        _ = try await store.addRef(parent.handle, ref: prRef())
        _ = try await store.setCadence(parent.handle, cadence: Cadence(refreshSources: ["github"]))
        _ = try await store.createItem(kind: .plan, project: "NativeAgent", title: "sub-item", parent: parent.handle)

        let live = try await store.liveState()
        let item = try #require(live.items.first { $0.handle == parent.handle })
        let stamp = DeskObservationEvaluator.verdictFingerprint(item, in: live)
        func drift(_ kind: DeskDriftKind) -> DeskDrift {
            var d = DeskDrift(handle: parent.handle, kind: kind, refKeys: ["user/nativeagent#pr#41"],
                              detail: "d", observedAt: iso(100))
            d.materialFingerprint = stamp
            return d
        }
        let verdict = DeskObservationVerdict(drifts: [drift(.blockedButShipped), drift(.shippedWithoutReceipt)])

        let first = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(first.flagged.count == 2)

        // Same verdict, unchanged reality: both dedupe against the trailing run.
        let second = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(second.flagged.isEmpty)
        #expect(second.flagsDeduped == 2)

        // A human note buries both; the next poll re-raises both, then settles.
        _ = try await store.appendNote(parent.handle, text: "User: I know, leave it")
        let third = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(third.flagged.count == 2)
        let fourth = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(fourth.flagsDeduped == 2)
    }

    // MARK: - Wave 5 review round 4 (gpt-5.5 run ca4c613a69d5)

    /// BLOCKING, from review: the dependent-blocker note ASSERTS that a blocker
    /// auto-resolved. It was written before the resolves ran, so a resolve that
    /// then lost its CAS race left behind a note claiming it had won.
    @Test("a blocker whose close loses its race never gets announced as resolved")
    func dependentDriftWaitsForTheBlockerToActuallyClose() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocker = try await store.createItem(kind: .gh, project: "NativeAgent", title: "the blocker")
        _ = try await store.addRef(blocker.handle, ref: prRef())
        _ = try await store.setCadence(blocker.handle, cadence: Cadence(refreshSources: ["github"]))
        let dependent = try await store.createItem(kind: .plan, project: "NativeAgent", title: "waiting on it")
        _ = try await store.setBlockedOn(dependent.handle, blockers: [blocker.handle])
        _ = try await store.setStatus(dependent.handle, status: .blocked, blockedReason: "waiting")

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        #expect(verdict.autoResolves.map(\.handle) == [blocker.handle])
        #expect(verdict.drifts.contains { $0.handle == dependent.handle })

        // User edits the BLOCKER, so its close will be refused. The dependent's
        // own record is untouched — only the premise died.
        _ = try await store.updateTitle(blocker.handle, title: "actually not that", summary: nil)

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved.isEmpty)
        let dep = try #require(try await store.liveState().items.first { $0.handle == dependent.handle })
        #expect(dep.notes.isEmpty, "no note may claim a blocker resolved when it did not")
        // A distinct bucket: nothing raced on the DEPENDENT, its premise died.
        #expect(outcome.premiseFailed == [dependent.handle])
        #expect(!outcome.skippedRaced.contains(dependent.handle))
    }

    /// The happy path of the same mechanism: when the blocker really does close,
    /// the dependent IS told — deferring the write must not drop it.
    @Test("a blocker that really closes does get announced to its dependents")
    func dependentDriftLandsWhenTheBlockerCloses() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let blocker = try await store.createItem(kind: .gh, project: "NativeAgent", title: "the blocker")
        _ = try await store.addRef(blocker.handle, ref: prRef())
        _ = try await store.setCadence(blocker.handle, cadence: Cadence(refreshSources: ["github"]))
        let dependent = try await store.createItem(kind: .plan, project: "NativeAgent", title: "waiting on it")
        _ = try await store.setBlockedOn(dependent.handle, blockers: [blocker.handle])
        _ = try await store.setStatus(dependent.handle, status: .blocked, blockedReason: "waiting")

        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(), observations: [observed()], now: now
        )
        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved == [blocker.handle])
        #expect(outcome.flagged.contains { $0.hasPrefix(dependent.handle) })
        let dep = try #require(try await store.liveState().items.first { $0.handle == dependent.handle })
        #expect(dep.notes.last?.text.contains("auto-resolved from observed reality") == true)
    }

    /// NEEDS_FIX, from review: a parent was told "your sub-items are still open"
    /// moments before the pass closed the last one. The flag now waits for the
    /// resolves and dies on the open-child count in the fingerprint.
    @Test("a parent is not told its sub-items are open when this pass closes them")
    func parentDriftDiesWhenItsChildResolvesInTheSamePass() async throws {
        let root = hermeticRoot()
        let store = SwiftNativeDeskStore(dataRoot: root)
        let parent = try await store.createItem(kind: .gh, project: "NativeAgent", title: "campaign")
        _ = try await store.addRef(parent.handle, ref: prRef())
        _ = try await store.setCadence(parent.handle, cadence: Cadence(refreshSources: ["github"]))
        let child = try await store.createItem(kind: .gh, project: "NativeAgent", title: "sub-item", parent: parent.handle)
        _ = try await store.addRef(child.handle, ref: prRef("user/nativeagent", 42))
        _ = try await store.setCadence(child.handle, cadence: Cadence(refreshSources: ["github"]))

        // Both PRs are terminal in the same pass.
        let verdict = DeskObservationEvaluator.evaluate(
            try await store.liveState(),
            observations: [observed(), observed("user/nativeagent#pr#42", status: "closed")],
            now: now
        )
        #expect(verdict.autoResolves.map(\.handle) == [child.handle])
        #expect(verdict.drifts.contains { $0.handle == parent.handle })

        let outcome = try await DeskObservationApplier.apply(verdict, to: store)
        #expect(outcome.resolved == [child.handle])
        let p = try #require(try await store.liveState().items.first { $0.handle == parent.handle })
        #expect(p.notes.isEmpty, "the premise expired inside this very pass")
        #expect(DeskProjection.driftSegment(p) == nil)
    }

    /// NEEDS_FIX, from review: the evaluator must be a function of
    /// (state, observations, now) with no wall-clock read anywhere, or two
    /// replays of the same inputs can disagree. Unparseable stamps were the
    /// fallback path that reached for `Date()`.
    @Test("an unparseable observation stamp still yields a deterministic verdict")
    func evaluatorIsPureEvenOnUnparseableStamps() {
        var broken = observed()
        broken.observedAt = "not-a-date"
        let subject = state([item(kind: .plan, refs: [prRef()], cadence: Cadence())])
        let first = DeskObservationEvaluator.evaluate(subject, observations: [broken], now: now)
        let second = DeskObservationEvaluator.evaluate(subject, observations: [broken], now: now)
        #expect(first == second)
        #expect(first.drifts.first?.observedAt == DeskClock.nowISO(now))
    }

    /// `blockedButShipped` has three producers, and one item can emit two of
    /// them (prose-blocked AND blocked-on a resolving item). Swift's sort is not
    /// stable, so (handle, kind) alone would let the verdict vary between two
    /// evaluations of identical inputs. Signature is the tiebreak that makes the
    /// order total.
    @Test("two same-kind drifts on one handle order deterministically")
    func sameKindDriftsOnOneHandleAreTotallyOrdered() {
        let blocker = item(handle: "h1", alias: "1", refs: [prRef()])
        let dependent = item(
            handle: "h2", alias: "2", kind: .gh, status: .blocked,
            refs: [prRef("user/nativeagent", 42)],
            blockedReason: "waiting on review", blockedOn: ["h1"]
        )
        let subject = state([blocker, dependent])
        let obs = [observed(), observed("user/nativeagent#pr#42", status: "closed")]

        let first = DeskObservationEvaluator.evaluate(subject, observations: obs, now: now)
        let h2Drifts = first.drifts.filter { $0.handle == "h2" && $0.kind == .blockedButShipped }
        #expect(h2Drifts.count == 2, "precondition: one handle, two same-kind drifts")
        for _ in 0..<8 {
            #expect(DeskObservationEvaluator.evaluate(subject, observations: obs, now: now) == first)
        }
    }
}
