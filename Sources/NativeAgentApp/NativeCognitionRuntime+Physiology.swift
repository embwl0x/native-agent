// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

extension NativeCognitionRuntime {
    func installedPhysiologySoakReport() async -> InstalledPhysiologySoakReport? {
        await drainPhysiologySubmissions()
        return await physiologySoakRecorder?.report()
    }

    /// Keeps observational evidence entirely off the synchronous chat/tool
    /// path while retaining a termination barrier so accepted rows are not
    /// abandoned during a clean app exit.
    func submitPhysiology(  // internal for actor extensions (move-only Wave C)
        _ operation: @escaping @Sendable (InstalledPhysiologySoakRecorder) async -> Void
    ) {
        guard let physiologySoakRecorder else { return }
        let predecessor = physiologySubmissionTail
        let generation = physiologySubmissionGeneration
        pendingPhysiologySubmissions += 1
        physiologySubmissionTail = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else {
                await self?.completePhysiologySubmission(generation: generation)
                return
            }
            await operation(physiologySoakRecorder)
            await self?.completePhysiologySubmission(generation: generation)
        }
    }

    private func completePhysiologySubmission(generation: UInt64) {
        guard generation == physiologySubmissionGeneration else { return }
        pendingPhysiologySubmissions = max(0, pendingPhysiologySubmissions - 1)
        if pendingPhysiologySubmissions == 0 {
            physiologySubmissionTail = nil
        }
    }

    /// Deterministic fault-injection seam for the ordered submission barrier.
    /// Production callers cannot use it because manually-flushed scheduling is
    /// available only to alternate/test runtimes.
    func submitPhysiologyForProof(
        _ operation: @escaping @Sendable (InstalledPhysiologySoakRecorder) async -> Void
    ) {
        guard microcycleSchedulingMode == .manuallyFlushed else { return }
        submitPhysiology(operation)
    }

    /// Waits until every recorder emission accepted before this barrier has
    /// traversed the single ordered tail. Re-checking the count after each
    /// suspension also catches work appended while the actor was re-entrant.
    func drainPhysiologySubmissions() async {  // internal for actor extensions (move-only Wave C)
        let deadline = ProcessInfo.processInfo.systemUptime
            + physiologySubmissionDrainDeadlineSeconds
        while pendingPhysiologySubmissions > 0 {
            guard let tail = physiologySubmissionTail else {
                // Defensive recovery: the count and tail are maintained
                // together, so this branch should be unreachable.
                assertionFailure("physiology submission count lost its ordered tail")
                abandonPhysiologySubmissions(
                    reason: "submission count lost its ordered tail"
                )
                return
            }
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let outcome = await raceAgainstTimeout(seconds: remaining) {
                await tail.value
            }
            switch outcome {
            case .value:
                continue
            case .timedOut:
                physiologySubmissionDrainTimeoutCount &+= 1
                abandonPhysiologySubmissions(
                    reason: "drain exceeded \(physiologySubmissionDrainDeadlineSeconds)s deadline"
                )
                return
            case .cancelled:
                abandonPhysiologySubmissions(reason: "drain caller was cancelled")
                return
            case .failure(let detail):
                abandonPhysiologySubmissions(reason: "drain race failed: \(detail)")
                return
            }
        }
    }

    private func abandonPhysiologySubmissions(reason: String) {
        let abandonedCount = pendingPhysiologySubmissions
        physiologySubmissionTail?.cancel()
        physiologySubmissionGeneration &+= 1
        pendingPhysiologySubmissions = 0
        physiologySubmissionTail = nil
        deadlineLogger(
            "PHYSIOLOGY BAIL-OUT: \(reason); abandoned \(abandonedCount) pending submission(s)"
        )
    }
}
