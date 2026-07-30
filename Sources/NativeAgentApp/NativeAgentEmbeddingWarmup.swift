import Foundation
import MemoryV2
import PersistenceCore
import PersonaEngine

// 2026-06-07 task #88: eager MiniLM warm-up for Fast mode. Reads the
// persisted embedding mode via the SwiftNativeMemoryV2 snapshot; if Fast
// is selected and the model isn't already loaded AND the bundle is on
// disk, fires a one-shot embed(["warmup"]) so the first chat turn
// doesn't pay the load tax. Detached caller wraps this in Task.detached
// so a multi-second cold-start can't block app launch.
//
// Skip conditions (each is a "do nothing, return"):
//   - Snapshot unavailable (memoryV2 disabled or actor unreachable)
//   - Mode != "performance" (user picked Balanced or Low)
//   - coreMLLoaded == true (something else already warmed it)
//   - modelLoadable == false (CoreML resources not on disk — let the
//     fail-closed contract surface the error on first real use, no
//     point repeatedly thrashing the load attempt at launch)
//   - effectiveBackend == "mock" (user explicitly opted out OR
//     NATIVE_AGENT_EMBEDDING_MOCK env var set — pre-warming a mock
//     provider is pointless)
// Nonisolated — the detached caller runs this off-main; the heavy CoreML
// work happens inside the embedder behind its own lock, so no MainActor
// hop is needed (gpt-5.5 review nit, addressed).
//
// 2026-06-07 ITERATION 2 (the user caught Activity Monitor showing 148 MB =
// MiniLM not loaded despite Fast mode + my pre-warm code shipping). The
// guards below now ALL log when they trigger, AND we no longer skip on
// modelLoadable=false — that probe can be transiently wrong at launch
// before resources are visible to FileManager, and the safe thing under
// "user explicitly wanted Fast mode" is to ATTEMPT the load and let
// the embedder's own fail-closed contract decide. Skipping would
// silently honor a false negative.
func maybeWarmEmbeddingsForFastMode() async {
    let memory = SwiftNativeMemoryV2.shared
    guard let snapshot = await memory.embeddingRuntimeSnapshot() else {
        NSLog("[embedding-warmup] SKIP: embeddingRuntimeSnapshot() returned nil — memoryV2 actor not initialized yet?")
        return
    }
    NSLog("[embedding-warmup] snapshot: mode=\(snapshot.mode) backend=requested:\(snapshot.requestedBackend)/effective:\(snapshot.effectiveBackend) coreMLLoaded=\(snapshot.coreMLLoaded) modelLoadable=\(snapshot.modelLoadable) resourcesAvailable=\(snapshot.coreMLResourcesAvailable) modelId=\(snapshot.modelId)")
    guard snapshot.mode == ManagedEmbeddingProvider.performanceMode else {
        NSLog("[embedding-warmup] SKIP: mode is '\(snapshot.mode)', not 'performance'")
        return
    }
    if snapshot.coreMLLoaded {
        NSLog("[embedding-warmup] SKIP: already loaded by another path")
        return
    }
    if snapshot.effectiveBackend == ManagedEmbeddingProvider.mockBackend {
        NSLog("[embedding-warmup] SKIP: effective backend is mock (user opt-out or NATIVE_AGENT_EMBEDDING_MOCK)")
        return
    }
    // Intentionally NOT gating on modelLoadable. If resources aren't on
    // disk we'll catch the failure below; better to ATTEMPT and surface
    // a real error than to defer to a probe that was wrong about my
    // staging path the first time.
    NSLog("[embedding-warmup] attempting load — modelLoadable=\(snapshot.modelLoadable)")
    do {
        try await memory.warmUpEmbedder()
        NSLog("[embedding-warmup] SUCCESS: MiniLM eagerly warmed for Fast mode")
        let after = await memory.embeddingRuntimeSnapshot()
        NSLog("[embedding-warmup] post-load snapshot: coreMLLoaded=\(after?.coreMLLoaded ?? false) effectiveBackend=\(after?.effectiveBackend ?? "nil")")
    } catch {
        NSLog("[embedding-warmup] FAILED: \(error.localizedDescription)")
    }
}

/// One-shot corpus convergence after launch-time canonical memory repair.
/// There is no heartbeat: a matching protected epoch returns after one state
/// read; an unprotected legacy store or changed model artifact performs one
/// bounded off-main candidate build and atomic switch. Failure leaves the
/// previous corpus untouched and writes a diagnosable receipt for the UI/
/// operator rather than poisoning ordinary chat with mixed vectors.
func reconcileMemoryEmbeddingEpochAtLaunch() async {
    let memory = SwiftNativeMemoryV2.shared
    let dataRoot = PersistenceCore.defaultDataRoot()
    let receipt = dataRoot
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("embedding_epoch_receipt.json")
    func writeReceipt(_ object: [String: Any]) {
        var payload = object
        payload["at"] = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: receipt, options: .atomic)
        }
    }
    do {
        let state = try await memory.memoryEmbeddingEpochState()
        guard let providerEpoch = await memory.embeddingEpoch() else {
            writeReceipt(["status": "failed", "error": "embedding provider unavailable"])
            return
        }
        guard state.activeEpoch != providerEpoch.rawValue else {
            writeReceipt([
                "status": "current",
                "active_epoch": providerEpoch.rawValue,
                "protected": true,
            ])
            return
        }
        let report = try await memory.reindexAllMemoryEmbeddingsForCurrentProvider()
        writeReceipt([
            "status": "activated",
            "active_epoch": report.epoch,
            "memories": report.memories,
            "proposals": report.proposals,
            "tombstones": report.tombstones,
            "protected": true,
        ])
        NSLog("[memory-epoch] activated %@ across %d canonical rows", report.epoch, report.total)
    } catch {
        writeReceipt(["status": "failed", "error": String(describing: error)])
        NSLog("[memory-epoch] activation failed; prior corpus retained: %@", String(describing: error))
    }
}

// Skills-recall rework (2026-07-03): launch/mutation skill-pointer sync. Scans
// the runtime + persona skill bodies and reconciles the memory store's
// "skill-pointer:<name>" rows (see MemoryV2+SkillIndex.swift). Fail-LOUD to
// stderr — the whole point of the rework is that skills stop being silently
// invisible, so a broken sync must not be silent either.
func syncSkillPointerIndex() async {
    NSLog("[skill-index] sync starting")
    let dataRoot = PersistenceCore.defaultDataRoot()
    let bodiesDirs = [
        dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
        PersonaRootResolver.resolve()
            .appendingPathComponent("skills/bodies", isDirectory: true),
    ]
    let runtimeRegistry = dataRoot.appendingPathComponent("skills/registry.json")
    // Receipt on disk, not stderr: the installed app's stderr goes nowhere
    // readable, and a silent sync failure recreates the invisible-library
    // problem this rework exists to fix. The MemoryV2 owner writes the same
    // receipt for launch and mutation-triggered reconciliation.
    let receipt = dataRoot.appendingPathComponent("skills/.pointer_sync_receipt.json")
    do {
        let result = try await SwiftNativeMemoryV2.shared
            .syncSkillPointersRecordingReceipt(
                bodiesDirs: bodiesDirs,
                runtimeRegistryURL: runtimeRegistry,
                receiptURL: receipt
            )
        NSLog("[skill-index] sync ok")
        NSLog(
            "[skill-index] added=%d updated=%d removed=%d unchanged=%d",
            result.added, result.updated, result.removed, result.unchanged
        )
    } catch {
        NSLog("[skill-index] SYNC FAILED: %@", String(describing: error))
    }
}
