import Foundation
import ChatTurnContracts
import Experiences
import SchedulerExecution
import AttentionRouting
import Cognition
import NativeAgentCore
import ProviderRouting
import BackgroundWork
import DreamREMCycle
import PersistenceCore
// Blueprint: | `EngineDreams.swift` | Manual and scheduled dreams share one matter and delivery receipt; previews commit nothing |

extension NativeAgentEngine {
    /// Preview dreams use lived material without draining owed moments or recording a live run.
    public static func previewDream(dataRoot root: URL) async throws -> MindClockResult {
        let fields: [String: JSONValue] = ["preview": .bool(true), "effects": .string("none"), "execution": .string("preview")]
        guard root.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return NativeCognitionRuntime.recordClockRun("dream", .init("preview_refused",
                "Live dream providers are unavailable for an alternate data root; preview did not open it.", fields: fields))
        }
        let providerGuard = ProviderStreamGuardConfig.fromEnvironment()
        try providerGuard.validate()
        guard providerGuard.wallTimeout > 0 else {
            return NativeCognitionRuntime.recordClockRun("dream", .init("preview_refused",
                "The provider completion wall bound is disabled. Preview refuses an unbounded generation.", fields: fields))
        }
        let cognition = cognitionRuntime(for: root)
        let result: MindClockResult
        if let why = await cognition.mindPreviewRefusal() {
            result = .init("unavailable", why, fields: fields)
        } else {
            // Preview spends provider usage without charging the calling turn’s budget or feeding body/vitals observers.
            let impl = try await dreamCycle(dataRoot: root, preview: true)
            let report = try await impl.previewDream()
            var fields = fields
            fields["sessionsProcessed"] = .int(Int64(report.sessionsProcessed))
            fields["owedMomentsNotDrained"] = .bool(true)
            if report.disabled {
                result = .init("held", DreamREMGatePolicy.dreamDisabledDetail, fields: fields)
            } else if !report.errors.isEmpty {
                result = .init("unavailable", report.errors.joined(separator: "; "), fields: fields)
            } else if let generated = report.preview {
                fields["dream"] = generated
                if let night = report.careNight {
                    let judgment = await cognition.substrate.previewCaresNight(night)
                    fields["careJudgments"] = judgment
                    if judgment.objectValue?["outcome"] != .string("evaluated_on_copy") {
                        return NativeCognitionRuntime.recordClockRun("dream", .init("unavailable",
                            judgment.objectValue?["why"]?.stringValue ?? "Current cares could not be judged.", fields: fields))
                    }
                } else {
                    return NativeCognitionRuntime.recordClockRun("dream", .init("unavailable",
                        "The dream generated, but its care material was unavailable; no care verdict is available.", fields: fields))
                }
                result = .init("would_dream", """
                    Generated and decoded the real dream. Care answers, stance changes and merges were evaluated on a copy of current cares. Nothing was \
                    applied or recorded as learning; provider usage was spent.
                    """, fields: fields)
            } else {
                result = .init("held", report.skipReason ?? "No dream was generated; no verdict is available.", fields: fields)
            }
        }
        return NativeCognitionRuntime.recordClockRun("dream", result)
    }

    private static func dreamCycle(dataRoot root: URL, preview: Bool = false) async throws -> SwiftNativeDreamREMCycle {
        let cognition = cognitionRuntime(for: root)
        return try await SwiftNativeDreamREMCycle(
            dataRoot: root,
            gate: CognitionViewFacade(dataRoot: root).dreamGate(),
            dreamMemoryDeltaProvider: DreamBackgroundWork.makeDreamMemoryDeltaProvider(dataRoot: root),
            dreamSurpriseProvider: DreamBackgroundWork.makeDreamSurpriseProvider(dataRoot: root, cognitionRuntime: cognition),
            dreamFeltSummaryProvider: DreamBackgroundWork.makeDreamFeltSummaryProvider(cognitionRuntime: cognition),
            dreamFeltOriginProvider: DreamBackgroundWork.makeDreamFeltOriginProvider(cognitionRuntime: cognition),
            dreamCareNightProvider: DreamBackgroundWork.makeDreamCareNightProvider(cognitionRuntime: cognition),
            dreamReceiptSink: preview ? nil : DreamBackgroundWork.makeDreamReceiptSink(cognitionRuntime: cognition),
            dreamMoodSink: preview ? nil : DreamBackgroundWork.makeDreamMoodSink(cognitionRuntime: cognition),
            lifecycleObserver: preview ? nil : cognition
        )
    }

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
    /// Manual and scheduled dreams share the same Self-half, felt origins and receipt owners; committed dreams reach the organism.
    public static func runDream(
        dataRoot root: URL,
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = try await dreamCycle(dataRoot: root)
        let report = try await DreamBackgroundWork.runDream(
            dataRoot: root, cycle: impl, cognitionRuntime: cognition,
            force: force, trigger: trigger, notifications: EngineREMProposalNotifications()
        )
        var response: [String: Any] = [
            "ok": report.errors.isEmpty, "backend": "swift", "force": force,
            "trigger": report.trigger.rawValue, "sessionsProcessed": report.sessionsProcessed,
            "entriesWritten": report.entriesWritten, "disabled": report.disabled, "errors": report.errors,
        ]
        if let skipReason = report.skipReason { response["skipReason"] = skipReason }
        if !report.busy.isEmpty { response["busy"] = report.busy }
        if !report.errors.isEmpty {
            response["remedy"] = (report.repair ?? Repair.remedy(owner: "dream cycle",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("mind.dream")])]), tap: nil)).foundationObject
        }
        let output = JSONValue.object(try NativeActionWire.jsonValueBody(response))
        let saved: Result<JSONValue, Error> = await settle {
            do {
                return .success(try await SchedulerDueJobRunner(root: root).surfaceDreamResult(output))
            } catch { return .failure(error) }
        }
        if case .object(let receipt) = try saved.get() {
            for (key, value) in receipt { response[key] = value.foundationObject }
        }
        return response
    }

    /// Manual and weekly REM share approval staging; the weekly job passes `force: false` so an earlier manual run cannot distil the same dreams twice.
    public static func runRem(dataRoot root: URL, force: Bool = true, repair: Bool = false) async throws -> [String: Any] {
        let cognition = cognitionRuntime(for: root)
        let impl = try makeDreamREMCycle(
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
            "outcome": report.outcome.rawValue,
            "tombstoneSkips": report.tombstoneSkips, "growthMDEvicted": report.growthMDEvicted,
            "archivedEntries": report.archivedEntries,
        ]
        if let skipReason = report.skipReason { response["skipReason"] = skipReason }
        return response
    }
}

private struct EngineREMProposalNotifications: REMProposalNotificationPort {
    func tell(_ matter: Matter, dataRoot: URL, reach: AttentionRouter.Reach, turn: Turn?) async throws -> AttentionOutcome {
        try await EngineBackgroundWorkPort().tell(matter, dataRoot: dataRoot, reach: reach, turn: turn)
    }
}
