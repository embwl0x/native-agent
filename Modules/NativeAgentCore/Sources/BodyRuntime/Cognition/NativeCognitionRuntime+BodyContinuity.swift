import Foundation
import MindCore
import MacNerves
import SenseCore
import NativeAgentCore
import DeskCore
import PersistenceCore
import ProviderRouting
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+BodyContinuity.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    private var organismPersistentStateURL: URL {
        dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
    }

    func restoreOrganismContinuityIfAvailable() async {
        guard !organismContinuityRestored else { return }
        persistedOrganismFile = nil
        organismContinuityRestored = true
        // Persist only after restore; a failed decode freezes saved continuity rather than overwriting it with a fresh body.
        defer { organismContinuityReadable = true }
        let url = organismPersistentStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let stamp = SnapshotTailOpLog.fileStamp(url)
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(OrganismPersistentState.self, from: data)
            if let stamp, stamp == SnapshotTailOpLog.fileStamp(url) {
                persistedOrganismFile = (stamp, SHA256Hex.of(try Self.continuityBytes(state)))
            }
            await organismKernel.restorePersistentState(state)
            organismRestoreFailedHard = false
            await substrate.recordReceipt(
                kind: "organism.restore",
                payload: .object([
                    "path": .string("cognition/organism_state.json"),
                    "schemaVersion": .int(Int64(state.schemaVersion)),
                    "signalCount": .int(Int64(state.signalCount)),
                ])
            )
        } catch {
            // A failed decode freezes writes to preserve saved continuity.
            organismRestoreFailedHard = true
            await substrate.recordReceipt(
                kind: "organism.restore_failed",
                payload: .object([
                    "path": .string("cognition/organism_state.json"),
                    "error": .string(String(describing: error)),
                ])
            )
        }
    }

    @discardableResult
    func persistOrganismContinuity(reason: String) async -> Bool {
        guard let generation = scheduleOrganismContinuityPersistence(reason: reason) else {
            return false
        }
        return await awaitOrganismContinuityPersistence(through: generation)
    }

    /// One actor-owned drain coalesces durable generations without suspending signal ingestion.
    @discardableResult
    func scheduleOrganismContinuityPersistence(reason: String) -> UInt64? {
        // Never write through a failed restore; remain memory-only until a clean boot.
        guard !organismRestoreFailedHard else { return nil }
        // Never save before restore finishes or fresh state could overwrite saved continuity.
        guard organismContinuityReadable else { return nil }
        organismPersistenceRequestedGeneration &+= 1
        organismPersistenceLatestReason = String(reason.prefix(120))
        if organismPersistenceDrainTask == nil {
            organismPersistenceDrainTask = Task { [weak self] in
                await self?.drainOrganismContinuityPersistence()
            }
        }
        return organismPersistenceRequestedGeneration
    }

    private func awaitOrganismContinuityPersistence(through generation: UInt64) async -> Bool {
        if organismPersistenceCompletedGeneration >= generation {
            return organismPersistenceLastResult
        }
        let id = UUID(), done = ScopedWaiter()
        organismPersistenceWaiters[generation, default: [:]][id] = OrganismPersistenceWait(done: done)
        await Task { await done.park() }.value
        guard let waiting = organismPersistenceWaiters[generation]?.removeValue(forKey: id), let result = waiting.result else {
            await substrate.recordReceipt(kind: "organism.persist_failed", payload: .object([
                "error": .string("The continuity writer released a waiter without its result."),
            ]))
            return false
        }
        if organismPersistenceWaiters[generation]?.isEmpty == true { organismPersistenceWaiters[generation] = nil }
        return result
    }

    /// Coalesce arrivals during a write into one subsequent latest-state snapshot.
    private func drainOrganismContinuityPersistence() async {
        while !Task.isCancelled {
            guard organismPersistenceCompletedGeneration < organismPersistenceRequestedGeneration else {
                organismPersistenceDrainTask = nil
                return
            }
            let generation = organismPersistenceRequestedGeneration
            let reason = organismPersistenceLatestReason
            let succeeded = await writeOrganismContinuitySnapshot(reason: reason)
            organismPersistenceCompletedGeneration = generation
            organismPersistenceLastResult = succeeded
            resumeOrganismPersistenceWaiters(through: generation, result: succeeded)
        }
        organismPersistenceDrainTask = nil
        resumeOrganismPersistenceWaiters(
            through: organismPersistenceRequestedGeneration,
            result: false
        )
    }

    private func resumeOrganismPersistenceWaiters(through generation: UInt64, result: Bool) {
        let completed = organismPersistenceWaiters.keys.filter { $0 <= generation }
        for key in completed {
            guard let waiting = organismPersistenceWaiters[key] else { continue }
            for id in waiting.keys {
                guard organismPersistenceWaiters[key]?[id]?.result == nil else { continue }
                organismPersistenceWaiters[key]?[id]?.result = result
                organismPersistenceWaiters[key]?[id]?.done.resume()
            }
        }
    }

    private func writeOrganismContinuitySnapshot(reason: String) async -> Bool {
        // Preserve continuity whether body effects are dormant or awake.
        let state = await organismKernel.exportContinuity()
        do {
            let url = organismPersistentStateURL
            persistedOrganismFile = try await Self.writeOrganismPersistentState(state, to: url, previous: persistedOrganismFile)
            return true
        } catch {
            await substrate.recordReceipt(
                kind: "organism.persist_failed",
                payload: .object([
                    "reason": .string(String(reason.prefix(120))),
                    "path": .string("cognition/organism_state.json"),
                    "error": .string(String(describing: error)),
                ])
            )
            return false
        }
    }

    private nonisolated static func continuityBytes(_ state: OrganismPersistentState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private nonisolated static func writeOrganismPersistentState(
        _ state: OrganismPersistentState,
        to url: URL,
        previous: ContinuityFile?
    ) async throws -> ContinuityFile? {
        try await Task.detached(priority: .utility) { () throws -> ContinuityFile? in
            let data = try continuityBytes(state)
            let digest = SHA256Hex.of(data)
            guard let stamp = SnapshotTailOpLog.fileStamp(url) else {
                throw PersistenceCoreError.ioFailure("Cannot inspect body continuity at \(url.path)")
            }
            if let previous, previous.stamp == stamp, previous.digest == digest { return previous }
            if stamp != .absent && stamp != previous?.stamp {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let stored = try decoder.decode(OrganismPersistentState.self, from: Data(contentsOf: url))
                guard stamp == SnapshotTailOpLog.fileStamp(url) else {
                    throw PersistenceCoreError.ioFailure("Body continuity changed while reading \(url.path)")
                }
                if SHA256Hex.of(try continuityBytes(stored)) == digest {
                    try SwiftNativePersistenceCore.syncDirectory(url.deletingLastPathComponent())
                    return (stamp, digest)
                }
            }
            let written = try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url, trackingRevision: true)
            return written.map { ($0, digest) }
        }.value
    }
}
