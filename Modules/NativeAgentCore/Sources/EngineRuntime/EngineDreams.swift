import Foundation
import AttentionRouting
import BackgroundWork
import DreamREMCycle
import PersistenceCore
// Blueprint: | `EngineDreams.swift` | NativeAgentEngine dream and REM commands, pending proposal staging and notifications; only a committed dream wakes EnginePractice |

extension NativeAgentEngine {
    public static let remStagingCatchUpLimit = DreamBackgroundWork.remStagingCatchUpLimit

    @discardableResult
    public static func stagePendingREMProposalsAtLaunch(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        limit: Int = remStagingCatchUpLimit,
        stager: REMApprovalStager? = nil
    ) async -> Int {
        await DreamBackgroundWork.stagePendingREMProposalsAtLaunch(
            dataRoot: dataRoot, limit: limit, stager: stager,
            notifications: EngineREMProposalNotifications()
        )
    }

}

extension NativeAgentEngine {
    /// One dream pass, for the scheduled nightly and the manual run alike:
    /// the same MemoryV2 Self-half, felt tone, felt origins (the diary names
    /// the journal entry a feeling came from), receipts and mood sink as the
    /// background loop, so neither path silently dreams with an empty
    /// Self-half. A committed dream then reaches the organism.
    public static func runDream(
        dataRoot root: URL,
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = SwiftNativeDreamREMCycle(
            dataRoot: root,
            gate: await CognitionViewFacade(dataRoot: root).dreamGate(),
            dreamMemoryDeltaProvider: DreamBackgroundWork.makeDreamMemoryDeltaProvider(dataRoot: root),
            dreamFeltSummaryProvider: DreamBackgroundWork.makeDreamFeltSummaryProvider(cognitionRuntime: cognition),
            dreamFeltOriginProvider: DreamBackgroundWork.makeDreamFeltOriginProvider(cognitionRuntime: cognition),
            dreamCareNightProvider: DreamBackgroundWork.makeDreamCareNightProvider(cognitionRuntime: cognition),
            dreamReceiptSink: DreamBackgroundWork.makeDreamReceiptSink(cognitionRuntime: cognition),
            // Dream mood flows back into her slow disposition.
            dreamMoodSink: DreamBackgroundWork.makeDreamMoodSink(cognitionRuntime: cognition),
            lifecycleObserver: cognition
        )
        let report = try await DreamBackgroundWork.runDream(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition,
            force: force, trigger: trigger, notifications: EngineREMProposalNotifications()
        )
        // The night's practice follows its dream, off the dream's path
        // (docs/AGENT_IS_THE_APP.md, "Practice compiles").
        if !Task.isCancelled, report.committed {
            EnginePractice.wake(dataRoot: root)
        }
        var response: [String: Any] = [
            "ok": report.errors.isEmpty, "backend": "swift", "force": force,
            "trigger": report.trigger.rawValue, "sessionsProcessed": report.sessionsProcessed,
            "entriesWritten": report.entriesWritten, "disabled": report.disabled, "errors": report.errors,
        ]
        if let skipReason = report.skipReason { response["skipReason"] = skipReason }
        if !report.errors.isEmpty {
            response["remedy"] = (report.repair ?? Repair.remedy(owner: "dream cycle",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("mind.dream")])]), tap: nil)).foundationObject
        }
        return response
    }

    /// Weekly REM consolidation. It stages approvals like the background
    /// loop, so a manual run's proposals reach the inbox. `force` defaults to
    /// the manual behaviour (the weekly marker is distinct from the
    /// one-dream-per-night diary contract); the persisted Sunday job passes
    /// false so a "Run REM now" earlier the same week and the 04:30 job never
    /// distil the same dreams twice.
    public static func runRem(dataRoot root: URL, force: Bool = true, repair: Bool = false) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = makeDreamREMCycle(
            root: root,
            gate: try await CognitionViewFacade(dataRoot: root).dreamGateChecked(),
            remStageApproval: DreamBackgroundWork.makeREMProposalStager(dataRoot: root, notifications: EngineREMProposalNotifications()),
            lifecycleObserver: cognition
        )
        if repair {
            let archived = try await impl.repairREM()
            return ["ok": true, "archivedEntries": archived, "proposalsGenerated": 0, "repaired": true]
        }
        let report = try await DreamBackgroundWork.runREM(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition, force: force
        )
        var response: [String: Any] = [
            "ok": true, "backend": "swift", "force": force,
            "proposalsGenerated": report.proposalsGenerated, "evidenceDatesMin": report.evidenceDatesMin,
            "tombstoneSkips": report.tombstoneSkips, "growthMDEvicted": report.growthMDEvicted,
            "archivedEntries": report.archivedEntries,
        ]
        if let skipReason = report.skipReason { response["skipReason"] = skipReason }
        return response
    }
}

private struct EngineREMProposalNotifications: REMProposalNotificationPort {
    func notifyIfAttentionWorthy(
        dataRoot: URL, itemId: String, title: String, summary: String,
        source: String, severity: String
    ) async {
        await NativeAgentEngine.live.ports.backgroundWork.attention.notifyIfAttentionWorthy(
            dataRoot: dataRoot, itemId: itemId, title: title, summary: summary,
            source: source, severity: severity
        )
    }
}
