import Foundation
import Observation
import Darwin
import AppKit
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
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

// PATCH-2026-05-07: model-providers v1 — NativeClient provider API methods
extension NativeClient {
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String? = nil) async throws -> EmptyResponse {
        let provider = try await ProvidersFacade(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .provider(id: id)
        let supportedModes = provider.auth_modes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let requestedMode = authMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The sheet always supplies a selected mode. Keep the existing
        // programmatic/iCloud compatibility behavior for omitted values by
        // selecting the provider's first advertised mode, never an invented
        // generic fallback.
        let normalizedMode = requestedMode.isEmpty ? (supportedModes.first ?? "") : requestedMode
        guard supportedModes.contains(normalizedMode) else {
            throw NSError(domain: "NativeAgentProvider", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.display_name) does not support the \(normalizedMode.isEmpty ? "requested" : normalizedMode) authentication method"
            ])
        }
        var config: [String: JSONValue] = ["auth_mode": .string(normalizedMode)]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            config["api_key"] = .string(key)
        }
        if let model = defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            config["default_model"] = .string(model)
        }
        _ = try await SwiftNativeProviderRouting(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
            .configureProvider(id: id, config: .object(config))
        return EmptyResponse()
    }

    // DAEMON-DEAD PORT (2026-06-02): native reachability probe. Resolves the
    // API key via LLMCredentialResolver (providers/<id>.json), then for
    // OpenAI hits GET /v1/models with a Bearer token and reports latency.
    // Anthropic (GET /v1/models, x-api-key) and OpenRouter (GET /api/v1/key)
    // are probed the same way; 401 (and Anthropic 403) reads "key rejected".
    //
    // User, 2026-09-06: `apiKeyOverride` is the key typed into the provider
    // sheet but not saved yet. Without it the button tested the credential on
    // disk while the sheet showed the result beside an unrelated draft — a bad
    // pasted key could read "Saved and tested" off the old saved one, and a
    // fresh install reported "no api key configured" for a valid pasted key.
    func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> ProviderTestResult {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        // This write is deliberately attached to the canonical, user-initiated
        // reachability probe rather than to a provider-list refresh. A readable
        // credential is not evidence that the provider was reachable. If the
        // status-file write itself fails, leave the prior record untouched so
        // its age truthfully becomes stale instead of fabricating a fresh row.
        let draftKey: String? = {
            let trimmed = apiKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        func recordProbeResult(_ result: ProviderTestResult) async -> ProviderTestResult {
            // A draft key is not this provider's credential — it has not been
            // saved. Its probe answers the sheet only; writing it to the status
            // feed would claim a configured provider was reachable when the
            // configured one was never touched (User, 2026-09-06).
            guard draftKey == nil else { return result }
            do {
                try await LLMProviderStatusFeed.write(result, dataRoot: dataRoot)
            } catch {
                NSLog("provider_status: could not persist provider check: \(error.localizedDescription)")
            }
            return result
        }
        let configFile: String? = switch id {
        case "openai", "anthropic", "moonshot", "kimi-code", "openrouter": "\(id).json"
        default: nil
        }

        guard let configFile else {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "unknown", tested: false,
                response: nil, model_used: nil,
                detail: "no native probe for \(id)", error: nil
            ))
        }
        guard let apiKey = draftKey ?? LLMCredentialResolver.resolveAPIKey(
            providerConfigFile: configFile, dataRoot: dataRoot
        ), !apiKey.isEmpty else {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: false,
                response: nil, model_used: nil,
                detail: nil, error: "no api key configured"
            ))
        }

        if id == "kimi-code" {
            // Real reachability probe: the subscription API has no free GET
            // /models, so spend one token on a minimal Messages call. Proves
            // key validity + endpoint reachability, and its 200 also confirms
            // the Anthropic-compat body shape end to end.
            var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/messages")!)
            req.httpMethod = "POST"
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.timeoutInterval = 20
            // A connectivity probe still needs A model to ask with: take the
            // FIRST row of this provider's own catalog (2026-09-13) rather than
            // naming one in code, so the probe follows the catalog.
            let probeModel = FirstPartyModelCatalog
                .models(forProviderID: "kimi-code").first?.id ?? ""
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": probeModel,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ])
            let start = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    return await recordProbeResult(ProviderTestResult(
                        provider_id: id, status: "ok", tested: true,
                        response: nil, model_used: probeModel,
                        detail: "latency=\(ms)ms", error: nil
                    ))
                }
                let hint = code == 401 ? "key rejected" : "HTTP \(code)"
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: probeModel,
                    detail: "latency=\(ms)ms", error: hint
                ))
            } catch {
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "error", tested: true,
                    response: nil, model_used: nil,
                    detail: nil, error: error.localizedDescription
                ))
            }
        }

        // Free authenticated GETs: a models list, or OpenRouter's own key
        // endpoint. The key rides only in a header, never the URL, so no
        // error or log line below can carry it.
        let modelsEndpoint: URL = switch id {
        case "moonshot": MoonshotModelCatalog.endpoint
        case "anthropic": URL(string: "https://api.anthropic.com/v1/models")!
        case "openrouter": URL(string: "https://openrouter.ai/api/v1/key")!
        default: URL(string: "https://api.openai.com/v1/models")!
        }
        var req = URLRequest(url: modelsEndpoint)
        req.httpMethod = "GET"
        if id == "anthropic" {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                if id == "moonshot" {
                    _ = await MoonshotModelCatalog.models(dataRoot: dataRoot, refresh: true)
                }
                return await recordProbeResult(ProviderTestResult(
                    provider_id: id, status: "ok", tested: true,
                    response: nil, model_used: nil,
                    detail: "latency=\(ms)ms", error: nil
                ))
            }
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                // Anthropic answers a bad key with 401 or 403.
                detail: "latency=\(ms)ms",
                error: code == 401 || (id == "anthropic" && code == 403) ? "key rejected" : "HTTP \(code)"
            ))
        } catch {
            return await recordProbeResult(ProviderTestResult(
                provider_id: id, status: "error", tested: true,
                response: nil, model_used: nil,
                detail: nil, error: error.localizedDescription
                    .replacingOccurrences(of: apiKey, with: "[redacted]")
            ))
        }
    }

    // DAEMON-DEAD PORT (2026-06-02): write surface→provider into
    // <dataRoot>/providers/active.json under flock, merged with existing.
    func setActiveProvider(surface: String, providerId: String) async throws -> EmptyResponse {
        try await Self.writeActiveProvider(surface: surface, providerID: providerId,
                                          dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        return EmptyResponse()
    }

    // Remove the matching registry entry under its lock; damaged authority
    // must remain byte-preserved rather than becoming an empty registry.
    func clearProvider(_ id: String) async throws -> EmptyResponse {
        // User, 2026-09-06: the client's own root, not the process default — a
        // removal against an override root was deleting the default install's
        // registry row and credential file and leaving the intended one intact.
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let path = dataRoot.appendingPathComponent("providers/registry.json")
        let persistence = SwiftNativePersistenceCore()
        guard !id.isEmpty, id != ".", id != "..",
              id.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }),
              !["registry", "models", "active", "surfaces", "pending-surface-configuration",
                "openrouter-models-cache", "moonshot-models-cache"].contains(id) else {
            throw ProviderRoutingError.invalidRequest
        }
        let credFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(id).json")
        let reference = try await persistence.withFileLock(path) {
            _ = try SwiftNativeProviderRouting.loadProviderRegistryChecked(at: path)
            return try await persistence.withFileLock(credFile) { () async throws -> String? in
                // Validate the target row and credential before the first write.
                // Unrelated rows survive; credential deletion still happens last.
                let remaining = try ProviderStateValidation.registryRemovingProvider(at: path, providerID: id)
                let credential = try ProviderStateValidation.credential(at: credFile)
                let fields = try SwiftNativeProviderRouting.loadProviderStateObjectChecked(
                    at: credFile, description: "provider \(id) configuration"
                )
                try SwiftNativeProviderRouting.validateProviderConfiguration(fields)
                let reference = credential[ProviderAPIKeyStore.referenceField] as? String
                if let remaining {
                    try await persistence.writeJSON(.array(remaining), to: path)
                }
                do {
                    try FileManager.default.removeItem(at: credFile)
                } catch {
                    let failure = error as NSError
                    guard failure.domain == NSCocoaErrorDomain,
                          failure.code == NSFileNoSuchFileError else { throw error }
                }
                return reference
            }
        }
        if let reference {
            do {
                try ProviderAPIKeyStore.delete(reference)
            } catch {
                NSLog("provider_credentials: provider removed; unused Keychain item cleanup failed")
            }
        }
        return EmptyResponse()
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test

    // PATCH-2026-05-08: wave3 Feature A/B/D new endpoints
    func getHealthCard() async throws -> HealthCard {
        // F6 (eval E06 fix-2): synthesize health from the real Swift
        // DoctorChecks runner (runDoctor) rather than a hardcoded all-ok
        // row set. Each CheckResult maps 1:1 to a HealthCardSubsystem; the
        // overall status is the worst-row rollup (fail > warn > ok) that
        // runDoctor already computes. A doctor failure falls back to a
        // single error row so the panel still renders.
        // W1.2: prefer DoctorAutoRunLoop's cached <dataRoot>/doctor/latest.json
        // when its runAt is <60s old, so the health card doesn't re-run every
        // probe per call. Stale or missing → fall through to a live runDoctor.
        //
        // A1/FIX-1a (2026-08-05): that 60s contract was DEAD on arrival. Its
        // only producer, DoctorAutoRunLoop, ticks on a SEVEN-DAY cadence, so
        // latest.json was permanently older than 60s (live file last written
        // Jun 19) and every 15s health-pill poll fell through to a full 9-check
        // doctor sweep — ~4 full sweeps per minute for as long as chat was
        // focused. getHealthCard now WRITES the snapshot it just computed, in
        // DoctorAutoRunLoop's exact wire shape (core checks only,
        // `{"checks":[...],"runAt":...}`), so the reader finally has a live
        // producer. Verdicts are unchanged: the live-owner coverage checks are
        // still recomputed on EVERY call and override their cached ids, and
        // only the offline core checks are ever served from the 60s window.
        let now = ISO8601DateFormatter().string(from: Date())
        let liveChecks = await liveDoctorCoverageChecks()
        return await Self.makeHealthCard(
            now: now,
            cachePath: Self.doctorCachePath(),
            liveChecks: liveChecks,
            runCoreChecks: { try await makeDoctorChecks().runAll(repair: false, checkLLM: true) }
        )
    }

    static func doctorCachePath() -> URL {
        PersistenceCore.defaultDataRoot().appendingPathComponent("doctor/latest.json")
    }

    /// Testable core of `getHealthCard`. `runCoreChecks` is the offline
    /// DoctorChecks sweep (the expensive part); `liveChecks` are the app's
    /// live-owner coverage rows, already computed by the caller because BOTH
    /// paths need them fresh.
    static func makeHealthCard(
        now: String,
        cachePath: URL,
        liveChecks: [CheckResult],
        runCoreChecks: () async throws -> [CheckResult]
    ) async -> HealthCard {
        await DoctorStatusProjection.makeHealthCard(now: now, cachePath: cachePath, liveChecks: liveChecks, safeDetail: Self.safeDoctorDetail, runCoreChecks: runCoreChecks)
    }

    /// Mirrors `DoctorAutoRunLoop.encodePayload` byte-for-byte: the same
    /// JSONEncoder(.sortedKeys) → JSONValue round-trip, the same
    /// `{"checks": [...], "runAt": "...", "measuredAt": "..."}` object, the
    /// same atomic writeJSON. `measuredAt` is when the checks were asked,
    /// `runAt` when the file was written (2026-09-12: the loop writer grew
    /// `measuredAt` first and this writer lagged; the wire-shape test caught it).
    /// Only the offline core checks are persisted — live coverage rows are
    /// per-call truth and would otherwise leak into SelfHealingHook's and the
    /// heartbeat's reading of this file.
    ///
    /// Best-effort: a write failure costs the next call a live doctor run,
    /// i.e. exactly the pre-fix behavior. It can never produce a wrong verdict.
    static func persistDoctorSnapshot(
        _ results: [CheckResult], to path: URL, runAt: String, measuredAt: String
    ) async {
        await DoctorStatusProjection.persistDoctorSnapshot(results, to: path, runAt: runAt, measuredAt: measuredAt)
    }

    static func readCachedHealthCard(at path: URL, now: String) -> HealthCard? {
        DoctorStatusProjection.readCachedHealthCard(at: path, now: now)
    }

    static func mergeHealthCard(cached: HealthCard, liveChecks: [CheckResult], now: String) -> HealthCard {
        DoctorStatusProjection.mergeHealthCard(cached: cached, liveChecks: liveChecks, now: now)
    }

    // Swift-native embedding status. The app no longer installs or probes
    // sentence-transformers/Python extras; the live truth is the MemoryV2
    // root-resolved embedder. Three terminal states: CoreML MiniLM when the
    // bundled model loads, explicit mock when the user opted out via config
    // OR set NATIVE_AGENT_EMBEDDING_MOCK=1, and fail-closed (embed() throws)
    // when CoreML was requested but resources are missing / load failed and
    // no env opt-in.
    func getEmbeddingsStatus() async throws -> EmbeddingsStatus {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        guard let runtime = await memory.embeddingRuntimeSnapshot() else {
            throw MemoryV2Error.storageUnavailable
        }
        return Self.embeddingsStatus(from: runtime)
    }

    /// Project a status from the exact runtime snapshot that performed an
    /// action. Release uses this rather than resolving a second alternate-root
    /// owner, which could make a fresh idle owner look like proof of release.
    private static func embeddingsStatus(from runtime: EmbeddingRuntimeSnapshot) -> EmbeddingsStatus {
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
            title: Self.embeddingModeTitle(runtime.mode),
            detail: Self.embeddingModeDetail(runtime, requestedCoreML: requestedCoreML),
            idleUnloadSeconds: runtime.idleUnloadSeconds
        )
        let reindexState = EmbeddingsInstallState(
            state: "complete",
            currentStep: Self.embeddingCurrentStep(runtime, requestedCoreML: requestedCoreML),
            progress: 100,
            error: runtime.lastLoadError,
            detail: Self.embeddingStatusDetail(runtime, requestedCoreML: requestedCoreML),
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

    private static func embeddingModeTitle(_ mode: String) -> String {
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

    private static func embeddingModeDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
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

    private static func embeddingCurrentStep(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String {
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
    private static func embeddingStatusDetail(_ runtime: EmbeddingRuntimeSnapshot, requestedCoreML: Bool) -> String? {
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
    func setEmbeddingsBackend(enabled: Bool) async throws -> EmbeddingsToggleResult {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        let before = await memory.embeddingRuntimeSnapshot()
        do {
            try await memory.configureEmbeddingBackend(enabled: enabled)
            let report = try await memory
                .reindexAllMemoryEmbeddingsForCurrentProvider()
            let detail = "Atomically activated one embedding epoch across \(report.memories) memories, \(report.proposals) proposals, and \(report.tombstones) tombstones."
            let status = try await getEmbeddingsStatus()
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
    func setEmbeddingsMemoryMode(mode: String) async throws -> EmbeddingsToggleResult {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
            .configureEmbeddingMemoryMode(mode)
        let status = try await getEmbeddingsStatus()
        return EmbeddingsToggleResult(ok: true, error: nil, detail: nil, status: status)
    }

    // DAEMON-DEAD PORT (2026-06-03): release the process-owned CoreML provider
    // reference. The next semantic recall lazy-loads it again unless the
    // backend is disabled. A returned success requires both the owner snapshot
    // and the re-read status to agree that no model remains resident.
    func releaseEmbeddingsMemory() async throws -> EmbeddingsToggleResult {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let memory = SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot)
        let released = await memory
            .releaseEmbeddingMemory(reason: "manual release")
        guard let postRelease = await memory.embeddingRuntimeSnapshot() else {
            throw MemoryV2Error.storageUnavailable
        }
        let status = Self.embeddingsStatus(from: postRelease)
        let verification = EmbeddingsMemoryReleaseVerification.verify(
            releasedSnapshot: released,
            reportedModelLoaded: status.modelState?.loaded
        )
        return EmbeddingsToggleResult(
            ok: verification.ok,
            error: verification.error,
            detail: verification.detail,
            status: status
        )
    }

    // WAVE 31 (2026-06-01): getEmbeddingsInstallStatus() removed — zero call
    // sites; the dead pollEmbeddingsInstall() appModel wrapper was its only
    // (uninvoked) caller. The daemon GET /v1/embeddings/install/status route is
    // retired this wave; progress comes from getEmbeddingsStatus().installState.
    // The EmbeddingsInstallState type is KEPT — it still decodes the installState/
    // reindexState fields embedded in EmbeddingsStatus.

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
            return "Memory search by meaning is turned off. Searches match words instead."
        case .testVectors:
            return "Memory search is running on test data, so results will not match meaning."
        case .modelMissing:
            return "Memory search by meaning is off because a required model is not installed. Searches match words instead."
        case .modelFailed:
            return "Memory search by meaning is off because the search model could not load. Searches match words instead."
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
