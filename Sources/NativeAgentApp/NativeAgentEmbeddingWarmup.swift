import Foundation
import MemoryV2
import PersistenceCore
import PersonaEngine

// Eagerly load the resident Neural Engine embedder without blocking app launch.
func maybeWarmEmbeddingsForFastMode() async {
    // Launch honors the bundled download descriptor in every memory mode; download never holds up warmup or chat.
    await EmbeddingModelDownloadController.shared.start()
    let memory = SwiftNativeMemoryV2.shared
    guard let snapshot = await memory.embeddingRuntimeSnapshot() else {
        nativeLog("[embedding-warmup] SKIP: embeddingRuntimeSnapshot() returned nil — memoryV2 actor not initialized yet?")
        return
    }
    nativeLog("[embedding-warmup] snapshot: mode=\(snapshot.mode) backend=requested:\(snapshot.requestedBackend)/effective:\(snapshot.effectiveBackend) coreMLLoaded=\(snapshot.coreMLLoaded) modelLoadable=\(snapshot.modelLoadable) resourcesAvailable=\(snapshot.coreMLResourcesAvailable) modelId=\(snapshot.modelId)")
    if snapshot.coreMLLoaded {
        nativeLog("[embedding-warmup] SKIP: already loaded by another path")
        return
    }
    // Intentionally NOT gating on modelLoadable. If resources aren't on
    // disk we'll catch the failure below; better to ATTEMPT and surface
    // a real error than to defer to a probe that was wrong about my
    // staging path the first time.
    nativeLog("[embedding-warmup] attempting load — modelLoadable=\(snapshot.modelLoadable)")
    do {
        try await memory.warmUpEmbedder()
        nativeLog("[embedding-warmup] SUCCESS: MiniLM eagerly warmed for Fast mode")
        let after = await memory.embeddingRuntimeSnapshot()
        nativeLog("[embedding-warmup] post-load snapshot: coreMLLoaded=\(after?.coreMLLoaded ?? false) effectiveBackend=\(after?.effectiveBackend ?? "nil")")
    } catch {
        nativeLog("[embedding-warmup] FAILED: \(error.localizedDescription)")
    }
}

/// One-shot corpus convergence after launch-time canonical memory repair.
/// There is no heartbeat: a matching protected epoch returns after one state
/// read; an unprotected legacy store or changed model artifact performs one
/// bounded off-main candidate build and atomic switch. Failure leaves the
/// previous corpus untouched and writes a diagnosable receipt for the UI/
/// operator rather than poisoning ordinary chat with mixed vectors.
@discardableResult
func reconcileMemoryEmbeddingEpochAtLaunch() async -> Bool {
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
            return false
        }
        guard state.activeEpoch != providerEpoch.rawValue else {
            writeReceipt([
                "status": "current",
                "active_epoch": providerEpoch.rawValue,
                "protected": true,
            ])
            return true
        }
        guard let report = try await memory.reconcileMemoryEmbeddingEpoch() else {
            writeReceipt(["status": "current", "active_epoch": providerEpoch.rawValue, "protected": true])
            return true
        }
        writeReceipt([
            "status": "activated",
            "active_epoch": report.epoch,
            "memories": report.memories,
            "proposals": report.proposals,
            "tombstones": report.tombstones,
            "protected": true,
        ])
        nativeLog("[memory-epoch] activated %@ across %d canonical rows", report.epoch, report.total)
        return true
    } catch {
        writeReceipt(["status": "failed", "error": String(describing: error)])
        nativeLog("[memory-epoch] activation failed; prior corpus retained: %@", String(describing: error))
        return false
    }
}

// Skills-recall rework (2026-07-03): launch/mutation skill-pointer sync. Scans
// the runtime + persona skill bodies and reconciles the memory store's
// "skill-pointer:<name>" rows (see MemoryV2+SkillIndex.swift). Fail-LOUD to
// stderr — the whole point of the rework is that skills stop being silently
// invisible, so a broken sync must not be silent either.
@discardableResult
func syncSkillPointerIndex(
    memory: SwiftNativeMemoryV2 = .shared,
    dataRoot: URL = PersistenceCore.defaultDataRoot(),
    personaRoot: URL = PersonaRootResolver.resolve()
) async -> SwiftNativeMemoryV2.SkillIndexSyncResult? {
    nativeLog("[skill-index] sync starting")
    let bodiesDirs = [
        dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
        personaRoot
            .appendingPathComponent("skills/bodies", isDirectory: true),
    ]
    let runtimeRegistry = dataRoot.appendingPathComponent("skills/registry.json")
    // Receipt on disk, not stderr: the installed app's stderr goes nowhere
    // readable, and a silent sync failure recreates the invisible-library
    // problem this rework exists to fix. The MemoryV2 owner writes the same
    // receipt for launch and mutation-triggered reconciliation.
    let receipt = dataRoot.appendingPathComponent("skills/.pointer_sync_receipt.json")
    do {
        let result = try await memory
            .syncSkillPointersRecordingReceipt(
                bodiesDirs: bodiesDirs,
                runtimeRegistryURL: runtimeRegistry,
                receiptURL: receipt
            )
        nativeLog("[skill-index] sync ok")
        nativeLog(
            "[skill-index] added=%d updated=%d removed=%d unchanged=%d",
            result.added, result.updated, result.removed, result.unchanged
        )
        return result
    } catch {
        nativeLog("[skill-index] SYNC FAILED: %@", String(describing: error))
        return nil
    }
}
