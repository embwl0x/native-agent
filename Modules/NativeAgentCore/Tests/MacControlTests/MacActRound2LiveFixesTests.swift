import Foundation
import Testing
@testable import MacControl
import PersistenceCore

// Agent's LIVE round-2 acceptance run (2026-08-22, build 0.4.2-dev.1949643f).
// Every test here pins one defect she quoted from a real envelope.

private func r2entry(
    _ handle: String, _ path: [Int], _ role: String, _ label: String?
) -> MacLookFrameEntry {
    MacLookFrameEntry(handle: handle, path: path, role: role, label: label, frame: nil, value: nil, enabled: true)
}

private func r2percept(
    affordances: [MacLookAffordance] = [],
    focus: MacLookFocus? = nil,
    readouts: [MacLookReadout] = [],
    windowTitle: String? = "W",
    truncated: Bool = false
) -> MacLookPercept {
    MacLookPercept(
        app: nil, windowTitle: windowTitle, focus: focus, modal: nil, landmarks: [],
        affordances: affordances, unlabeledByRole: [:], affordancesOmitted: 0,
        interactiveCount: affordances.count, labeledCount: affordances.count,
        truncated: truncated, truncationReasons: truncated ? ["node_cap"] : [], skippedAtLeast: 0,
        readouts: readouts
    )
}

private func r2frame(
    entries: [String: MacLookFrameEntry] = [:],
    readouts: [String: MacLookReadoutRecord] = [:],
    windowTitle: String? = "W",
    focusHandle: String? = nil,
    caps: MacLookCompileCaps? = nil
) -> MacLookFrame {
    MacLookFrame(
        frameId: "f1", capturedAt: Date(), appName: "A", bundleId: nil,
        windowTitle: windowTitle, entries: entries, pid: 1, focusHandle: focusHandle,
        hasModal: false, modalPath: nil, readouts: readouts, caps: caps
    )
}

// MARK: - Finding 1: a focus-only handle must be actable (Notes `type`)

@Test
func focusOnlyHandle_resolvesThroughTheFocusChannel_andDoesNotDrift() {
    // An empty note body: interactive, no title, no value ⇒ never an affordance,
    // but the frame minted a FOCUS-derived entry and the look advertised it.
    let entry = r2entry("5j7mra", [0, 5, 0], "AXTextArea", nil)
    let percept = r2percept(
        affordances: [],
        focus: MacLookFocus(role: "AXTextArea", label: nil, handle: "5j7mra", path: [0, 5, 0])
    )
    let live = MacActClosedLoop.liveIdentity(entry: entry, percept: percept)
    #expect(live?.handle == "5j7mra")
    #expect(
        MacActClosedLoop.identityDrift(entry: entry, live: live) == nil,
        "the focused note body IS the element she named — refusing it made `type` impossible"
    )
}

@Test
func focusOnlyHandle_negativeControl_genuinelyAbsentStillRefuses() {
    // NEGATIVE CONTROL: the guard must not have been softened into a pass.
    let entry = r2entry("5j7mra", [0, 5, 0], "AXTextArea", nil)
    let percept = r2percept(
        affordances: [],
        focus: MacLookFocus(role: "AXTextArea", label: nil, handle: "5j7mra", path: [9, 9])
    )
    #expect(MacActClosedLoop.liveIdentity(entry: entry, percept: percept) == nil)
    let drift = MacActClosedLoop.identityDrift(
        entry: entry,
        live: MacActClosedLoop.liveIdentity(entry: entry, percept: percept)
    )
    #expect(drift?.on == "element_absent")
}

@Test
func focusOnlyHandle_differentControlNowFocusedAtThatPath_stillRefuses() {
    let entry = r2entry("5j7mra", [0, 5, 0], "AXTextArea", nil)
    let percept = r2percept(
        affordances: [],
        focus: MacLookFocus(role: "AXTextField", label: "Search", handle: "zzzzzz", path: [0, 5, 0])
    )
    let drift = MacActClosedLoop.identityDrift(
        entry: entry,
        live: MacActClosedLoop.liveIdentity(entry: entry, percept: percept)
    )
    #expect(drift?.on == "handle", "a different control at that path is drift, focus channel or not")
}

// MARK: - Finding 2: Equals must carry "42"

@Test
func readoutRename_pairsIntoOneChangedRow_carryingTheAnswer() {
    // Calculator retitles its display when it shows a result, so the readout's
    // handle (fingerprint includes the title) moves: it arrived as
    // added_total 2 / removed_total 1 with an EMPTY changed list, and "42" was
    // nowhere in the act's own answer.
    let before = r2frame(readouts: [
        "old": MacLookReadoutRecord(handle: "old", path: [1], role: "AXStaticText", text: "7×6"),
    ])
    let after = r2percept(readouts: [
        MacLookReadout(handle: "new", role: "AXStaticText", text: "42", source: "value", path: [1]),
    ])
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.readoutsChangedTotal == 1)
    #expect(diff.readoutsAddedTotal == 0)
    #expect(diff.readoutsRemovedTotal == 0)
    let change = diff.readoutsChanged.first
    #expect(change?.renamed == true)
    #expect(change?.beforeText == "7×6")
    #expect(change?.afterText == "42", "the number she pressed Equals for")
    #expect(diff.changeReasons.contains("readouts_changed"))
}

@Test
func readoutsAdded_emitRowsWithText_notJustATotal() {
    let before = r2frame()
    let after = r2percept(readouts: [
        MacLookReadout(handle: "h1", role: "AXStaticText", text: "42", source: "value", path: [2]),
    ])
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.readoutsAddedTotal == 1)
    #expect(diff.readoutsAdded.first?.text == "42")
    guard case .object(let json)? = diff.readoutsAdded.first?.toJSON() else {
        Issue.record("expected an object"); return
    }
    #expect(json["text"] == .string("42"), "a total does not contain the answer; the row does")
}

// MARK: - Finding 3: no acted-success from capped-compile churn (Finder `open`)

@Test
func cappedRecompileChurn_isNotEvidenceOfChange() {
    // 29 affordances "added" by a recompile that truncated where the look did not.
    let before = r2frame(
        entries: ["a": r2entry("a", [0], "AXButton", "One")],
        caps: MacLookCompileCaps(truncated: false, maxAffordances: 60, maxNodes: 400, maxDepth: 12)
    )
    let after = r2percept(
        affordances: [
            MacLookAffordance(handle: "a", role: "AXButton", label: "One", labelSource: "title", path: [0]),
            MacLookAffordance(handle: "b", role: "AXButton", label: "Two", labelSource: "title", path: [1]),
        ],
        truncated: true
    )
    let diff = MacActClosedLoop.diff(
        before: before, after: after, afterWindowTitle: "W",
        afterCaps: MacLookCompileCaps(truncated: true, maxAffordances: 60, maxNodes: 400, maxDepth: 12)
    )
    #expect(diff.addedTotal == 1, "the row is still listed — it is only not counted as EVIDENCE")
    #expect(!diff.diffComparable)
    #expect(diff.diffIncomparableReason != nil)
    #expect(!diff.changeReasons.contains("affordances_added"))
    #expect(!diff.windowChanged, "an unobserved act on a capped recompile did NOT change the window")
}

@Test
func identityKeyedChannelsSurviveIncomparability() {
    let before = r2frame(
        entries: [:], windowTitle: "Recents",
        caps: MacLookCompileCaps(truncated: false, maxNodes: 400)
    )
    let after = r2percept(windowTitle: "Documents", truncated: true)
    let diff = MacActClosedLoop.diff(
        before: before, after: after, afterWindowTitle: "Documents",
        afterCaps: MacLookCompileCaps(truncated: true, maxNodes: 400)
    )
    #expect(!diff.diffComparable)
    #expect(diff.changeReasons == ["window_title_changed"])
    #expect(diff.windowChanged, "a real navigation still reports, truncated walk or not")
}

@Test
func windowChanged_isNeverTrueWithoutAReason() {
    let before = r2frame(entries: ["a": r2entry("a", [0], "AXButton", "One")])
    let after = r2percept(affordances: [
        MacLookAffordance(handle: "a", role: "AXButton", label: "One", labelSource: "title", path: [0]),
    ])
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.changeReasons.isEmpty)
    #expect(!diff.windowChanged)
    #expect(diff.isEmpty)
}

// MARK: - Finding 4: a layout group is not a content row

@Test
func contentIdentity_excludesAXGroup() {
    #expect(!MacLookHandle.contentIdentityRoles.contains("AXGroup"),
            "a title-less group wrapping the display took the display TEXT as its identity")
    for role in ["AXRow", "AXCell", "AXOutlineRow", "AXListItem"] {
        #expect(MacLookHandle.contentIdentityRoles.contains(role), "\(role) is a real content row")
    }
}

// MARK: - C2: the new readout rows must carry the COMPILE's verdict

@Test
func readoutRows_emitTheCompileRedaction_notAContextFreeRe_render() {
    // Round 3 closed this hole on `readouts_changed`: a readout of "123" inside
    // a group titled "CVV" is in the clear by SHAPE alone, and the standalone
    // redactor cannot see the caption. The new added/removed rows must not
    // reopen it — they emit what the compile decided, never the raw text.
    let withheld = JSONValue.object(["redacted": .bool(true), "chars": .int(3)])
    let after = r2percept(readouts: [
        MacLookReadout(
            handle: "h1", role: "AXStaticText", text: "123", source: "value",
            path: [2], textJSON: withheld
        ),
    ])
    let diff = MacActClosedLoop.diff(before: r2frame(), after: after, afterWindowTitle: "W")
    guard case .object(let json)? = diff.readoutsAdded.first?.toJSON() else {
        Issue.record("expected a row"); return
    }
    #expect(json["text"] == withheld, "the compile withheld this; the row must not print it")
    #expect(json["text"] != .string("123"))
}

// MARK: - Finding 2 / C2 — the diff PIPELINE must carry each readout's compile
// verdict into removed + renamed rows, not just added (gpt-5.5 round-3 B3
// reopened on new channels; wired by Claude in the round-3+4 integration).
// These are PIPELINE tests: ReadoutRow.toJSON redaction is unit-tested above,
// but only wiring proves diff() actually passes textJSON through. Reverting
// either wiring line leaves every other test green — these are the gate.

private let r2withheld = JSONValue.object(["redacted": .bool(true), "chars": .int(3)])

@Test
func readoutsRemoved_carryTheCompileRedaction_notAContextFreeReRender() {
    // A "123" inside a group titled "CVV": the compile withheld it (textJSON is
    // the marker). It is REMOVED (after has no readouts). The removed row must
    // ship the marker, never "123".
    let before = r2frame(readouts: [
        "path:3": MacLookReadoutRecord(handle: nil, path: [3], role: "AXStaticText",
                                       text: "123", textJSON: r2withheld, secret: true),
    ])
    let after = r2percept(readouts: [])
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    #expect(diff.readoutsRemovedTotal == 1)
    guard case .object(let json)? = diff.readoutsRemoved.first?.toJSON() else {
        Issue.record("expected a removed row object"); return
    }
    #expect(json["text"] == r2withheld, "the compile withheld this; the removed row must emit the marker")
    #expect(json["text"] != .string("123"), "the secret must never ride out in the clear")
}

@Test
func renamedReadout_carriesBothCompileVerdicts_notClearText() {
    // The channel Calculator's Equals actually travels is a RENAME (the display
    // retitles). If the secret case ever rides a rename, both sides must be the
    // compile marker. Same path + role before/after ⇒ paired into one renamed
    // changed row.
    let before = r2frame(readouts: [
        "path:1": MacLookReadoutRecord(handle: "old", path: [1], role: "AXStaticText",
                                       text: "123", textJSON: r2withheld, secret: true),
    ])
    let after = r2percept(readouts: [
        MacLookReadout(handle: "new", role: "AXStaticText", text: "456",
                       source: "value", path: [1], textJSON: r2withheld),
    ])
    let diff = MacActClosedLoop.diff(before: before, after: after, afterWindowTitle: "W")
    let change = diff.readoutsChanged.first { $0.renamed }
    #expect(change != nil, "an add+remove at the same path/role is a rename")
    #expect(change?.beforeJSON == r2withheld, "the removed side's compile verdict, not clear '123'")
    #expect(change?.afterJSON == r2withheld, "the added side's compile verdict, not clear '456'")
    #expect(change?.beforeJSON != .string("123"))
    #expect(change?.afterJSON != .string("456"))
}
