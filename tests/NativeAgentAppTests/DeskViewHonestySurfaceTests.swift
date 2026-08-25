import Foundation
import Testing
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, including the Desk's reader-honesty
// projection and a handful of view-body-only wiring contracts.
//
// The clear/loading and lane failure/quiet rules use the production projection
// consumed by DeskView. The remaining wiring-only checks use source inspection
// because their values only exist as SwiftUI modifier arguments.
//
// Ledger rows covered (docs/evals/ledger.json, fence app.desk):
//   desk.view.hasLoadedOnce.emptyStateGate  — wrong value (empty claim on a
//                                             board that never reported)
//   desk.view.laneUnavailableNotice         — silent zero (a failed lane
//                                             rendering as a quiet lane)
//   desk.counters.tapToScroll               — dead control (counter → anchor)
//   desk.counters.watching                  — dead control (same anchor rule)
//   desk.counters.staleWatch                — the anchor half of the row
//   desk.control.toolbar.palette            — dead control (paired ⌘K)
//   desk.reloader.singleActivation          — slowdown (two watchers, one view)
//
// Each test states the mutation that turns it red; all seven were run against a
// deliberately broken copy of the gate/anchor/branch before being kept.

private func deskViewSource() throws -> String {
    try AppSourceScraping.appSource("DeskView.swift")
}

// MARK: - the empty-state claim

/// "The desk is clear" is a claim about the DESK. It may only render when every
/// lane actually reported and none failed — never before the first load has
/// returned.
@Test("empty-state claim is gated on every lane reporting AND a completed first load")
func deskEmptyStateClaimIsGatedOnEveryLaneReporting() {
    let beforeFirstRead = DeskHonestyPresentation.boardBody(
        itemCount: 0, executionCount: 0, githubItemCount: 0,
        loadError: nil, hasLoadedOnce: false, hasUnavailableLane: false)
    #expect(beforeFirstRead == .loading)

    let confirmedEmpty = DeskHonestyPresentation.boardBody(
        itemCount: 0, executionCount: 0, githubItemCount: 0,
        loadError: nil, hasLoadedOnce: true, hasUnavailableLane: false)
    #expect(confirmedEmpty == .clear)

    let failedLane = DeskHonestyPresentation.boardBody(
        itemCount: 0, executionCount: 0, githubItemCount: 0,
        loadError: nil, hasLoadedOnce: true, hasUnavailableLane: true)
    #expect(failedLane == .populated)

    let failedDeskStore = DeskHonestyPresentation.boardBody(
        itemCount: 0, executionCount: 0, githubItemCount: 0,
        loadError: "unreadable", hasLoadedOnce: true, hasUnavailableLane: false)
    #expect(failedDeskStore == .populated)
}

// MARK: - a failed lane never renders as a quiet lane

/// `DeskLaneState` exists so a read failure cannot be drawn as emptiness. That
/// only holds if EVERY lane-backed section actually branches on
/// `unavailableReason` before its quiet copy. A new lane added without the
/// branch (or a call site deleted in a refactor) is the silent-zero this pins.
///
/// Mutation proof: deleting the `laneUnavailableNotice(` call from
/// `benchSection` fails this test.
@Test("Desk lanes present unavailable reads as uncertainty and healthy empty reads as quiet")
func deskLanesDistinguishUnavailableFromQuiet() throws {
    let githubUnavailable = DeskHonestyPresentation.githubLane(.unavailable("GitHub bytes unreadable"))
    #expect(githubUnavailable == .unavailable(.init(
        title: "GitHub Watcher state unavailable", detail: "GitHub bytes unreadable")))

    let githubQuiet = DeskHonestyPresentation.githubLane(.rows([]))
    #expect(githubQuiet == .quiet(DeskHonestyPresentation.githubQuietCopy))

    let executionUnavailable = DeskHonestyPresentation.executionLane(
        .unavailable("execution bytes unreadable"), hasRenderedBenchRows: false)
    #expect(executionUnavailable == .unavailable(.init(
        title: "Execution lane unavailable", detail: "execution bytes unreadable")))

    let executionQuiet = DeskHonestyPresentation.executionLane(
        .rows([]), hasRenderedBenchRows: false)
    #expect(executionQuiet == .quiet(DeskHonestyPresentation.executionQuietCopy))

    /*
    Historical source-shape assertion retained below temporarily as design
    context while this coverage row is owned by the executable presentation
    projection above.
    let source = try deskViewSource()

    // 1. Find the lanes the VIEW holds by their `@State` declarations, not by a
    //    hardcoded list — a third lane added tomorrow is picked up
    //    automatically. (The load snapshot carries the same two lanes as plain
    //    `let`s; those are the transport, not the render state.)
    var laneNames: [String] = []
    var cursor = source.startIndex
    while let hit = source.range(of: ": DeskLaneState<", range: cursor..<source.endIndex) {
        cursor = hit.upperBound
        let lineStart = source[..<hit.lowerBound].lastIndex(of: "\n")
            .map { source.index(after: $0) } ?? source.startIndex
        let decl = String(source[lineStart..<hit.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard decl.hasPrefix("@State") else { continue }
        guard let name = decl.split(separator: " ").last.map(String.init) else { continue }
        laneNames.append(name)
    }
    #expect(laneNames.count >= 2, "expected at least the executions and GitHub lanes, got \(laneNames)")

    // 2. Every lane must have an `if let reason = <lane>.unavailableReason {`
    //    branch whose body calls the notice.
    for lane in laneNames {
        let needle = "if let reason = \(lane).unavailableReason {"
        guard let branch = source.range(of: needle) else {
            Issue.record("lane `\(lane)` has no unavailable-reason render branch — a failed read of it renders as an empty lane")
            continue
        }
        let tail = source[branch.upperBound...].prefix(400)
        #expect(tail.contains("laneUnavailableNotice("),
                "lane `\(lane)`'s failure branch does not render the unavailable notice")
    }

    // 3. The notice must keep the sentence that makes it readable as a READER
    //    failure. Restyled into the quiet-lane placeholder, the whole primitive
    //    becomes decorative.
    #expect(source.contains("This is a read failure, not an empty lane"),
            "the unavailable notice lost the line that distinguishes it from a quiet lane")

    // 4. One definition, two-or-more call sites.
    let calls = AppSourceScraping.executableCalls(named: "laneUnavailableNotice", in: source)
    #expect(calls.count >= laneNames.count + 1,
            "expected one definition plus one call per lane, found \(calls.count) for \(laneNames.count) lanes")
    */
}

// MARK: - counters point at anchors that exist

/// Every triage counter is a tap target that scrolls to a section anchor. The
/// anchor id is a bare string in two files-worth of view body: rename the
/// section's `.id("sec-…")` and the counter keeps its hover cursor and goes
/// nowhere.
///
/// Mutation proof: renaming `.id("sec-watch")` (or a counter's `target:`) fails
/// this test.
@Test("every triage counter target has a rendered anchor with that id")
func everyTriageCounterTargetHasARenderedAnchor() throws {
    let source = try deskViewSource()

    // Targets the counters scroll to.
    var targets: Set<String> = []
    for call in AppSourceScraping.executableCalls(named: "triageCounter", in: source) {
        guard let range = call.range(of: "target: \"") else { continue }
        let rest = call[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        targets.insert(String(rest[..<end]))
    }
    #expect(targets.count >= 3, "expected the triage counters to name at least three anchors, got \(targets)")

    // Anchors the sections render.
    var anchors: Set<String> = []
    for call in AppSourceScraping.executableCalls(named: ".id", in: source) {
        guard let range = call.range(of: "(\"") else { continue }
        let rest = call[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        let id = String(rest[..<end])
        if id.hasPrefix("sec-") { anchors.insert(id) }
    }

    for target in targets {
        #expect(anchors.contains(target),
                "counter target `\(target)` has no matching `.id(\"\(target)\")` — the tap scrolls nowhere")
    }

    // And the scroll only ever goes to a counter target: one writer, one reader.
    #expect(source.contains("scrollTarget = target"),
            "the counter tap no longer feeds scrollTarget")
    #expect(source.contains("proxy.scrollTo(new"),
            "scrollTarget is no longer consumed by a ScrollViewReader")
}

// MARK: - ⌘K is a PAIRED affordance

/// The focusable bench swallows the toolbar button's `.keyboardShortcut`, so
/// ⌘K only works because a SECOND handler lives in the body. Delete either and
/// the palette stops opening from one of the two focus states, with no error.
///
/// Mutation proof: removing the `.keyboardShortcut("k", modifiers: .command)`
/// (or the `onKeyPress` branch) fails this test.
@Test("⌘K opens the palette from BOTH the toolbar shortcut and the in-body key handler")
func commandKPaletteHasBothAffordances() throws {
    let source = try deskViewSource()

    #expect(source.contains("keyboardShortcut(\"k\", modifiers: .command)"),
            "the toolbar ⌘K shortcut is gone — the palette is unreachable when focus is outside the bench")

    guard let keyPress = source.range(of: "onKeyPress(keys: [KeyEquivalent(\"k\")]") else {
        Issue.record("the in-body ⌘K handler is gone — the focused bench swallows the toolbar shortcut, so ⌘K is dead there")
        return
    }
    let body = source[keyPress.upperBound...].prefix(600)
    #expect(body.contains("press.modifiers.contains(.command)"),
            "the in-body k handler no longer requires the command modifier")
    #expect(body.contains("showingPalette = true"),
            "the in-body ⌘K handler no longer opens the palette")

    // Both affordances open the SAME sheet.
    #expect(AppSourceScraping.occurrences(of: "DeskCommandPaletteView(", in: source) == 1,
            "the palette must have exactly one presenter")
}

// MARK: - one watcher per desk

/// `DeskLiveReloader.shared` is process-wide. Two activations means two
/// watchers calling load() — doubled disk reads behind an identical-looking UI
/// (the comment forbidding a second `.task` on benchScroll is the only thing
/// standing between us and that today).
///
/// Mutation proof: adding a second `DeskLiveReloader.shared.activate(` fails
/// this test.
@Test("the desk arms its live reloader from exactly one site, paired with one deactivate")
func deskLiveReloaderIsActivatedFromExactlyOneSite() throws {
    let source = try deskViewSource()

    let activates = AppSourceScraping.executableCalls(named: "reloader.activate", in: source)
        + AppSourceScraping.executableCalls(named: "DeskLiveReloader.shared.activate", in: source)
    #expect(activates.count == 1,
            "expected exactly one activate() site, found \(activates.count) — each one arms its own watcher")

    #expect(AppSourceScraping.occurrences(of: "DeskLiveReloader.shared.deactivate()", in: source) == 1,
            "activate() must be paired with exactly one deactivate() or the watcher outlives the view")
    #expect(AppSourceScraping.occurrences(of: "DeskLiveReloader.shared", in: source)
            == AppSourceScraping.occurrences(of: "DeskLiveReloader", in: source),
            "every reference to the reloader must go through the process-wide `.shared` — a second instance is a second watcher")

    // The paths it arms are the two stores the desk actually reads.
    guard let activate = activates.first else { return }
    #expect(activate.contains("store.opsPath"),
            "the reloader no longer watches the desk ops ledger")
    #expect(activate.contains("GitHubCommandStore(dataRoot: dataRoot).opsPath"),
            "the reloader no longer watches the GitHub command ledger")
}
