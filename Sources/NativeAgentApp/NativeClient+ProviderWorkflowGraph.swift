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

/// Read-only tissue from Workflow's canonical run reducer into resident
/// attention. It owns no workflow state, never advances a run, and is live-
/// root confined so fixtures and previews cannot alter Agent's physiology.
enum WorkflowResidentOutcomeProjector {
    typealias Observer = @Sendable (MotorActionReadModel) async -> Void

    struct Snapshot: Sendable, Equatable {
        let model: MotorActionReadModel?
    }

    static func snapshot(
        client: any WorkflowOrchestrationClient,
        actionId: String,
        dataRoot: URL,
        canonicalRoot: URL = PersistenceCore.defaultDataRoot()
    ) async -> Snapshot? {
        guard dataRoot.standardizedFileURL == canonicalRoot.standardizedFileURL,
              let provider = client as? any MotorActionReadModelProviding else {
            return nil
        }
        do {
            return Snapshot(model: try await provider.motorActionReadModel(actionId: actionId))
        } catch {
            NSLog("workflow: resident outcome snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func observe(
        client: any WorkflowOrchestrationClient,
        actionId: String,
        dataRoot: URL,
        canonicalRoot: URL = PersistenceCore.defaultDataRoot(),
        executionWasRequested: Bool = true,
        observer: @escaping Observer
    ) async {
        guard executionWasRequested,
              let snapshot = await snapshot(
                client: client,
                actionId: actionId,
                dataRoot: dataRoot,
                canonicalRoot: canonicalRoot
              ),
              let model = snapshot.model else {
            return
        }
        // A v1 execute=false run is a dry-run receipt. It is useful audit
        // evidence, but it is not a lived action consequence.
        guard !(model.phase == .succeeded && model.verification == .notRequired) else {
            return
        }
        await observer(model)
    }

    /// Catch-path projection is allowed only when the authoritative owner
    /// changed while the attempted mutation was in flight. Re-reading an
    /// unchanged historical terminal row would otherwise manufacture a fresh
    /// resident consequence for a validation/transport error that did no work.
    static func observeChanged(
        client: any WorkflowOrchestrationClient,
        actionId: String,
        dataRoot: URL,
        canonicalRoot: URL = PersistenceCore.defaultDataRoot(),
        baseline: Snapshot?,
        observer: @escaping Observer
    ) async {
        guard let baseline,
              let current = await snapshot(
                client: client,
                actionId: actionId,
                dataRoot: dataRoot,
                canonicalRoot: canonicalRoot
              ),
              current != baseline,
              let model = current.model,
              !(model.phase == .succeeded && model.verification == .notRequired) else {
            return
        }
        await observer(model)
    }
}

extension NativeClient {
    func configureModel(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String? = nil,
        inferProvider: Bool = false
    ) async throws -> ModelCatalogResponse {
        try await configureModel(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            inferProvider: inferProvider,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    func configureSurfaceSelection(
        surface: String,
        providerID: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String?,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            providerId: providerID,
            seedMissingControls: true
        )
        return try await getModelCatalog(
            refresh: false,
            dataRoot: dataRoot,
            codexCacheURL: codexCacheURL
        )
    }

    func configureModel(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String? = nil,
        inferProvider: Bool = false,
        dataRoot: URL,
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        // Swift-native cutover native impl (2026-06-02): write surface→{model,effort}
        // into `<dataRoot>/providers/surfaces.json` under flock. Returns the
        // freshly-read catalog so the UI re-renders with the new pref.
        let inferredProvider = inferProvider ? Self.inferProviderID(forModel: model) : nil
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            providerId: inferredProvider,
            seedMissingControls: true
        )
        // Only an explicitly provider-less model selection may move the
        // active-provider pin. Think/Fast changes carry the current model too,
        // so unconditional inference here silently changed an explicit Codex
        // or API-key route to OAuth Direct.
        // Model-only saves may move the active-provider pin when the
        // model family unambiguously implies one (daemon parity:
        // activate_provider_for_surface_if_model_implies). Without this, the
        // chat-box "Chat brain saved: gpt-5.5" toast lied — routing kept the
        // stale anthropic pin and silently ran the pin's catalog default
        // (audit 2026-06-09, verified against live active.json). The helper
        // is namespace-aware: OpenRouter "anthropic/..." ids pin openrouter
        // (the namespace's provider), never the Anthropic OAuth provider;
        // unknown families return nil and leave the pin untouched.
        return try await getModelCatalog(
            refresh: false,
            dataRoot: dataRoot,
            codexCacheURL: codexCacheURL
        )
    }

    // PATCH-2026-05-28 (per-surface model): set just the model for a surface,
    // without a reasoningEffort change, and with inferProvider control. The
    // per-surface Providers UI sets the provider EXPLICITLY (setActiveProvider)
    // and passes inferProvider=false so an OpenRouter id like
    // "anthropic/claude-..." is not misread as the anthropic OAuth provider.
    func setSurfaceModel(surface: String, model: String, inferProvider: Bool = false) async throws -> ModelCatalogResponse {
        try await setSurfaceModel(
            surface: surface,
            model: model,
            inferProvider: inferProvider,
            dataRoot: PersistenceCore.defaultDataRoot()
        )
    }

    func setSurfaceModel(
        surface: String,
        model: String,
        inferProvider: Bool = false,
        dataRoot: URL,
        codexCacheURL: URL? = nil
    ) async throws -> ModelCatalogResponse {
        // Swift-native cutover native impl (2026-06-02): persist the model into
        // surfaces.json (preserving existing reasoningEffort), and when
        // inferProvider=true, also write the prefix-matched provider into
        // active.json. Inference is intentionally simple — the UI's explicit
        // setActiveProvider path is the source of truth; this is a hint.
        let inferredProvider = inferProvider ? Self.inferProviderID(forModel: model) : nil
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).saveSurfaceConfiguration(
            surface: surface,
            model: model,
            reasoningEffort: nil,
            serviceTier: nil,
            providerId: inferredProvider,
            seedMissingControls: true
        )
        return try await getModelCatalog(
            refresh: false,
            dataRoot: dataRoot,
            codexCacheURL: codexCacheURL
        )
    }

    /// App compatibility seam. Persistence ownership remains in
    /// `SwiftNativeProviderRouting`; this wrapper exists for the few app
    /// surfaces and regression tests that still call the static helper.
    static func writeSurfacePref(
        surface: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).saveSurfacePreference(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            seedMissingControls: true
        )
    }

    /// Read `<dataRoot>/providers/active.json` (surface → provider hint).
    /// Missing is empty; damaged existing state throws. This is the READ-SIDE counterpart
    /// to `writeActiveProvider(surface:providerID:)` — the UI's picker and
    /// the SwiftNativeLLMClient dispatch tiebreaker both pull from here so
    /// save/read are unified.
    static func readActiveProvidersFromDisk(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws -> [String: String] {
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).readActiveProvidersChecked()
    }

    // W-H Providers-band lift (move-only): fileprivate→internal so the
    // relocated provider routes (NativeClient+Providers.swift) still reach it
    // while configureModel/setSurfaceModel keep calling it from the root.
    static func writeActiveProvider(
        surface: String,
        providerID: String,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async throws {
        try await SwiftNativeProviderRouting(dataRoot: dataRoot).setActiveProvider(
            surface: surface,
            providerId: providerID
        )
    }

    static func inferProviderID(forModel model: String) -> String? {
        // Mirror ProviderRouting.inferProviderForModel: trim/lowercase and
        // return the CONCRETE provider ids (the ones providers.json and the
        // Providers UI picker actually carry). Writing the short aliases
        // ("openai"/"anthropic") routed fine (runtime normalizes) but left
        // the picker pointing at an id not in its options (gpt-5.5 review
        // 2026-06-09).
        SwiftNativeProviderRouting.inferredProviderID(forModel: model)
    }

    func planRoute(message: String) async throws -> IntentRoutePlan {
        let impl = makeRouterPlanClient()
        let swiftResult = try await impl.planRoute(message: message)
        // Bridge SystemOps.RoutePlanResult → NativeAgentApp.IntentRoutePlan via JSON.
        // Field overlap is exact (id, message, goalType, recommendedSurface,
        // risk, requiresApproval, matchedCapabilities, nextActions, createdAt).
        // DORMANT aspect: `matchedCapabilities` arrives as `[]` from the Swift
        // port because `select_context_capabilities` couples to daemon-loaded
        // capability records that aren't Swift-native yet — IntentRoutePlan's
        // `[CapabilityRecord]` decodes the empty array fine.
        let data = try swiftResult.toJSON().serializedData(pretty: false)
        return try JSONDecoder().decode(IntentRoutePlan.self, from: data)
    }

    func runWorkflow(id: String, objective: String, execute: Bool) async throws -> WorkflowRun {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let impl = makeWorkflowOrchestrationClient(root: dataRoot)
        do {
            let row = try await impl.runWorkflow(
                id: id,
                objective: objective,
                execute: execute,
                engineVersion: nil,
                variables: nil
            )
            await WorkflowResidentOutcomeProjector.observe(
                client: impl,
                actionId: Self.workflowRunID(row, fallback: id),
                dataRoot: dataRoot,
                executionWasRequested: execute,
                observer: { await NativeCognitionRuntime.shared.observeMotorActionState($0) }
            )
            let data = try row.serializedData(pretty: false)
            return try JSONDecoder().decode(WorkflowRun.self, from: data)
        } catch {
            // `id` identifies the workflow definition, not a newly allocated
            // run. Without a returned run identity there is no exact owner row
            // this catch path can safely project.
            throw error
        }
    }

    func resumeWorkflowRun(id: String) async throws -> WorkflowRun {
        try await workflowMutation(id: id) { try await $0.resumeWorkflowRun(id: id) }
    }

    func cancelWorkflowRun(id: String) async throws -> WorkflowRun {
        try await workflowMutation(id: id) { try await $0.cancelWorkflowRun(id: id) }
    }

    func rollbackWorkflowRun(id: String) async throws -> WorkflowRun {
        // rollback returns the public run merged with rollbackReceipts; the
        // WorkflowRun model ignores the extra rollbackReceipts key (no field),
        // matching how the HTTP path already drops it on decode.
        try await workflowMutation(id: id) { try await $0.rollbackWorkflowRun(id: id) }
    }

    private func workflowMutation(
        id: String,
        operation: (any WorkflowOrchestrationClient) async throws -> JSONValue
    ) async throws -> WorkflowRun {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let impl = makeWorkflowOrchestrationClient(root: dataRoot)
        let baseline = await WorkflowResidentOutcomeProjector.snapshot(
            client: impl,
            actionId: id,
            dataRoot: dataRoot
        )
        do {
            let row = try await operation(impl)
            await WorkflowResidentOutcomeProjector.observe(
                client: impl,
                actionId: Self.workflowRunID(row, fallback: id),
                dataRoot: dataRoot,
                observer: { await NativeCognitionRuntime.shared.observeMotorActionState($0) }
            )
            let data = try row.serializedData(pretty: false)
            return try JSONDecoder().decode(WorkflowRun.self, from: data)
        } catch {
            await WorkflowResidentOutcomeProjector.observeChanged(
                client: impl,
                actionId: id,
                dataRoot: dataRoot,
                baseline: baseline,
                observer: { await NativeCognitionRuntime.shared.observeMotorActionState($0) }
            )
            throw error
        }
    }

    nonisolated private static func workflowRunID(
        _ row: JSONValue,
        fallback: String
    ) -> String {
        guard case .object(let object) = row,
              case .string(let runID)? = object["id"],
              !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return runID
    }
    func runResearchLab(objective: String) async throws -> ResearchLabRun {
        // Wave 31 W03 (2026-06-01): the SwiftNative path emits the
        // record_activity + record_trace side-effects (Research.swift) that
        // Python emits to the SAME on-disk JSONL
        // files (data/activity/events.jsonl + data/traces/events.jsonl), so
        // the Mac feeds preserve the established route shape.
        //
        // Wave 32 W01 (2026-06-01): RE-ENABLED — closes the §6.75 item-1 reopen
        // prereq. The wave-31-round-2 revert pulled this gate because the Mac
        // in-process writer and the old iOS HTTP writer both did a
        // read-insert-write of data/research/lab/runs.json with NO cross-process
        // flock, racing to a lost update. This wave wraps that R-M-W in a
        // cross-process flock on BOTH sides — Swift
        // SwiftNativeResearchClient.runResearchLab now holds
        // withFileLock(labRunsPath) over its read-insert-write, and the daemon's
        // run_research_lab holds the symmetric with file_lock(research_lab_path)
        // over its read-insert-write. The flock sibling-path /
        // open-mode / LOCK_EX convention is identical across
        // PersistenceCore+FileLock.swift <-> the retired daemon, so the two
        // processes serialize against each other. With the writers serialized,
        // the Swift writer is safe as the sole local path.
        return try await swiftRunResearchLab(objective: objective)
    }

    // PORTED wave 31 W15 (2026-06-01): `.capabilityTrust` snapshot routes
    // POST /v1/capability-catalog/sources (upsert) through SwiftNativeCatalogWrites.
    // The read-modify-write of <dataRoot>/catalog/sources/sources.json runs under
    // the SAME cross-process flock the wave-30 W07 read-side actor
    // (SwiftNativeCatalogSources) already holds — symmetric with Python's
    // `with file_lock(self.catalog_sources_path)` at the retired daemon — so
    // the daemon and Swift never trample each other mid-cutover. slugify, default
    // record, and status (ready|needs_setup) semantics are byte-identical to
    // `upsert_catalog_source()`. NOTE: the daemon route
    // also calls record_trace("catalog.source.save", ...); that audit side-effect
    // is intentionally omitted (same carve as the catalog-read port) and the
    // daemon still emits it whenever the flag is OFF.
    func upsertCatalogSource(name: String, url: String, kind: String) async throws -> CapabilityCatalogSource {
        // RE-ENABLED wave 32 W02 (2026-06-01): the W31-W15 revert was driven by
        // two gaps, both now closed. (1) The record_trace("catalog.source.save",
        // ...) audit side-effect is now ported into SwiftNativeCatalogWrites
        // (TrustCenter/CapabilityCatalog.swift, emitCatalogTrace) so the
        // /v1/activity + /v1/traces feeds stay byte-identical whether the upsert
        // flows through Python or Swift. (2) The "cross-process write
        // coordination unproven" concern is moot: wave-30 W07's
        // getCapabilityCatalogSources already performs the same flock'd
        // read-modify-WRITE-BACK of catalog/sources/sources.json live in
        // production (it merges defaults + saved and writes the file back under
        // the SAME the retired daemon <-> PersistenceCore.withFileLock lock).
        // So the write path through this shared flock is already exercised in
        // production; this gate adds only the upsert + the now-present trace.
        let writes = SwiftNativeCatalogWrites(
            dataRoot: PersistenceCore.defaultDataRoot(),
            persistence: SwiftNativePersistenceCore()
        )
        // Match the daemon's body keys; non-supplied fields fall through to
        // the actor's str(... or ...) defaults (kind -> "local", etc.).
        let record = try await writes.upsertCatalogSource([
            "name": .string(name),
            "url": .string(url),
            "kind": .string(kind),
        ])
        let data = try JSONValue.object(record).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityCatalogSource.self, from: data)
    }

    // PORTED wave 31 W15 (2026-06-01): `.capabilityTrust` snapshot routes
    // POST /v1/capability-catalog/updates/check through SwiftNativeCatalogWrites.
    // Reads the installs list (lock-free), emits a "current" update row per
    // install, then stamps lastCheckedAt on every source under the sources flock
    // — byte-identical to `check_capability_updates()`,
    // including the symmetric flock on catalog_sources_path.
    func checkCapabilityUpdates() async throws -> CapabilityUpdateCheck {
        // RE-ENABLED wave 32 W02 (2026-06-01): the W31-W15 revert cited the
        // "same write-parity gap as upsertCatalogSource". Unlike the upsert,
        // check_capability_updates() emits NO record_trace (the retired daemon
        // has no audit call — it only stamps lastCheckedAt), so there is no trace
        // side-effect to port here. The only remaining concern was cross-process
        // write coordination on catalog/sources/sources.json, which is moot for
        // the same reason as upsertCatalogSource: wave-30 W07's read-side actor
        // already performs the flock'd write-back of that file live in
        // production. The "checked" result shape, the per-install "current"
        // update rows, and the lastCheckedAt stamp are byte-identical to Python.
        let writes = SwiftNativeCatalogWrites(
            dataRoot: PersistenceCore.defaultDataRoot(),
            persistence: SwiftNativePersistenceCore()
        )
        let result = try await writes.checkCapabilityUpdates()
        let data = try JSONValue.object(result).serializedData(pretty: false)
        return try JSONDecoder().decode(CapabilityUpdateCheck.self, from: data)
    }

    // SwiftNativeCapabilityTrust evaluates capability trust in-process from the
    // native capability records and trust metadata.
    func evaluateCapabilityTrust(id: String) async throws -> CapabilityTrustEvaluation {
        let impl = makeCapabilityTrust()
        let swiftResult = try await impl.evaluate(capabilityId: id)
        // Bridge TrustCenter.CapabilityTrustEvaluation → NativeAgentApp.CapabilityTrustEvaluation.
        // Both Codable, byte-identical shapes (verified 2026-05-31 against
        // CapabilityTrust.swift wire types vs Models.swift L1629). JSON round-trip
        // is the canonical seam — when the eventual full aggregator port lands,
        // this stays one line.
        let data = try JSONEncoder().encode(swiftResult)
        return try JSONDecoder().decode(CapabilityTrustEvaluation.self, from: data)
    }

}
