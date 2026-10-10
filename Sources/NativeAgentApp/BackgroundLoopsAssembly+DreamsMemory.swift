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

// MARK: - Dream and REM runs

extension BackgroundLoopsAssembly {
    /// One dream pass, for the scheduled nightly and the manual run alike:
    /// the same MemoryV2 Self-half, felt tone, felt origins (the diary names
    /// the journal entry a feeling came from), receipts and mood sink as the
    /// background loop, so neither path silently dreams with an empty
    /// Self-half. A committed dream then reaches the organism.
    static func runDream(
        dataRoot root: URL,
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = SwiftNativeDreamREMCycle(
            dataRoot: root,
            gate: await CognitionViewFacade(dataRoot: root).dreamGate(),
            dreamMemoryDeltaProvider: makeDreamMemoryDeltaProvider(dataRoot: root),
            dreamFeltSummaryProvider: makeDreamFeltSummaryProvider(dataRoot: root),
            dreamFeltOriginProvider: makeDreamFeltOriginProvider(dataRoot: root),
            dreamReceiptSink: makeDreamReceiptSink(dataRoot: root),
            // …and the dream's mood flows back out into her slow disposition
            // layer, for the same reason (U2a, 2026-07-09).
            dreamMoodSink: makeDreamMoodSink(dataRoot: root),
            lifecycleObserver: cognition
        )
        let result = try await impl.runDream(force: force, trigger: trigger)
        let response = try foundationDictionary(result.rawResponse)
        guard var metadata = dreamCompletionMetadataIfCommitted(response, force: force) else {
            return response
        }
        metadata["trigger"] = .string(trigger.rawValue)
        let feltSummary = try? await makeDreamFeltSummaryProvider(dataRoot: root)()
        if let feltSummary, !feltSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["feltDaySummary"] = .string(feltSummary)
        }
        await cognition.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            intensity: 0.62,
            valence: 0.35,
            arousal: 0.12,
            metadata: metadata
        )
        return response
    }

    /// Weekly REM consolidation. It stages approvals like the background
    /// loop, so a manual run's proposals reach the inbox. `force` defaults to
    /// the manual behaviour (the weekly marker is distinct from the
    /// one-dream-per-night diary contract); the persisted Sunday job passes
    /// false so a "Run REM now" earlier the same week and the 04:30 job never
    /// distil the same dreams twice.
    static func runRem(dataRoot root: URL, force: Bool = true) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = makeDreamREMCycle(
            root: root,
            gate: try await CognitionViewFacade(dataRoot: root).dreamGateChecked(),
            remStageApproval: makeREMProposalStager(dataRoot: root),
            lifecycleObserver: cognition
        )
        let result = try await impl.runREM(force: force)
        let response = try foundationDictionary(result.rawResponse)
        guard response["skipReason"] == nil else { return response }
        let proposals = dreamNumber(response["proposalsGenerated"])
        let archived = dreamNumber(response["archivedEntries"])
        await cognition.ingestOrganismSignal(
            kind: .remIntegrated,
            sourceOrgan: "rem",
            intensity: proposals > 0 ? 0.58 : 0.22,
            valence: 0.28,
            arousal: 0.14,
            metadata: [
                "proposalsGenerated": .int(Int64(proposals)),
                "archivedEntries": .int(Int64(archived)),
                "force": .bool(force),
                "feltDaySummary": .string("REM integrated \(proposals) proposal(s) from recent dream evidence."),
            ]
        )
        return response
    }

    private static func foundationDictionary(_ value: JSONValue) throws -> [String: Any] {
        let data = try value.serializedData(pretty: false)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func dreamNumber(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func dreamCompletionMetadataIfCommitted(
        _ response: [String: Any],
        force: Bool
    ) -> [String: JSONValue]? {
        let entries = dreamNumber(response["entriesWritten"])
        let disabled = response["disabled"] as? Bool ?? false
        let errors = response["errors"] as? [String] ?? []
        guard entries > 0, !disabled, errors.isEmpty else { return nil }

        return [
            "entriesWritten": .int(Int64(entries)),
            "sessionsProcessed": .int(Int64(dreamNumber(response["sessionsProcessed"]))),
            "force": .bool(force),
        ]
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
