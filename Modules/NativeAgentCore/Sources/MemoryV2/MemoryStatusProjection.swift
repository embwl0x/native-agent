import Foundation
import PersistenceCore

/// Read-only status and hygiene projections using the existing stores and runtime.
public enum MemoryStatusProjection {
    public static func embeddingRuntime(dataRoot: URL) async throws -> EmbeddingRuntimeSnapshot {
        guard let runtime = await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).embeddingRuntimeSnapshot() else {
            throw MemoryV2Error.storageUnavailable
        }
        return runtime
    }

    public static func afterTurnRecovery(dataRoot: URL) -> AfterTurnMemoryRecoveryStatus {
        do {
            let held = try AdaptiveMemoryPromoter.readHeld(dataRoot: dataRoot)
            let latest = held.compactMap(\.failure).max { $0.at < $1.at }
            return AfterTurnMemoryRecoveryStatus(status: held.isEmpty ? "ready" : "held",
                                                heldCount: held.count, failure: latest)
        } catch {
            return AfterTurnMemoryRecoveryStatus(status: "unavailable", heldCount: nil, failure: nil)
        }
    }

    public static func getMemoryVectorStatus(dataRoot: URL) async throws -> MemoryVectorStatus {
        // An absent feed is unmeasured. A present-but-unreadable feed is
        // unavailable; neither state may impersonate a ready zero-count store.
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("vector_status.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return MemoryVectorStatus(
                status: "unmeasured",
                provider: nil,
                providerModel: nil,
                providerConfigured: nil,
                providerReason: "vector status has not been recorded for this data root",
                dimensions: nil,
                nodeCount: nil,
                entityCount: nil,
                updatedAt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        if let data = try? Data(contentsOf: path),
           let decoded = try? statusDecoder().decode(MemoryVectorStatus.self, from: data) {
            return decoded
        }
        return MemoryVectorStatus(
            status: "unavailable",
            provider: nil,
            providerModel: nil,
            providerConfigured: false,
            providerReason: "vector status not available",
            dimensions: nil,
            nodeCount: nil,
            entityCount: nil,
            updatedAt: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func getMemoryV2Status(dataRoot: URL) async throws -> MemoryV2Status {
        // Counts stay in SQLite; embedding fields share one runtime snapshot.
        var memCount = 0
        var activeCount = 0
        var pinnedCount = 0
        var pendingProposals: Int? = nil
        var storageReadable = false
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await storage.statusCounts()
            storageReadable = true
            memCount = counts.memories
            activeCount = counts.active
            pinnedCount = counts.pinned
            pendingProposals = counts.pendingProposals
        } catch {
            storageReadable = false
        }
        let runtimeSnapshot = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = runtimeSnapshot.map { "\($0.modelId)/d\($0.dimensions)" }
        let fallback: String? = {
            guard !isReal else { return nil }
            switch effective {
            case ManagedEmbeddingProvider.mockBackend:
                return "Semantic embeddings are explicitly set to mock (config or NATIVE_AGENT_EMBEDDING_MOCK)"
            case ManagedEmbeddingProvider.failClosedBackend:
                return "CoreML semantic embeddings unavailable; recall is fail-closed until the MiniLM bundle is installed"
            default:
                // Snapshot was nil (runtime not yet wired) — surface that honestly.
                return "Semantic embedding runtime is unavailable"
            }
        }()
        // F2: surface hygiene_last_run.json so the UI can show "last run at X /
        // next ~24h" instead of an empty hygiene slot that reads as "never".
        let hygieneReport = Self.readHygieneLastRun(dataRoot: dataRoot)
        return MemoryV2Status(
            // An unreadable store is not an empty store. The Memory screen
            // uses this provenance to avoid claiming no memories are saved
            // when the real reader could not establish a count.
            status: storageReadable ? (memCount > 0 ? "ready" : "empty") : "unavailable",
            version: "swift-native",
            embedding: MemoryV2Embedding(
                activeBackend: backend,
                realSemanticAvailable: isReal,
                fallbackReason: fallback
            ),
            counts: MemoryV2Counts(
                memories: memCount,
                active: activeCount,
                pinned: pinnedCount,
                pendingProposals: pendingProposals
            ),
            hygiene: hygieneReport,
            vault: nil,
            afterTurn: afterTurnRecovery(dataRoot: dataRoot),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func readHygieneLastRun(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> MemoryHygieneReport? {
        let path = dataRoot
            .appendingPathComponent("memory")
            .appendingPathComponent("hygiene_last_run.json")
        guard let data = try? Data(contentsOf: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let createdAt = (obj["createdAt"] as? String)
            ?? (obj["created_at"] as? String)
            ?? (obj["lastRun"] as? String)
            ?? (obj["last_run"] as? String)
        // Prefer the report's own nextScheduled; derive lastRun + 7d only when
        // absent. The cadence is WEEKLY (MemoryConsolidationHygieneRunner
        // stages one approval card per week) — the old derived +24h made the
        // Memory tab claim hygiene was overdue six days out of seven.
        var nextScheduled: String? = (obj["nextScheduled"] as? String)
            ?? (obj["next_scheduled"] as? String)
        // Honest-status (2026-07-24): a staged/refused run completed nothing —
        // its receipt intentionally carries no "next" stamp, and deriving one
        // here would recreate the false cadence boundary the runner just
        // stopped writing.
        let statusValue = (obj["status"] as? String) ?? "idle"
        if nextScheduled == nil,
           statusValue != "staged", statusValue != "refused",
           let createdAt, let dt = ISO8601DateFormatter().date(from: createdAt) {
            nextScheduled = ISO8601DateFormatter().string(from: dt.addingTimeInterval(7 * 24 * 3600))
        }
        return MemoryHygieneReport(
            id: obj["id"] as? String,
            status: (obj["status"] as? String) ?? "idle",
            reason: obj["reason"] as? String,
            version: obj["version"] as? String,
            createdAt: createdAt,
            beforeCount: obj["beforeCount"] as? Int,
            afterCount: obj["afterCount"] as? Int,
            normalized: obj["normalized"] as? Int,
            archivedDuplicates: obj["archivedDuplicates"] as? Int,
            archivedReflections: obj["archivedReflections"] as? Int,
            distilledFactsAdded: obj["distilledFactsAdded"] as? Int,
            decayedMemories: obj["decayedMemories"] as? Int,
            proposalHygiene: nil,
            consolidationRunId: (obj["consolidationRunId"] as? String)
                ?? (obj["consolidation_run_id"] as? String),
            nextScheduled: nextScheduled
        )
    }

    /// The miss ledger for the ISO `weeks` asked: every time she was given a
    /// correction in them (graduated ones too — a lesson now kept in GROWTH was
    /// still missed), grouped by the lesson it teaches, the most recently
    /// missed lesson first. Weekly counts per lesson are the growth metric.
    /// A correction given again collapses into its row; each turn-stamped
    /// repeat in `duplicate_occurrences` is a miss of its own, at its turn.
    /// Read for a `surface`, a row its disclosure keeps from that surface still
    /// counts but shows no text (nil: the Mac's own page, which sees all).
    public static func misses(dataRoot: URL, weeks: [String], surface: String? = nil) async throws -> [MemoryMissLesson] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        var lessons: [MemoryMissLesson] = []
        for m in try await storage.listMemories(persona: nil, status: nil, limit: nil)
        where m.status != "deleted" && MemoryMoments.metadataString(m.metadata, "kind") == "correction" {
            let session = MemoryMoments.metadataString(m.metadata, "session_id")
            // Dated by the turn that gave it (a held or recovered correction is
            // kept later); rows kept before turns were stamped, by their insert.
            var occurrences = [(at: MemoryMoments.metadataString(m.metadata, "turn_at") ?? m.createdAt, session: session,
                                history: MemoryMoments.metadataString(m.metadata, "history"))]
            if case .object(let meta)? = m.metadata, case .array(let repeats)? = meta["duplicate_occurrences"] {
                for case .object(let repeated) in repeats {
                    guard case .string(let at)? = repeated["turn_at"] else { continue }
                    // A key the repeat shares with the row is left out of it.
                    occurrences.append((at, MemoryMoments.metadataString(.object(repeated), "session_id") ?? session,
                                        MemoryMoments.metadataString(.object(repeated), "history")))
                }
            }
            // Scope only: a graduated or archived miss is history, not hidden.
            // A hidden one counts under one name and shows neither its words
            // nor the lesson named from them.
            let record = MemoryRecord(stored: m)
            let shown = surface == nil || MemoryRecordDisclosurePolicy.classify(
                personaID: record.personaId, status: "active", lifecycle: nil, tags: record.tags, metadata: record.extras
            )?.permits(surface: surface, personaID: nil) == true
            let name = !shown ? "not shown on this surface"
                : MemoryMoments.metadataString(m.metadata, "lesson") ?? lesson(metadata: m.metadata, text: m.content)
            let text = shown ? m.content : ""
            for occurrence in occurrences {
                let week = isoWeek(MemoryMoments.parseTimestamp(occurrence.at) ?? .distantPast)
                guard weeks.contains(week) else { continue }
                let miss = MemoryMiss(memoryId: m.id, text: text, at: occurrence.at, week: week,
                                      sessionId: occurrence.session, history: occurrence.history)
                if let index = lessons.firstIndex(where: { $0.lesson == name }) {
                    lessons[index].misses.append(miss)
                } else {
                    lessons.append(MemoryMissLesson(lesson: name, misses: [miss]))
                }
            }
        }
        // Newest first, each lesson's misses and the lessons themselves.
        func newest(_ miss: MemoryMiss) -> Date { MemoryMoments.parseTimestamp(miss.at) ?? .distantPast }
        for index in lessons.indices { lessons[index].misses.sort { newest($0) > newest($1) } }
        return lessons.sorted { newest($0.misses[0]) > newest($1.misses[0]) }
    }

    /// "2026-W41": the ISO week `date` falls in, on this Mac's clock. `ago`
    /// whole weeks back from it.
    public static func isoWeek(_ date: Date = Date(), ago: Int = 0) -> String {
        let date = date.addingTimeInterval(-Double(ago) * 7 * 86_400)
        let parts = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// Labels too broad to say what an agreement or a correction is about.
    public static let genericSubjects: Set<String> = [
        "instruction", "correction", "preference", "policy", "user", "agent", "claude", "codex", "nativeagent",
    ]

    /// The lesson a correction teaches, as one short tag, stamped once when it
    /// is kept (`lesson`): the memory manager's subject, else her first
    /// specific tag or topic, else the first words of its first clause. Rows
    /// kept before the stamp are named the same way when read.
    public static func lesson(metadata: JSONValue?, text: String) -> String {
        func tag(_ text: String) -> String {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4).joined(separator: "-")
        }
        var labels = [MemoryMoments.metadataString(metadata, "correction_subject")].compactMap { $0 }
        if case .object(let meta)? = metadata {
            for key in ["tags", "context_topics"] {
                guard case .array(let values)? = meta[key] else { continue }
                labels += values.compactMap { if case .string(let label) = $0 { label } else { nil } }
            }
        }
        if let label = labels.map(tag).first(where: { !$0.isEmpty && !genericSubjects.contains($0) }) {
            return label
        }
        return tag(text.split { ".,;:—(".contains($0) }.first.map(String.init) ?? text)
    }

    private static func statusDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct MemoryV2NativeStackSnapshot: Sendable, Equatable {
    public var sqliteRecordCount: Int
    public var sqliteProposalCount: Int
    /// `nil` before the direct store probe, `false` when it could not read.
    public var storageReadable: Bool?
    public var coreMLReady: Bool
    public var coreMLModelLabel: String
    public var embedderDimensions: Int
    public var runtimeEmbedderDimensions: Int? = nil
    // Runtime state distinguishes an installed model from a working embedder.
    public var coreMLLoaded: Bool
    public var coreMLLastLoadError: String?
    public var coreMLLoadCount: Int
    public var embeddingMode: String
    public var requestedEmbeddingBackend: String
    public var effectiveEmbeddingBackend: String
    public var spotlightReindexed: Bool
    public var spotlightIndexedCount: Int
    public var cloudKitAccountStatus: String
    public var dataRootPath: String

    /// Visual + textual status derived from the runtime fields above.
    /// Distinguishes real-model readiness from disabled or mock search.
    public enum EmbedderHealth {
        case working(loadCount: Int)   // green
        case ready                      // orange — resources present, never loaded
        case broken(reason: String)     // red — lastLoadError set
        case missing                    // red — bundled resources not reachable
        case disabled
        case mock

        public var isHealthy: Bool {
            if case .working = self { return true }
            return false
        }
        public var needsAttention: Bool {
            switch self {
            case .broken, .missing: return true
            default: return false
            }
        }
    }

    /// Derive the at-a-glance health state. Caller decides how to
    /// render — typical: green for working, orange for ready, red for
    /// broken/missing.
    public var embedderHealth: EmbedderHealth {
        if requestedEmbeddingBackend == ManagedEmbeddingProvider.mockBackend {
            return .disabled
        }
        if effectiveEmbeddingBackend == ManagedEmbeddingProvider.mockBackend {
            return .mock
        }
        if let err = coreMLLastLoadError {
            return .broken(reason: err)
        }
        if coreMLLoaded {
            return .working(loadCount: coreMLLoadCount)
        }
        if coreMLReady {
            return .ready
        }
        return .missing
    }

    public var shouldPollEmbeddingStartup: Bool {
        embeddingMode == ManagedEmbeddingProvider.performanceMode
            && effectiveEmbeddingBackend == ManagedEmbeddingProvider.coreMLBackend
            && coreMLReady
            && !coreMLLoaded
            && coreMLLastLoadError == nil
    }

    public static let empty = MemoryV2NativeStackSnapshot(
        sqliteRecordCount: 0,
        sqliteProposalCount: 0,
        storageReadable: nil,
        coreMLReady: false,
        coreMLModelLabel: "MiniLM-L6-v2 (pending .mlpackage)",
        embedderDimensions: 384,
        coreMLLoaded: false,
        coreMLLastLoadError: nil,
        coreMLLoadCount: 0,
        embeddingMode: "unknown",
        requestedEmbeddingBackend: "unknown",
        effectiveEmbeddingBackend: "unknown",
        spotlightReindexed: false,
        spotlightIndexedCount: 0,
        cloudKitAccountStatus: "checking…",
        dataRootPath: ""
    )

    public static func read(
        dataRoot: URL
    ) async -> MemoryV2NativeStackSnapshot {
        var snap = MemoryV2NativeStackSnapshot.empty
        snap.dataRootPath = dataRoot.path
        var spotlightEligibleCount = 0
        var storageGeneration: String?

        // SQLite probe — open the same store MemoryV2+Storage.swift uses and
        // count active rows. A clean empty store is 0; a failed read remains
        // explicit so the panel cannot present it as an empty memory profile.
        do {
            let store = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await store.statusCounts()
            snap.storageReadable = true
            snap.sqliteRecordCount = counts.active
            spotlightEligibleCount = counts.active
            storageGeneration = try await store.spotlightGenerationFingerprint()
            snap.sqliteProposalCount = counts.pendingProposals
        } catch {
            snap.storageReadable = false
        }

        // Core ML MiniLM probe. 2026-06-07 task #88: this used to roll its
        // own `Bundle.main.url(forResource: "MiniLM_L6_v2", ...)` check that
        // (a) used the wrong filename (the actual SPM resource is
        // `minilm.mlpackage`) and (b) couldn't traverse into the
        // NativeAgentCore_MemoryV2.bundle sub-bundle where the runtime
        // actually looks. Result: page perpetually said "pending .mlpackage"
        // even with a fully staged model. Now we ask the runtime's own
        // resolver — single source of truth, both `bundled` and
        // installedAppFallbackBundle paths covered. An installed model whose
        // manifest is unusable is NOT ready and never reads as the bundled
        // MiniLM (S12, 2026-09-26); refreshEmbeddingRuntime() below carries
        // the reason as the load error.
        do {
            if let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot) {
                snap.coreMLReady = true
                snap.coreMLModelLabel = installed.modelID + " (installed)"
                snap.embedderDimensions = installed.dimensions
            } else if CoreMLEmbeddingProvider.bundledResourcesAvailable() {
                snap.coreMLReady = true
                snap.coreMLModelLabel = CoreMLEmbeddingProvider.bundledModelID + " (bundled)"
            }
        } catch {
            snap.coreMLModelLabel = "installed model did not load"
        }

        // Runtime truth fields — the disk probe above tells us if
        // resources are reachable, but only the runtime knows whether
        // the model actually loaded and inference works. Pull
        // coreMLLoaded / lastLoadError / loadCount from
        // SwiftNativeMemoryV2's snapshot.
        await snap.refreshEmbeddingRuntime()

        // Spotlight — the `.spotlight_reindexed` sentinel is written by
        // MemorySpotlightBootstrap on first launch after the
        // cutover. Presence alone is not proof: a failed reindex can clear the
        // domain after a previous marker was written. The marker is valid only
        // when it names the current canonical projection generation.
        let spotMarker = SwiftNativeMemoryIndexer.markerURL(dataRoot: dataRoot)
        if let storageGeneration,
           let markerData = try? Data(contentsOf: spotMarker),
           String(data: markerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == storageGeneration {
            snap.spotlightReindexed = true
            snap.spotlightIndexedCount = spotlightEligibleCount
        }

        return snap
    }

    public mutating func refreshEmbeddingRuntime() async {
        guard let runtime = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot() else {
            return
        }
        runtimeEmbedderDimensions = runtime.dimensions
        embeddingMode = runtime.mode
        requestedEmbeddingBackend = runtime.requestedBackend
        effectiveEmbeddingBackend = runtime.effectiveBackend
        coreMLLoaded = runtime.coreMLLoaded
        coreMLLastLoadError = runtime.lastLoadError
        coreMLLoadCount = runtime.loadCount
    }
}

extension MemoryStatusProjection {
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
    public static func embeddingsStatus(dataRoot: URL) async throws -> EmbeddingsStatus {
        return embeddingsStatus(from: try await MemoryStatusProjection.embeddingRuntime(dataRoot: dataRoot))
    }

    /// Project a status from one runtime snapshot.
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
    public static func toggleEmbeddingsBackend(enabled: Bool, dataRoot: URL) async throws -> EmbeddingsToggleResult {
        let result = try await SwiftNativeMemoryV2.configureEmbeddingBackendAndReindex(enabled: enabled, dataRoot: dataRoot)
        let report = result.report
        let detail = "Atomically activated one embedding epoch across \(report.memories) memories, \(report.proposals) proposals, and \(report.tombstones) tombstones."
        return EmbeddingsToggleResult(ok: true, error: nil, detail: detail, status: embeddingsStatus(from: result.runtime))
    }

}

public enum EmbeddingPlainCopy {

    /// What the embedding runtime is actually doing for search right now.
    public enum SearchState: Equatable {
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
    public static func headline(_ state: SearchState) -> String {
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
    public static func technicalDetail(_ state: SearchState, error: String? = nil) -> String? {
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
    public static func modeLine(mode: String) -> String {
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
    public static let notLoadedYetLine =
        "The search model is not loaded right now. It loads on your next search."
}

extension MemoryStatusProjection {
    /// This ISO week's and last week's misses by lesson; nil when the ledger
    /// could not be read.
    public static func recentMisses(dataRoot: URL) async -> [MemoryMissLesson]? {
        try? await MemoryStatusProjection.misses(
            dataRoot: dataRoot, weeks: [MemoryStatusProjection.isoWeek(), MemoryStatusProjection.isoWeek(ago: 1)])
    }

}
