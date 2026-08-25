import Foundation
import Testing
@testable import MacControl

// Agent's LIVE round-4 acceptance run (2026-08-22, build 0.4.2-dev.0fb107fd),
// finding 1 — the only substantive defect she reported.
//
// Finder home, `.agents` exposed as AXTextField handle gygc2x. `mac_act`
// verb=open returned ok / status=acted / method=cgevent_double_click_fallback /
// fallback_reason=ax_action_refused (op F92233EC-4D03-40BE-B409-C2B5EE678951)
// while the window title stayed `home-folder`, the acted element stayed
// `.agents`, readouts_changed=0 and effect.window_changed=false. The only
// "evidence" was one AXRowCountChanged plus a 29-added/1-removed census taken
// across two TRUNCATED walks — an incomparable set difference.

/// The round-4 Finder diff, verbatim: every identity-keyed channel still,
/// a fat census, and the census is not comparable.
private func r4FinderOpenDiff(
    comparable: Bool = false,
    addedTotal: Int = 29,
    removedTotal: Int = 1,
    windowTitleChanged: Bool = false,
    changedTotal: Int = 0,
    focusChanged: Bool = false,
    readoutsChangedTotal: Int = 0
) -> MacActClosedLoop.EffectDiff {
    MacActClosedLoop.EffectDiff(
        added: [],
        removed: [],
        changed: [],
        addedTotal: addedTotal,
        removedTotal: removedTotal,
        changedTotal: changedTotal,
        focusChanged: focusChanged,
        focusHandleAfter: "gygc2x",
        focusLabelAfter: ".agents",
        focusRoleAfter: "AXTextField",
        modalAppeared: false,
        modalDisappeared: false,
        modalLabelAfter: nil,
        windowTitleChanged: windowTitleChanged,
        windowTitleAfter: windowTitleChanged ? ".agents" : "home-folder",
        readoutsChangedTotal: readoutsChangedTotal,
        diffComparable: comparable,
        diffIncomparableReason: comparable
            ? nil
            : "both the look's walk and the post-act walk truncated"
    )
}

@Test("round 4: Finder open that navigated nowhere is acted_unobserved, not acted")
func round4FinderOpenWithoutNavigationIsUnobserved() {
    let diff = r4FinderOpenDiff()
    // The premise the bug rested on: a notification DID fire.
    let verdict = MacActClosedLoop.classify(
        performedOK: true,
        verb: .open,
        notificationObserved: true,
        diff: diff
    )
    #expect(verdict.status == "acted_unobserved")
    #expect(verdict.reason == "navigation_unverified")
    // The census must be named as the non-evidence it was, or the caller is
    // left wondering why 29 additions bought nothing.
    #expect(verdict.note?.contains("not comparable") == true)
    #expect(verdict.note?.contains("truncated") == true)
}

@Test("round 4: an incomparable census cannot make window_changed true")
func round4IncomparableCensusIsNotAChange() {
    let diff = r4FinderOpenDiff()
    #expect(diff.windowChanged == false)
    #expect(diff.changeReasons.isEmpty)
}

/// NEGATIVE CONTROL, in the reachable position: identical call, one real
/// navigation channel moved. If this does not flip to `acted`, the test above
/// is pinning "open is always unobserved" rather than the defect.
@Test("round 4 control: an open whose title moved is acted")
func round4FinderOpenWithTitleChangeIsActed() {
    let verdict = MacActClosedLoop.classify(
        performedOK: true,
        verb: .open,
        notificationObserved: true,
        diff: r4FinderOpenDiff(windowTitleChanged: true)
    )
    #expect(verdict.status == "acted")
    #expect(verdict.reason == nil)
}

/// The other reachable control: a COMPARABLE census with additions is real
/// evidence of navigation and must still pass.
@Test("round 4 control: a comparable census with additions is acted")
func round4ComparableCensusIsActed() {
    let verdict = MacActClosedLoop.classify(
        performedOK: true,
        verb: .open,
        notificationObserved: true,
        diff: r4FinderOpenDiff(comparable: true)
    )
    #expect(verdict.status == "acted")
}

/// REGRESSION FENCE for the two flows Agent reported PASSING in round 4.
/// The navigation rule must not reach a non-navigation verb: Notes `type`
/// published AXValueChanged, and Calculator's readout moved. Neither may be
/// re-classified by this change.
@Test("round 4: non-navigation verbs keep the notification-only rule")
func round4NonNavigationVerbsUnaffected() {
    for verb in [MacActVerb.type, .click, .select, .toggle, .scroll, .dismiss] {
        // Even with a totally still diff, a fired notification still means acted
        // for these — that is the pre-existing contract and it is not in scope.
        let verdict = MacActClosedLoop.classify(
            performedOK: true,
            verb: verb,
            notificationObserved: true,
            diff: r4FinderOpenDiff()
        )
        #expect(verdict.status == "acted", "\(verb.rawValue) must be unaffected")
    }
    #expect(MacActClosedLoop.navigationVerbs == [.open])
}

@Test("round 4: no notification still outranks everything as none_observed")
func round4NoNotificationIsNoneObserved() {
    let verdict = MacActClosedLoop.classify(
        performedOK: true,
        verb: .open,
        notificationObserved: false,
        diff: r4FinderOpenDiff(comparable: true, windowTitleChanged: true)
    )
    #expect(verdict.status == "acted_unobserved")
    #expect(verdict.reason == "none_observed")
}

/// A nil diff is the window-died path (frame_window_gone / frame_app_gone /
/// window_drifted). The frame dying IS a transition, so it must NOT be read as
/// "did not navigate" — those paths name themselves in `effect.percept`.
@Test("round 4: a nil diff is not counted as failure to navigate")
func round4NilDiffIsNotUnnavigated() {
    let verdict = MacActClosedLoop.classify(
        performedOK: true,
        verb: .open,
        notificationObserved: true,
        diff: nil
    )
    #expect(verdict.status == "acted")
}

@Test("round 4: a failed act stays failed regardless of verb")
func round4FailedStaysFailed() {
    let verdict = MacActClosedLoop.classify(
        performedOK: false,
        verb: .open,
        notificationObserved: true,
        diff: r4FinderOpenDiff(comparable: true, windowTitleChanged: true)
    )
    #expect(verdict.status == "failed")
    #expect(verdict.reason == nil)
}

/// SUPERSEDED BY LIVE EVIDENCE (Agent round 6, receipt 1780C1D3).
///
/// This test used to assert that ANY identity-keyed channel licenses `acted`
/// for `open` — focus, an affordance change, a readout change, or the title.
/// That was written from fixtures, and round 6 proved three quarters of it
/// wrong on the real thing: an `open` that navigated nowhere was called `acted`
/// off a lone `readouts_changed` that was itself noise (a "Doc" → "Document"
/// text expansion on a DIFFERENT row). Navigation is STRUCTURAL; reacting is
/// not navigating. The channels are now split by what they actually prove.
@Test("round 4→6: only STRUCTURAL channels license acted for open")
func round4EachChannelLicensesActed() {
    // These prove the surface went somewhere.
    let structural: [(String, MacActClosedLoop.EffectDiff)] = [
        ("title", r4FinderOpenDiff(windowTitleChanged: true)),
        ("comparable_census", r4FinderOpenDiff(comparable: true)),
    ]
    for (name, diff) in structural {
        let verdict = MacActClosedLoop.classify(
            performedOK: true, verb: .open, notificationObserved: true, diff: diff
        )
        #expect(verdict.status == "acted", "\(name) should license acted")
    }
    // These prove only that the app reacted — round-6's false success.
    let reactions: [(String, MacActClosedLoop.EffectDiff)] = [
        ("focus", r4FinderOpenDiff(focusChanged: true)),
        ("affordances_changed", r4FinderOpenDiff(changedTotal: 3)),
        ("readouts_changed", r4FinderOpenDiff(readoutsChangedTotal: 1)),
    ]
    for (name, diff) in reactions {
        #expect(diff.windowChanged, "\(name) is still a real change…")
        let verdict = MacActClosedLoop.classify(
            performedOK: true, verb: .open, notificationObserved: true, diff: diff
        )
        #expect(verdict.status == "acted_unobserved", "…but \(name) is not navigation")
    }
}
