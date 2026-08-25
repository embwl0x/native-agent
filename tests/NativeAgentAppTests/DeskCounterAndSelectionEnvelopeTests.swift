import Foundation
import Testing
@testable import PersistenceCore
@testable import WorkshopExecution
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`. Three envelope properties the desk's
// numbers and its caret depend on, proven on the SHARED functions the view
// renders from (never re-implemented here).
//
// Ledger rows covered:
//   desk.counters.needsYou     — wrong value: "Needs you 5" over a section
//                                listing 3
//   desk.attention.revealButton — stale UI: a reveal offered when nothing is
//                                hidden
//   desk.select.terminalGuard   — dead control: two definitions of "selectable"
//                                (the click path re-derives what the arrow path
//                                computes), so a row can be arrow-reachable and
//                                click-inert, or selected and never rendered

// MARK: - fixtures

private func deskItem(
    _ alias: String,
    status: DeskStatus = .now,
    kind: DeskKind = .plan,
    project: String = "p",
    origin: DeskOrigin = .owner,
    pursuit: Pursuit? = nil,
    blockedReason: String? = nil
) -> DeskItem {
    DeskItem(
        handle: "desk_\(alias)",
        alias: alias,
        kind: kind,
        status: status,
        project: project,
        title: "t \(alias)",
        openedAt: "2026-08-01T00:00:00.000000+00:00",
        updatedAt: "2026-08-01T00:00:00.000000+00:00",
        blockedReason: blockedReason,
        origin: origin,
        pursuit: pursuit)
}

private func stampedGitHubBlocked(_ alias: String) -> DeskItem {
    deskItem(alias, status: .blocked,
             blockedReason: DeskAttentionStrip.githubStampedBlockedReason)
}

private func approvalRecord(_ id: String) -> WorkshopExecution.WorkshopExecutionRecord {
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

private func ghItem(_ id: String, number: Int) -> GitHubCommandItem {
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

private func pursuitPayload() -> Pursuit {
    Pursuit(why: "w", evidence: PromotionDossier(citations: []),
            doneLooksLike: "d", abandonCondition: "a")
}

// MARK: - the "Needs you" counter can never disagree with the strip

/// `needsYouCount` is `approvalExecutions + attentionItems + needsUserGitHubItems`
/// (DeskView.swift), while the section it scrolls to is built by
/// `DeskAttentionStrip.plan` from FOUR collections — approvals, needs-User
/// GitHub, non-GitHub attention, and GitHub-stamped-blocked attention.
///
/// The two agree only because `isGitHubStampedBlock` PARTITIONS the attention
/// items: every blocked/flagged row lands in exactly one of the strip's two
/// desk-item buckets, so their sizes always re-add to `attentionItems.count`.
/// That partition is the whole contract. Break it (make the predicate drop a
/// row, or make one bucket filter something extra) and the counter says 5 while
/// the section lists 3, with nothing failing.
@Test("the needs-you counter re-adds to exactly what the attention section builds")
func needsYouCounterCanNeverDisagreeWithTheAttentionStrip() {
    // A mix that exercises every bucket, including rows that are blocked for a
    // hand-written reason (which must NOT roll up under GitHub).
    let attention: [DeskItem] = [
        deskItem("1", status: .blocked, blockedReason: "waiting on a decision"),
        deskItem("2", status: .flag),
        stampedGitHubBlocked("3"),
        stampedGitHubBlocked("4"),
        deskItem("5", status: .blocked),
        deskItem("6", status: .flag, kind: .gh, project: "acme"),
    ]
    let approvals = (0..<3).map { approvalRecord("e\($0)") }
    let ghNeedsYou = (0..<2).map { ghItem("g\($0)", number: $0) }

    // The view's split, taken from the SAME predicate the view calls.
    let ghBlocked = attention.filter(DeskAttentionStrip.isGitHubStampedBlock)
    let nonGh = attention.filter { !DeskAttentionStrip.isGitHubStampedBlock($0) }

    // 1. The partition itself: disjoint AND exhaustive.
    #expect(ghBlocked.count + nonGh.count == attention.count)
    #expect(Set(ghBlocked.map(\.handle)).isDisjoint(with: Set(nonGh.map(\.handle))))

    // 2. Therefore the counter expression equals the section's honest total, in
    //    both the collapsed and the revealed state.
    let needsYouCount = approvals.count + attention.count + ghNeedsYou.count
    for showingAll in [false, true] {
        let plan = DeskAttentionStrip.plan(
            approvals: approvals,
            githubNeedsYou: ghNeedsYou,
            otherAttention: nonGh,
            githubBlocked: ghBlocked,
            showingAll: showingAll)
        #expect(plan.totalItems == needsYouCount,
                "counter (\(needsYouCount)) disagrees with the section it scrolls to (\(plan.totalItems)), showingAll=\(showingAll)")
    }

    // 3. And the counter is nonzero exactly when the section has something in
    //    it — a tinted counter over an empty section (or the reverse) is the
    //    visible half of the same bug.
    let empty = DeskAttentionStrip.plan(
        approvals: [], githubNeedsYou: [], otherAttention: [], githubBlocked: [],
        showingAll: false)
    #expect(empty.totalItems == 0)
    #expect(empty.isEmpty)
}

// MARK: - the reveal is offered only when it changes the screen

/// The reveal button renders on `strip.hiddenItems > 0 || showAllAttention`,
/// and `showAllAttention` is view-local `@State` that survives a live reload.
/// The honest envelope underneath it: `hiddenItems` must be zero whenever
/// everything already fits, and the label must never promise rows that are
/// already on screen.
@Test("the attention reveal never claims to hide rows that are already visible")
func attentionRevealIsOfferedOnlyWhenItChangesTheScreen() {
    let cap = DeskAttentionStrip.visibleLineCap

    // Under the cap: nothing is hidden in EITHER state, so a reveal control
    // would be a button that changes nothing.
    let small = (0..<(cap - 3)).map { deskItem("s\($0)", status: .blocked, blockedReason: "r\($0)") }
    for showingAll in [false, true] {
        let plan = DeskAttentionStrip.plan(
            approvals: [], githubNeedsYou: [], otherAttention: small, githubBlocked: [],
            showingAll: showingAll)
        #expect(plan.hiddenItems == 0,
                "a strip under the cap reports \(plan.hiddenItems) hidden with showingAll=\(showingAll)")
        #expect(plan.visible.count == plan.totalItems)
        #expect(plan.hiddenNeedsUser == 0)
    }

    // Over the cap: collapsed hides a positive number; revealed hides none, and
    // the visible list grows to the full set.
    let many = (0..<(cap + 7)).map { deskItem("m\($0)", status: .blocked, blockedReason: "r\($0)") }
    let collapsed = DeskAttentionStrip.plan(
        approvals: [], githubNeedsYou: [], otherAttention: many, githubBlocked: [],
        showingAll: false)
    let revealed = DeskAttentionStrip.plan(
        approvals: [], githubNeedsYou: [], otherAttention: many, githubBlocked: [],
        showingAll: true)
    #expect(collapsed.hiddenItems == many.count - cap)
    #expect(collapsed.visible.count == cap)
    #expect(revealed.hiddenItems == 0)
    #expect(revealed.visible.count == many.count)
    #expect(revealed.totalItems == collapsed.totalItems)

    // The collapsed label must name what it hides; the revealed one must not
    // claim anything is still hidden.
    #expect(collapsed.revealLabel(showingAll: false).contains("\(collapsed.hiddenItems) more waiting"))
    let revealedLabel = revealed.revealLabel(showingAll: true)
    #expect(!revealedLabel.contains("more waiting"),
            "the revealed label still advertises hidden rows: \(revealedLabel)")
}

// MARK: - one definition of "selectable"

/// The caret has two doors: arrow keys walk `selectableHandles`, while a click
/// or a palette Enter goes through `select(_:)`, which re-derives its own guard
/// from `activeItems` and then opens the family with `revealKeys`.
///
/// Two properties keep those doors on the same room:
///   A. everything the arrows can reach is something `select(_:)` accepts
///      (nothing arrow-reachable is click-inert), and
///   B. everything `select(_:)` accepts becomes visible once its reveal keys
///      are applied (no selection lands on a row the board will not render).
/// Terminal rows are outside both by design.
@Test("select() and the arrow order agree on every row, in both directions")
func selectAndArrowOrderAgreeOnEverySelectableRow() {
    let items: [DeskItem] = [
        // a family: root + two buried children
        deskItem("1"), deskItem("1.1"), deskItem("1.2"),
        // a lone orphan child (renders flat — nothing to open)
        deskItem("7.3"),
        // an orphan family of two (header is chrome; children need the reveal)
        deskItem("8.1"), deskItem("8.2"),
        // watches, including a nested one
        deskItem("w", kind: .watch), deskItem("w.1", kind: .watch),
        // GitHub rows, collapsed under their project roll-up
        deskItem("g1", kind: .gh, project: "acme"),
        deskItem("g2", kind: .gh, project: "acme"),
        deskItem("g3", kind: .gh, project: "other"),
        // a pursuit — always at the top, never buried
        deskItem("p", kind: .project, origin: .agent, pursuit: pursuitPayload()),
        // terminal rows: history is glance-only
        deskItem("d1", status: .done), deskItem("d2", status: .canceled),
    ]

    let activeHandles = Set(DeskBoardLayout.activeItems(items).map(\.handle))
    #expect(activeHandles.count == items.count - 2)

    // A. across a spread of expansion states, the arrow order never contains a
    //    handle select() would refuse.
    let expansions: [Set<String>] = [
        [],
        ["board:1"],
        ["board:8", "watch:w"],
        ["gh:acme", "gh:other", "board:1", "board:8", "watch:w"],
    ]
    for expanded in expansions {
        let order = DeskBoardLayout.selectableHandles(items: items, expandedRoots: expanded)
        #expect(Set(order).isSubset(of: activeHandles),
                "arrow order reached a row select() refuses, expanded=\(expanded)")
        #expect(Set(order).count == order.count, "the arrow order repeats a handle")
        for terminal in ["desk_d1", "desk_d2"] {
            #expect(!order.contains(terminal), "a terminal row entered the arrow order")
        }
    }

    // B. every row select() accepts is renderable once its reveal keys open.
    //    This is the property that stops a selection from landing where
    //    `scrollTo` has nothing to scroll to.
    for handle in activeHandles.sorted() {
        let keys = DeskBoardLayout.revealKeys(for: handle, items: items)
        let opened = DeskBoardLayout.selectableHandles(
            items: items, expandedRoots: Set(keys))
        #expect(opened.contains(handle),
                "select(\(handle)) opens \(keys) and the row still does not render")
    }

    // Terminal rows: refused by select() AND given no reveal keys, so the
    // palette cannot smuggle one in through the reveal path either.
    for terminal in ["desk_d1", "desk_d2"] {
        #expect(!activeHandles.contains(terminal))
        #expect(DeskBoardLayout.revealKeys(for: terminal, items: items).isEmpty)
    }
    // An unknown handle is a no-op, not a crash or a phantom reveal.
    #expect(DeskBoardLayout.revealKeys(for: "desk_nope", items: items).isEmpty)
}
