import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore

// U4 Wave C — adversarial net for the autonomy-promotion proposal loop.
//
// The point of this suite is the SECURITY invariants: the loop proposes only
// confirm/supervised tools with clean LOCAL approval history, never the
// hard-excluded external/builder tools, and the reconcile pass applies a
// promotion ONLY for a re-verified human-approved card, idempotently.
//
// Everything is hermetic: an in-memory fake port + injected currentTier /
// applyPromotion fakes + a fixed clock. No Date(), no disk inbox.

// MARK: - Fakes

/// Thread-safe in-memory port. Records call counts on the mutating surfaces so
/// tests assert exactly what the loop did.
private final class FakePort: AutonomyPromotionInboxPort, @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: [ToolDecisionSnapshot]
    private var pending: Set<String>
    private var recentlyDecided: Set<String>
    private var approved: [ApprovedPromotion]
    private var cards: [String: CardSnapshot]

    private(set) var staged: [PromotionCandidate] = []
    private(set) var annotations: [(id: String, executedAction: JSONValue, detail: String)] = []

    init(
        resolved: [ToolDecisionSnapshot] = [],
        pending: Set<String> = [],
        recentlyDecided: Set<String> = [],
        approved: [ApprovedPromotion] = [],
        cards: [String: CardSnapshot] = [:]
    ) {
        self.resolved = resolved
        self.pending = pending
        self.recentlyDecided = recentlyDecided
        self.approved = approved
        self.cards = cards
    }

    func resolvedToolDecisions() async -> [ToolDecisionSnapshot] {
        lock.withLock { resolved }
    }
    func pendingPromotionTools() async -> Set<String> {
        lock.withLock { pending }
    }
    func recentlyDecidedPromotionTools() async -> Set<String> {
        lock.withLock { recentlyDecided }
    }
    func stagePromotion(_ candidate: PromotionCandidate) async {
        lock.withLock { staged.append(candidate) }
    }
    func approvedPromotions() async -> [ApprovedPromotion] {
        lock.withLock { approved }
    }
    func reverifyCard(id: String) async -> CardSnapshot? {
        lock.withLock { cards[id] }
    }
    func annotate(id: String, executedAction: JSONValue, detail: String) async {
        lock.withLock {
            annotations.append((id, executedAction, detail))
            // Mirror the real inbox: once stamped, the card reads as executed,
            // so a second reconcile tick skips it (idempotency under test).
            if let c = cards[id] {
                cards[id] = CardSnapshot(
                    status: c.status, decision: c.decision, action: c.action,
                    tool: c.tool, executedActionPresent: true)
            }
        }
    }

    var stagedTools: [String] { lock.withLock { staged.map { $0.tool } } }
}

/// Thread-safe applyPromotion fake: records the tools it was asked to flip and
/// returns a fixed success value.
private final class ApplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _tools: [String] = []
    private let succeed: Bool
    init(succeed: Bool = true) { self.succeed = succeed }
    func apply(_ tool: String) -> Bool {
        lock.withLock { _tools.append(tool) }
        return succeed
    }
    var tools: [String] { lock.withLock { _tools } }
    var count: Int { lock.withLock { _tools.count } }
}

// MARK: - Builders

private let t0 = "2026-01-01T12:00:00+00:00"

/// N approved local tool-call snapshots spread one per day starting at `base`.
private func approvals(
    tool: String, count: Int, baseDay: Int = 1, remote: Bool = false
) -> [ToolDecisionSnapshot] {
    (0..<count).map { i in
        let day = baseDay + i
        let ts = String(format: "2026-01-%02dT12:00:00+00:00", day)
        return ToolDecisionSnapshot(
            tool: tool, decision: "approved", createdAt: ts,
            resolvedAt: ts, remoteResolvable: remote, localOnly: !remote)
    }
}

/// A history that easily clears the gate: 6 approvals across 20 days, 4 of them
/// on distinct days (days 1, 6, 11, 21 → span 20, distinct 4 — but we need ≥5
/// approvals, so use 6 rows on 6 distinct days spanning 20d).
private func cleanHistory(tool: String) -> [ToolDecisionSnapshot] {
    let days = [1, 4, 8, 12, 16, 21]   // 6 approvals, 6 distinct days, span 20
    return days.map { day in
        let ts = String(format: "2026-01-%02dT12:00:00+00:00", day)
        return ToolDecisionSnapshot(
            tool: tool, decision: "approved", createdAt: ts,
            resolvedAt: ts, remoteResolvable: false, localOnly: true)
    }
}

private func makeLoop(
    port: FakePort,
    tiers: [String: String],
    apply: ApplyRecorder = ApplyRecorder(),
    isEnabled: Bool = true
) -> AutonomyPromotionLoop {
    AutonomyPromotionLoop(
        isEnabled: { isEnabled },
        port: port,
        currentTier: { tool in tiers[tool] },
        applyPromotion: { tool in apply.apply(tool) },
        dataRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("autonomy_promotion_test_\(UUID().uuidString)"),
        clock: { Date(timeIntervalSince1970: 1_767_400_000) }   // fixed
    )
}

/// Port whose stagePromotion always throws — proves the loop surfaces a
/// staging-write failure instead of swallowing it (FIX 3, A4.5).
private final class ThrowingStagePort: AutonomyPromotionInboxPort, @unchecked Sendable {
    struct StageError: Error {}
    let history: [ToolDecisionSnapshot]
    init(history: [ToolDecisionSnapshot]) { self.history = history }
    func resolvedToolDecisions() async -> [ToolDecisionSnapshot] { history }
    func pendingPromotionTools() async -> Set<String> { [] }
    func recentlyDecidedPromotionTools() async -> Set<String> { [] }
    func stagePromotion(_ candidate: PromotionCandidate) async throws { throw StageError() }
    func approvedPromotions() async -> [ApprovedPromotion] { [] }
    func reverifyCard(id: String) async -> CardSnapshot? { nil }
    func annotate(id: String, executedAction: JSONValue, detail: String) async throws {}
}

@Test func autonomy_staging_failure_returns_failed() async {
    // FIX 3 (A4.5): a swallowed stagePromotion write dropped the promotion card
    // silently while the tick still reported .completed. It must return .failed
    // so the manager's failure-receipt net records the drop.
    let loop = AutonomyPromotionLoop(
        isEnabled: { true },
        port: ThrowingStagePort(history: cleanHistory(tool: "weather.lookup")),
        currentTier: { _ in "confirm" },
        applyPromotion: { _ in true },
        dataRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("autonomy_stage_fail_\(UUID().uuidString)"),
        clock: { Date(timeIntervalSince1970: 1_767_400_000) }
    )
    let outcome = await loop.tickOutcome()
    guard case .failed(let error) = outcome else {
        Issue.record("expected .failed when the promotion staging write fails, got \(outcome)")
        return
    }
    #expect(error.contains("autonomy promotion staging"))
}

// MARK: - PROPOSE tests (drive evaluate() directly — no cooldown marker)

@Test func propose_clean_confirm_tool_yields_one_candidate() async {
    let port = FakePort(resolved: cleanHistory(tool: "weather.lookup"))
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"])
    let c = await loop.evaluate(
        tool: "weather.lookup", rows: cleanHistory(tool: "weather.lookup"), pending: [])
    #expect(c != nil)
    #expect(c?.tool == "weather.lookup")
    #expect(c?.fromTier == "confirm")
    #expect(c?.approvals == 6)
    #expect(c?.distinctDays == 6)
    #expect(c?.spanDays == 20)
}

@Test func propose_already_auto_tool_no_candidate() async {
    let rows = cleanHistory(tool: "weather.lookup")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "auto"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_send_approval_tier_hard_excluded() async {
    let rows = cleanHistory(tool: "agentmail.compose")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["agentmail.compose": "send_approval"])
    #expect(await loop.evaluate(tool: "agentmail.compose", rows: rows, pending: []) == nil)
}

@Test func propose_draft_auto_tier_hard_excluded() async {
    let rows = cleanHistory(tool: "agentmail.draft")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["agentmail.draft": "draft_auto"])
    #expect(await loop.evaluate(tool: "agentmail.draft", rows: rows, pending: []) == nil)
}

@Test func propose_one_denial_disqualifies() async {
    var rows = cleanHistory(tool: "weather.lookup")
    rows.append(ToolDecisionSnapshot(
        tool: "weather.lookup", decision: "denied",
        createdAt: "2026-01-22T12:00:00+00:00", resolvedAt: "2026-01-22T12:00:00+00:00",
        remoteResolvable: false, localOnly: true))
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_remote_approval_in_history_disqualifies() async {
    var rows = cleanHistory(tool: "weather.lookup")
    // One approval came from a remote-resolvable card → local-only requirement
    // fails for the whole tool.
    rows.append(ToolDecisionSnapshot(
        tool: "weather.lookup", decision: "approved",
        createdAt: "2026-01-25T12:00:00+00:00", resolvedAt: "2026-01-25T12:00:00+00:00",
        remoteResolvable: true, localOnly: false))
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_existing_pending_card_no_duplicate() async {
    let rows = cleanHistory(tool: "weather.lookup")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(
        tool: "weather.lookup", rows: rows, pending: ["weather.lookup"]) == nil)
}

@Test func propose_builder_tool_defensively_excluded() async {
    // Even if shell were (hypothetically) confirm with clean history, it must
    // never be proposed — defensive literal exclusion.
    let rows = cleanHistory(tool: "shell")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["shell": "confirm"])
    #expect(await loop.evaluate(tool: "shell", rows: rows, pending: []) == nil)
}

@Test func propose_dot_send_tool_excluded() async {
    let rows = cleanHistory(tool: "gmail.send")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["gmail.send": "confirm"])
    #expect(await loop.evaluate(tool: "gmail.send", rows: rows, pending: []) == nil)
}

@Test func propose_insufficient_approvals_no_candidate() async {
    let rows = approvals(tool: "weather.lookup", count: 4, baseDay: 1)   // only 4
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_span_too_short_no_candidate() async {
    // 6 approvals but all within 5 days → spanDays < 14.
    let rows = approvals(tool: "weather.lookup", count: 6, baseDay: 1)   // days 1..6, span 5
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_supervised_tier_is_promotable() async {
    let rows = cleanHistory(tool: "calendar.read")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["calendar.read": "supervised"])
    let c = await loop.evaluate(tool: "calendar.read", rows: rows, pending: [])
    #expect(c?.fromTier == "supervised")
}

@Test func propose_invoke_prefix_excluded() async {
    // gpt-5.5: exclude every invoke_* surface, not just invoke_claude/codex.
    let rows = cleanHistory(tool: "invoke_hermes")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["invoke_hermes": "confirm"])
    #expect(await loop.evaluate(tool: "invoke_hermes", rows: rows, pending: []) == nil)
}

@Test func propose_namespaced_code_exec_aliases_excluded() async {
    // gpt-5.5 r2: the explicit builder list misses Mac-namespaced aliases. A
    // shell/exec/write tool must never be promoted even as `mac.shell`,
    // `mac.jxa`, `mac.applescript`, `mac.write_file`, regardless of tier.
    for tool in ["mac.shell", "mac.jxa", "mac.applescript", "mac.write_file",
                 "mac.run_shortcut", "local_files.delete"] {
        let rows = cleanHistory(tool: tool)
        let loop = makeLoop(port: FakePort(resolved: rows), tiers: [tool: "confirm"])
        #expect(await loop.evaluate(tool: tool, rows: rows, pending: []) == nil,
                "\(tool) is a code-exec/fs-write alias and must never be a promotion candidate")
    }
}

@Test func propose_evolution_tools_never_promoted() async {
    // U4 Wave D (gpt-5.5 review BLOCKER): the self-evolution chat tools ship at
    // `confirm` (a promotable tier). They must NEVER be auto-promoted to `auto`
    // — flipping self_install to auto would make the app-self-modification
    // install trigger approval-free ("nothing self-grants"). Both the explicit
    // names AND a future `evolution_*` alias are excluded.
    for tool in ["evolution_propose", "evolution_status", "self_install",
                 "evolution_apply", "mac.evolution_propose"] {
        #expect(AutonomyPromotionLoop.isPromotableTarget(tool: tool, tier: "confirm") == false,
                "\(tool) is a self-evolution surface and must never be a promotion candidate")
        let rows = cleanHistory(tool: tool)
        let loop = makeLoop(port: FakePort(resolved: rows), tiers: [tool: "confirm"])
        #expect(await loop.evaluate(tool: tool, rows: rows, pending: []) == nil)
    }
}

@Test func propose_recently_decided_tool_not_reproposed() async {
    // gpt-5.5: a tool whose promote card was already resolved (e.g. DENIED) must
    // not be re-staged — respect the human's decision.
    let rows = cleanHistory(tool: "weather.lookup")
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(
        tool: "weather.lookup", rows: rows, pending: [],
        recentlyDecided: ["weather.lookup"]) == nil)
}

@Test func propose_local_only_false_in_history_disqualifies() async {
    // gpt-5.5: a legacy card missing remoteResolvable parses as false (looks
    // local); require localOnly==true too. One approval with localOnly=false
    // disqualifies the tool.
    var rows = cleanHistory(tool: "weather.lookup")
    rows.append(ToolDecisionSnapshot(
        tool: "weather.lookup", decision: "approved",
        createdAt: "2026-01-25T12:00:00+00:00", resolvedAt: "2026-01-25T12:00:00+00:00",
        remoteResolvable: false, localOnly: false))   // not genuinely local
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    #expect(await loop.evaluate(tool: "weather.lookup", rows: rows, pending: []) == nil)
}

@Test func propose_uses_resolvedAt_not_createdAt_for_span() async {
    // gpt-5.5: span/distinct must come from resolvedAt (when approved), not
    // createdAt. Craft 6 cards all CREATED the same day but APPROVED across 20
    // days → must still qualify (proves resolvedAt drives the math).
    let createdSameDay = "2026-01-01T08:00:00+00:00"
    let resolveDays = [1, 4, 8, 12, 16, 21]
    let rows = resolveDays.map { day -> ToolDecisionSnapshot in
        let rts = String(format: "2026-01-%02dT12:00:00+00:00", day)
        return ToolDecisionSnapshot(
            tool: "weather.lookup", decision: "approved", createdAt: createdSameDay,
            resolvedAt: rts, remoteResolvable: false, localOnly: true)
    }
    let loop = makeLoop(port: FakePort(resolved: rows), tiers: ["weather.lookup": "confirm"])
    let c = await loop.evaluate(tool: "weather.lookup", rows: rows, pending: [])
    #expect(c != nil, "resolvedAt span is 20d → qualifies even though createdAt span is 0")
    #expect(c?.spanDays == 20)
    #expect(c?.distinctDays == 6)
}

// MARK: - RECONCILE tests

@Test func reconcile_approved_confirm_tool_applies_once_idempotent() async {
    let cardId = "card-1"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder(succeed: true)
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)

    try? await loop.reconcile()
    #expect(apply.tools == ["weather.lookup"])
    #expect(port.annotations.count == 1)
    // status=applied stamped.
    if case .object(let ea)? = port.annotations.first?.executedAction,
       case .string(let s)? = ea["status"] {
        #expect(s == "applied")
    } else {
        Issue.record("missing applied executedAction")
    }

    // Second tick: card now reads executedActionPresent=true → NOT re-applied.
    try? await loop.reconcile()
    #expect(apply.count == 1)   // still one
}

@Test func reconcile_denied_card_not_applied() async {
    let cardId = "card-2"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "denied", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
    #expect(port.annotations.isEmpty)
}

@Test func reconcile_canceled_card_not_applied() async {
    let cardId = "card-3"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "canceled", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
}

@Test func reconcile_pending_card_not_applied() async {
    let cardId = "card-4"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "pending", decision: nil, action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
}

@Test func reconcile_tampered_action_not_applied() async {
    // Re-verified snapshot has a DIFFERENT action than autonomy.promote — a
    // forged/tampered card must not mutate policy.
    let cardId = "card-5"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "self_improvement.apply",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
}

@Test func reconcile_tool_mismatch_not_applied() async {
    // The approved record claims one tool; the on-disk card names another.
    let cardId = "card-6"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "calendar.read", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm", "calendar.read": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
}

@Test func reconcile_tool_already_auto_skips_and_stamps() async {
    // Human approved, but by the time reconcile runs the tool is already auto
    // (or no longer confirm/supervised) → do NOT flip; stamp skipped.
    let cardId = "card-7"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "auto"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0)
    #expect(port.annotations.count == 1)
    if case .object(let ea)? = port.annotations.first?.executedAction,
       case .string(let s)? = ea["status"] {
        #expect(s == "skipped")
    } else {
        Issue.record("missing skipped executedAction")
    }
}

@Test func reconcile_apply_failure_stamps_failed() async {
    let cardId = "card-8"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder(succeed: false)   // policy write fails
    let loop = makeLoop(port: port, tiers: ["weather.lookup": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 1)
    if case .object(let ea)? = port.annotations.first?.executedAction,
       case .string(let s)? = ea["status"] {
        #expect(s == "failed")
    } else {
        Issue.record("missing failed executedAction")
    }
}

@Test func reconcile_hard_excluded_tool_not_applied_even_if_approved() async {
    // gpt-5.5 (defense in depth): the apply path must NOT trust the card's
    // payload.tool. An AUTHENTIC approved autonomy.promote card naming a
    // hard-excluded builder, even if the tier somehow reads confirm, must be
    // SKIPPED (not applied) and stamped.
    let cardId = "card-x"
    let port = FakePort(
        approved: [ApprovedPromotion(cardId: cardId, tool: "shell")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "shell", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(port: port, tiers: ["shell": "confirm"], apply: apply)
    try? await loop.reconcile()
    #expect(apply.count == 0, "a hard-excluded tool must never be promoted, even from an approved card")
    #expect(port.annotations.count == 1)
    if case .object(let ea)? = port.annotations.first?.executedAction,
       case .string(let s)? = ea["status"] {
        #expect(s == "skipped")
    } else {
        Issue.record("missing skipped executedAction")
    }
}

// MARK: - Master gate

@Test func disabled_neither_proposes_nor_reconciles() async {
    let cardId = "card-9"
    let port = FakePort(
        resolved: cleanHistory(tool: "weather.lookup"),
        approved: [ApprovedPromotion(cardId: cardId, tool: "weather.lookup")],
        cards: [cardId: CardSnapshot(
            status: "resolved", decision: "approved", action: "autonomy.promote",
            tool: "weather.lookup", executedActionPresent: false)])
    let apply = ApplyRecorder()
    let loop = makeLoop(
        port: port, tiers: ["weather.lookup": "confirm"], apply: apply, isEnabled: false)
    await loop.tick()
    #expect(apply.count == 0)         // no reconcile
    #expect(port.staged.isEmpty)      // no propose
}

@Test func loopId_is_stable() {
    let loop = makeLoop(port: FakePort(), tiers: [:])
    #expect(loop.loopId == "autonomy_promotion_proposals")
    #expect(loop.tickTimeoutOverride == nil)
}
