import Foundation
import Darwin
import NativeAgentCore
import BackgroundLoops
import ChatOrchestration
import DoctorChecks
import MemoryV2
import PersistenceCore
import ProviderRouting
import DreamREMCycle
import TelegramBot
import ApprovalInbox
import WorkshopExecution
import TrustCenter
import MacControl
import SelfImprovement

// MARK: - Autonomy Promotion

extension BackgroundLoopsAssembly {
    // MARK: - U4 Wave C: autonomy-promotion proposal loop

    /// Raw saved trust policy path. The reconciler writes here directly
    /// (data/trust is write-denied to sandboxed builder tools — Wave B — so
    /// this in-process reconciler is the ONLY writer; there is no self-grant
    /// path through a shell).
    static func trustPolicyPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    /// Hourly loop that mints confirm→auto promotion PROPOSALS from local
    /// approval history and applies human-APPROVED ones via a re-verifying
    /// reconcile. Cards only; nothing self-grants. Gated on `enableAutonomy`
    /// (fail-safe FALSE). See AutonomyPromotionLoop for the security shape.
    static func makeAutonomyPromotionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some EventDeadlineLoopRunner {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let policyPath = trustPolicyPath(dataRoot: dataRoot)
        let loop = AutonomyPromotionLoop(
            // Daily is now the missed-event integrity cadence. Approval/policy
            // mutations and the persisted proposal cooldown drive normal work.
            interval: 24 * 60 * 60,
            // Fail-safe: autonomy OFF ⇒ no proposals, no reconciliation. Read
            // the same enableAutonomy flag the Workshop execution gate uses.
            isEnabled: {
                let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
                if case .bool(true) = policy["enableAutonomy"] ?? .null { return true }
                return false
            },
            port: AutonomyPromotionInboxAdapter(inbox: inbox, dataRoot: dataRoot),
            // RAW saved toolAutonomy[tool]; nil if absent (absent ⇒ default/auto
            // ⇒ not a candidate). NOT loadTrustPolicy — that merges ~75 defaults.
            currentTier: { tool in
                let raw = await SwiftNativePersistenceCore().readJSON(
                    policyPath, defaultValue: .object([:]))
                guard case .object(let obj) = raw,
                      case .object(let autonomy)? = obj["toolAutonomy"],
                      case .string(let tier)? = autonomy[tool] else { return nil }
                return tier
            },
            // Locked RAW-policy write: set toolAutonomy[tool]="auto" preserving
            // EVERY other saved key + other tools. Reads the saved dict (not the
            // normalized one) so we never bake the default catalog into the file.
            applyPromotion: { tool in
                let persistence = SwiftNativePersistenceCore()
                do {
                    return try await persistence.withFileLock(policyPath) { () -> Bool in
                        let raw = await persistence.readJSON(policyPath, defaultValue: .object([:]))
                        var obj: [String: JSONValue]
                        if case .object(let o) = raw { obj = o } else { obj = [:] }
                        var autonomy: [String: JSONValue]
                        if case .object(let a)? = obj["toolAutonomy"] { autonomy = a } else { autonomy = [:] }
                        // CAS + eligibility re-check INSIDE the lock (gpt-5.5
                        // review): the tier the reconciler observed may have been
                        // tightened (the user/TrustCenter) between its check and this
                        // write. Re-read the LOCKED raw tier and apply the SAME
                        // eligibility predicate the proposer uses; write "auto"
                        // ONLY if still a legitimate target. Never clobber a
                        // tightening; never promote an ineligible/forged target.
                        let lockedTier: String? = {
                            if case .string(let t)? = autonomy[tool] { return t }
                            return nil
                        }()
                        guard let lockedTier,
                              AutonomyPromotionLoop.isPromotableTarget(tool: tool, tier: lockedTier)
                        else { return false }   // not eligible under the lock → no write
                        autonomy[tool] = .string("auto")
                        obj["toolAutonomy"] = .object(autonomy)
                        try await persistence.writeJSON(.object(obj), to: policyPath)
                        return true
                    }
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
            policyPath: policyPath
        )
    }
}

private struct AutonomyPromotionEventDeadlineRunner: EventDeadlineLoopRunner {
    let underlying: AutonomyPromotionLoop
    let dataRoot: URL
    let policyPath: URL

    var loopId: String { underlying.loopId }
    var interval: TimeInterval { underlying.interval }
    var tickTimeoutOverride: TimeInterval? { underlying.tickTimeoutOverride }

    func tick() async { await underlying.tick() }
    func tickOutcome() async -> LoopTickOutcome { await underlying.tickOutcome() }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            policyPath,
        ])
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

/// Concrete `AutonomyPromotionInboxPort` over `SwiftNativeApprovalInbox`,
/// mapping `ApprovalRecord` ↔ the loop's lightweight Sendable snapshots
/// (keeping BackgroundLoops free of any ApprovalInbox type). All methods are
/// non-throwing — IO errors are logged and swallowed (empty/nil) so a
/// transient inbox failure never throws out of the loop's `tick()`.
struct AutonomyPromotionInboxAdapter: AutonomyPromotionInboxPort {
    let inbox: SwiftNativeApprovalInbox
    let dataRoot: URL

    /// Meta op-actions that are NOT tool-call cards — excluded from the
    /// approval-history scan (the loop treats `action` as a tool name).
    static let metaActions: Set<String> = [
        "autonomy.promote", "self_improvement.apply", "approval",
        "backup_restore", "mission.step", "memory.repair",
    ]
    static let metaPrefixes: [String] = ["memory.", "improvement."]

    private static func isToolCard(_ action: String) -> Bool {
        if action.isEmpty { return false }
        if metaActions.contains(action) { return false }
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
                tool: rec.action, decision: decision, createdAt: rec.createdAt,
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
        let preview = "[promote \(candidate.tool): \(candidate.fromTier)→auto] approved "
            + "\(candidate.approvals)/\(candidate.approvals) over \(candidate.spanDays)d "
            + "(\(candidate.distinctDays) active days)"
        let body: JSONValue = .object([
            "title": .string("Promote \(candidate.tool) to auto?"),
            "action": .string("autonomy.promote"),
            // SECURITY loosening → high risk. remoteResolvable is forced false
            // by ApprovalInbox's localOnlyActions (U4 Wave C edit).
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
                "windowDays": .int(Int64(candidate.windowDays)),
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

    /// Stamp `executedAction` + `detail` directly on requests.json under the
    /// persistence flock (the memory.repair / consolidation-gate convention —
    /// ApprovalInbox has no protocol method for this).
    func annotate(id: String, executedAction: JSONValue, detail: String) async throws {
        let path = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                let raw = await persistence.readJSON(path, defaultValue: .array([]))
                guard case .array(var rows) = raw else { return }
                for idx in rows.indices {
                    guard case .object(var obj) = rows[idx],
                          case .string(let rowID)? = obj["id"],
                          rowID == id else { continue }
                    obj["executedAction"] = executedAction
                    obj["detail"] = .string(detail)
                    rows[idx] = .object(obj)
                    break
                }
                try await persistence.writeJSON(.array(rows), to: path)
            }
        } catch {
            // FIX 3 (A4.5): rethrow — a swallowed annotate() left the card
            // unstamped (silently re-applicable) while the tick reported success.
            FileHandle.standardError.write(Data(
                "AutonomyPromotion: annotate failed for \(id): \(error)\n".utf8))
            throw error
        }
    }
}
