import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import CognitiveSubstrate
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry


extension NativeClient {
    func runDream(force: Bool = false) async throws -> [String: Any] {
        let root = PersistenceCore.defaultDataRoot()
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
            // …and the dream's mood flows back out into her slow disposition
            // layer, for the same reason (U2a, 2026-07-09).
            dreamMoodSink: BackgroundLoopsAssembly.makeDreamMoodSink(),
            lifecycleObserver: NativeCognitionRuntime.shared
        )
        let result = try await impl.runDream(force: force)
        let response = try Self.foundationDictionary(result.rawResponse)
        guard var metadata = Self.dreamCompletionMetadataIfCommitted(response, force: force) else {
            return response
        }
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

    // PATCH-2026-05-29: dreams-tab GET /v1/dream/diary?limit=N -> {entries, enabled}.
    // WAVE 33 W20: when `.dreamREM` is ON, read the diary in-process from
    // `<dataRoot>/dream_diary/*.md` via the file-backed Swift port — no daemon
    // round-trip. The diary read is PURE FILE I/O on the daemon side too
    //, so this is a true port. The
    // `enabled` composite gate (trainingPolicy.dream_scheduler AND
    // personalityPolicy.dream_cycle_enabled, daemon defaults False/True) is
    // sourced from SwiftNativeTrustCenter to match the daemon's `is_enabled()`.
    // See CUTOVER_PLAN.md §6.96.
    func getDreamDiary(limit: Int = 30) async throws -> DreamDiaryResponse {
        let impl = makeDreamREMCycle(root: PersistenceCore.defaultDataRoot())
        let moduleEntries = try await impl.listDreamDiary(limit: limit)
        let entries = try Self.decodeDreamEntries(moduleEntries)
        let enabled = await swiftDreamCompositeEnabled()
        return DreamDiaryResponse(entries: entries, enabled: enabled)
    }

    // PATCH-2026-05-29: dreams-tab GET /v1/dream/<YYYY-MM-DD> -> a single DreamEntry (404 if missing).
    // WAVE 33 W20: file-backed Swift read when `.dreamREM` is ON. The daemon
    // returns 404 (which the HTTP path surfaces as a thrown error) when the
    // entry is missing; the Swift reader returns nil, so we throw the same
    // not-found shape to keep the caller contract identical
    // (AppModel.fetchDreamEntry maps any throw to nil). See CUTOVER_PLAN.md §6.96.
    func getDreamEntry(date: String) async throws -> DreamEntry {
        let impl = makeDreamREMCycle(root: PersistenceCore.defaultDataRoot())
        guard let moduleEntry = try await impl.getDreamForDate(date) else {
            // Mirror the daemon's JSON 404 contract (Wave 32 W07 set this
            // precedent for SwiftNative reads). AppModel.fetchDreamEntry
            // maps any throw to nil, identical to the HTTP-404 branch.
            throw DaemonError.notFound("/v1/dream/\(date)")
        }
        let entries = try Self.decodeDreamEntries([moduleEntry])
        guard let first = entries.first else {
            throw DaemonError.notFound("/v1/dream/\(date)")
        }
        return first
    }

    /// WAVE 33 W20: byte-compatible conversion from the DreamREMCycle module's
    /// `DreamEntry` (encodes snake_case `modified_at` + content/size/filename)
    /// into the app-side `DreamEntry` model. Re-encode → decode through the same
    /// JSON the daemon would have emitted so the two models stay in lockstep
    /// even if one side adds a field.
    static func decodeDreamEntries(
        _ moduleEntries: [DreamREMCycle.DreamEntry]
    ) throws -> [DreamEntry] {
        let data = try JSONEncoder().encode(moduleEntries)
        return try JSONDecoder().decode([DreamEntry].self, from: data)
    }

    /// WAVE 33 W20: mirror daemon `DreamCycle.is_enabled()` — the composite gate
    /// is `trainingPolicy.dream_scheduler AND personalityPolicy.dream_cycle_enabled`
    ///. Daemon defaults: dream_scheduler False,
    /// dream_cycle_enabled True. Read straight off the SwiftNative trust loader
    /// (in-process, no HTTP) the way makeCommandPaletteContext does. Any load
    /// failure → false (conservative: a Dreams tab can't claim "enabled" if it
    /// can't prove it).
    func swiftDreamCompositeEnabled() async -> Bool {
        await swiftDreamREMGate().dreamEnabled
    }

    /// WAVE 35 W15 (§6.117): single source of truth for the dream + REM gates,
    /// mirroring the daemon's `DreamCycle.is_enabled()` / `REMCycle.is_enabled()`
    ///. Reads the
    /// SwiftNative trust loader in-process (no HTTP) and packs the three policy
    /// bools into the centralized `DreamREMGatePolicy` so the gate math lives in
    /// ONE place (the DreamREMCycle module) instead of being re-derived ad hoc.
    /// Any load failure leaves the policy at its constructor defaults (dream:
    /// scheduler False → dreamEnabled False; rem: enabled True), which is
    /// conservative for the dream composite (a Dreams tab can't claim "enabled"
    /// without proof) and matches the daemon default for REM.
    func swiftDreamREMGate() async -> DreamREMGatePolicy {
        let policy = await SwiftNativeTrustCenter().loadTrustPolicy()
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
    func runRem() async throws -> [String: Any] {
        // remStageApproval: the manual run must stage approvals like the
        // background loop — otherwise "Run REM now" appends proposals that
        // never reach the inbox (the W6 dead-end).
        let root = PersistenceCore.defaultDataRoot()
        let impl = makeDreamREMCycle(
            root: root,
            gate: await swiftDreamREMGate(),
            remStageApproval: BackgroundLoopsAssembly.makeREMProposalStager(dataRoot: root),
            lifecycleObserver: NativeCognitionRuntime.shared
        )
        let result = try await impl.runREM(force: true)
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
                "force": .bool(true),
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

    // SUBSYSTEM #17: retired Swift wrapper runTrainingSelfTest + daemon /v1/training/self_test route — training.py::TrainingLoop.self_test() preserved.
}
