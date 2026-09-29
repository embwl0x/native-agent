import Foundation
import Cognition
import NativeAgentShared
import PersistenceCore
import CognitiveSubstrate
import TrustCenter
import DreamREMCycle


extension NativeClient {
    func runDream(
        force: Bool = false,
        trigger: DreamTrigger = .schedule
    ) async throws -> [String: Any] {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // 2026-06-05 dream-design-restore (pass 2): wire the same
        // MemoryV2-backed Self-half provider the BackgroundLoopsAssembly
        // path uses, so the scheduled nightly run + the manual run-now
        // shim share one source of truth instead of silently defaulting
        // to an empty Self-half here.
        let impl = SwiftNativeDreamREMCycle(
            dataRoot: root,
            gate: await CognitionViewFacade(dataRoot: root).dreamGate(),
            dreamMemoryDeltaProvider: BackgroundLoopsAssembly.makeDreamMemoryDeltaProvider(),
            // Felt tone rides the scheduled nightly too (same lesson as the
            // delta provider: this path bypasses BackgroundLoopsAssembly).
            dreamFeltSummaryProvider: BackgroundLoopsAssembly.makeDreamFeltSummaryProvider(),
            // Studio citation: the felt nodes behind that summary, so the diary
            // can name the journal entry a feeling came from (desk 903, phase 2).
            dreamFeltOriginProvider: BackgroundLoopsAssembly.makeDreamFeltOriginProvider(),
            dreamReceiptSink: BackgroundLoopsAssembly.makeDreamReceiptSink(),
            // …and the dream's mood flows back out into her slow disposition
            // layer, for the same reason (U2a, 2026-07-09).
            dreamMoodSink: BackgroundLoopsAssembly.makeDreamMoodSink(),
            lifecycleObserver: NativeAgentEngine.liveCognition
        )
        let result = try await impl.runDream(force: force, trigger: trigger)
        let response = try Self.foundationDictionary(result.rawResponse)
        guard var metadata = Self.dreamCompletionMetadataIfCommitted(response, force: force) else {
            return response
        }
        metadata["trigger"] = .string(trigger.rawValue)
        let feltProvider = BackgroundLoopsAssembly.makeDreamFeltSummaryProvider()
        let feltSummary = try? await feltProvider()
        if let feltSummary, !feltSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["feltDaySummary"] = .string(feltSummary)
        }
        await NativeAgentEngine.liveCognition.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            intensity: 0.62,
            valence: 0.35,
            arousal: 0.12,
            metadata: metadata
        )
        return response
    }

    // PATCH-2026-05-29: dreams-tab POST /v1/rem/run — manual weekly REM consolidation.
    // Manual REM stays force:true because the weekly marker is distinct from
    // the one-dream-per-night diary contract.
    //
    // 2026-09-06: `force` is now a PARAMETER, defaulting to the manual
    // behaviour. The persisted Sunday scheduler job called this same entry
    // point and inherited force:true, so the weekly claim it was meant to
    // respect was bypassed on every scheduled run — a "Run REM now" click
    // earlier the same week and the 04:30 job both distilled the SAME dreams
    // and appended a second set of proposals under fresh UUIDs (the id dedupe
    // cannot see them as the same row). The scheduler passes force:false.
    func runRem(force: Bool = true) async throws -> [String: Any] {
        // remStageApproval: the manual run must stage approvals like the
        // background loop — otherwise "Run REM now" appends proposals that
        // never reach the inbox (the W6 dead-end).
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let impl = makeDreamREMCycle(
            root: root,
            gate: try await CognitionViewFacade(dataRoot: root).dreamGateChecked(),
            remStageApproval: BackgroundLoopsAssembly.makeREMProposalStager(dataRoot: root),
            lifecycleObserver: NativeAgentEngine.liveCognition
        )
        let result = try await impl.runREM(force: force)
        let response = try Self.foundationDictionary(result.rawResponse)
        let proposals = Self.dreamNumber(response["proposalsGenerated"])
        let archived = Self.dreamNumber(response["archivedEntries"])
        await NativeAgentEngine.liveCognition.ingestOrganismSignal(
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

    func patchDreamCycleEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        let body: [String: Any] = [
            "personalityPolicy": ["dream_cycle_enabled": enabled],
            "trainingPolicy": ["dream_scheduler": enabled],
        ]
        return try await postTrustWrite(body: body)
    }

    // PATCH-2026-05-29: dreams-tab REM-cycle kill switch.
    // trainingPolicy.rem_cycle_enabled gates /v1/rem/run. Minimal deep-merged
    // patch — preserves dream_scheduler / autonomous_training / route_through_promotion.
    func patchRemCycleEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        let body: [String: Any] = ["trainingPolicy": ["rem_cycle_enabled": enabled]]
        return try await postTrustWrite(body: body)
    }

    private static func dreamNumber(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    static func dreamCompletionMetadataIfCommitted(
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
