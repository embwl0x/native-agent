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
    typealias PhysiologySubmission = @Sendable (InstalledPhysiologySoakRecorder) async -> Void

    private enum PhysiologySubmissionWork: Sendable {
        case operation(PhysiologySubmission)
        case loss(UInt64)
    }

    /// The recorder's real enablement provenance. Consumers must not infer
    /// that a nil report represents a healthy zero-observation installed run.
    func installedPhysiologySoakCollectionStatus() -> InstalledPhysiologySoakEnablement {
        physiologySoakEnablement
    }

    func installedPhysiologySoakReport() async -> InstalledPhysiologySoakReport? {
        let drained = await drainPhysiologySubmissions()
        let report = await physiologySoakRecorder?.report()
        return drained ? report : report?.addingClaimBlocker(
            "physiology submission barrier did not complete"
        )
    }

    /// Keeps observational evidence entirely off the synchronous chat/tool
    /// path while retaining a termination barrier so accepted rows are not
    /// abandoned during a clean app exit.
    func submitPhysiology(  // internal for actor extensions (move-only Wave C)
        _ operation: @escaping @Sendable (InstalledPhysiologySoakRecorder) async -> Void
    ) {
        guard physiologySoakRecorder != nil else { return }
        guard pendingPhysiologySubmissions < Self.maximumPendingPhysiologySubmissions else {
            pendingPhysiologySubmissionLoss &+= 1
            return
        }
        pendingPhysiologySubmissions += 1
        physiologySubmissionQueue.append(operation)
        startPhysiologySubmissionWorkerIfNeeded()
    }

    private func startPhysiologySubmissionWorkerIfNeeded() {
        guard physiologySubmissionTail == nil, let physiologySoakRecorder else { return }
        let generation = physiologySubmissionGeneration
        physiologySubmissionTail = Task { [weak self] in
            while let work = await self?.nextPhysiologySubmission(generation: generation) {
                guard !Task.isCancelled else { return }
                switch work {
                case .operation(let operation):
                    await operation(physiologySoakRecorder)
                    await self?.completePhysiologySubmission(generation: generation)
                case .loss(let count):
                    await physiologySoakRecorder.recordSubmissionLoss(count)
                }
            }
        }
    }

    private func nextPhysiologySubmission(generation: UInt64) -> PhysiologySubmissionWork? {
        // Cancellation alone cannot stop a non-cooperative operation already
        // in flight. The generation fence prevents every later queued closure
        // from executing after that abandoned operation eventually returns.
        guard generation == physiologySubmissionGeneration, !Task.isCancelled else { return nil }
        if !physiologySubmissionQueue.isEmpty {
            return .operation(physiologySubmissionQueue.removeFirst())
        }
        if pendingPhysiologySubmissionLoss > 0 {
            let count = pendingPhysiologySubmissionLoss
            pendingPhysiologySubmissionLoss = 0
            return .loss(count)
        }
        physiologySubmissionTail = nil
        return nil
    }

    private func completePhysiologySubmission(generation: UInt64) {
        guard generation == physiologySubmissionGeneration else { return }
        pendingPhysiologySubmissions = max(0, pendingPhysiologySubmissions - 1)
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
    /// traversed the single ordered worker. Re-checking the worker after each
    /// suspension also catches work appended while the actor was re-entrant.
    @discardableResult
    func drainPhysiologySubmissions() async -> Bool {  // internal for actor extensions (move-only Wave C)
        let deadline = ProcessInfo.processInfo.systemUptime
            + physiologySubmissionDrainDeadlineSeconds
        while let tail = physiologySubmissionTail {
            let generation = physiologySubmissionGeneration
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let outcome = await raceAgainstTimeout(seconds: remaining) {
                await tail.value
            }
            // Another concurrent barrier may already have abandoned this
            // generation. Its timeout cannot cancel a newly admitted worker.
            guard generation == physiologySubmissionGeneration else { return false }
            switch outcome {
            case .value:
                continue
            case .timedOut:
                physiologySubmissionDrainTimeoutCount &+= 1
                await abandonPhysiologySubmissions(
                    reason: "drain exceeded \(physiologySubmissionDrainDeadlineSeconds)s deadline"
                )
                return false
            case .cancelled:
                await abandonPhysiologySubmissions(reason: "drain caller was cancelled")
                return false
            case .failure(let detail):
                await abandonPhysiologySubmissions(reason: "drain race failed: \(detail)")
                return false
            }
        }
        return true
    }

    private func abandonPhysiologySubmissions(reason: String) async {
        let abandonedCount = pendingPhysiologySubmissions
        let loss = pendingPhysiologySubmissionLoss &+ UInt64(abandonedCount)
        physiologySubmissionTail?.cancel()
        physiologySubmissionGeneration &+= 1
        pendingPhysiologySubmissions = 0
        physiologySubmissionQueue.removeAll(keepingCapacity: true)
        pendingPhysiologySubmissionLoss = 0
        physiologySubmissionTail = nil
        deadlineLogger(
            "PHYSIOLOGY BAIL-OUT: \(reason); abandoned \(abandonedCount) pending submission(s)"
        )
        // The in-flight operation is conservatively unknown, not silently
        // successful. Persist the gap through the recorder's existing owner.
        await physiologySoakRecorder?.recordSubmissionLoss(loss)
    }
}
