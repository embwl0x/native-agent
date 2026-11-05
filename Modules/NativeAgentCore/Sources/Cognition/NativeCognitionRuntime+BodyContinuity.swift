import Foundation
import MemoryV2
import ApprovalInbox
import AuthoredCapabilities
import ChatTurnRuntime
import CognitiveSubstrate
import Context
import ContextFlow
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting
import TurnTrace
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
        organismContinuityRestored = true
        // Persist only after restore; a failed decode freezes saved continuity rather than overwriting it with a fresh body.
        defer { organismContinuityReadable = true }
        let url = organismPersistentStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(OrganismPersistentState.self, from: data)
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
        // An awaited save bypasses debounce even when cancelled.
        organismPersistenceDebounceTask?.cancel()
        await Task { await done.park() }.value
        let result = organismPersistenceWaiters[generation]!.removeValue(forKey: id)!.result!
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
            // Coalesce unawaited saves for 30 seconds; awaited saves flush immediately.
            if !organismPersistenceWaiters.values.contains(where: { $0.values.contains(where: { $0.result == nil }) }),
               let last = organismPersistenceLastWriteAt,
               ContinuousClock.now < last + .seconds(30) {
                let due = last + .seconds(30)
                let debounce = Task<Void, Never> {
                    try? await Task.sleep(until: due, clock: .continuous)
                }
                organismPersistenceDebounceTask = debounce
                await debounce.value
                organismPersistenceDebounceTask = nil
                continue
            }
            let generation = organismPersistenceRequestedGeneration
            let reason = organismPersistenceLatestReason
            let succeeded = await writeOrganismContinuitySnapshot(reason: reason)
            organismPersistenceLastWriteAt = ContinuousClock.now
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
            try await Self.writeOrganismPersistentState(state, to: url)
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

    /// Run encoding and filesystem work outside the actor; the sole drain awaits it to preserve ordering while sensory events continue.
    private nonisolated static func writeOrganismPersistentState(
        _ state: OrganismPersistentState,
        to url: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
        }.value
    }
}
