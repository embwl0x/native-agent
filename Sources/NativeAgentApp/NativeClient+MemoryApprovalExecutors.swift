import Foundation
import PersistenceCore
import ApprovalInbox
import ApprovalTransactions

extension NativeClient {
    static func applyResolvedMemoryRepair(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryApprovalTransactions.applyResolvedMemoryRepair(from: rec, dataRoot: dataRoot)
    }

    static func reconcileUnappliedMemoryRepairs(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryApprovalTransactions.reconcileUnappliedMemoryRepairs(dataRoot: dataRoot)
    }

    static func applyResolvedKindBackfill(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryApprovalTransactions.applyResolvedKindBackfill(from: rec, dataRoot: dataRoot)
    }

    static func reconcileUnappliedKindBackfills(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryApprovalTransactions.reconcileUnappliedKindBackfills(dataRoot: dataRoot)
    }

    static func stageKindBackfillIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryApprovalTransactions.stageKindBackfillIfNeeded(
            dataRoot: dataRoot,
            ports: MemoryApprovalTransactionPorts(
                makeLLMClient: { BackgroundLoopsAssembly.makeSharedLLMClient() }
            )
        )
    }
}
