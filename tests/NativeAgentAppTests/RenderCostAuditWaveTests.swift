import Foundation
import Observation
import Testing
import NativeAgentShared
@testable import NativeAgentApp

// Covers the render-cost audit wave (lane A4 findings F11, F14, F4).
//
// The through-line for all three: Swift Observation fires on *write*, not on
// *change*, so a refresh that fetches byte-identical data still invalidated
// every view that read the field. These tests pin the "identical payload ⇒ no
// write ⇒ no invalidation" property, which is the whole point of the wave —
// a future refactor that drops an equality gate has to fail here, not in a
// profiler six months later.

/// `withObservationTracking`'s onChange is an escaping @Sendable closure, so it
/// cannot capture a local `var`. This box carries the flag out. (Same shape as
/// the one in ChatComposerAndPanelStalenessTests.)
private final class FireFlag: @unchecked Sendable {
    var fired = false
}

// MARK: - F11: refreshAll's equality gate

@MainActor
@Test
func setIfChanged_identicalValue_performsNoObservableWrite() {
    let model = AppModel()
    model.statusText = "Native runtime online"

    let flag = FireFlag()
    withObservationTracking {
        _ = model.statusText
    } onChange: {
        flag.fired = true
    }

    model.setIfChanged(\.statusText, "Native runtime online")

    #expect(flag.fired == false)
    #expect(model.statusText == "Native runtime online")
}

@MainActor
@Test
func setIfChanged_differentValue_stillWritesAndInvalidates() {
    let model = AppModel()
    model.statusText = "Native runtime online"

    let flag = FireFlag()
    withObservationTracking {
        _ = model.statusText
    } onChange: {
        flag.fired = true
    }

    model.setIfChanged(\.statusText, "Native runtime unavailable")

    #expect(flag.fired == true)
    #expect(model.statusText == "Native runtime unavailable")
}

/// The collection payloads are what `refreshAll` actually re-assigns ~60 times
/// a pass, and the ones the root `ContentView` fans out over. An equal array
/// must not invalidate; a changed one must.
/// Decoded rather than constructed: this is exactly how `refreshAll` produces
/// the value it assigns, so an "unchanged backend" really does hand the model a
/// brand-new array whose elements compare equal.
private func decodedActivity(_ json: String) throws -> [ActivityEvent] {
    try JSONDecoder().decode([ActivityEvent].self, from: Data(json.utf8))
}

private let activityFixture = """
[{"id":"e1","kind":"chat","title":"one","status":"done","createdAt":"2026-08-05T00:00:00Z"},
 {"id":"e2","kind":"chat","title":"two","status":"done","createdAt":"2026-08-05T00:00:01Z"}]
"""

@MainActor
@Test
func setIfChanged_identicalCollectionPayload_performsNoObservableWrite() throws {
    let model = AppModel()
    model.activityEvents = try decodedActivity(activityFixture)

    let flag = FireFlag()
    withObservationTracking {
        _ = model.activityEvents
    } onChange: {
        flag.fired = true
    }

    // Re-decode of an unchanged backing file: a different array instance
    // holding equal elements.
    model.setIfChanged(\.activityEvents, try decodedActivity(activityFixture))

    #expect(flag.fired == false)
    #expect(model.activityEvents.count == 2)
}

@MainActor
@Test
func setIfChanged_changedCollectionPayload_invalidates() throws {
    let model = AppModel()
    model.activityEvents = try decodedActivity(activityFixture)

    let flag = FireFlag()
    withObservationTracking {
        _ = model.activityEvents
    } onChange: {
        flag.fired = true
    }

    model.setIfChanged(\.activityEvents, try decodedActivity("""
    [{"id":"e1","kind":"chat","title":"CHANGED","status":"done","createdAt":"2026-08-05T00:00:00Z"},
     {"id":"e2","kind":"chat","title":"two","status":"done","createdAt":"2026-08-05T00:00:01Z"}]
    """))

    #expect(flag.fired == true)
    #expect(model.activityEvents.first?.title == "CHANGED")
}

// MARK: - F14: PanelRefreshStatus no longer guarantees a redraw

@MainActor
@Test
func staleFlagOnlyStatus_firstEverAttempt_isStored() {
    let now = Date()
    let stored = AppModel.staleFlagOnlyStatusToStore(
        previous: nil, failedEndpoints: [], at: now
    )
    // nil vs non-nil is itself a rendered distinction (loading vs loaded).
    #expect(stored != nil)
    #expect(stored?.isStale == false)
    #expect(stored?.lastSuccessAt == now)
}

@MainActor
@Test
func staleFlagOnlyStatus_idlePollWithSameOutcome_needsNoWrite() {
    let first = Date(timeIntervalSince1970: 1_000_000)
    let previous = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: first)

    // This is the case A4 flagged: a clean poll on an unchanged system. Before
    // the fix it produced a struct that could never equal its predecessor
    // (fresh `lastAttemptAt`), so it redrew every reader of
    // `sidebarActivityRefreshStatus` — including the root ContentView.
    let stored = AppModel.staleFlagOnlyStatusToStore(
        previous: previous,
        failedEndpoints: [],
        at: first.addingTimeInterval(600)
    )
    #expect(stored == nil)
}

@MainActor
@Test
func staleFlagOnlyStatus_persistentFailureWithSameEndpoints_needsNoWrite() {
    let first = Date(timeIntervalSince1970: 1_000_000)
    let previous = AppModel.nextRefreshStatus(
        previous: nil, failedEndpoints: ["approvals"], at: first
    )
    let stored = AppModel.staleFlagOnlyStatusToStore(
        previous: previous,
        failedEndpoints: ["approvals"],
        at: first.addingTimeInterval(10)
    )
    #expect(stored == nil)
}

@MainActor
@Test
func staleFlagOnlyStatus_outcomeChange_isAlwaysStored() {
    let first = Date(timeIntervalSince1970: 1_000_000)
    let clean = AppModel.nextRefreshStatus(previous: nil, failedEndpoints: [], at: first)
    let later = first.addingTimeInterval(10)

    // clean -> failed must land: `isStale` is what ContentView renders.
    let wentStale = AppModel.staleFlagOnlyStatusToStore(
        previous: clean, failedEndpoints: ["inbox"], at: later
    )
    #expect(wentStale?.isStale == true)
    // Last-good time is carried forward, exactly as `nextRefreshStatus` does.
    #expect(wentStale?.lastSuccessAt == first)

    // failed -> recovered must land too.
    let recovered = AppModel.staleFlagOnlyStatusToStore(
        previous: wentStale, failedEndpoints: [], at: later.addingTimeInterval(10)
    )
    #expect(recovered?.isStale == false)

    // A *different* set of failures is a different outcome even though both
    // are stale.
    let differentFailure = AppModel.staleFlagOnlyStatusToStore(
        previous: wentStale, failedEndpoints: ["approvals"], at: later.addingTimeInterval(20)
    )
    #expect(differentFailure?.failedEndpoints == ["approvals"])
}

/// The coalescing helper is only sound for a status whose sole rendered
/// projection is `isStale`. `panelRefreshStatus` is NOT such a status —
/// `panelStaleNotice(for:)` renders an age computed from both timestamps — so
/// `recordPanelRefresh` must keep writing unconditionally. This test fails if
/// someone "optimizes" it with the same helper: a frozen `lastAttemptAt` stops
/// the staleness notice from aging.
@MainActor
@Test
func recordPanelRefresh_keepsAdvancingTheAgeItRenders() {
    let model = AppModel()
    let start = Date()
    model.recordPanelRefresh(.chat, failedEndpoints: [])
    let firstAttempt = model.panelRefreshStatus[.chat]?.lastAttemptAt
    #expect(firstAttempt != nil)
    #expect(firstAttempt.map { $0.timeIntervalSince(start) >= 0 } == true)

    model.recordPanelRefresh(.chat, failedEndpoints: ["trust policy"])
    let secondAttempt = model.panelRefreshStatus[.chat]?.lastAttemptAt
    #expect(secondAttempt != nil)
    #expect((secondAttempt ?? .distantPast) >= (firstAttempt ?? .distantFuture))
    // And the notice it feeds is still produced.
    #expect(model.panelStaleNotice(for: .chat) != nil)
}

/// The contract that makes the F14 coalescing sound, enforced against the
/// source rather than trusted to a comment: `sidebarActivityRefreshStatus` may
/// only ever be projected through `isStale`. The moment a view renders its
/// `lastAttemptAt` or `lastSuccessAt`, coalescing freezes a value that is on
/// screen — so this test has to fail before that ships.
@Test
func sidebarActivityRefreshStatus_isOnlyEverReadThroughIsStale() throws {
    let root = try AppSourceScraping.appSourcesRoot()
    var offenders: [String] = []
    for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
        // The declaration and the single writer are not reads.
        if file.hasSuffix("AppModel.swift") || file.hasSuffix("AppModel+ChatSessions.swift") { continue }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("sidebarActivityRefreshStatus") else { continue }
            let projected = line
                .replacingOccurrences(of: "sidebarActivityRefreshStatus?.isStale", with: "")
                .replacingOccurrences(of: "sidebarActivityRefreshStatus.isStale", with: "")
            if projected.contains("sidebarActivityRefreshStatus") {
                offenders.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(offenders.isEmpty, "sidebarActivityRefreshStatus must only be read as .isStale — see AppModel+ChatSessions.staleFlagOnlyStatusToStore. Offenders: \(offenders)")
}

// MARK: - F4: digest selection is unchanged by the move off the MainActor

@Test
func newestDigest_picksTheLatestModification() {
    let a = URL(fileURLWithPath: "/tmp/digests/2026-08-01.md")
    let b = URL(fileURLWithPath: "/tmp/digests/2026-08-05.md")
    let c = URL(fileURLWithPath: "/tmp/digests/2026-07-30.md")
    let picked = SelfImprovementView.newestDigest([
        (a, Date(timeIntervalSince1970: 100)),
        (b, Date(timeIntervalSince1970: 300)),
        (c, Date(timeIntervalSince1970: 200)),
    ])
    #expect(picked == b)
}

@Test
func newestDigest_emptyInputIsNil() {
    #expect(SelfImprovementView.newestDigest([]) == nil)
}

/// `max(by:)` only replaces on a strict increase, so ties keep the *earlier*
/// element in enumeration order. The pre-wave inline `max(by:)` behaved this
/// way; pinning it here so the stat-once rewrite can't silently flip which
/// digest renders when two files share a modification date.
@Test
func newestDigest_tiesKeepTheEarlierEnumeratedFile() {
    let first = URL(fileURLWithPath: "/tmp/digests/first.md")
    let second = URL(fileURLWithPath: "/tmp/digests/second.md")
    let sameInstant = Date(timeIntervalSince1970: 500)
    #expect(SelfImprovementView.newestDigest([
        (first, sameInstant),
        (second, sameInstant),
    ]) == first)
}
