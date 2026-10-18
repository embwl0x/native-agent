import Foundation
import NativeAgentCore
import BackgroundLoops
import PersistenceCore
import ApprovalInbox
import TrustCenter

// MARK: - Autonomy Promotion

public enum AutonomyBackgroundWork {
    // MARK: - U4 Wave C: autonomy-promotion proposal loop

    /// Raw saved trust policy path. The reconciler writes here directly
    /// (data/trust is write-denied to sandboxed builder tools — Wave B — so
    /// this in-process reconciler is the ONLY writer; there is no self-grant
    /// path through a shell).
    public static func trustPolicyPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Hourly loop that mints confirm→auto promotion PROPOSALS from local
    /// approval history and applies human-APPROVED ones via a re-verifying
    /// reconcile. Cards only; nothing self-grants. Gated on `enableAutonomy`
    /// (fail-safe FALSE). See AutonomyPromotionLoop for the security shape.
    public static func makeAutonomyPromotionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        events: any BackgroundWorkEventPort
    ) -> some EventDeadlineLoopRunner {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let policyPath = trustPolicyPath(dataRoot: dataRoot)
        let trustCenter = SwiftNativeTrustCenter(dataRoot: dataRoot)
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        let loop = AutonomyPromotionLoop(
            // Daily is now the missed-event integrity cadence. Approval/policy
            // mutations and the persisted proposal cooldown drive normal work.
            interval: 24 * 60 * 60,
            // Fail-safe: autonomy OFF ⇒ no proposals, no reconciliation. Read
            // the same enableAutonomy flag the Workshop execution gate uses.
            gate: {
                let policy = await trustCenter.loadTrustPolicy()
                guard case .bool(true) = policy["enableAutonomy"] ?? .null else {
                    return .off("autonomy disabled")
                }
                // Full Mac already supplies temporary runtime authority. Do
                // not mint promotion prompts or permanently loosen saved
                // per-tool authority while that checked grant is admitted.
                let yolo = await securityCenter.fullMacYoloAuthority(
                    tool: "autonomy.promote",
                    origin: SecurityOriginContext(
                        surface: "desk",
                        source: "background_autonomy_promotion",
                        isRemote: false
                    )
                )
                return yolo.admitted ? .notNeeded("under Full Mac") : nil
            },
            port: AutonomyPromotionInboxAdapter(inbox: inbox),
            // RAW saved toolAutonomy[tool]; nil if absent (absent ⇒ default/auto
            // ⇒ not a candidate). NOT loadTrustPolicy — that merges ~75 defaults.
            currentTier: { tool in
                try? await trustCenter.userConfiguredAutonomyLevel(for: tool)
            },
            // Canonical checked CAS: preserve every other raw saved key and
            // refuse corruption or a tier changed since the human-approved
            // promotion was re-verified.
            applyPromotion: { tool in
                do {
                    guard let tier = try await trustCenter.userConfiguredAutonomyLevel(for: tool),
                          AutonomyPromotionLoop.isPromotableTarget(tool: tool, tier: tier)
                    else { return false }
                    return try await trustCenter.compareAndSetToolAutonomy(
                        tool: tool,
                        expectedCurrentTiers: [tier],
                        newTier: "auto"
                    )
                } catch {
                    FileHandle.standardError.write(Data(
                        "AutonomyPromotion: policy write failed for \(tool): \(error)\n".utf8))
                    return false
                }
            },
            dataRoot: dataRoot
        )
        return AutonomyPromotionEventDeadlineRunner(
            underlying: loop,
            dataRoot: dataRoot,
            policyPath: policyPath,
            events: events
        )
    }
}

private struct AutonomyPromotionEventDeadlineRunner: EventDeadlineLoopRunner {
    let underlying: AutonomyPromotionLoop
    let dataRoot: URL
    let policyPath: URL
    let events: any BackgroundWorkEventPort

    var loopId: String { underlying.loopId }
    var interval: TimeInterval { underlying.interval }
    var tickTimeoutOverride: TimeInterval? { underlying.tickTimeoutOverride }

    func tickOutcome() async -> LoopTickOutcome { await underlying.tickOutcome() }

    func physiologyEvents() -> AsyncStream<Void> {
        events.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            policyPath,
        ], loopId: nil)
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let marker = dataRoot
            .appendingPathComponent("security/autonomy_promotion/last_scan")
        guard let data = try? Data(contentsOf: marker),
              let raw = String(data: data, encoding: .utf8),
              let last = AutonomyPromotionLoop.parseISO(raw) else {
            return nil
        }
        let due = last.addingTimeInterval(AutonomyPromotionLoop.proposeCooldown)
        return due > now ? due : nil
    }
}

/// Concrete adapter over `SwiftNativeApprovalInbox`,
/// mapping `ApprovalRecord` ↔ the loop's lightweight Sendable snapshots.
/// All methods are
/// non-throwing — IO errors are logged and swallowed (empty/nil) so a
/// transient inbox failure never throws out of the loop's `tick()`.
struct AutonomyPromotionInboxAdapter: Sendable {
    let inbox: SwiftNativeApprovalInbox

    /// Meta op-actions that are NOT tool-call cards — excluded from the
    /// approval-history scan (the loop treats `action` as a tool name).
    static let metaActions: Set<String> = [
        "autonomy.promote", "self_improvement.apply", "approval",
        "backup_restore", WorkshopStepApprovalAction.canonical, "memory.repair",
    ]
    static let metaPrefixes: [String] = ["memory.", "improvement."]

    private static func isToolCard(_ action: String) -> Bool {
        if action.isEmpty { return false }
        // P2-4: history rows carry `mission.step`; the allowlist carries
        // `execution.step`. Canonicalize or every historical step-approval is
        // misread as a tool card and inflates the promotion counters.
        if metaActions.contains(ExecutionEventVocabulary.canonicalKind(action)) { return false }
        if metaPrefixes.contains(where: { action.hasPrefix($0) }) { return false }
        return true
    }

    private static func payloadTool(_ payload: JSONValue) -> String {
        guard case .object(let obj) = payload,
              case .string(let tool)? = obj["tool"] else { return "" }
        return tool
    }

    func resolvedToolDecisions() async -> [ToolDecisionSnapshot] {
        guard let records = try? await inbox.list(filter: .resolved) else { return [] }
        return records.compactMap { rec in
            guard Self.isToolCard(rec.action), let decision = rec.decision else { return nil }
            return ToolDecisionSnapshot(
                tool: rec.action, decision: decision,
                resolvedAt: rec.resolvedAt, remoteResolvable: rec.remoteResolvable,
                localOnly: rec.localOnly)
        }
    }

    func pendingPromotionTools() async -> Set<String> {
        guard let records = try? await inbox.list(
            filter: ApprovalFilter(status: "pending", action: "autonomy.promote"))
        else { return [] }
        return Set(records.map { Self.payloadTool($0.payload) }.filter { !$0.isEmpty })
    }

    /// Tools whose `autonomy.promote` card was already RESOLVED (gpt-5.5 review:
    /// a denied promotion must not be re-staged every day — the denied card is
    /// meta-excluded from the tool-history scan, so without this it would
    /// re-propose forever). Any resolved promote card for a tool suppresses
    /// re-proposal: an APPROVED one already promoted it (tool now auto ⇒ not a
    /// candidate anyway); a DENIED/canceled one is a human "no" to respect.
    func recentlyDecidedPromotionTools() async -> Set<String> {
        guard let records = try? await inbox.list(
            filter: ApprovalFilter(status: "resolved", action: "autonomy.promote"))
        else { return [] }
        return Set(records.map { Self.payloadTool($0.payload) }.filter { !$0.isEmpty })
    }

    func stagePromotion(_ candidate: PromotionCandidate) async throws {
        let preview = "Let \(candidate.tool) run without asking (now \(candidate.fromTier)). Approved "
            + "\(candidate.approvals)/\(candidate.approvals) over \(candidate.spanDays)d "
            + "(\(candidate.distinctDays) active days)"
        let body: JSONValue = .object([
            "title": .string("Promote \(candidate.tool) to auto?"),
            "action": .string("autonomy.promote"),
            // SECURITY loosening → high risk. remoteResolvable is forced false
            // by ApprovalInbox's hardLocalOnlyActions (U4 Wave C edit).
            "risk": .string("high"),
            "reason": .string(
                "\(candidate.tool) was approved \(candidate.approvals) times with no denials "
                + "over \(candidate.spanDays) days (\(candidate.distinctDays) active days), "
                + "all from local approvals."),
            "payload": .object([
                "tool": .string(candidate.tool),
                "fromTier": .string(candidate.fromTier),
                "toTier": .string("auto"),
                "approvals": .int(Int64(candidate.approvals)),
                "distinctDays": .int(Int64(candidate.distinctDays)),
                "spanDays": .int(Int64(candidate.spanDays)),
                "windowDays": .int(Int64(candidate.spanDays)),
            ]),
            "payloadPreview": .string(preview),
        ])
        do {
            _ = try await inbox.create(body)
        } catch {
            // FIX 3 (A4.5): rethrow — a swallowed create() dropped the promotion
            // card silently while the tick still reported .completed.
            FileHandle.standardError.write(Data(
                "AutonomyPromotion: stage failed for \(candidate.tool): \(error)\n".utf8))
            throw error
        }
    }

    func approvedPromotions() async -> [ApprovedPromotion] {
        guard let records = try? await inbox.list(
            filter: ApprovalFilter(status: "resolved", action: "autonomy.promote"))
        else { return [] }
        return records.compactMap { rec in
            guard rec.decision == "approved", rec.executedAction == nil else { return nil }
            let tool = Self.payloadTool(rec.payload)
            guard !tool.isEmpty else { return nil }
            return ApprovedPromotion(cardId: rec.id, tool: tool)
        }
    }

    func reverifyCard(id: String) async -> CardSnapshot? {
        guard let rec = try? await inbox.get(id) else { return nil }
        return CardSnapshot(
            status: rec.status, decision: rec.decision, action: rec.action,
            tool: Self.payloadTool(rec.payload),
            executedActionPresent: rec.executedAction != nil)
    }

    /// Stamp the executor outcome through the authoritative ApprovalInbox.
    func annotate(id: String, executedAction: JSONValue, detail: String) async throws {
        do {
            _ = try await inbox.annotateExecution(
                id,
                executedAction: executedAction,
                detail: detail
            )
        } catch {
            // FIX 3 (A4.5): rethrow — a swallowed annotate() left the card
            // unstamped (silently re-applicable) while the tick reported success.
            FileHandle.standardError.write(Data(
                "AutonomyPromotion: annotate failed for \(id): \(error)\n".utf8))
            throw error
        }
    }
}

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
/// - `gate` returns the skip that stops the tick — Off when autonomy is off,
///   Not needed under Full Mac — and nil only when the loop may run: neither
///   proposals nor reconciliation happen behind a closed gate.
///
public struct AutonomyPromotionLoop: LoopRunner {
    public let loopId: String = "autonomy_promotion_proposals"
    public let interval: TimeInterval

    private let gate: @Sendable () async -> LoopTickOutcome?
    private let port: AutonomyPromotionInboxAdapter
    /// Reads the RAW saved `toolAutonomy[tool]` tier; nil if absent (absent ⇒
    /// default/auto ⇒ not a candidate).
    private let currentTier: @Sendable (String) async -> String?
    /// Performs the locked raw-policy write that sets `toolAutonomy[tool] =
    /// "auto"` preserving all other saved keys; returns success. Called ONLY
    /// from the reconcile path, ONLY after re-verification.
    private let applyPromotion: @Sendable (String) async -> Bool
    private let dataRoot: URL
    private let clock: @Sendable () -> Date

    init(
        interval: TimeInterval = 3600,
        gate: @escaping @Sendable () async -> LoopTickOutcome?,
        port: AutonomyPromotionInboxAdapter,
        currentTier: @escaping @Sendable (String) async -> String?,
        applyPromotion: @escaping @Sendable (String) async -> Bool,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = interval
        self.gate = gate
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
    /// payload.tool — a forged approved card naming `shell` or an
    /// `invoke_*` surface must be rejected even if the on-disk tier somehow
    /// reads confirm/supervised). Keeping it in one place means the apply path
    /// and the proposal path can never drift.
    public static func isPromotableTarget(tool: String, tier: String) -> Bool {
        if tool.hasPrefix("invoke_") { return false }          // any agent-invoke surface
        // Code-execution / OS-automation / fs-write name SHAPES — never auto-
        // promote a tool that can run code or mutate the system, namespaced
        // aliases included (gpt-5.5 r2: `mac.shell`,
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
        if hardExcludeTiers.contains(tier) { return false }    // external-consequence guard tiers
        return promotableTiers.contains(tier)                  // must be confirm/supervised
    }

    // MARK: - tick

    public func tickOutcome() async -> LoopTickOutcome {
        // Fail-safe: autonomy off ⇒ neither reconcile nor propose. A security
        // loosening must never apply while the master switch is off.
        if let closed = await gate() { return closed }
        let applied: Int
        let staged: Int
        do {
            applied = try await reconcile()
            staged = try await propose()
        } catch {
            // A staging/annotate WRITE did not land — do not report success.
            // .failed trips the manager's failure-receipt net so the dropped
            // proposal/apply-receipt card is recorded rather than silently lost.
            FileHandle.standardError.write(Data(
                "AutonomyPromotionLoop: staging failed: \(error)\n".utf8))
            return .failed(error: "autonomy promotion staging: \(SwiftNativeLoopScheduler.describeLoopError(error))")
        }
        // The overwhelmingly common tick applies nothing and stages nothing:
        // there is no approved card waiting and no tool has crossed the trust
        // thresholds. That is not success, and stamping it `.completed` made
        // this lane look busy to the dormancy rule forever.
        guard applied > 0 || staged > 0 else {
            return .skipped(reason: "no approved promotions to apply and no new candidates")
        }
        return .completed(
            result: "autonomy promotion applied \(applied), staged \(staged)")
    }

    // MARK: - Reconcile (apply human-approved promotions)

    /// Apply every human-APPROVED, not-yet-executed `autonomy.promote` card.
    /// Runs every tick (cheap, must be responsive). Each card is re-read and
    /// re-verified from the inbox before any policy mutation, and stamped
    /// afterward so it is never re-applied.
    ///
    /// Returns how many promotion cards this pass actually stamped (applied,
    /// skipped-as-ineligible, or failed) — every one of those is a durable
    /// mutation. A pass that found no approved card returns 0.
    @discardableResult
    func reconcile() async throws -> Int {
        let approved = await port.approvedPromotions()
        var stamped = 0
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
                stamped += 1
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
            stamped += 1
        }
        return stamped
    }

    // MARK: - Propose (stage promotion cards)

    /// Scan resolved tool-call approval history and stage a promotion card for
    /// every tool that crosses the trust thresholds. Gated by a daily cooldown
    /// marker so an hourly tick does not re-scan the same data.
    ///
    /// Returns how many promotion cards were staged; 0 when the daily cooldown
    /// holds or no tool crossed the thresholds.
    @discardableResult
    func propose() async throws -> Int {
        guard await shouldScan() else { return 0 }
        let decisions = await port.resolvedToolDecisions()
        let pending = await port.pendingPromotionTools()
        let recentlyDecided = await port.recentlyDecidedPromotionTools()

        // Group decisions by tool.
        var byTool: [String: [ToolDecisionSnapshot]] = [:]
        for d in decisions { byTool[d.tool, default: []].append(d) }

        var staged = 0
        for (tool, rows) in byTool {
            if let candidate = await evaluate(
                tool: tool, rows: rows, pending: pending, recentlyDecided: recentlyDecided) {
                try await port.stagePromotion(candidate)
                staged += 1
            }
        }
        return staged
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
            distinctDays: distinctDays, spanDays: spanDays)
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
        NativeTimestampFormat.parseISO8601(s)
    }

    static func isoStamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// UTC calendar day (yyyy-MM-dd) for distinct-day counting.
    static func dayString(_ date: Date) -> String {
        NativeTimestampFormat.utcDay(date)
    }
}

/// One resolved tool-call approval, reduced to what the candidate math needs.
public struct ToolDecisionSnapshot: Sendable, Equatable {
    public let tool: String
    public let decision: String          // "approved" | "denied" | "canceled"
    public let resolvedAt: String?       // ISO-8601 or nil
    public let remoteResolvable: Bool
    public let localOnly: Bool

    public init(
        tool: String, decision: String,
        resolvedAt: String?, remoteResolvable: Bool, localOnly: Bool
    ) {
        self.tool = tool
        self.decision = decision
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

    public init(
        tool: String, fromTier: String, approvals: Int,
        distinctDays: Int, spanDays: Int
    ) {
        self.tool = tool
        self.fromTier = fromTier
        self.approvals = approvals
        self.distinctDays = distinctDays
        self.spanDays = spanDays
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
