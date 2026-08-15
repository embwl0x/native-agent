import Foundation
import NativeAgentCore
import PersistenceCore

/// U4 Wave C — autonomy-promotion PROPOSAL loop.
///
/// Turns per-tool HUMAN approval history into inbox proposal cards that
/// recommend promoting a `confirm`/`supervised` tool to `auto`. CARDS ONLY:
/// this loop NEVER flips a policy on its own. A promotion is applied ONLY
/// after the human taps Approve, via the reconcile pass below — which
/// RE-READS the approved card from the inbox and re-verifies it before
/// mutating policy. This honors the campaign's hard rule: nothing
/// self-grants; every loosening (confirm→auto) ships as a user-gated inbox
/// proposal.
///
/// Security shape:
/// - The card `action` is `autonomy.promote`, which ApprovalInbox forces to
///   `remoteResolvable=false` / `localOnly=true` (the `localOnlyActions`
///   edit in this wave) — a remote/chat surface can NEVER approve a security
///   loosening.
/// - Only LOCAL approval history justifies a local promotion: any tool whose
///   approval history includes a remote-resolvable card is skipped.
/// - The reconcile pass re-verifies the card from the inbox (status,
///   decision, action, tool) so a forged in-process record cannot mutate
///   live policy, re-checks the tool is STILL at confirm/supervised, and
///   stamps `executedAction` so a second tick never double-applies.
/// - `isEnabled` fails SAFE (false) — autonomy off means no proposals and no
///   reconciliation.
///
/// Dependency-clean: all inbox IO is injected through
/// `AutonomyPromotionInboxPort` (BackgroundLoops imports neither ApprovalInbox
/// nor TrustCenter — same rule as WeeklySelfImprovementLoop). The two raw
/// policy.json reads/writes are injected closures so the security DECISION
/// logic (candidate gating + reconcile re-verify) lives in this testable
/// struct while the thin PersistenceCore IO lives in the assembly.
public struct AutonomyPromotionLoop: LoopRunner {
    public let loopId: String = "autonomy_promotion_proposals"
    public let interval: TimeInterval

    private let isEnabled: @Sendable () async -> Bool
    private let port: any AutonomyPromotionInboxPort
    /// Reads the RAW saved `toolAutonomy[tool]` tier; nil if absent (absent ⇒
    /// default/auto ⇒ not a candidate).
    private let currentTier: @Sendable (String) async -> String?
    /// Performs the locked raw-policy write that sets `toolAutonomy[tool] =
    /// "auto"` preserving all other saved keys; returns success. Called ONLY
    /// from the reconcile path, ONLY after re-verification.
    private let applyPromotion: @Sendable (String) async -> Bool
    private let dataRoot: URL
    private let clock: @Sendable () -> Date

    public init(
        interval: TimeInterval = 3600,
        isEnabled: @escaping @Sendable () async -> Bool,
        port: any AutonomyPromotionInboxPort,
        currentTier: @escaping @Sendable (String) async -> String?,
        applyPromotion: @escaping @Sendable (String) async -> Bool,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = interval
        self.isEnabled = isEnabled
        self.port = port
        self.currentTier = currentTier
        self.applyPromotion = applyPromotion
        self.dataRoot = dataRoot
        self.clock = clock
    }

    // MARK: - Thresholds / security exclusions

    /// Tiers that a tool must currently sit at to even be a promotion
    /// candidate. `auto` is already-loose (nothing to propose); everything
    /// else is an external/irreversible guard (excluded below).
    static let promotableTiers: Set<String> = ["confirm", "supervised"]
    /// Tiers that are HARD-EXCLUDED regardless of history — these are
    /// external/irreversible-consequence guards (send mail, draft+auto-send),
    /// NOT trust friction, so approval volume must never loosen them.
    static let hardExcludeTiers: Set<String> = ["send_approval", "draft_auto"]
    /// Defensive literal exclusion: builder/process-spawning + agent-invoking
    /// tools. They are already `auto` (so they would not be confirm/supervised
    /// anyway) but are listed so a hypothetical mis-tiered entry can never be
    /// proposed for promotion.
    static let hardExcludeTools: Set<String> = [
        // shell-class builders (Process spawn / fs write / arbitrary code)
        "shell", "bash", "git", "apply_patch", "run_tests",
        "swift_build", "swift_test",
        // app/agent control surfaces
        "restart_app", "install_app", "invoke_claude", "invoke_codex",
        // U4 Wave D (gpt-5.5 review BLOCKER): the self-evolution chat tools.
        // evolution_propose files a self-mod proposal, self_install stages the
        // install card, evolution_status reads. They ship at `confirm` (a
        // promotable tier), so without this exclusion clean approval history
        // could let THIS loop propose flipping `self_install` to `auto` —
        // a "nothing self-grants" violation (the install trigger going
        // approval-free). Never auto-promote a self-modification surface.
        "evolution_propose", "evolution_status", "self_install",
    ]
    static let minApprovals = 5
    static let minSpanDays = 14
    static let minDistinctDays = 3
    /// Daily cooldown for the (cheap but unnecessary-to-rerun-hourly) propose
    /// scan. Reconcile runs EVERY tick.
    public static let proposeCooldown: TimeInterval = 24 * 60 * 60

    /// The SINGLE eligibility predicate (gpt-5.5 review): a `(tool, tier)` is a
    /// legitimate promotion TARGET iff it is a trust-friction tier and not an
    /// external/irreversible/privileged surface. Used by BOTH the propose gate
    /// AND the locked apply (the apply path must NOT trust the card's
    /// payload.tool — a forged approved card naming `shell`/`restart_app`/an
    /// `invoke_*` surface must be rejected even if the on-disk tier somehow
    /// reads confirm/supervised). Keeping it in one place means the apply path
    /// and the proposal path can never drift.
    public static func isPromotableTarget(tool: String, tier: String) -> Bool {
        if hardExcludeTools.contains(tool) { return false }
        if tool.hasPrefix("invoke_") { return false }          // any agent-invoke surface
        // Code-execution / OS-automation / fs-write name SHAPES — never auto-
        // promote a tool that can run code or mutate the system, even under a
        // namespaced alias the explicit list misses (gpt-5.5 r2: `mac.shell`,
        // `mac.jxa`, `mac.applescript`, `mac.write_file` are shell/exec/write
        // tools TrustCenter classifies as approval-gated, but `mac.shell` is
        // not literally `shell`). Conservative by design: a safe tool that
        // happens to match a fragment simply gets no promotion proposal —
        // promoting a dangerous tool is a security failure; missing a safe one
        // is a minor convenience loss.
        if tool.contains("shell") { return false }             // shell / bash / mac.shell / …
        if tool.contains("applescript") || tool.contains(".jxa") { return false }  // arbitrary OS automation
        if tool.hasSuffix(".write_file") || tool.hasSuffix(".write")
            || tool.hasSuffix(".delete") || tool.hasSuffix(".run_shortcut") { return false }  // fs / exec
        if tool.hasSuffix(".send") || tool.contains(".post_") { return false }  // external send
        // U4 Wave D (gpt-5.5 review BLOCKER): self-evolution name SHAPES — never
        // auto-promote a tool that proposes/triggers app self-modification, even
        // under a future namespaced alias the explicit list misses.
        if tool.contains("evolution") || tool.contains("self_install") { return false }
        if hardExcludeTiers.contains(tier) { return false }    // external-consequence guard tiers
        return promotableTiers.contains(tier)                  // must be confirm/supervised
    }

    // MARK: - tick

    public func tickOutcome() async -> LoopTickOutcome {
        // Fail-safe: autonomy off ⇒ neither reconcile nor propose. A security
        // loosening must never apply while the master switch is off.
        guard await isEnabled() else { return .skipped(reason: "autonomy disabled") }
        do {
            try await reconcile()
            try await propose()
        } catch {
            // A staging/annotate WRITE did not land — do not report success.
            // .failed trips the manager's failure-receipt net so the dropped
            // proposal/apply-receipt card is recorded rather than silently lost.
            FileHandle.standardError.write(Data(
                "AutonomyPromotionLoop: staging failed: \(error)\n".utf8))
            return .failed(error: "autonomy promotion staging: \(SwiftNativeLoopScheduler.describeLoopError(error))")
        }
        return .completed(result: "autonomy promotion reconcile/propose completed")
    }

    // MARK: - Reconcile (apply human-approved promotions)

    /// Apply every human-APPROVED, not-yet-executed `autonomy.promote` card.
    /// Runs every tick (cheap, must be responsive). Each card is re-read and
    /// re-verified from the inbox before any policy mutation, and stamped
    /// afterward so it is never re-applied.
    func reconcile() async throws {
        let approved = await port.approvedPromotions()
        for promotion in approved {
            // RE-READ from the inbox — the caller's record is trusted for its
            // ID ONLY. A forged in-process ApprovedPromotion must not mutate
            // policy: the on-disk card is the source of truth.
            guard let snap = await port.reverifyCard(id: promotion.cardId) else { continue }
            guard snap.status == "resolved",
                  snap.decision == "approved",
                  snap.action == "autonomy.promote",
                  !snap.executedActionPresent,
                  snap.tool == promotion.tool,
                  !snap.tool.isEmpty
            else {
                // Tampered / denied / canceled / pending / already-executed /
                // tool-mismatch → do NOT apply.
                continue
            }
            let tool = snap.tool
            // Re-validate FULL eligibility (gpt-5.5 review): not just "still
            // confirm/supervised" but the SAME predicate the proposer uses —
            // the apply path must NOT trust the card's payload.tool. An
            // authentic approved card naming a hard-excluded tool (builder,
            // invoke_*, *.send) or a tool no longer at a promotable tier is
            // SKIPPED + stamped (idempotent), never applied. (The authoritative
            // re-check also re-runs INSIDE the policy-write lock — see the
            // assembly's applyPromotion — to close the check→write CAS window.)
            let tier = await currentTier(tool)
            guard let tier, Self.isPromotableTarget(tool: tool, tier: tier) else {
                try await port.annotate(
                    id: promotion.cardId,
                    executedAction: .object([
                        "op": .string("autonomy_promote"),
                        "status": .string("skipped"),
                        "tool": .string(tool),
                        "reason": .string(
                            "tool not an eligible promotion target (tier \(tier ?? "absent/auto"))"),
                    ]),
                    detail: "autonomy promotion skipped: \(tool) is not an eligible promotion "
                        + "target (current tier: \(tier ?? "absent/default-auto")) — nothing changed")
                continue
            }
            let ok = await applyPromotion(tool)
            try await port.annotate(
                id: promotion.cardId,
                executedAction: .object([
                    "op": .string("autonomy_promote"),
                    "status": .string(ok ? "applied" : "failed"),
                    "tool": .string(tool),
                    "toTier": .string("auto"),
                ]),
                detail: ok
                    ? "autonomy promotion applied: \(tool) \(tier)→auto"
                    : "autonomy promotion FAILED to write policy for \(tool) (left at \(tier))")
        }
    }

    // MARK: - Propose (stage promotion cards)

    /// Scan resolved tool-call approval history and stage a promotion card for
    /// every tool that crosses the trust thresholds. Gated by a daily cooldown
    /// marker so an hourly tick does not re-scan the same data.
    func propose() async throws {
        guard await shouldScan() else { return }
        let decisions = await port.resolvedToolDecisions()
        let pending = await port.pendingPromotionTools()
        let recentlyDecided = await port.recentlyDecidedPromotionTools()

        // Group decisions by tool.
        var byTool: [String: [ToolDecisionSnapshot]] = [:]
        for d in decisions { byTool[d.tool, default: []].append(d) }

        for (tool, rows) in byTool {
            if let candidate = await evaluate(
                tool: tool, rows: rows, pending: pending, recentlyDecided: recentlyDecided) {
                try await port.stagePromotion(candidate)
            }
        }
    }

    /// Pure-ish candidate gate (the `currentTier` read is the only IO). Returns
    /// a `PromotionCandidate` iff every trust + security invariant holds, else
    /// nil. Extracted so the adversarial test net drives it directly.
    ///
    /// `pending` = tools with an open promote card (no duplicate).
    /// `recentlyDecided` = tools whose promote card was already RESOLVED
    /// (approved or DENIED) recently — gpt-5.5 review: without this, a DENIED
    /// promotion is re-staged every day forever (the denied card is meta-
    /// excluded from the tool-history scan), nagging the human who already said
    /// no. Respect the decision; don't re-propose.
    func evaluate(
        tool: String, rows: [ToolDecisionSnapshot],
        pending: Set<String>, recentlyDecided: Set<String> = []
    ) async -> PromotionCandidate? {
        // No duplicate while a card is open, and no re-nag after a recent
        // decision (esp. a denial).
        if pending.contains(tool) || recentlyDecided.contains(tool) { return nil }

        // Tier + tool-shape eligibility through the SINGLE shared predicate
        // (absent saved tier ⇒ not a candidate).
        guard let tier = await currentTier(tool) else { return nil }
        guard Self.isPromotableTarget(tool: tool, tier: tier) else { return nil }

        let approvedRows = rows.filter { $0.decision == "approved" }
        let denials = rows.filter { $0.decision == "denied" }.count
        let approvals = approvedRows.count

        // Any denial is disqualifying — the human has actively distrusted it.
        guard denials == 0 else { return nil }
        guard approvals >= Self.minApprovals else { return nil }

        // Local-only history requirement (gpt-5.5 review): only genuinely LOCAL
        // approvals justify a local promotion. Require BOTH localOnly==true AND
        // remoteResolvable==false — a legacy card missing the remoteResolvable
        // flag parses as false and would otherwise masquerade as local.
        guard approvedRows.allSatisfy({ $0.remoteResolvable == false && $0.localOnly == true })
        else { return nil }

        // Span + distinct-days from each approval's RESOLVED-AT timestamp
        // (gpt-5.5 review: when the human actually approved, not when the card
        // was created — else a batch of old pending cards approved in one
        // sitting fakes a long "trust history"). Require every approval to
        // carry a parseable resolvedAt.
        let dates = approvedRows.compactMap { $0.resolvedAt.flatMap(Self.parseISO) }
        guard dates.count == approvedRows.count, let minD = dates.min(), let maxD = dates.max()
        else { return nil }
        let spanDays = Int(maxD.timeIntervalSince(minD) / 86_400)
        let distinctDays = Set(dates.map { Self.dayString($0) }).count
        guard spanDays >= Self.minSpanDays, distinctDays >= Self.minDistinctDays else { return nil }

        return PromotionCandidate(
            tool: tool, fromTier: tier, approvals: approvals,
            distinctDays: distinctDays, spanDays: spanDays,
            // We consider the tool's full LOCAL history; the observed span IS
            // the window summarized on the card.
            windowDays: spanDays)
    }

    // MARK: - Cooldown marker

    /// Check-and-stamp the daily scan marker under the cross-process file lock.
    /// Returns true (and stamps now) when ≥1 day has passed since the last
    /// scan; false otherwise. Restores the prior stamp if the lock body fails.
    private func shouldScan() async -> Bool {
        let marker = dataRoot
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("autonomy_promotion", isDirectory: true)
            .appendingPathComponent("last_scan")
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = clock()
        // Check-and-stamp the daily marker under the cross-process lock via the
        // shared once-per-period reservation. Reserved ⇒ scan; already-fresh or
        // lock failure ⇒ skip. The reservation's rollback is unused: a failed
        // propose() is cheap to re-run and the daily stamp intentionally holds.
        let reservation = await reserveOncePerPeriod(at: marker, stamp: Self.isoStamp(now)) { stored in
            guard let stamp = stored.flatMap(Self.parseISO) else { return false }
            return now.timeIntervalSince(stamp) < Self.proposeCooldown
        }
        if case .reserved = reservation { return true }
        return false
    }

    // MARK: - Helpers

    public static func parseISO(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
            ?? {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f.date(from: s)
            }()
    }

    static func isoStamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// UTC calendar day (yyyy-MM-dd) for distinct-day counting.
    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Injected inbox port

/// The inbox surface the loop needs, expressed in lightweight Sendable structs
/// so BackgroundLoops gains no ApprovalInbox type dependency. The assembly
/// supplies a concrete adapter over `SwiftNativeApprovalInbox`.
///
/// READ methods are non-throwing — the adapter returns empty/nil on IO error,
/// which is fail-safe (no data → no promotion). The two WRITE methods
/// (`stagePromotion`, `annotate`) are `throws` as of the 2026-07-23 A4.5 audit:
/// a swallowed write dropped a proposal/apply-receipt card SILENTLY and the
/// tick still reported `.completed`. They now surface the failure so the loop
/// returns `.failed`, tripping the manager's failure-receipt net.
public protocol AutonomyPromotionInboxPort: Sendable {
    /// All RESOLVED tool-call cards mapped to lightweight snapshots.
    func resolvedToolDecisions() async -> [ToolDecisionSnapshot]
    /// Tools that already have a PENDING `autonomy.promote` card (dedupe).
    func pendingPromotionTools() async -> Set<String>
    /// Tools whose `autonomy.promote` card was already RESOLVED (approved or
    /// denied) recently — do not re-propose (respect a denial; don't re-nag).
    func recentlyDecidedPromotionTools() async -> Set<String>
    /// Create the `autonomy.promote` proposal card for a candidate.
    func stagePromotion(_ candidate: PromotionCandidate) async throws
    /// RESOLVED + approved + action `autonomy.promote` + not-yet-executed.
    func approvedPromotions() async -> [ApprovedPromotion]
    /// Re-read a card by id for forge-prevention; nil if absent.
    func reverifyCard(id: String) async -> CardSnapshot?
    /// Stamp `executedAction` + `detail` on a card so it is never re-applied.
    func annotate(id: String, executedAction: JSONValue, detail: String) async throws
}

/// One resolved tool-call approval, reduced to what the candidate math needs.
public struct ToolDecisionSnapshot: Sendable, Equatable {
    public let tool: String
    public let decision: String          // "approved" | "denied" | "canceled"
    public let createdAt: String         // ISO-8601
    public let resolvedAt: String?       // ISO-8601 or nil
    public let remoteResolvable: Bool
    public let localOnly: Bool

    public init(
        tool: String, decision: String, createdAt: String,
        resolvedAt: String?, remoteResolvable: Bool, localOnly: Bool
    ) {
        self.tool = tool
        self.decision = decision
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.remoteResolvable = remoteResolvable
        self.localOnly = localOnly
    }
}

/// A tool that crossed the trust thresholds, ready to stage as a card.
public struct PromotionCandidate: Sendable, Equatable {
    public let tool: String
    public let fromTier: String
    public let approvals: Int
    public let distinctDays: Int
    public let spanDays: Int
    public let windowDays: Int

    public init(
        tool: String, fromTier: String, approvals: Int,
        distinctDays: Int, spanDays: Int, windowDays: Int
    ) {
        self.tool = tool
        self.fromTier = fromTier
        self.approvals = approvals
        self.distinctDays = distinctDays
        self.spanDays = spanDays
        self.windowDays = windowDays
    }
}

/// A human-approved promotion awaiting application (reconcile input).
public struct ApprovedPromotion: Sendable, Equatable {
    public let cardId: String
    public let tool: String
    public init(cardId: String, tool: String) {
        self.cardId = cardId
        self.tool = tool
    }
}

/// Re-read of an `autonomy.promote` card for forge-prevention.
public struct CardSnapshot: Sendable, Equatable {
    public let status: String
    public let decision: String?
    public let action: String
    public let tool: String
    public let executedActionPresent: Bool

    public init(
        status: String, decision: String?, action: String,
        tool: String, executedActionPresent: Bool
    ) {
        self.status = status
        self.decision = decision
        self.action = action
        self.tool = tool
        self.executedActionPresent = executedActionPresent
    }
}
