import Foundation
import Testing
@testable import MacControl

// Agent acceptance round 4, finding 1(a) — the half that makes Finder `open`
// actually WORK. 1(b) (commit c16e0a85) made the verdict honest; it could not
// make the act land, because the verb was aimed at the wrong element.
//
// Her live envelope: handle gygc2x was `.agents` exposed as an AXTextField —
// the filename CELL. AXOpen was refused on it (fallback_reason=
// ax_action_refused) and the CGEvent double-click landed on the text, which is
// Finder's RENAME gesture. Nothing navigated, every time.

/// A probe over a fixed path→(role, actions) map, standing in for the
/// window-anchored resolve production passes.
private func probe(_ tree: [[Int]: (role: String, actions: [String])])
    -> ([Int]) -> (role: String, actions: [String])? {
    { path in tree[path] }
}

/// Her live shape: window → outline → row → filename cell.
private let finderTree: [[Int]: (role: String, actions: [String])] = [
    []: (role: "AXWindow", actions: []),
    [0]: (role: "AXScrollArea", actions: []),
    [0, 0]: (role: "AXOutline", actions: []),
    [0, 0, 3]: (role: "AXRow", actions: ["AXPress", "AXOpen"]),
    [0, 0, 3, 0]: (role: "AXTextField", actions: ["AXPress", "AXOpen"]),
]

@Test("round 5: a filename cell resolves UP to the row that actually opens")
func round5FilenameCellResolvesToRow() {
    // Her shape: the filename cell does not open, the row does.
    var tree = finderTree
    tree[[0, 0, 3, 0]] = (role: "AXTextField", actions: ["AXPress"])
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 3, 0],
        probe: probe(tree)
    )
    #expect(plan.semantic?.path == [0, 0, 3], "must land on the ROW, not the filename text")
    #expect(plan.semantic?.hops == 1)
    #expect(plan.semantic?.role == "AXRow")
    #expect((plan.semantic?.advertisesOpen ?? false))
    #expect(plan.semantic?.reason == "ancestor_advertises_open")
    #expect((plan.semantic?.redirected ?? false))
}

@Test("round 5: the fallback walk ignores the handle's own AXOpen")
func round5FallbackIgnoresTheHandlesOwnActions() {
    // Agent's cell ADVERTISED AXOpen and refused it. The call site tries that
    // first; by the time this resolver runs, the handle has already failed to
    // open, so its own advertised actions must not steer the walk at all.
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 3, 0],
        probe: probe(finderTree)   // this cell advertises AXOpen
    )
    #expect(plan.semantic?.path == [0, 0, 3], "it must still climb to the row")
    #expect(plan.semantic?.reason == "ancestor_advertises_open")
    #expect((plan.semantic?.redirected ?? false))
}

/// Finder's real shape is AXRow > AXCell > AXStaticText. A cell must be climbed
/// THROUGH, never stopped at — double-clicking a filename cell is the RENAME
/// gesture, which is the entire bug.
@Test("round 5: an AXCell is climbed through, not treated as the open target")
func round5CellIsNotAClickTarget() {
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0, 0]: (role: "AXOutline", actions: []),
        [0, 0, 3]: (role: "AXRow", actions: ["AXPress"]),
        [0, 0, 3, 0]: (role: "AXCell", actions: ["AXPress"]),
        [0, 0, 3, 0, 0]: (role: "AXStaticText", actions: []),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 3, 0, 0], probe: probe(tree)
    )
    #expect(plan.click?.path == [0, 0, 3], "the ROW, two hops up past the cell")
    #expect(plan.click?.role == "AXRow")
    #expect(plan.click?.hops == 2)
    #expect(MacActClosedLoop.openableAncestorRoles.contains("AXCell") == false,
            "a cell is never a click target")
}

/// THE GUARD THAT MATTERS. Climbing past a row to the AXOutline and
/// double-clicking its centre opens whichever file happens to sit in the middle
/// of the list — a different one every time it scrolls.
@Test("round 5: the walk never climbs past a row into the container")
func round5WalkStopsAtTheContainer() {
    // A cell whose ancestors are containers only — no row anywhere.
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0]: (role: "AXScrollArea", actions: []),
        [0, 0]: (role: "AXOutline", actions: []),
        [0, 0, 1]: (role: "AXStaticText", actions: ["AXPress"]),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 1],
        probe: probe(tree)
    )
    #expect(plan.semantic == nil)
    #expect(plan.click == nil, "an AXOutline must never become the click target")
}

@Test("round 5: a row without AXOpen is still the nearest openable target")
func round5RowWithoutAXOpenIsStillTheTarget() {
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0, 0, 3]: (role: "AXRow", actions: ["AXPress"]),
        [0, 0, 3, 0]: (role: "AXTextField", actions: ["AXPress"]),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 3, 0], probe: probe(tree)
    )
    #expect(plan.click?.path == [0, 0, 3])
    #expect(plan.click?.reason == "nearest_openable_row")
    #expect(plan.semantic == nil, "nothing advertises AXOpen, so there is no semantic candidate")
}

@Test("round 5: the walk is bounded and stops at the window root")
func round5WalkIsBounded() {
    // Every ancestor is an unremarkable group: the walk must give up, not climb
    // to the window and click its centre.
    var tree: [[Int]: (role: String, actions: [String])] = [:]
    for depth in 1...6 {
        tree[Array(repeating: 0, count: depth)] = (role: "AXUnknown", actions: [])
    }
    let deep = Array(repeating: 0, count: 7)
    let plan = MacActClosedLoop.planOpenFallback(
        path: deep, probe: probe(tree)
    )
    #expect(plan.semantic == nil)
    #expect(plan.click == nil)
    #expect(MacActClosedLoop.maxOpenWalkHops == 3)
}

@Test("round 5: an unresolvable ancestor ends the walk instead of guessing")
func round5UnresolvableAncestorEndsTheWalk() {
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 3, 0],
        probe: { _ in nil }
    )
    #expect(plan.semantic == nil)
    #expect(plan.click == nil)
}

@Test("round 5: a top-level handle has nowhere to climb")
func round5TopLevelHandleDoesNotClimb() {
    let plan = MacActClosedLoop.planOpenFallback(
        path: [2], probe: probe(finderTree)
    )
    #expect(plan.semantic == nil)
    #expect(plan.click == nil)
}

/// gpt-5.5 round-5 review, BLOCKING #2: "first ancestor advertising AXOpen
/// wins" was NOT what the first cut implemented — it returned the nearest
/// openable ROLE as soon as it saw one, so a row that only takes a double-click
/// beat a higher ancestor that opens semantically. A synthesized double-click is
/// always the worse mechanism: it is the one that renames when it lands wrong.
@Test("round 5: a semantic AXOpen higher up beats a nearer click-only row")
func round5SemanticOpenBeatsANearerClickTarget() {
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0, 0]: (role: "AXOutlineRow", actions: ["AXPress", "AXOpen"]),
        [0, 0, 1]: (role: "AXRow", actions: ["AXPress"]),
        [0, 0, 1, 0]: (role: "AXTextField", actions: ["AXPress"]),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 1, 0], probe: probe(tree)
    )
    #expect(plan.semantic?.path == [0, 0], "the AXOpen advertiser, not the nearer plain row")
    #expect(plan.click?.path == [0, 0, 1], "and the nearer row is still the CLICK candidate")
}

/// …and the click target still wins when NOTHING in the bounded walk opens
/// semantically, so the two-pass preference did not just disable clicking.
@Test("round 5: with no AXOpen anywhere, the nearest row is still the target")
func round5ClickTargetStillWinsWhenNothingOpens() {
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0, 0]: (role: "AXOutlineRow", actions: ["AXPress"]),
        [0, 0, 1]: (role: "AXRow", actions: ["AXPress"]),
        [0, 0, 1, 0]: (role: "AXTextField", actions: ["AXPress"]),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 1, 0], probe: probe(tree)
    )
    #expect(plan.semantic == nil)
    #expect(plan.click?.path == [0, 0, 1], "NEAREST — the widest click is the worst click")
}

@Test("round 5: the widened stop-role list covers the containers that bite")
func round5StopRolesCoverTheDangerousContainers() {
    for role in ["AXBrowser", "AXCollection", "AXGrid", "AXWebArea", "AXTabGroup", "AXToolbar"] {
        let tree: [[Int]: (role: String, actions: [String])] = [
            [0, 0]: (role: role, actions: []),
            [0, 0, 1]: (role: "AXStaticText", actions: ["AXPress"]),
        ]
        let plan = MacActClosedLoop.planOpenFallback(
            path: [0, 0, 1], probe: probe(tree)
        )
        #expect(plan.click == nil, "\(role) must never become a click target")
    }
}

/// gpt-5.5 round-5 review, second pass BLOCKING: an `AXCell` that ADVERTISES
/// `AXOpen` used to win the walk outright, and when its `AXOpen` then refused
/// the call site double-clicked THAT CELL — the rename gesture again, by a new
/// route. The plan now keeps the two candidates apart: the cell may be asked to
/// open SEMANTICALLY, but only a ROW may ever be clicked.
@Test("round 5: an AXOpen-advertising cell is a semantic candidate, never a click target")
func round5AdvertisingCellIsNeverAClickTarget() {
    let tree: [[Int]: (role: String, actions: [String])] = [
        [0, 0]: (role: "AXRow", actions: ["AXPress"]),
        [0, 0, 0]: (role: "AXCell", actions: ["AXPress", "AXOpen"]),
        [0, 0, 0, 0]: (role: "AXStaticText", actions: []),
    ]
    let plan = MacActClosedLoop.planOpenFallback(
        path: [0, 0, 0, 0], probe: probe(tree)
    )
    #expect(plan.semantic?.path == [0, 0, 0], "the cell may be ASKED to open")
    #expect(plan.semantic?.role == "AXCell")
    #expect(plan.click?.path == [0, 0], "but only the ROW may ever be clicked")
    #expect(plan.click?.role == "AXRow")
    #expect(plan.click?.path != plan.semantic?.path,
            "if the cell's AXOpen refuses, the click must NOT reuse the cell")
}
