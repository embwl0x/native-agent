import Foundation
import Observation
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
import TrustCenter
import DreamREMCycle
import DoctorChecks
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
import Cognition
import Context
import ContextFlow

/// The identity field is one of the few profile fields with immediate live UI
/// effect.  Its save outcome must be derived from the persisted profile the
/// writer returned, not from the name the editor attempted to submit.
enum PersonalityNameSaveOutcome: Equatable {
    case saved(PersonalityProfile)
    case refused(String)
    case failed(String)
}

/// A personality-document refresh either replaces the in-memory document set
/// with one canonical reader result, or leaves that last known set intact and
/// reports exactly why it could not be refreshed.
enum PersonalityDocumentsReloadOutcome: Equatable {
    case loaded(documentCount: Int)
    case failed(detail: String, retainedDocumentCount: Int)
}

@MainActor
extension AppModel {
    /// The persona owner for this model's data root. An injected root reads
    /// only its own persona, never the process's seed roots.
    var personaEngine: SwiftNativePersonaEngine {
        dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? SwiftNativePersonaEngine()
    }

    /// The saved profile, read and parsed off the main actor.
    nonisolated static func readPersonality(dataRoot: URL) async throws -> PersonalityProfile {
        try await Task.detached { try PersonaCompiler.compileProfile(dataRoot: dataRoot).sharedProfile }.value
    }

    /// The personality growth summary: the chat packet's fingerprint and
    /// kind, the persona-feedback memory count, and this week's substrate
    /// changes from the live mind.
    nonisolated static func readPersonalityGrowth() async throws -> PersonalityGrowthSummary {
        try await RuntimeReadProjection.swiftPersonalityGrowth {
            await NativeAgentEngine.liveCognition.substrate.growthWeekLines()
        }
    }

    /// `training/artifacts/index.json`; missing reads as `[]`.
    nonisolated static func readTrainingArtifacts(dataRoot: URL) async throws -> [TrainingArtifact] {
        let url = dataRoot
            .appendingPathComponent("training", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("index.json")
        return try RuntimeReadProjection.readLocalJSON(url, fallbackJSON: "[]")
    }

    /// `release/checklist.json`; missing reads as an empty checklist (every
    /// field decodes if present).
    nonisolated static func readReleaseChecklist(dataRoot: URL) async throws -> ReleaseChecklist {
        let url = dataRoot
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("checklist.json")
        return try RuntimeReadProjection.readLocalJSON(url, fallbackJSON: "{}")
    }

    @MainActor
    func savePersonality(_ profile: PersonalityProfile) async {
        // The page shows the failure in `statusText`; a caller that has to
        // ANSWER for the save (app_setting_set's receipt) uses the throwing
        // form, because a swallowed error there reads as a successful write.
        try? await savePersonalityChecked(profile)
    }

    /// The same save, with the persistence error left intact.
    @MainActor
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        do {
            personality = try await personaEngine.savePersonality(profile).sharedProfile
            teachMemoryHygieneName()
            compiledPersonality = try? await PersonaCompiler(engine: personaEngine).compiledPacket(surface: "chat")
            if let listing = try? await personaEngine.listPersonaDocSpecs() {
                personalityDocs = listing.docs
            }
            statusText = "Personality saved"
            await refreshAll()
        } catch {
            setFailureStatus(error, action: "save the personality")
            throw error
        }
    }

    @discardableResult
    func savePersonalityName(_ rawName: String) async -> PersonalityNameSaveOutcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let detail = "Enter a name before saving."
            statusText = "Name save refused: \(detail)"
            return .refused(detail)
        }
        // Generic persona labels are intentionally rendered as the fallback
        // across the live app. Refuse them here so a claimed saved name cannot
        // immediately disappear into "NativeAgent" on the next render.
        guard !NativeAgentIdentity.displayName(name, fallback: "").isEmpty else {
            let detail = "Choose a specific name instead of a generic persona label."
            statusText = "Name save refused: \(detail)"
            return .refused(detail)
        }
        do {
            let saved = try await personaEngine.savePersonality(body: ["name": .string(name)]).sharedProfile
            personality = saved
            teachMemoryHygieneName()
            statusText = "Name saved as \(saved.name)"
            return .saved(saved)
        } catch {
            let detail = UserFacingError.cause(error, action: "save the name")
            setFailureStatus("Couldn't save the name. " + detail, cause: error)
            return .failed(detail)
        }
    }

    /// TTL for reusing a completed Doctor run when building the Support
    /// Snapshot instead of re-running the whole offline pass (B2.6d).
    nonisolated static let supportSnapshotDoctorReuseTTL: TimeInterval = 90

    enum SupportDiagnosticsLoadOutcome: Equatable {
        case unavailable(String)
        case loaded(SupportDiagnostics, reusedDoctorReport: Bool)
        case failed(String)
    }

    @MainActor
    @discardableResult
    func loadSupportDiagnostics() async -> SupportDiagnosticsLoadOutcome {
        guard !supportDiagnosticsLoading else {
            return .unavailable("A Support Snapshot is already being prepared.")
        }
        guard !engine.doctor.isRunning else {
            return .unavailable("Doctor is currently running. Wait for it to finish before preparing a Support Snapshot.")
        }
        supportDiagnosticsLoading = true
        defer { supportDiagnosticsLoading = false }
        do {
            // B2.6d: if a full Doctor run finished within the TTL, reuse its
            // result (identical offline rollup) rather than re-running the
            // whole pass. Falls back to a fresh run when stale or never run.
            let reuse: DoctorReport? = {
                guard let report = engine.doctor.report,
                      let completedAt = engine.doctor.reportCompletedAt else { return nil }
                let age = Date().timeIntervalSince(completedAt)
                guard age >= 0, age < Self.supportSnapshotDoctorReuseTTL
                else { return nil }
                return report
            }()
            let diagnostics = try await SupportDiagnostics.read(reusing: reuse)
            supportDiagnostics = diagnostics
            statusText = reuse != nil
                ? "Support diagnostics refreshed (reused recent Doctor result)"
                : "Support diagnostics refreshed"
            return .loaded(diagnostics, reusedDoctorReport: reuse != nil)
        } catch {
            let detail = UserFacingError.cause(error, action: "gather support diagnostics")
            setFailureStatus("Couldn't gather support diagnostics. " + detail, cause: error)
            return .failed(detail)
        }
    }

    @MainActor
    @discardableResult
    func loadPersonalityDocs() async -> Bool {
        if case .loaded = await reloadPersonalityDocuments() { return true }
        return false
    }

    @MainActor
    @discardableResult
    func reloadPersonalityDocuments() async -> PersonalityDocumentsReloadOutcome {
        do {
            personalityDocs = try await personaEngine.listPersonaDocSpecs().docs
            statusText = "Personality documents reloaded"
            return .loaded(documentCount: personalityDocs.count)
        } catch {
            let detail = UserFacingError.cause(error, action: "load the personality docs")
            setFailureStatus("Couldn't load the personality docs. " + detail, cause: error)
            return .failed(detail: detail, retainedDocumentCount: personalityDocs.count)
        }
    }

    @MainActor
    @discardableResult
    func savePersonalityDoc(id: String, content: String) async -> Bool {
        do {
            let saved = try await personaEngine.savePersonalityDoc(id: id, content: content)
            if let index = personalityDocs.firstIndex(where: { $0.id == saved.id }) {
                personalityDocs[index] = saved
            } else {
                personalityDocs.append(saved)
            }
            compiledPersonality = try? await PersonaCompiler(engine: personaEngine).compiledPacket(surface: "chat")
            statusText = "\(saved.filename) saved"
            return true
        } catch {
            setFailureStatus(error, action: "save that personality doc")
            return false
        }
    }

    /// This ISO week's and last week's misses by lesson; nil when the ledger
    /// could not be read.
    nonisolated static func readMisses(dataRoot: URL) async -> [MemoryMissLesson]? {
        try? await MemoryStatusProjection.misses(
            dataRoot: dataRoot, weeks: [MemoryStatusProjection.isoWeek(), MemoryStatusProjection.isoWeek(ago: 1)])
    }

    // PATCH-2026-05-07: living-memory AppModel methods for memory proposals
    // U5 W-A item 1 (2026-06-11): these five loaders previously swallowed
    // failures with bare `try? ... ?? []`, so a read/decode error rendered
    // as a healthy-EMPTY panel — indistinguishable from "no data". They now
    // ride decodeLogged, which logs the endpoint + error and records it in
    // lastRefreshError instead of fabricating an empty success.
    @MainActor
    func loadMemoryProposals(animateDecision: Bool = false) async {
        let proposals = await decodeLogged("getMemoryProposals", default: []) {
            try await engine.memory.proposals(status: "pending")
        }
        withAnimation(animateDecision ? NativeAgentMotion.arrive : nil) {
            engine.memory.proposals = proposals
        }
    }

    @MainActor
    func approveMemoryProposal(id: String) async throws {
        _ = try await engine.memory.accept(proposalID: id)
        await loadMemoryProposals(animateDecision: true)
        engine.approvals.records = (try? await engine.approvals.list()) ?? engine.approvals.records
    }

    @MainActor
    func rejectMemoryProposal(id: String, reason: String = "") async throws {
        try await engine.memory.reject(proposalID: id, reason: reason)
        await loadMemoryProposals(animateDecision: true)
        engine.approvals.records = (try? await engine.approvals.list()) ?? engine.approvals.records
    }

    @MainActor
    func triggerMemoryConsolidation(dryRun: Bool = false) async throws -> [String: Any] {
        let result = try await Self.runMemoryConsolidation(dataRoot: engine.dataRoot, dryRun: dryRun)
        await loadMemoryProposals()
        return result
    }

    // PATCH-2026-05-29: dreams-tab — Dreams tab data + control methods.

    /// Fetch the dream diary (newest first) plus the composite dream-enabled flag.
    /// Returns nil on failure and records the error in `dreamError`.
    @MainActor
    func fetchDreamDiary(limit: Int = 30) async -> DreamDiary? {
        dreamError = nil
        do {
            return try await engine.cognitionView.dreamDiary(limit: limit)
        } catch {
            dreamError = UserFacingError.message(error, action: "load the dream diary")
            return nil
        }
    }

    /// Fetch a single diary entry by date (YYYY-MM-DD). Returns nil on 404/error.
    @MainActor
    func fetchDreamEntry(date: String) async -> DreamEntry? {
        dreamError = nil
        do {
            return try await engine.cognitionView.dreamEntry(date: date)
        } catch {
            dreamError = UserFacingError.message(error, action: "load the entry for \(date)")
            return nil
        }
    }

    /// Run a REM consolidation pass now. The returned presentation comes from
    /// the real native completion record, so the Dreams button can distinguish
    /// a completed zero-proposal week from an incomplete or failed invocation.
    @MainActor
    func runRemPass() async -> DreamsREMActionFeedback {
        dreamError = nil
        do {
            let feedback = DreamsREMActionFeedback.resolve(response: try await BackgroundLoopsAssembly.runRem(dataRoot: engine.dataRoot))
            if feedback.isSuccess {
                statusText = feedback.message
            } else {
                dreamError = "REM cycle failed: \(feedback.message)"
                statusText = "REM cycle failed"
            }
            return feedback
        } catch {
            let feedback = DreamsREMActionFeedback.failed(UserFacingError.message(error, action: "run the REM cycle"))
            dreamError = feedback.message
            statusText = "REM cycle failed"
            return feedback
        }
    }

    /// Toggle the deep dream kill switch (personalityPolicy.dream_cycle_enabled).
    /// Persists via the deep-merged trust patch and refreshes `engine.trust.policy`.
    @MainActor
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: [
                    "personalityPolicy": ["dream_cycle_enabled": enabled],
                    "trainingPolicy": ["dream_scheduler": enabled],
                ],
                dataRoot: engine.dataRoot
            )
            engine.trust.policy = saved
            statusText = enabled ? "Dream cycle enabled" : "Dream cycle disabled"
            return true
        } catch {
            dreamError = UserFacingError.message(error, action: "save the dream cycle setting")
            return false
        }
    }

    /// Toggle the REM kill switch (trainingPolicy.rem_cycle_enabled).
    /// Persists via the deep-merged trust patch and refreshes `engine.trust.policy`.
    @MainActor
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            // Change only the REM gate; preserve the dream scheduler.
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["trainingPolicy": ["rem_cycle_enabled": enabled]], dataRoot: engine.dataRoot
            )
            engine.trust.policy = saved
            statusText = enabled ? "REM cycle enabled" : "REM cycle disabled"
            return true
        } catch {
            dreamError = UserFacingError.message(error, action: "save the REM cycle setting")
            return false
        }
    }

    /// The Settings page's "An inner life" switch, one call for the page and
    /// for app_setting_set: the master over every lane, the hour's cached
    /// installation (the hour cannot outlive the master), and — turning on —
    /// Fluid Context's Active default when no choice was ever made. Returns
    /// the runtime's own state and, when it is not running as asked, the
    /// sentence that says why.
    @MainActor
    func setInnerLifeEnabled(_ enabled: Bool) async -> (state: NativeSubconsciousRuntimeState, problem: String?) {
        let budget = UserDefaults.standard.object(forKey: "cognitiveSubstrateDailyReflectionBudget") as? Int ?? 2
        let state = await NativeAgentEngine.liveCognition.setSubconsciousMasterEnabled(
            enabled,
            reflectionBudget: enabled ? max(1, budget) : 0
        )
        engine.cognitionView.subconsciousRuntime = state
        await NativeCognitionRuntime.reloadStudioWanderInstallation()
        await engine.cognitionView.refreshVitals()

        var problem: String?
        if enabled {
            // User, 2026-09-06: this used to force Fluid Context to Active on
            // every enable, silently undoing an Off the user had
            // chosen. The identical switch in Slim Settings leaves the mode
            // alone, so the two disagreed. Only an UNSET preference gets the
            // Active default; an existing choice stands, and the warning below
            // now compares against what was actually asked for.
            let stored = UserDefaults.standard.string(
                forKey: NativeContextFlowConfiguration.modeDefaultsKey
            ).flatMap(ContextFlowMode.init(rawValue:))
            let preferred = stored ?? .active
            let status: NativeContextFlowModeStatus
            if stored == nil {
                status = await NativeAgentEngine.live.contextFlow.setMode(.active)
            } else {
                status = await NativeAgentEngine.live.contextFlow.modeStatus()
            }
            if status.effectiveMode != preferred {
                problem = "Some of my inner life is held off by setup, safety, or provider health."
            }
        }
        if enabled && !state.enabled {
            let voice = AgentVoice(name: agentDisplayName)
            problem = "Connect a provider, or choose my reflection mind under Personality ▸ \(voice.possessive) minds, before turning this on."
        }
        statusText = state.enabled
            ? "I have an inner life again"
            : "My inner life is off"
        return (state, problem)
    }

    /// Dream-tab-scoped dream run: routes errors to `dreamError` (not the
    /// Self-Improvement banner) and skips the self-improvement reload.
    /// Returns true on success so
    /// the caller only reloads (which clears dreamError) when the run succeeded.
    @MainActor
    func runDreamPassForDreams() async -> Bool {
        dreamError = nil
        do {
            let result = try await BackgroundLoopsAssembly.runDream(dataRoot: engine.dataRoot, trigger: .manual)
            let errors = result["errors"] as? [String] ?? []
            guard DoctorStatusProjection.boolValue(result["ok"]) == true, errors.isEmpty else {
                let detail = errors.isEmpty ? "The dream run did not complete successfully." : errors.joined(separator: "; ")
                dreamError = "Dream cycle failed: \(detail)"
                statusText = "Dream cycle failed"
                return false
            }
            statusText = Self.dreamRunStatusText(result)
            return true
        } catch {
            dreamError = UserFacingError.message(error, action: "run the dream cycle")
            statusText = "Dream cycle failed"
            return false
        }
    }

    private static func dreamRunStatusText(_ result: [String: Any]) -> String {
        let entries = DoctorStatusProjection.intValue(result["entriesWritten"]) ?? 0
        let disabled = DoctorStatusProjection.boolValue(result["disabled"]) ?? false
        if disabled { return "Dream cycle disabled" }
        if let reason = result["skipReason"] as? String {
            switch reason {
            case "already_dreamt": return "Dream already ran for the target night"
            case "already_running": return "A dream cycle is already running"
            case "no_new_material": return "No new material to dream about"
            default: return "Dream cycle skipped: \(reason)"
            }
        }
        if entries <= 0 { return "Dream cycle wrote no entries" }
        return entries == 1 ? "Dream cycle wrote 1 entry" : "Dream cycle wrote \(entries) entries"
    }

}
