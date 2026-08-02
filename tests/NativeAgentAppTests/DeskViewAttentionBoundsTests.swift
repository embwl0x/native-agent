import Foundation
import Testing
@testable import PersistenceCore
@testable import WorkshopExecution
@testable import NativeAgentApp

// DeskView's "Waiting on you" strip + the lane-honesty primitives behind the
// bench and GitHub Command sections.
//
// Three invariants are proven here without SwiftUI, because all three are pure
// data shaping:
//   1. BOUNDED — the strip's four op-log-sourced collections flatten into one
//      capped list, so the nested VStack inside the LazyVStack can't build an
//      unbounded number of rows on every render.
//   2. HONEST — nothing the cap hides is lost: the header total counts every
//      item, the GitHub roll-up header keeps its own count when its children are
//      cut, and the reveal restores the full list.
//   3. NEVER-EMPTY-ON-FAILURE — a failed lane read is `.unavailable(reason)`,
//      never `.rows([])`, so a broken store cannot render as a quiet bench.

// MARK: - fixtures

private func deskItem(
    _ handle: String,
    title: String,
    status: DeskStatus,
    blockedReason: String? = nil,
    waitingOn: String? = nil
) -> DeskItem {
    DeskItem(
        handle: handle,
        alias: handle,
        kind: .project,
        status: status,
        project: "p",
        title: title,
        openedAt: "2026-08-01T00:00:00.000000+00:00",
        updatedAt: "2026-08-01T00:00:00.000000+00:00",
        blockedReason: blockedReason,
        waitingOn: waitingOn)
}

private func ghBlockedItem(_ handle: String) -> DeskItem {
    deskItem(handle, title: "gh \(handle)", status: .blocked,
             blockedReason: DeskAttentionStrip.githubStampedBlockedReason)
}

private func approval(_ id: String) -> WorkshopExecution.WorkshopExecutionRecord {
    WorkshopExecutionRecord(
        id: id,
        title: "exec \(id)",
        objective: "o",
        createdAt: "2026-08-01T00:00:00.000000+00:00",
        status: "blocked_on_approval",
        plan: [],
        stepsCompleted: [],
        receiptsDir: "/tmp/r",
        triggerSource: "manual",
        trustRequired: "none",
        expectedOutputs: [],
        currentStepId: "",
        updatedAt: "2026-08-01T00:00:00.000000+00:00",
        result: .null,
        rerunCount: 0)
}

private func ghCommandItem(_ id: String, number: Int) -> GitHubCommandItem {
    GitHubCommandItem(
        itemId: id,
        repository: "user/repo",
        number: number,
        kind: .pullRequest,
        title: "pr \(number)",
        state: .needsUser,
        observation: nil,
        dispatchIntent: nil,
        dispatchReceipt: nil,
        workLog: [],
        blocker: nil,
        finalReceipt: nil,
        lastCallbackStatus: nil,
        lastSettledEventKey: nil,
        notificationClaims: [],
        notificationReceipts: [],
        verificationReadFailures: nil,
        createdAt: "2026-08-01T00:00:00.000000+00:00",
        updatedAt: "2026-08-01T00:00:00.000000+00:00")
}

// MARK: - bounded

@Test func attentionStripCapsAcrossAllFourSourcesCombined() {
    // Each source individually under the cap, four sources together way over —
    // this is exactly what a per-source cap would fail to bound.
    let lines = DeskAttentionStrip.lines(
        approvals: (0..<6).map { approval("e\($0)") },
        githubNeedsYou: (0..<6).map { ghCommandItem("g\($0)", number: $0) },
        otherAttention: (0..<6).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) },
        githubBlocked: (0..<6).map { ghBlockedItem("b\($0)") })

    let visible = DeskAttentionStrip.visible(lines, showingAll: false)
    #expect(visible.count == DeskAttentionStrip.visibleLineCap)
    #expect(lines.count > DeskAttentionStrip.visibleLineCap)
}

@Test func attentionStripBuildsNothingBeyondItsSourcesWhenSmall() {
    let lines = DeskAttentionStrip.lines(
        approvals: [approval("e0")],
        githubNeedsYou: [],
        otherAttention: [deskItem("i0", title: "t", status: .flag, waitingOn: "codex")],
        githubBlocked: [])
    #expect(lines.count == 2)
    #expect(DeskAttentionStrip.visible(lines, showingAll: false).count == 2)
    #expect(DeskAttentionStrip.hiddenItemCount(lines, showingAll: false) == 0)
}

// MARK: - honest

@Test func hiddenAttentionItemsAreStillCountedAndRevealable() {
    let blocked = (0..<25).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) }
    let lines = DeskAttentionStrip.lines(
        approvals: [], githubNeedsYou: [], otherAttention: blocked, githubBlocked: [])

    // The header total is the honest count, not the rendered count.
    #expect(DeskAttentionStrip.itemCount(lines) == 25)
    #expect(DeskAttentionStrip.hiddenItemCount(lines, showingAll: false)
            == 25 - DeskAttentionStrip.visibleLineCap)
    // And the reveal gets every one of them back.
    #expect(DeskAttentionStrip.visible(lines, showingAll: true).count == 25)
    #expect(DeskAttentionStrip.hiddenItemCount(lines, showingAll: true) == 0)
}

@Test func nothingVanishesFromTheStrip() {
    let lines = DeskAttentionStrip.lines(
        approvals: (0..<3).map { approval("e\($0)") },
        githubNeedsYou: (0..<3).map { ghCommandItem("g\($0)", number: $0) },
        otherAttention: (0..<3).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) },
        githubBlocked: (0..<3).map { ghBlockedItem("b\($0)") })

    // Every source is represented, ids are unique, and expanding is a superset
    // of collapsing — a blocked item can be scrolled past, never erased.
    #expect(Set(lines.map(\.id)).count == lines.count)
    #expect(DeskAttentionStrip.itemCount(lines) == 12)
    let collapsed = Set(DeskAttentionStrip.visible(lines, showingAll: false).map(\.id))
    let expanded = Set(DeskAttentionStrip.visible(lines, showingAll: true).map(\.id))
    #expect(collapsed.isSubset(of: expanded))
    #expect(expanded == Set(lines.map(\.id)))
}

@Test func attentionStripOrdersByWhoIsActuallyWaitedOn() {
    let lines = DeskAttentionStrip.lines(
        approvals: [approval("e0")],
        githubNeedsYou: [ghCommandItem("g0", number: 7)],
        otherAttention: [deskItem("i0", title: "t", status: .blocked)],
        githubBlocked: [ghBlockedItem("b0")])

    #expect(lines.map(\.id) == [
        "approval:e0", "gh:g0", "item:i0", "ghblocked:header", "ghblocked:b0",
    ])
    // The GitHub roll-up is LAST: those items are waiting on GitHub, not User.
    #expect(lines[3].shape == .groupHeader)
    #expect(lines[4].shape == .groupChild)
}

@Test func githubRollupHeaderCarriesItsCountEvenWhenChildrenAreCut() {
    let lines = DeskAttentionStrip.lines(
        approvals: [], githubNeedsYou: [], otherAttention: [],
        githubBlocked: (0..<40).map { ghBlockedItem("b\($0)") })
    let visible = DeskAttentionStrip.visible(lines, showingAll: false)
    let header = try! #require(visible.first { $0.shape == .groupHeader })
    #expect(header.text.contains("· 40"))
    // ...and the roll-up header is chrome, so it never inflates the item total.
    #expect(DeskAttentionStrip.itemCount(lines) == 40)
}

@Test func onlyUserBlockingRowsAreEmphasized() {
    // The strip's title claims these are waiting on HIM; only the rows that are
    // actually his get the weight.
    let lines = DeskAttentionStrip.lines(
        approvals: [approval("e0")],
        githubNeedsYou: [ghCommandItem("g0", number: 7)],
        otherAttention: [deskItem("i0", title: "t", status: .blocked)],
        githubBlocked: [ghBlockedItem("b0")])
    #expect(lines.filter(\.needsUserDirectly).map(\.id) == ["approval:e0", "gh:g0"])
}

@Test func revealLabelNamesWhatIsHidden() {
    // Ordinary case: the cap eats the tail, and the tail is never User's.
    let tail = DeskAttentionStrip.lines(
        approvals: [approval("e0")], githubNeedsYou: [],
        otherAttention: (0..<20).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) },
        githubBlocked: [])
    #expect(DeskAttentionStrip.hiddenNeedsUserCount(tail, showingAll: false) == 0)
    #expect(DeskAttentionStrip.revealLabel(tail, showingAll: false)
            == "13 more waiting — show all 21")
    #expect(DeskAttentionStrip.revealLabel(tail, showingAll: true) == "Show fewer")

    // More than a capful of approvals: the collapsed strip must SAY that some of
    // what it hid is User's, not just "and some more".
    let userHeavy = DeskAttentionStrip.lines(
        approvals: (0..<12).map { approval("e\($0)") },
        githubNeedsYou: [], otherAttention: [], githubBlocked: [])
    #expect(DeskAttentionStrip.hiddenNeedsUserCount(userHeavy, showingAll: false) == 4)
    #expect(DeskAttentionStrip.revealLabel(userHeavy, showingAll: false)
            == "4 more waiting — show all 12 · 4 need your call")
}

@Test func onlyTheStampedGitHubReasonRollsUp() {
    // A hand-written reason that merely mentions GitHub keeps its own line.
    let stamped = ghBlockedItem("b0")
    let handWritten = deskItem("b1", title: "t", status: .blocked,
                               blockedReason: "waiting on a GitHub answer from User")
    #expect(DeskAttentionStrip.isGitHubStampedBlock(stamped))
    #expect(!DeskAttentionStrip.isGitHubStampedBlock(handWritten))
}

@Test func attentionLineTextKeepsTheStatusCriticalReason() {
    let lines = DeskAttentionStrip.lines(
        approvals: [],
        githubNeedsYou: [],
        otherAttention: [
            deskItem("i0", title: "ship it", status: .blocked, blockedReason: "no signing key"),
            deskItem("i1", title: "review", status: .flag, waitingOn: "Agent"),
        ],
        githubBlocked: [])
    #expect(lines[0].text == "ship it — no signing key")
    #expect(lines[1].text == "review — waiting on Agent")
}

// MARK: - NEEDS_FIX 2: the strip is reload-stable

/// Nine approvals in the SAME createdAt bucket, fed in two different orders —
/// exactly what directory enumeration + a non-stable sort produce across
/// reloads. Without a tie-breaker a different approval becomes the hidden 9th
/// each time and the strip flickers with no state change behind it.
@Test func equalTimestampApprovalsKeepTheSameHiddenTailAcrossReloads() {
    let ids = (0..<9).map { "e\($0)" }
    let forward = ids.map { approval($0) }
    let reversed = Array(forward.reversed())
    let shuffled = [forward[4], forward[0], forward[8], forward[2],
                    forward[6], forward[1], forward[7], forward[3], forward[5]]

    let a = DeskAttentionStrip.plan(approvals: forward, githubNeedsYou: [],
                                    otherAttention: [], githubBlocked: [], showingAll: false)
    let b = DeskAttentionStrip.plan(approvals: reversed, githubNeedsYou: [],
                                    otherAttention: [], githubBlocked: [], showingAll: false)
    let c = DeskAttentionStrip.plan(approvals: shuffled, githubNeedsYou: [],
                                    otherAttention: [], githubBlocked: [], showingAll: false)

    #expect(a.visible.map(\.id) == b.visible.map(\.id))
    #expect(a.visible.map(\.id) == c.visible.map(\.id))
    // The tie-breaker is id asc, so the hidden 9th is deterministic: e8.
    #expect(a.visible.map(\.id) == ids.prefix(8).map { "approval:\($0)" })
    #expect(a.hiddenItems == 1)
}

@Test func newerApprovalsStillOutrankOlderOnesBeforeTheTieBreaker() {
    let old = WorkshopExecutionRecord(
        id: "a-old", title: "old", objective: "o",
        createdAt: "2026-07-01T00:00:00.000000+00:00", status: "blocked_on_approval",
        plan: [], stepsCompleted: [], receiptsDir: "/tmp/r", triggerSource: "manual",
        trustRequired: "none", expectedOutputs: [], currentStepId: "",
        updatedAt: "2026-07-01T00:00:00.000000+00:00", result: .null, rerunCount: 0)
    let new = approval("z-new")  // createdAt 2026-08-01
    let lines = DeskAttentionStrip.lines(
        approvals: [old, new], githubNeedsYou: [], otherAttention: [], githubBlocked: [])
    #expect(lines.map(\.id) == ["approval:z-new", "approval:a-old"])
}

@Test func everyAttentionBucketIsOrderStableUnderInputReshuffle() {
    let approvals = (0..<4).map { approval("e\($0)") }
    let gh = (0..<4).map { ghCommandItem("g\($0)", number: $0) }
    let other = (0..<4).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) }
    let blocked = (0..<4).map { ghBlockedItem("b\($0)") }

    let straight = DeskAttentionStrip.lines(
        approvals: approvals, githubNeedsYou: gh,
        otherAttention: other, githubBlocked: blocked)
    let flipped = DeskAttentionStrip.lines(
        approvals: approvals.reversed(), githubNeedsYou: gh.reversed(),
        otherAttention: other.reversed(), githubBlocked: blocked.reversed())
    #expect(straight.map(\.id) == flipped.map(\.id))
    // All four buckets share one timestamp, so all four fall to their id
    // tie-breakers — the whole strip is a function of the data.
    #expect(straight.map(\.id) == [
        "approval:e0", "approval:e1", "approval:e2", "approval:e3",
        "gh:g0", "gh:g1", "gh:g2", "gh:g3",
        "item:i0", "item:i1", "item:i2", "item:i3",
        "ghblocked:header",
        "ghblocked:b0", "ghblocked:b1", "ghblocked:b2", "ghblocked:b3",
    ])
}

// MARK: - NIT 3: hidden lines are never CONSTRUCTED

/// The cap now bounds construction, not just rendering. The invariant that
/// makes that safe: a limited build is byte-identical to a prefix of the full
/// build, in every bucket-population shape (including the roll-up header
/// landing exactly on the boundary).
@Test func limitedBuildEqualsPrefixOfTheFullBuild() {
    let shapes: [(Int, Int, Int, Int)] = [
        (0, 0, 0, 0), (12, 0, 0, 0), (0, 0, 0, 12), (3, 3, 3, 3),
        (8, 0, 0, 5), (7, 1, 0, 5), (2, 2, 2, 9), (0, 0, 8, 4),
    ]
    for (a, g, o, b) in shapes {
        let approvals = (0..<a).map { approval("e\($0)") }
        let ghItems = (0..<g).map { ghCommandItem("g\($0)", number: $0) }
        let other = (0..<o).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) }
        let blocked = (0..<b).map { ghBlockedItem("b\($0)") }
        let full = DeskAttentionStrip.lines(
            approvals: approvals, githubNeedsYou: ghItems,
            otherAttention: other, githubBlocked: blocked)
        for limit in 0...(full.count + 2) {
            let bounded = DeskAttentionStrip.lines(
                approvals: approvals, githubNeedsYou: ghItems,
                otherAttention: other, githubBlocked: blocked, limit: limit)
            #expect(bounded == Array(full.prefix(limit)),
                    "shape \(a),\(g),\(o),\(b) limit \(limit)")
        }
    }
}

/// ...and the plan's COUNTS still describe the full strip even though only the
/// visible lines were built — the header total, the hidden count, and "N need
/// your call" are the honesty contract, and they now come from arithmetic.
@Test func planCountsMatchTheFullBuildWithoutBuildingIt() {
    let shapes: [(Int, Int, Int, Int)] = [
        (12, 0, 0, 0), (3, 3, 3, 3), (0, 0, 0, 40), (2, 2, 20, 6), (1, 0, 1, 0),
    ]
    for (a, g, o, b) in shapes {
        let approvals = (0..<a).map { approval("e\($0)") }
        let ghItems = (0..<g).map { ghCommandItem("g\($0)", number: $0) }
        let other = (0..<o).map { deskItem("i\($0)", title: "t\($0)", status: .blocked) }
        let blocked = (0..<b).map { ghBlockedItem("b\($0)") }
        let full = DeskAttentionStrip.lines(
            approvals: approvals, githubNeedsYou: ghItems,
            otherAttention: other, githubBlocked: blocked)
        for showingAll in [false, true] {
            let plan = DeskAttentionStrip.plan(
                approvals: approvals, githubNeedsYou: ghItems,
                otherAttention: other, githubBlocked: blocked, showingAll: showingAll)
            #expect(plan.visible == DeskAttentionStrip.visible(full, showingAll: showingAll))
            #expect(plan.totalItems == DeskAttentionStrip.itemCount(full))
            #expect(plan.hiddenItems
                    == DeskAttentionStrip.hiddenItemCount(full, showingAll: showingAll))
            #expect(plan.hiddenNeedsUser
                    == DeskAttentionStrip.hiddenNeedsUserCount(full, showingAll: showingAll))
            #expect(plan.revealLabel(showingAll: showingAll)
                    == DeskAttentionStrip.revealLabel(full, showingAll: showingAll))
        }
        // Collapsed builds at most a capful of lines, no matter the source size.
        let collapsed = DeskAttentionStrip.plan(
            approvals: approvals, githubNeedsYou: ghItems,
            otherAttention: other, githubBlocked: blocked, showingAll: false)
        #expect(collapsed.visible.count <= DeskAttentionStrip.visibleLineCap)
    }
}

// MARK: - lane honesty (never render a failure as emptiness)

@Test func laneClassifyTreatsSilentZeroAsUnavailable() {
    // Zero rows while records still sit on disk = a failing reader, not a
    // quiet bench. listAll() cannot throw, so this is the only honest signal.
    let lane = DeskLaneState<Int>.classify(
        rows: [], probe: .records(4), noun: "execution record(s)")
    #expect(lane.items.isEmpty)
    let reason = try! #require(lane.unavailableReason)
    #expect(reason.contains("4 execution record(s)"))
}

@Test func laneClassifyKeepsAnHonestEmptyEmpty() {
    let readableAndEmpty = DeskLaneState<Int>.classify(
        rows: [], probe: .records(0), noun: "execution record(s)")
    #expect(readableAndEmpty.unavailableReason == nil)
    #expect(readableAndEmpty.items.isEmpty)

    // No store on disk at all is equally honest emptiness.
    let noStore = DeskLaneState<Int>.classify(
        rows: [], probe: .empty, noun: "execution record(s)")
    #expect(noStore.unavailableReason == nil)
    #expect(noStore.items.isEmpty)
}

/// BLOCKING 1(a) — the false negative. An UNREADABLE root is the exact
/// corrupt-store case the cross-check exists for, and the old bare-count probe
/// returned 0 for it, so `rows == [] && count == 0` rendered as a clear bench.
@Test func laneClassifyReportsAnUnreadableRootInsteadOfAnEmptyBench() {
    let lane = DeskLaneState<Int>.classify(
        rows: [], probe: .unreadable("Permission denied"), noun: "execution record(s)")
    #expect(lane.items.isEmpty)
    let reason = try! #require(lane.unavailableReason)
    #expect(reason.contains("execution record(s)"))
    #expect(reason.contains("Permission denied"))
}

@Test func laneClassifyBoundsTheUnreadableReason() {
    let lane = DeskLaneState<Int>.classify(
        rows: [], probe: .unreadable(String(repeating: "x", count: 4000)), noun: "n")
    #expect(try! #require(lane.unavailableReason).count == DeskLaneState<Int>.maxReasonChars)
}

@Test func laneClassifyPassesRowsThroughEvenWithDiskSkew() {
    // Rows present is rows present — a stale/racing disk count must not turn a
    // working lane into an error.
    let lane = DeskLaneState<Int>.classify(rows: [1, 2], probe: .records(9), noun: "n")
    #expect(lane.items == [1, 2])
    #expect(lane.unavailableReason == nil)
}

private struct LaneTestError: Error, CustomStringConvertible {
    let description: String
}

@Test func laneFailedCarriesABoundedReason() {
    let lane = DeskLaneState<Int>.failed(
        LaneTestError(description: String(repeating: "x", count: 4000)))
    let reason = try! #require(lane.unavailableReason)
    #expect(reason.count == DeskLaneState<Int>.maxReasonChars)
    #expect(lane.items.isEmpty)
}

// MARK: - BLOCKING 1: the probe is TRI-state (missing / unreadable / readable)

private func makeExecutionDir(_ root: URL, _ id: String, mission: Bool) throws {
    let dir = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if mission {
        try Data(#"{"id":"\#(id)"}"#.utf8)
            .write(to: dir.appendingPathComponent("mission.json"))
    }
}

/// State 1 — the root does not exist. Nothing written yet: honest zero.
@Test func executionProbeCallsAMissingRootEmpty() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskViewLaneTests-\(UUID().uuidString)", isDirectory: true)
    #expect(DeskView.probeExecutionRecords(root) == .empty)
}

/// State 2 — the root exists but will not open. This is the case the whole
/// cross-check exists for, and the pre-fix bare count reported it as 0, i.e.
/// as a genuinely empty bench.
@Test func executionProbeReportsAnUnreadableRootAsUnreadableNotZero() throws {
    guard geteuid() != 0 else { return }  // root ignores the mode bits
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("DeskViewLaneTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try makeExecutionDir(root, "e1", mission: true)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? fm.removeItem(at: root)
    }

    let probe = DeskView.probeExecutionRecords(root)
    // Not .empty and not .records(0) — those both render as a clear bench.
    #expect(probe != .empty)
    #expect(probe != .records(0))
    guard case .unreadable = probe else {
        Issue.record("expected .unreadable, got \(probe)")
        return
    }
    // ...and it reaches the surface as an unavailable lane, never emptiness.
    let lane = DeskLaneState<Int>.classify(rows: [], probe: probe, noun: "execution record(s)")
    #expect(lane.unavailableReason != nil)
}

/// State 3 — readable: count only dirs that actually HOLD a record. The runner
/// writes `<root>/<id>/mission.json`; a reservation or cancelled dir cleanly
/// has none, and counting those (BLOCKING 1(b)) put a bogus "unavailable"
/// banner over a healthy empty bench.
@Test func executionProbeCountsOnlyDirsHoldingARecord() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("DeskViewLaneTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    #expect(DeskView.probeExecutionRecords(root) == .records(0))

    try makeExecutionDir(root, "e1", mission: true)
    try makeExecutionDir(root, "e2", mission: true)
    // In-flight admission reservation: dir + .reserved, mission.json not landed.
    try makeExecutionDir(root, "e3-reserved", mission: false)
    try Data("".utf8).write(
        to: root.appendingPathComponent("e3-reserved/.reserved"))
    // Cancelled-before-write leftover: dir with nothing in it at all.
    try makeExecutionDir(root, "e4-cancelled", mission: false)
    // Runner bookkeeping + stray file are not records.
    try fm.createDirectory(
        at: root.appendingPathComponent(".admission", isDirectory: true),
        withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("stray.json"))

    #expect(DeskView.probeExecutionRecords(root) == .records(2))

    // And an EMPTY bench of nothing but reservations stays honestly empty.
    for id in ["e1", "e2"] {
        try fm.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }
    let probe = DeskView.probeExecutionRecords(root)
    #expect(probe == .records(0))
    #expect(DeskLaneState<Int>.classify(
        rows: [], probe: probe, noun: "execution record(s)").unavailableReason == nil)
}

/// A record dir whose contents can't be listed is malformed, not absent — it
/// still counts, because "unreadable" must never collapse into "empty".
@Test func executionProbeCountsAnUnreadableRecordDir() throws {
    guard geteuid() != 0 else { return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("DeskViewLaneTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try makeExecutionDir(root, "e1", mission: true)
    let sealed = root.appendingPathComponent("e2", isDirectory: true)
    try makeExecutionDir(root, "e2", mission: true)
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path)
        try? fm.removeItem(at: root)
    }
    #expect(DeskView.probeExecutionRecords(root) == .records(2))
}

// MARK: - M12: only the newest load may publish

@Test func loadGenerationGateRejectsTheSlowLoserOfARace() {
    // Mirrors load()'s exact usage: each call takes a token BEFORE its detached
    // read, and checks it after. A slow first load that lands after a fast
    // second one is rejected wholesale, so it can't stomp fresh items.
    var gate = LatestAsyncRequestGate()
    let slow = gate.begin()
    let fast = gate.begin()
    #expect(!gate.accepts(slow))
    #expect(gate.accepts(fast))
}
