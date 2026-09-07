import Foundation
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
            gate: await swiftDreamREMGate(),
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
            lifecycleObserver: NativeCognitionRuntime.shared
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
        await NativeCognitionRuntime.shared.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            intensity: 0.62,
            valence: 0.35,
            arousal: 0.12,
            metadata: metadata
        )
        return response
    }

    // Read the file-backed diary and project its composite TrustCenter gate.
    func getDreamDiary(limit: Int = 30) async throws -> DreamDiaryResponse {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: diary.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw DreamREMCycleError.underlying("dream_diary is not a directory")
        }
        let impl = makeDreamREMCycle(root: root)
        let moduleEntries = try await impl.listDreamDiary(limit: limit)
        let entries = try Self.decodeDreamEntries(moduleEntries)
        let diaryNames = isDirectory.boolValue
            ? try FileManager.default.contentsOfDirectory(atPath: diary.path)
                .filter { $0.hasSuffix(".md") }
                .sorted(by: >)
            : []
        let totalEntries: Int? = diaryNames.count
        // FileBackedDreamDiary intentionally skips individual unreadable files
        // so one damaged entry does not hide readable ones. Carry that evidence
        // forward: an all-unreadable window must not become "No dreams yet."
        let boundedCount = min(max(1, min(limit, 365)), diaryNames.count)
        let visibleNames = Set(entries.compactMap(\.filename))
        let unreadableEntries = diaryNames.prefix(boundedCount).count {
            !visibleNames.contains($0)
        }
        let enabled = await swiftDreamCompositeEnabled()
        return DreamDiaryResponse(
            entries: entries,
            enabled: enabled,
            totalEntries: totalEntries,
            unreadableEntries: unreadableEntries
        )
    }

    // Missing diary entries preserve the app read route's not-found error.
    func getDreamEntry(date: String) async throws -> DreamEntry {
        let impl = makeDreamREMCycle(root: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        guard let moduleEntry = try await impl.getDreamForDate(date) else {
            throw DaemonError.notFound("/v1/dream/\(date)")
        }
        let entries = try Self.decodeDreamEntries([moduleEntry])
        guard let first = entries.first else {
            throw DaemonError.notFound("/v1/dream/\(date)")
        }
        return first
    }

    /// Preserve the module's encoded field mapping when projecting the app model.
    static func decodeDreamEntries(
        _ moduleEntries: [DreamREMCycle.DreamEntry]
    ) throws -> [DreamEntry] {
        let data = try JSONEncoder().encode(moduleEntries)
        return try JSONDecoder().decode([DreamEntry].self, from: data)
    }

    /// A dream needs both the scheduler and personality-cycle gates.
    func swiftDreamCompositeEnabled() async -> Bool {
        await swiftDreamREMGate().dreamEnabled
    }

    /// TrustCenter supplies policy; DreamREMCycle owns the composite gate arithmetic.
    func swiftDreamREMGate() async -> DreamREMGatePolicy {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let policy = await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicy()
        return Self.dreamREMGate(from: policy)
    }

    /// Manual REM changes persistent, approval-gated state. Unlike a passive
    /// compatibility read, its effect-time policy check must expose damaged
    /// authority bytes rather than turn a fail-closed projection into an
    /// apparently enabled REM cycle.
    func swiftREMGateChecked(root: URL) async throws -> DreamREMGatePolicy {
        let policy = try await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicyChecked()
        return Self.dreamREMGate(from: policy)
    }

    private static func dreamREMGate(
        from policy: [String: JSONValue]
    ) -> DreamREMGatePolicy {
        func boolAt(_ section: String, _ key: String, default def: Bool) -> Bool {
            guard case .object(let sec)? = policy[section] else { return def }
            if case .bool(let b)? = sec[key] { return b }
            return def
        }
        return DreamREMGatePolicy(
            dreamScheduler: boolAt("trainingPolicy", "dream_scheduler", default: false),
            dreamCycleEnabled: boolAt("personalityPolicy", "dream_cycle_enabled", default: true),
            remCycleEnabled: boolAt("trainingPolicy", "rem_cycle_enabled", default: true)
        )
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
            gate: try await swiftREMGateChecked(root: root),
            remStageApproval: BackgroundLoopsAssembly.makeREMProposalStager(dataRoot: root),
            lifecycleObserver: NativeCognitionRuntime.shared
        )
        let result = try await impl.runREM(force: force)
        let response = try Self.foundationDictionary(result.rawResponse)
        let proposals = Self.dreamNumber(response["proposalsGenerated"])
        let archived = Self.dreamNumber(response["archivedEntries"])
        await NativeCognitionRuntime.shared.ingestOrganismSignal(
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
