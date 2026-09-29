import Foundation
import BackgroundLoops
import BackgroundWork
import Cognition
import DreamREMCycle
import PersistenceCore

extension BackgroundLoopsAssembly {
    static let remStagingCatchUpLimit = DreamBackgroundWork.remStagingCatchUpLimit

    @discardableResult
    static func stagePendingREMProposalsAtLaunch(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        limit: Int = remStagingCatchUpLimit,
        stager: REMApprovalStager? = nil
    ) async -> Int {
        await DreamBackgroundWork.stagePendingREMProposalsAtLaunch(
            dataRoot: dataRoot, limit: limit, stager: stager,
            notifications: AppREMProposalNotifications()
        )
    }

    static func makeREMProposalStager(dataRoot: URL) -> REMApprovalStager {
        DreamBackgroundWork.makeREMProposalStager(
            dataRoot: dataRoot, notifications: AppREMProposalNotifications()
        )
    }

    static func makeMemoryConsolidationLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        MemoryConsolidationHygieneRunner(dataRoot: dataRoot)
    }

    static func makeDreamMemoryDeltaProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DreamMemoryDeltaProvider {
        DreamBackgroundWork.makeDreamMemoryDeltaProvider(dataRoot: dataRoot)
    }

    static func makeDreamFeltSummaryProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamFeltSummaryProvider {
        DreamBackgroundWork.makeDreamFeltSummaryProvider(
            dataRoot: dataRoot, cognitionRuntime: cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        )
    }

    static func makeDreamFeltOriginProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamFeltOriginProvider {
        DreamBackgroundWork.makeDreamFeltOriginProvider(
            dataRoot: dataRoot, cognitionRuntime: cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        )
    }

    static func makeDreamReceiptSink(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamReceiptSink {
        DreamBackgroundWork.makeDreamReceiptSink(
            dataRoot: dataRoot, cognitionRuntime: cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        )
    }

    static func makeDreamMoodSink(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        cognitionRuntime: NativeCognitionRuntime? = nil
    ) -> DreamDatedMoodSink {
        DreamBackgroundWork.makeDreamMoodSink(
            dataRoot: dataRoot, cognitionRuntime: cognitionRuntime ?? self.cognitionRuntime(for: dataRoot)
        )
    }
}

private struct AppREMProposalNotifications: REMProposalNotificationPort {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await InboxPushNotifier.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }
}
