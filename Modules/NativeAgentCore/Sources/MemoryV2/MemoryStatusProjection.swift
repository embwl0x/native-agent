import Foundation
import PersistenceCore

/// Read-only status and hygiene projections using the existing stores and runtime.
public enum MemoryStatusProjection {
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
        // fix3/F2: route truthfully through SwiftNativeMemoryV2.shared. Counts
        // come from MemoryStorage; pinned reads metadata.pinned; pending
        // proposals reads storage.listProposals(status: "pending"); embedding
        // backend reflects the live runtime snapshot — CoreML when MiniLM
        // loaded, mock when the user explicitly opted in (config or env),
        // fail-closed otherwise.
        var memCount = 0
        var activeCount = 0
        var pinnedCount = 0
        var pendingProposals: Int? = nil
        var storageReadable = false
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let all = try await storage.listMemories(persona: nil, status: nil, limit: nil)
            storageReadable = true
            memCount = all.count
            for m in all {
                // ONE MEANING OF "active" (Astra comb 4, lane4 finding 6). The
                // count read `status` alone while the browser also excludes the
                // corrected/contradicted/deleted lifecycles, so the summary said
                // "190 active" over a list that could only ever show 169: the 21
                // `status=active, lifecycle=corrected` rows (`FDF6A630-…` and
                // `BF12BC92-…`, both superseded sleep-schedule statements) were
                // counted by one surface and excluded by the other. Same
                // predicate as `listMemories(status: "active")`.
                if m.status == "active", MemoryLifecycle.isRecallEligible(m.lifecycle) {
                    activeCount += 1
                }
                // SQLite schema has no `pinned` column; updateMemory()
                // encodes the flag under metadata.pinned. Surface the
                // real count by inspecting the metadata blob.
                if case .object(let obj)? = m.metadata,
                   case .bool(true)? = obj["pinned"] {
                    pinnedCount += 1
                }
            }
            if let pending = try? await storage.listProposals(status: "pending") {
                pendingProposals = pending.count
            }
        } catch {
            storageReadable = false
        }
        let modelId = await SwiftNativeMemoryV2.shared.embedderModelId()
        let dims = await SwiftNativeMemoryV2.shared.embedderDimensions()
        // gpt-5.5 review-4 STILL-NEEDS-FIX: `embedderModelId()` returns
        // "all-MiniLM-L6-v2" whenever config requests CoreML — even when the
        // effective runtime is fail-closed (resources missing, embed() throws).
        // Deriving `isReal` from `modelId != "mock"` therefore lied to the UI:
        // a broken install surfaced as `realSemanticAvailable: true` with
        // `fallbackReason: nil`. Drive off the runtime snapshot's
        // `effectiveBackend` instead, which is the single source of truth
        // computed inside ManagedEmbeddingProvider with all the branch logic.
        let runtimeSnapshot = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = modelId.map { "\($0)\(dims.map { "/d\($0)" } ?? "")" }
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
                noisyReflections: nil,
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

    private static func statusDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
