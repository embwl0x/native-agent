import Foundation
import Testing
@testable import MacControl

// Agent's round-6 Finder-only LIVE pass (2026-08-22), receipt
// 1780C1D3-4568-4A1D-BBCB-3FB8015949C2, frame A4A9362E-6294-4210-8796-1592D009EFD1.
// Verdict: FAIL. `open` on `.agent-browser` returned status `acted` and did not
// navigate — the Finder title stayed `home-folder` throughout.
//
// The classifier licensed `acted` off ONE change reason: `readouts_changed`,
// and that delta was noise — a text expansion "Doc" → "Document" on a
// DIFFERENT row (handle zmyzpv, path [0,2,0,0,7,3,0]) which the rename pairing
// counted as a rename. Title, acted element and focus all unchanged; census
// explicitly incomparable (both walks truncated, 29 added / 1 removed).

/// Her round-6 diff, to the numbers she reported.
private func round6Diff(
    readoutsChangedTotal: Int = 1,
    windowTitleChanged: Bool = false,
    comparable: Bool = false,
    addedTotal: Int = 29,
    removedTotal: Int = 1,
    focusChanged: Bool = false,
    changedTotal: Int = 0,
    modalAppeared: Bool = false
) -> MacActClosedLoop.EffectDiff {
    MacActClosedLoop.EffectDiff(
        added: [],
        removed: [],
        changed: [],
        addedTotal: addedTotal,
        removedTotal: removedTotal,
        changedTotal: changedTotal,
        focusChanged: focusChanged,
        focusHandleAfter: "bookin",
        focusLabelAfter: ".agent-browser",
        focusRoleAfter: "AXTextField",
        modalAppeared: modalAppeared,
        modalDisappeared: false,
        modalLabelAfter: nil,
        windowTitleChanged: windowTitleChanged,
        windowTitleAfter: windowTitleChanged ? ".agent-browser" : "home-folder",
        readoutsChangedTotal: readoutsChangedTotal,
        diffComparable: comparable,
        diffIncomparableReason: comparable
            ? nil
            : "both the look's walk and the post-act walk truncated"
    )
}

@Test("round 6 LIVE: a lone readout change is not navigation")
func round6ReadoutAloneIsNotNavigation() {
    let diff = round6Diff()
    // The old gate said yes — that is precisely the false success she caught.
    #expect(diff.windowChanged, "her envelope really did report window_changed:true")
    #expect(diff.changeReasons == ["readouts_changed"], "and off this reason alone")
    // The new gate says no.
    #expect(diff.navigated == false, "a readout text expansion is not going somewhere")

    let verdict = MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true, diff: diff
    )
    #expect(verdict.status == "acted_unobserved", "round 6 must not read as success")
    #expect(verdict.reason == "navigation_unverified")
}

/// NEGATIVE CONTROL, reachable: the same call with the signal Finder actually
/// produces on a real navigation — it retitles to the folder name.
@Test("round 6 control: a retitle IS navigation")
func round6RetitleIsNavigation() {
    let diff = round6Diff(windowTitleChanged: true)
    #expect(diff.navigated)
    let verdict = MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true, diff: diff
    )
    #expect(verdict.status == "acted")
}

@Test("round 6: a comparable affordance turnover is still navigation")
func round6ComparableTurnoverIsNavigation() {
    #expect(round6Diff(comparable: true).navigated)
}

@Test("round 6: an incomparable census can never license navigation")
func round6IncomparableCensusNeverNavigates() {
    // Her exact 29-added/1-removed under two truncated walks.
    #expect(round6Diff(comparable: false, addedTotal: 29, removedTotal: 1).navigated == false)
}

@Test("round 6: selection alone is not navigation")
func round6FocusAloneIsNotNavigation() {
    let diff = round6Diff(readoutsChangedTotal: 0, focusChanged: true)
    #expect(diff.windowChanged, "focus moving is a real change…")
    #expect(diff.navigated == false, "…but selecting a row is not opening it")
}

@Test("round 6: an affordance flip alone is not navigation")
func round6AffordanceFlipAloneIsNotNavigation() {
    let diff = round6Diff(readoutsChangedTotal: 0, changedTotal: 4)
    #expect(diff.windowChanged)
    #expect(diff.navigated == false, "a highlight or enabled flip is not navigation")
}

@Test("round 6: a modal is navigation — an error sheet is a destination")
func round6ModalIsNavigation() {
    #expect(round6Diff(readoutsChangedTotal: 0, modalAppeared: true).navigated)
}

/// Non-navigation verbs keep the looser rule: Agent's Notes-type and
/// Calculator-equals passes are licensed by exactly the channels excluded above.
@Test("round 6: non-navigation verbs still accept a readout change")
func round6NonNavigationVerbsUnaffected() {
    for verb in [MacActVerb.type, .click, .select, .toggle, .scroll, .dismiss] {
        let verdict = MacActClosedLoop.classify(
            performedOK: true, verb: verb, notificationObserved: true, diff: round6Diff()
        )
        #expect(verdict.status == "acted", "\(verb.rawValue) must keep the readout signal")
    }
}

// MARK: - The Open command, and intent matching

@Test("round 6 live: Finder's proven Open chord is cmd+down; unmeasured apps get none")
func round6OpenChordTableIsProvenOnly() {
    let finder = MacActClosedLoop.openCommandChord(forBundleId: "com.apple.finder")
    #expect(finder?.source == "cmd+down")
    #expect(finder?.keyCode == 0x7D)
    #expect(finder?.modifiers == .command)
    // No chord is invented for an app nobody measured — an unverified keystroke
    // fired into an arbitrary app is the same class of bug as the inert click.
    for app in ["com.apple.mail", "com.apple.dt.Xcode", "com.apple.Safari", "com.apple.Notes"] {
        #expect(MacActClosedLoop.openCommandChord(forBundleId: app) == nil, "\(app) is unmeasured")
    }
    #expect(MacActClosedLoop.openCommandChord(forBundleId: nil) == nil)
    // The gate is the BUNDLE ID, so an impostor named "Finder" gets nothing.
    #expect(MacActClosedLoop.openCommandChord(forBundleId: "com.evil.Finder") == nil)
}

@Test("round 6: destination matching credits the folder we asked for")
func round6DestinationMatching() {
    // Her exact case: opening `.agent-browser` retitles the window to it.
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: ".agent-browser", intendedTarget: ".agent-browser") == true)
    // Finder's real behaviour, measured live this round.
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: "home-folder", intendedTarget: ".agent-browser") == false)
    // Not checkable is NOT a match.
    #expect(MacActClosedLoop.destinationMatchesIntent(title: nil, intendedTarget: "x") == nil)
    #expect(MacActClosedLoop.destinationMatchesIntent(title: "x", intendedTarget: nil) == nil)
    #expect(MacActClosedLoop.destinationMatchesIntent(title: "  ", intendedTarget: "x") == nil)
    // Short targets must not match by luck.
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: "Documents", intendedTarget: "oc") == false)
}

@Test("round 6: a structural change to the WRONG destination is not success")
func round6WrongDestinationIsNotActed() {
    // The window really did retitle — but to something we did not ask for.
    let diff = round6Diff(windowTitleChanged: true)   // title becomes .agent-browser
    let verdict = MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true,
        diff: diff, intendedTarget: "Screenshots"
    )
    #expect(verdict.status == "acted_unobserved")
    #expect(verdict.reason == "navigation_intent_unmatched")
    #expect(verdict.note?.contains(".agent-browser") == true, "the note must name what DID change")
}

@Test("round 6 control: the right destination IS success")
func round6RightDestinationIsActed() {
    let verdict = MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true,
        diff: round6Diff(windowTitleChanged: true), intendedTarget: ".agent-browser"
    )
    #expect(verdict.status == "acted")
    #expect(verdict.reason == nil)
}

@Test("round 6: unchecked intent falls back to the structural floor, not a promotion")
func round6UncheckedIntentUsesTheFloor() {
    // No intended target ⇒ nothing to compare ⇒ structural floor decides.
    #expect(MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true,
        diff: round6Diff(windowTitleChanged: true), intendedTarget: nil
    ).status == "acted")
    // …and the floor still refuses her round-6 envelope.
    #expect(MacActClosedLoop.classify(
        performedOK: true, verb: .open, notificationObserved: true,
        diff: round6Diff(), intendedTarget: nil
    ).status == "acted_unobserved")
}

@Test("round 7: destination matching is EXACT — no substring promotions")
func round7DestinationMatchingIsExact() {
    // gpt-5.5 round-7 review: the substring rule promoted coincidences.
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: "Documents", intendedTarget: "Doc") == false)
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: ".agent-browser", intendedTarget: "agent") == false)
    // Exact still matches, case- and whitespace-insensitively.
    #expect(MacActClosedLoop.destinationMatchesIntent(
        title: " .agent-browser ", intendedTarget: ".AGENT-BROWSER") == true)
}
