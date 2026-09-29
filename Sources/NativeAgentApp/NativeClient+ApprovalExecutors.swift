import Foundation
import ChatOrchestration
import NativeAgentShared
import ApprovalTransactions
import ApprovalInbox
import PersistenceCore
import Browser
import MemoryV2

extension NativeClient {
    var approvalTransactions: ApprovalTransactionCoordinator {
        ApprovalTransactionCoordinator(effects: NativeClientApprovalTransactionEffects(client: self),
                                       dataRootOverride: dataRootOverride)
    }

    private static var approvalTransactions: ApprovalTransactionCoordinator {
        NativeClient(baseURL: "").approvalTransactions
    }

    typealias ApprovalExecutionReconcileKind = ApprovalTransactionCoordinator.ApprovalExecutionReconcileKind
    typealias ChatApprovalContinuation = ApprovalTransactionCoordinator.ChatApprovalContinuation
    typealias ApprovalReceiptTools = ApprovalTransactionCoordinator.ApprovalReceiptTools

    static func memoryHygieneReceipt(
        _ report: MemoryHygieneReport
    ) -> (fields: [String: JSONValue], detail: String) {
        ApprovalTransactionCoordinator.memoryHygieneReceipt(ApprovalMemoryHygieneResult(id: report.id, status: report.status, reason: report.reason, consolidationRunId: report.consolidationRunId))
    }

    static func applyResolvedProceduralSkillProposal(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await Self.approvalTransactions.applyResolvedProceduralSkillProposal(from: rec, dataRoot: dataRoot)
    }

    static func applyResolvedStudioCanonProposal(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await Self.approvalTransactions.applyResolvedStudioCanonProposal(from: rec, dataRoot: dataRoot)
    }

    static func reconcileUnappliedApprovalExecutions() async {
        await Self.approvalTransactions.reconcileUnappliedApprovalExecutions()
    }

    static func resolvedApprovalsForReconciliation(
        dataRoot: URL, records: [ApprovalRecord]? = nil
    ) async -> [ApprovalRecord] {
        await ApprovalTransactionCoordinator.resolvedApprovalsForReconciliation(dataRoot: dataRoot, records: records)
    }

    static func checkpointApprovalReconciliation(
        dataRoot: URL, records: [ApprovalRecord], retry: Set<String> = []
    ) async {
        await Self.approvalTransactions.checkpointApprovalReconciliation(dataRoot: dataRoot, records: records, retry: retry)
    }

    static func reconcileUnappliedApprovalExecutions(
        dataRoot: URL,
        kinds: [ApprovalExecutionReconcileKind],
        records: [ApprovalRecord]? = nil
    ) async {
        await ApprovalTransactionCoordinator.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, kinds: kinds, records: records)
    }

    static func selfImprovementReconcileEligible(_ rec: ApprovalRecord) -> Bool {
        ApprovalTransactionCoordinator.selfImprovementReconcileEligible(rec)
    }

    static func productionApprovalReconcileKinds() -> [ApprovalExecutionReconcileKind] {
        Self.approvalTransactions.productionApprovalReconcileKinds()
    }

    static func applyResolvedAgentMailSend(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        await Self.approvalTransactions.applyResolvedAgentMailSend(from: rec, dataRoot: dataRoot)
    }

    @discardableResult
    static func reconcileUnappliedChatToolApprovalExecutions(
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        records: [ApprovalRecord]? = nil,
        continuation: @escaping ChatApprovalContinuation = continueChatToolApproval
    ) async -> Set<String> {
        await Self.approvalTransactions.reconcileUnappliedChatToolApprovalExecutions(dataRoot: dataRoot, records: records, continuation: continuation)
    }

    static func reconcileUnappliedConnectorActionApprovals(
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        records: [ApprovalRecord]? = nil
    ) async {
        await Self.approvalTransactions.reconcileUnappliedConnectorActionApprovals(dataRoot: dataRoot, records: records)
    }

    static func applyResolvedChatToolApproval(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        continuation: @escaping ChatApprovalContinuation = continueChatToolApproval
    ) async {
        await Self.approvalTransactions.applyResolvedChatToolApproval(from: rec, dataRoot: dataRoot, continuation: continuation)
    }

    @discardableResult
    static func ensureChatToolApprovalOutcomeReceipt(
        from rec: ApprovalRecord,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot(),
        continuation: @escaping ChatApprovalContinuation = continueChatToolApproval
    ) async -> Bool {
        await Self.approvalTransactions.ensureChatToolApprovalOutcomeReceipt(from: rec, dataRoot: dataRoot, continuation: continuation)
    }

    static func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws {
        try await Self.approvalTransactions.continueChatToolApproval(dataRoot: dataRoot, sessionID: sessionID, envelope: envelope, prompt: prompt)
    }

    static func chatToolApprovalExecutionReceipt(
        toolName: String,
        surface: String,
        result: JSONValue
    ) -> (action: JSONValue, preview: String) {
        ApprovalTransactionCoordinator.chatToolApprovalExecutionReceipt(toolName: toolName, surface: surface, result: result)
    }

    static func reconcileResolvedBrowserRun(
        from rec: ApprovalRecord,
        runsPath: URL = SwiftNativeBrowserClient.defaultClient().runsPath,
        dataRoot: URL = SwiftNativeApprovalInbox.defaultDataRoot()
    ) async {
        await Self.approvalTransactions.reconcileResolvedBrowserRun(from: rec, runsPath: runsPath, dataRoot: dataRoot)
    }

    static func terminalBrowserRun(runID: String, runsPath: URL) async throws -> JSONValue? {
        try await ApprovalTransactionCoordinator.terminalBrowserRun(runID: runID, runsPath: runsPath)
    }

    func resolveApproval(
        id: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui")
    ) async throws -> ApprovalRecord {
        try await approvalTransactions.resolveApproval(id: id, decision: decision, provenance: provenance)
    }

}
