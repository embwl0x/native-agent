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
// Blueprint: | `NativeCognitionRuntime+BodyContinuity.swift` | `NativeCognitionRuntime` body continuity: restore-gated organism persistence through one coalescing drain and atomic writer |

extension NativeCognitionRuntime {
    private var organismPersistentStateURL: URL {
        dataRoot
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
    }

    func restoreOrganismContinuityIfAvailable() async {
        guard !organismContinuityRestored else { return }
        organismContinuityRestored = true
        // The body persists only once its restore has finished: a missing file
        // is her first life, a decoded file is her body, a failed decode
        // freezes the file (`organismRestoreFailedHard`).
        defer { organismContinuityReadable = true }
        let url = organismPersistentStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(OrganismPersistentState.self, from: data)
            await organismKernel.restorePersistentState(state)
            // A clean restore unfreezes continuity persistence.
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
            // A failed decode freezes writes so the saved continuity survives.
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

    /// Advances the desired durable generation without suspending the caller.
    /// The actor owns exactly one drain task regardless of event burst size.
    @discardableResult
    func scheduleOrganismContinuityPersistence(reason: String) -> UInt64? {
        // Never write through a failed restore; remain memory-only until a clean boot.
        guard !organismRestoreFailedHard else { return nil }
        // Never write before the restore finished: a body written then would be
        // a fresh one over hers.
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
        return await withCheckedContinuation { continuation in
            organismPersistenceWaiters[generation, default: []].append(continuation)
            // An awaited save never waits out the debounce.
            organismPersistenceDebounceTask?.cancel()
        }
    }

    /// Serial latest-state drain coalesces arrivals during a write into one subsequent snapshot.
    private func drainOrganismContinuityPersistence() async {
        while !Task.isCancelled {
            guard organismPersistenceCompletedGeneration < organismPersistenceRequestedGeneration else {
                organismPersistenceDrainTask = nil
                return
            }
            // Un-awaited saves coalesce for 30 seconds; a waiter flushes immediately.
            if organismPersistenceWaiters.isEmpty,
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
            let continuations = organismPersistenceWaiters.removeValue(forKey: key) ?? []
            for continuation in continuations {
                continuation.resume(returning: result)
            }
        }
    }

    private func writeOrganismContinuitySnapshot(reason: String) async -> Bool {
        // Dormant or awake, the body's continuity is kept and saved.
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

    /// Encoding and filesystem work run outside the cognition actor. Awaiting
    /// this detached job keeps write ordering in the sole drain while allowing
    /// new sensory events to enter the actor during a slow disk operation.
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
