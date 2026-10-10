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

/// Visible snapshot samplers can be triggered by their retained poll and by a
/// user action at the same time. Requests may still perform concurrently, but
/// only the newest request may publish UI state, preventing a slower old error
/// from replacing a newer successful snapshot.
struct LatestSnapshotRefreshGate: Equatable {
    private(set) var latestGeneration: UInt64 = 0

    mutating func begin() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }
}

@MainActor
extension AppModel {
    // Swift-native embedding status. The app no longer installs or probes
    // sentence-transformers/Python extras; the live truth is the MemoryV2
    // root-resolved embedder. Three terminal states: CoreML MiniLM when the
    // bundled model loads, explicit mock when the user opted out via config
    // OR set NATIVE_AGENT_EMBEDDING_MOCK=1, and fail-closed (embed() throws)
    // when CoreML was requested but resources are missing / load failed and
    // no env opt-in.
    //
    // Every embedding action resolves the root's memory owner, which may
    // open, migrate and prune the store, so all of them run off the main actor.
    nonisolated static func embeddingsStatus(dataRoot: URL) async throws -> EmbeddingsStatus {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        guard let runtime = await memory.embeddingRuntimeSnapshot() else {
            throw MemoryV2Error.storageUnavailable
        }
        return embeddingsStatus(from: runtime)
    }

    /// Project a status from one runtime snapshot.
    nonisolated private static func embeddingsStatus(from runtime: EmbeddingRuntimeSnapshot) -> EmbeddingsStatus {
        let readiness = MemoryStatusProjection.embeddingReadiness(runtime)
        let requestedCoreML = readiness.requestedCoreML
        // effectiveCoreML must be TRUE only when the runtime is ACTUALLY
        // serving CoreML vectors — not when it's mock and not when it's
        // fail-closed (CoreML failed + no NATIVE_AGENT_EMBEDDING_MOCK opt-in).
        // The earlier check `effectiveBackend != mockBackend` returned true
        // for "fail-closed" too, so the UI reported "local"/"Active" while
        // every embed() call was throwing. Match against the canonical CoreML
        // backend instead.
        let isFailClosed = readiness.isFailClosed
        let modelName: String = {
            if isFailClosed {
                return "Unavailable / \(runtime.dimensions)d (\(runtime.lastLoadError ?? "CoreML resources missing"))"
            }
            if requestedCoreML {
                let loaded = runtime.coreMLLoaded ? "loaded" : "idle"
                return "\(runtime.modelId) / \(runtime.dimensions)d (\(loaded))"
            }
            return "Deterministic mock / \(runtime.dimensions)d (semantic embeddings off)"
        }()
        let modeDetail = EmbeddingsMemoryModeDetail(
            mode: runtime.mode,
            title: embeddingModeTitle(runtime.mode),
            detail: embeddingModeDetail(runtime, requestedCoreML: requestedCoreML),
            idleUnloadSeconds: runtime.idleUnloadSeconds
        )
        let reindexState = EmbeddingsInstallState(
            state: "complete",
            currentStep: embeddingCurrentStep(runtime, requestedCoreML: requestedCoreML),
            progress: 100,
            error: runtime.lastLoadError,
            detail: embeddingStatusDetail(runtime, requestedCoreML: requestedCoreML),
            startedAt: nil,
            failedAt: nil,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            extrasPath: nil,
            hfCachePath: nil,
            total: nil,
            candidates: nil,
            embedded: nil,
            skipped: nil,
            failed: nil,
            reason: nil,
            lastUpdatedAt: nil
        )
        return EmbeddingsStatus(
            libraryAvailable: runtime.coreMLResourcesAvailable,
            modelLoadable: runtime.modelLoadable,
            configBackend: runtime.requestedBackend,
            envEnabled: true,
            effectiveBackend: readiness.effectiveBackend,
            modelName: modelName,
            requestedEnabled: requestedCoreML,
            memoryMode: runtime.mode,
            memoryModeDetail: modeDetail,
            idleUnloadSeconds: runtime.idleUnloadSeconds,
            modelState: EmbeddingsModelState(
                mode: runtime.mode,
                loaded: runtime.coreMLLoaded,
                parentLoaded: runtime.coreMLLoaded,
                workerRunning: false,
                workerPid: nil,
                lastUsedAt: runtime.lastUsedAt,
                lastLoadedAt: runtime.lastLoadedAt,
                lastUnloadedAt: runtime.lastUnloadedAt,
                unloadReason: runtime.unloadReason,
                loadCount: runtime.loadCount,
                unloadCount: runtime.unloadCount,
                cacheSize: nil,
                cacheMaxSize: nil
            ),
            installState: nil,
            reindexState: reindexState,
            extrasPath: nil
        )
    }

    nonisolated private static func embeddingModeTitle(_ mode: String) -> String {
        switch mode {
        case "performance": return "Fast"
        case "low_memory": return "Low"
        default: return "Balanced"
        }
    }

    // gpt-5.5 review-3 NEEDS_FIX: the three UI-string helpers below now drive
    // off `runtime.effectiveBackend` so the env-mock-opt-in case
    // (NATIVE_AGENT_EMBEDDING_MOCK=1 with requestedCoreML=true) doesn't get
    // mislabeled as fail-closed when embed() is actually returning mock
    // vectors. Snapshot already computes the right `effectiveBackend` value
    // (coreml-minilm / mock / fail-closed); these strings just have to honor
    // it instead of re-deriving from individual fields.

    nonisolated private static func embeddingModeDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
        guard requestedCoreML else {
            return EmbeddingPlainCopy.headline(.turnedOff)
        }
        // Env-mock opt-in path: user wanted CoreML, set the env var, runtime
        // returns mock vectors. Say so honestly.
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return EmbeddingPlainCopy.headline(.testVectors)
        }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend {
            return EmbeddingPlainCopy.headline(runtime.lastLoadError == nil ? .modelMissing : .modelFailed)
        }
        return EmbeddingPlainCopy.modeLine(mode: runtime.mode)
    }

    nonisolated private static func embeddingCurrentStep(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
        if !requestedCoreML { return "Semantic CoreML embedder disabled by user" }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return "Mock embedder active (NATIVE_AGENT_EMBEDDING_MOCK opt-in)"
        }
        if runtime.coreMLLoaded { return "CoreML semantic embedder loaded" }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.coreMLBackend
            && runtime.lastLoadError == nil {
            return "CoreML semantic embedder ready to lazy-load"
        }
        return "Semantic embedder fail-closed (CoreML resources missing or load failed)"
    }

    // This value lands in the SECONDARY line under a plain headline
    // (SlimSettingsView.modelUnavailableRow), so it is where the identifiers
    // are allowed to live — the headline above it never carries them.
    nonisolated private static func embeddingStatusDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String? {
        if !requestedCoreML { return EmbeddingPlainCopy.technicalDetail(.turnedOff) }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
            return EmbeddingPlainCopy.technicalDetail(.testVectors)
        }
        if let error = runtime.lastLoadError {
            return EmbeddingPlainCopy.technicalDetail(.modelFailed, error: error)
        }
        if runtime.coreMLLoaded { return nil }
        if runtime.effectiveBackend == ManagedEmbeddingProvider.failClosedBackend {
            return EmbeddingPlainCopy.technicalDetail(.modelMissing)
        }
        return EmbeddingPlainCopy.notLoadedYetLine
    }

    // DAEMON-DEAD PORT (2026-06-03): configure the Swift embedding runtime.
    // The managed provider persists <dataRoot>/config/embeddings.json::backend
    // and immediately releases CoreML when disabled.
    nonisolated static func toggleEmbeddingsBackend(enabled: Bool, dataRoot: URL) async throws -> EmbeddingsToggleResult {
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        let before = await memory.embeddingRuntimeSnapshot()
        do {
            try await memory.configureEmbeddingBackend(enabled: enabled)
            let report = try await memory
                .reindexAllMemoryEmbeddingsForCurrentProvider()
            let detail = "Atomically activated one embedding epoch across \(report.memories) memories, \(report.proposals) proposals, and \(report.tombstones) tombstones."
            let status = try await embeddingsStatus(dataRoot: dataRoot)
            return EmbeddingsToggleResult(ok: true, error: nil, detail: detail, status: status)
        } catch {
            // A backend is not allowed to change while canonical vectors stay
            // in the prior space. Restore the requested backend so recall
            // immediately returns to the previously active epoch.
            let wasEnabled = before?.requestedBackend != ManagedEmbeddingProvider.mockBackend
            try? await memory.configureEmbeddingBackend(enabled: wasEnabled)
            throw error
        }
    }

    // DAEMON-DEAD PORT (2026-06-02): configure the managed Swift embedding
    // runtime's idle-retention mode and return current status.
    nonisolated static func setEmbeddingsMemoryMode(_ mode: String, dataRoot: URL) async throws -> EmbeddingsToggleResult {
        try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).configureEmbeddingMemoryMode(mode)
        let status = try await embeddingsStatus(dataRoot: dataRoot)
        return EmbeddingsToggleResult(ok: true, error: nil, detail: nil, status: status)
    }

    // PATCH-2026-05-08: wave3-health-card Feature A — load health card
    @MainActor
    func loadHealthCard(includeApprovals: Bool = true) async {
        let healthGeneration = healthCardRefreshGate.begin()
        // Fix 10: catch and log decode/network errors instead of silently swallowing them
        let nextHealthCard: HealthCard
        do {
            nextHealthCard = try await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager).getHealthCard()
        } catch {
            guard !Task.isCancelled else { return }
            print("[NativeAgent] loadHealthCard failed: \(error)")
            nextHealthCard = HealthCard(
                overall: "error",
                subsystems: [
                    HealthCardSubsystem(
                        id: "runtime",
                        label: "Runtime",
                        status: "error",
                        detail: UserFacingError.message(error, action: "run the health check"),
                        fixAction: "doctor"
                    )
                ],
                createdAt: nil
            )
        }
        guard !Task.isCancelled else { return }
        if healthCardRefreshGate.isCurrent(healthGeneration) {
            setHealthCardIfMeaningfullyChanged(nextHealthCard)
        }
        if includeApprovals {
            do {
                engine.approvals.records = try await engine.approvals.list()
            } catch {
                guard !Task.isCancelled else { return }
                // FIX: previously only print()'d, leaving stale approvals on
                // screen. Clear the list and surface the failure so the UI
                // doesn't show outdated/phantom approvals.
                print("[NativeAgent] getApprovals failed: \(error)")
                engine.approvals.records = []
                setFailureStatus(error, action: "load approvals")
            }
        }
    }

    /// The live health poll intentionally runs while chat is visible, but its
    /// `createdAt` timestamp is not rendered anywhere. Treating that timestamp
    /// as UI state forced a complete health-surface layout every 15 seconds even
    /// when every visible verdict was identical.
    @MainActor
    func setHealthCardIfMeaningfullyChanged(_ next: HealthCard) {
        let current = engine.doctor.healthCard
        if current?.overall != next.overall || current?.subsystems != next.subsystems {
            engine.doctor.healthCard = next
        }
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /compact support
}

// MARK: - Plain-English semantic search copy
//
// UI-6 (2026-08-01, public era): every user-visible sentence about the memory
// search model. Same rule as DoctorPlainCopy / MemoryStatusPlainCopy — the
// headline says what a person lost and what it means for them, and the
// identifiers (Core ML, MiniLM, the env override, the raw load error) survive
// in a secondary technical line instead of being deleted. Pure values in,
// Strings out, so the wording is unit-testable without a UI harness.
enum EmbeddingPlainCopy {

    /// What the embedding runtime is actually doing for search right now.
    enum SearchState: Equatable {
        /// The on-device model is serving real vectors.
        case byMeaning
        /// The user opted out of semantic embeddings in settings.
        case turnedOff
        /// NATIVE_AGENT_EMBEDDING_MOCK opt-in: deterministic test vectors.
        case testVectors
        /// Model resources are not on disk.
        case modelMissing
        /// Model resources exist but failed to load.
        case modelFailed
    }

    /// Leads with the user's loss, never with a backend name.
    static func headline(_ state: SearchState) -> String {
        switch state {
        case .byMeaning:
            return "Memory search finds results by meaning."
        case .turnedOff:
            return "Memory search by meaning is turned off."
        case .testVectors:
            return "Memory search is running on test data, so results will not match meaning."
        case .modelMissing:
            return "Memory search is unavailable because a required model is not installed."
        case .modelFailed:
            return "Memory search is unavailable because the search model could not load."
        }
    }

    /// The secondary line. Nil when there is nothing technical worth naming.
    static func technicalDetail(_ state: SearchState, error: String? = nil) -> String? {
        switch state {
        case .byMeaning:
            return nil
        case .turnedOff:
            return "Semantic embeddings are off in settings. Turn them on to use the bundled Core ML MiniLM model."
        case .testVectors:
            return "NATIVE_AGENT_EMBEDDING_MOCK is set, so search uses deterministic test vectors instead of the bundled Core ML MiniLM model."
        case .modelMissing:
            return "Search model: Core ML MiniLM. The bundled resources are not on disk."
        case .modelFailed:
            let trimmed = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                return "Search model: Core ML. Load failed."
            }
            return "Search model: Core ML. Load failed: \(trimmed)"
        }
    }

    /// Idle-retention mode, described by what the user feels rather than by
    /// which model unloads when.
    static func modeLine(mode: String) -> String {
        switch mode {
        case "performance":
            return "The search model stays loaded, so searches return as fast as possible."
        case "low_memory":
            return "The search model unloads after 45 seconds of no use, to keep memory free."
        default:
            return "The search model loads when you search and unloads after 5 minutes of no use."
        }
    }

    /// Transient: the model is fine, just not resident this second.
    static let notLoadedYetLine =
        "The search model is not loaded right now. It loads on your next search."
}
