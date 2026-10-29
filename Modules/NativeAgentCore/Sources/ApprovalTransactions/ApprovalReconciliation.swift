import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ApprovalReconciliation.swift` | Approval execution reconciliation and Desk settlement |
extension ApprovalExecution {
    public static func settleDeskWaits(dataRoot: URL) async {
        guard !Task.isCancelled else { return }
        do {
            let approvals = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: ApprovalFilter())
            guard !Task.isCancelled else { return }
            try await settle {
                do {
                    try await SwiftNativeDeskStore(dataRoot: dataRoot).settleWaits { item in
                        let tokens = [item.blockedReason, item.waitingOn].compactMap { $0?.lowercased() }
                            .flatMap { $0.split { !$0.isHexDigit && $0 != "-" } }.filter { $0.count >= 8 }
                        let named = approvals.filter { row in tokens.contains { row.id.lowercased().hasPrefix($0) } }
                        guard named.count == 1, let row = named.first, let decision = row.decision else { return nil }
                        let line = "Decided: \(decision)" + (row.decidedBy.map { " by \($0)" } ?? "")
                            + (row.resolvedAt.map { " on \($0.prefix(10))" } ?? "")
                        return ("\(line) (approval \(row.id)).", decision == "approved" ? .todo : .blocked,
                                decision == "approved" ? nil : "\(line) — needs a new plan")
                    }
                    return Result<Void, Error>.success(())
                } catch { return .failure(error) }
            }.get()
        } catch {
            nativeLog("[deskApprovalWait] Desk waits on decided approvals were not settled: \(error)")
        }
    }
    /// Settle what was decided while the app was down, then again on every
    /// resolve the inbox publishes, whoever resolved it. Subscribes first so a
    /// decision landing during the launch pass is not missed.
    public static func settleDeskWaitsOnEveryResolve(dataRoot: URL) async {
        let events = await ApprovalLifecycleBus.shared.events()
        await settleDeskWaits(dataRoot: dataRoot)
        for await event in events where event.phase == .resolved {
            guard !Task.isCancelled else { return }
            await settleDeskWaits(dataRoot: dataRoot)
        }
    }
    /// One domain executor, shared by resolution and crash recovery.
    public struct ApprovalExecutor {
        let action: String
        let shouldReconcile: (ApprovalRecord) -> Bool
        let execute: (ApprovalRecord) async throws -> Void
        public init(action: String, shouldReconcile: @escaping (ApprovalRecord) -> Bool = { _ in true },
                    execute: @escaping (ApprovalRecord) async throws -> Void) {
            self.action = action
            self.shouldReconcile = shouldReconcile
            self.execute = execute
        }
    }
    /// Resolved records without execution evidence re-enter their idempotent domain executor.
    @discardableResult
    public func reconcileUnappliedApprovalExecutions(
        dataRoot: URL, records: [ApprovalRecord]
    ) async -> Int {
        let executed = await Self.reconcileUnappliedApprovalExecutions(
            kinds: approvalExecutors(), records: records)
        let chatTools = await reconcileUnappliedChatToolApprovalExecutions(dataRoot: dataRoot, records: records)
        let connectors = await reconcileUnappliedConnectorActionApprovals(dataRoot: dataRoot, records: records)
        await checkpointApprovalReconciliation(dataRoot: dataRoot, records: records, retry: chatTools.failures)
        return executed + chatTools.executed + connectors
    }
    // Owns the Codable cursor object in workflows/approvals: local backup and
    // export include it, phone sync excludes it, PrivacyMap lists Approvals.
    struct ApprovalReconciliationCursor: Codable {
        var stamp = ""
        // Optional so old (stamp, id) cursors safely revisit the boundary.
        var boundaryIDs: Set<String>?
        var retry: [String] = []
        static func path(_ root: URL) -> URL {
            root.appendingPathComponent("workflows/approvals/reconciliation-cursor.json")
        }
        static func read(_ root: URL) throws -> Self {
            let path = path(root)
            guard FileManager.default.fileExists(atPath: path.path) else { return Self() }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        }
    }
    // Reconcile by resolution time, oldest first; failed effects/receipts keep explicit retries.
    public static func resolvedApprovalsForReconciliation(
        dataRoot: URL
    ) async -> [ApprovalRecord] {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        do {
            let cursor = try ApprovalReconciliationCursor.read(dataRoot)
            let rows = try await inbox.list(filter: .resolved)
            // Keep the timestamp boundary open for rows resolved during or after this snapshot.
            let page = rows.filter {
                let stamp = $0.resolvedAt ?? $0.createdAt
                return stamp > cursor.stamp || (stamp == cursor.stamp
                    && !(cursor.boundaryIDs ?? []).contains($0.id))
            }.sorted {
                ($0.resolvedAt ?? $0.createdAt, $0.id) < ($1.resolvedAt ?? $1.createdAt, $1.id)
            }.prefix(SwiftNativeApprovalInbox.storedApprovalCap)
            let ids = Set(page.map(\.id))
            let retainedIDs = Set(rows.map(\.id))
            let retryIDs = Set(cursor.retry.filter { retainedIDs.contains($0) }
                .prefix(SwiftNativeApprovalInbox.storedApprovalCap))
            return Array(page) + rows.filter { record in
                guard !ids.contains(record.id) else { return false }
                if retryIDs.contains(record.id) { return true }
                // Continuity is a separate commit from the replay cursor.
                // Include owed turns and abandoned claims independently of age
                // and the execution cursor. A started turn must be settled.
                guard let replay = Self.chatToolApprovalReplay(from: record, reportingOnly: true),
                      let session = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId),
                      !(replay.surface == "connector_action" && session.hasPrefix("ephemeral:connector_action:")) else { return false }
                if case .object(let state)? = record.chatContinuation,
                   state["started"] != nil, state["done"] != .bool(true) { return true }
                return SwiftNativeApprovalInbox.continuationIsPending(record)
            }
        } catch {
            nativeLog("[approvalReconcile] scan failed: \(String(describing: error))")
            return []
        }
    }
    public func checkpointApprovalReconciliation(
        dataRoot: URL, records: [ApprovalRecord], retry: Set<String> = []
    ) async {
        guard !records.isEmpty else { return }
        do {
            var cursor = try ApprovalReconciliationCursor.read(dataRoot)
            let refreshed = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .resolved)
            let selected = Set(records.map(\.id))
            let unresolved = refreshed.filter {
                selected.contains($0.id) && (($0.decision == "approved" && $0.executedAction == nil)
                    || retry.contains($0.id))
            }.map(\.id)
            let retainedIDs = Set(refreshed.map(\.id))
            cursor.retry.removeAll { selected.contains($0) || !retainedIDs.contains($0) }
            cursor.retry.append(contentsOf: unresolved)
            for row in records {
                let stamp = row.resolvedAt ?? row.createdAt
                if stamp > cursor.stamp {
                    cursor.stamp = stamp
                    cursor.boundaryIDs = []
                }
                if stamp == cursor.stamp {
                    cursor.boundaryIDs = (cursor.boundaryIDs ?? []).union([row.id])
                }
            }
            cursor.boundaryIDs?.formIntersection(Set(refreshed.map(\.id)))
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(cursor), to: ApprovalReconciliationCursor.path(dataRoot))
        } catch {
            nativeLog("[approvalReconcile] checkpoint failed: \(error)")
        }
    }
    /// Execute the checked batch in executor order.
    @discardableResult
    public static func reconcileUnappliedApprovalExecutions(
        kinds: [ApprovalExecutor],
        records: [ApprovalRecord]
    ) async -> Int {
        var executed = 0
        for kind in kinds {
            for rec in records where rec.executedAction == nil
                && ExecutionEventVocabulary.matches(rec.action, kind.action) {
                guard kind.shouldReconcile(rec) else { continue }
                nativeLog("[approvalReconcile] reconciling unexecuted resolved \(kind.action) "
                    + "\(rec.id) (decision: \(rec.decision ?? "?"))")
                do { try await kind.execute(rec) }
                catch { nativeLog("[approvalReconcile] \(kind.action) failed for \(rec.id): \(error)") }
                executed += 1
            }
        }
        return executed
    }
    public func approvalExecutors() -> [ApprovalExecutor] {
        let client = self
        return [
            ApprovalExecutor(
                action: "rem.proposal",
                execute: { await client.applyResolvedREMProposal(from: $0) }),
            ApprovalExecutor(
                action: WorkshopStepApprovalAction.canonical,
                execute: { await client.applyResolvedWorkshopStep(from: $0) }),
            ApprovalExecutor(
                action: "self_improvement.apply",
                shouldReconcile: { $0.decision == "approved" },
                execute: { await client.applyApprovedSelfImprovement(from: $0) }),
            ApprovalExecutor(
                action: "self_evolution.apply",
                execute: { await client.retireSelfEvolutionApproval(from: $0) }),
            ApprovalExecutor(
                action: "browser.open_url",
                execute: { try await self.executeResolvedBrowserRun(from: $0) }),
            ApprovalExecutor(
                action: StudioCanonProposal.approvalAction,
                execute: { await self.applyResolvedStudioCanonProposal(from: $0) }),
            ApprovalExecutor(
                action: SwiftNativeApprovalInbox.skillScriptInstallAction,
                execute: { await self.applyResolvedSkillScriptInstall(from: $0) }),
            ApprovalExecutor(
                action: SwiftNativeApprovalInbox.procedureExactActivationApprovalAction,
                execute: {
                    await Self.applyResolvedProcedureExactActivation(from: $0, dataRoot: self.dataRoot)
                }),
            ApprovalExecutor(action: MemoryRepairOneShot.action,
                execute: { await MemoryRepairOneShot.applyResolvedMemoryRepair(from: $0, dataRoot: self.dataRoot) }),
            ApprovalExecutor(action: MemoryKindBackfill.action,
                execute: { await MemoryApprovalTransactions.applyResolvedKindBackfill(from: $0, dataRoot: self.dataRoot) }),
        ]
    }
}
