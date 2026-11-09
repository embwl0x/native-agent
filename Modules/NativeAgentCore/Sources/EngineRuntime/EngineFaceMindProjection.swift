import Cognition
import Context
import ContextFlow
import Foundation
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
// Blueprint: | `EngineFaceMindProjection.swift` | Independently held memory, cognition and event-driven context health presentations |

public enum EngineFaceMindProjection {
    @concurrent static func prepareCapture(_ key: FaceKey, engine: NativeAgentEngine) async throws {
        switch key {
        case .memoryDiagnostics:
            let issues = await engine.memory.refreshStatuses()
            guard issues.isEmpty else {
                throw failure("memory_refresh_failed", issues.map { $0.error.localizedDescription }.joined(separator: "\n"))
            }
            await engine.memory.refreshDiagnostics()
            await engine.face.post(memoryFace(await memoryInput(engine)), at: key)
        case .cognition:
            await engine.cognitionView.refreshDetail()
            guard let detail = await engine.cognitionView.detail else {
                throw failure("cognition_unavailable", "The resident mind has supplied no Observatory reading.")
            }
            await engine.face.post(EngineFaceCognitionProjection.face(detail), at: key)
        case .contextFlowHealth:
            await engine.cognitionView.refreshContextFlowHealth { await engine.contextFlow.observatoryHealthState() }
            await engine.face.post(context(await engine.cognitionView.contextFlowHealth), at: key)
        default:
            throw failure("capture_key_unavailable", "This owner does not prepare that native capture value.")
        }
    }

    @concurrent static func observe(_ key: FaceKey, engine: NativeAgentEngine) async {
        if key == .memoryDiagnostics {
            await memory(engine)
            return
        }
        if key == .contextFlowHealth {
            await contextHealth(engine)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let changes = await engine.cognitionView.changes()
                await engine.cognitionView.refreshDetail()
                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    await engine.cognitionView.refreshDetail()
                }
            }
            await EngineFaceProjection.watch(read: { engine.cognitionView.detail }) { detail in
                guard !Task.isCancelled else { return }
                let face: CognitionFace
                if let detail { face = EngineFaceCognitionProjection.face(detail) }
                else {
                    face = CognitionFace(sections: [], proposals: [], receipts: [], organism: [], capsule: [],
                        state: engine.cognition == nil
                            ? .unavailable(EngineFaceActs.failure("body_unavailable", "This root has no resident mind."))
                            : .waiting(on: "cognition"))
                }
                await engine.face.post(face, at: .cognition)
            }
            group.cancelAll()
        }
    }

    @concurrent private static func contextHealth(_ engine: NativeAgentEngine) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in engine.contextFlow.healthChanges() {
                    guard !Task.isCancelled else { return }
                    await engine.cognitionView.refreshContextFlowHealth { await engine.contextFlow.observatoryHealthState() }
                }
            }
            await EngineFaceProjection.watch(read: {
                (engine.cognitionView.contextFlowHealth, engine.cognitionView.contextFlowHealthCheckedAt)
            }) { health, checkedAt in
                guard !Task.isCancelled else { return }
                let face = checkedAt == nil
                    ? ContextFlowHealthFace(health: .unreadable, rows: [], state: .waiting(on: "Context Flow health")) : context(health)
                await engine.face.post(face, at: .contextFlowHealth)
            }
            group.cancelAll()
        }
    }

    private struct MemoryInput: Sendable {
        let snapshot: MemoryV2NativeStackSnapshot
        let checkedAt: Date?
        let stale: Bool?
        let counts: [String: Int]
        let issue: String?
        let embeddingIssue: String?
        let owed: [String]
    }

    @concurrent private static func memory(_ engine: NativeAgentEngine) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await engine.memory.refreshEmbeddingDiagnostics() }
            group.addTask {
                let path = engine.dataRoot.appendingPathComponent("memory/memory.sqlite")
                await EngineFaceProjection.watchFiles([path, URL(fileURLWithPath: path.path + "-wal")], refresh: {
                    await engine.memory.setDiagnosticsObservationIssue(nil)
                    _ = await engine.memory.refreshStatuses()
                }, unavailable: { await engine.memory.setDiagnosticsObservationIssue($0) })
            }
            await EngineFaceProjection.watch(read: { memoryInput(engine) }) { input in
                guard !Task.isCancelled else { return }
                await engine.face.post(memoryFace(input), at: .memoryDiagnostics)
            }
            group.cancelAll()
        }
    }

    @MainActor static func memoryPresentation(_ engine: NativeAgentEngine) -> MemoryDiagnosticsFace {
        memoryFace(memoryInput(engine))
    }

    @MainActor private static func memoryInput(_ engine: NativeAgentEngine) -> MemoryInput {
        let memory = engine.memory
        let counts = memory.status?.counts
        return MemoryInput(snapshot: memory.diagnostics, checkedAt: memory.diagnosticsCheckedAt,
            stale: memory.statusRefresh?.isStale,
            counts: ["memories": counts?.memories, "active": counts?.active, "pinned": counts?.pinned,
                "pendingProposals": counts?.pendingProposals].compactMapValues { $0 },
            issue: memory.statusReadError ?? memory.diagnosticsObservationIssue,
            embeddingIssue: memory.embeddingsError,
            owed: memory.status?.afterTurn?.lines ?? [])
    }

    private static func memoryFace(_ input: MemoryInput) -> MemoryDiagnosticsFace {
        let snapshot = input.snapshot
        let state: FaceReadState
        if let issue = input.issue { state = .unavailable(failure("memory_diagnostics_unavailable", issue)) }
        else if snapshot.storageReadable == false {
            state = .unavailable(failure("memory_storage_unavailable", "Saved memories could not be read."))
        } else { state = input.checkedAt == nil ? .waiting(on: "memory diagnostics") : .ready }
        let countLabels = ["memories": "Saved memories", "active": "Active memories", "pinned": "Pinned memories",
            "pendingProposals": "Pending proposals"]
        var rows = input.counts.keys.sorted().compactMap { key -> PartFace.Row? in
            guard let label = countLabels[key], let count = input.counts[key] else { return nil }
            return row("count." + key, label, String(count))
        }
        if input.checkedAt != nil {
            rows += [row("model", "On-device search", snapshot.coreMLModelLabel),
                row("backend", "Embedding backend", snapshot.requestedEmbeddingBackend + " → " + snapshot.effectiveEmbeddingBackend),
                row("inference", "Model inference", snapshot.coreMLLoaded ? "Loaded · \(snapshot.coreMLLoadCount) loads" : "Not loaded"),
                row("spotlight", "Spotlight", snapshot.spotlightReindexed ? "\(snapshot.spotlightIndexedCount) indexed" : "Not indexed"),
                row("cloudkit", "iCloud", snapshot.cloudKitAccountStatus),
                row("profile", "Long-term memory profile", "USER.md"),
                row("model.dimensions", "Model dimensions", String(snapshot.embedderDimensions)),
                row("runtime.dimensions", "Runtime dimensions", snapshot.runtimeEmbedderDimensions.map(String.init) ?? "Unavailable"),
                row("location", "Data root", "Private location hidden"),
                row("checked", "Diagnostics checked", nil, date: input.checkedAt)]
            if let issue = snapshot.spotlightLastError { rows.append(row("spotlight.issue", "Spotlight issue", issue)) }
        }
        rows += input.owed.enumerated().map { row("owed.\($0.offset)", "Lived moments", $0.element) }
        return MemoryDiagnosticsFace(rows: rows, counts: input.counts,
            dimensions: input.checkedAt == nil ? nil : snapshot.runtimeEmbedderDimensions, checkedAt: input.checkedAt,
            stale: input.stale, cloudKitIssue: nil,
            embeddingIssue: (input.embeddingIssue ?? snapshot.coreMLLastLoadError).map { failure("embedding_unavailable", $0) }, state: state)
    }

    public static func context(_ input: ContextFlowObservatoryHealthState) -> ContextFlowHealthFace {
        switch input {
        case .unavailable:
            return ContextFlowHealthFace(health: .unreadable, rows: [],
                state: .unavailable(failure("context_health_unavailable", "Context Flow health could not be read.")))
        case .off:
            return ContextFlowHealthFace(health: .off, rows: [row("mode", "Mode", "off")], state: .ready)
        case .health(let health):
            var rows = [row("mode", "Mode", health.mode.rawValue),
                row("started", "Started", String(health.started)),
                row("store", "Store generation", health.activeStoreGenerationID.map(String.init) ?? "None published"),
                row("arena", "RAM generation", health.activeArenaGenerationID.map(String.init) ?? "None published"),
                row("sources", "Registered sources", String(health.registeredSourceCount)),
                row("degraded", "Degraded sources", String(health.degradedSourceCount)),
                row("bytes", "Arena bytes", String(health.arenaMetrics.residentLogicalBytes)),
                row("pressure", "Pressure", health.arenaMetrics.pressure.rawValue),
                row("leases", "Active leases", String(health.arenaMetrics.activeLeaseCount)),
                row("feedback", "Feedback events", String(health.feedbackEventCount))]
            if let date = health.lastReconciledAt { rows.append(row("reconciled", "Reconciled", nil, date: date)) }
            if let issue = health.lastError { rows.append(row("issue", "Context Flow issue", issue)) }
            let state: FaceReadState = health.lastError.map { .unavailable(failure("context_health_failed", $0)) } ?? .ready
            return ContextFlowHealthFace(health: health.lastError != nil || !health.started ? .failed : .ready, rows: rows, state: state)
        }
    }

    static func row(_ id: String, _ title: String, _ detail: String?, state: String? = nil, date: Date? = nil) -> PartFace.Row {
        PartFace.Row(id: id, title: NativeAppSecretRedactor.redactText(title), detail: detail.map(NativeAppSecretRedactor.redactText),
            value: state, at: date.map { ISO8601DateFormatter().string(from: $0) }, actions: [])
    }

    static func failure(_ code: String, _ cause: String) -> WireFailure {
        EngineFaceActs.failure(code, NativeAppSecretRedactor.redactText(cause))
    }
}
