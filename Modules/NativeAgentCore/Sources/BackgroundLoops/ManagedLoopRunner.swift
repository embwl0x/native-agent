import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `ManagedLoopRunner.swift` | LoopExecutionGate and ManagedLoopRunner serialize each registration through physical worker exit and durable accounting |

/// Serializes every execution request for one loop registration. A request
/// arriving during an active tick waits for that tick and then returns without
/// invoking the underlying loop again.

internal actor LoopExecutionGate {
    struct Snapshot: Sendable {
        let executing: Bool
        let executionStartedAt: Date?
    }

    private var active = false
    private var accepting = true
    private var worker: Task<LoopTickOutcome, Never>?
    private var activeSince: Date?
    private var idle = ScopedWaiter()
    /// `finish` only releases the execution that owns this token.
    private var generation: UInt64 = 0

    /// Returns the ownership token to the request that owns this execution.
    /// Coalesced callers wait for that owner and receive nil.
    func acquireOrJoin(startedAt: Date) async -> UInt64? {
        guard accepting, !Task.isCancelled else { return nil }
        guard active else {
            active = true
            idle = ScopedWaiter()
            activeSince = startedAt
            generation &+= 1
            return generation
        }
        await idle.park()
        return nil
    }

    /// Releases exactly one acquire after its body and accounting settle.
    func finish(token: UInt64) {
        guard active, token == generation else { return }
        active = false
        activeSince = nil
        idle.resume()
    }

    func retain(_ task: Task<LoopTickOutcome, Never>, token: UInt64) async {
        guard active, token == generation else {
            task.cancel()
            _ = await task.value
            return
        }
        worker = task
        if !accepting { task.cancel() }
    }

    func close() {
        accepting = false
        worker?.cancel()
    }

    func join() async {
        _ = await worker?.value
        if active { await idle.park() }
        _ = await worker?.value
    }
    func reopen() { if !active { accepting = true } }

    func snapshot() -> Snapshot {
        Snapshot(
            executing: active,
            executionStartedAt: activeSince
        )
    }
}

internal struct ManagedLoopRunner: LoopRunner {
    let underlying: any LoopRunner
    let gate: LoopExecutionGate
    let clock: @Sendable () -> Date
    let onFinished: @Sendable () async -> Void

    var loopId: String { underlying.loopId }
    var interval: TimeInterval { underlying.interval }
    var tickTimeoutOverride: TimeInterval? { underlying.tickTimeoutOverride }

    /// The outer timeout selects the caller's verdict; this retained child
    /// releases its gate token only after body exit and outcome accounting.
    func tickOutcome() async -> LoopTickOutcome {
        await tickOutcome(ifDue: nil)
    }

    func shutdown() async {
        await gate.close()
        await underlying.shutdown()
        await settle { await gate.join() }
    }

    /// Gate admission precedes the durable due and lifecycle checks.
    func tickOutcome(ifDue isDue: (@Sendable () async -> Bool)?) async -> LoopTickOutcome {
        guard let accounting = LoopTickAccounting.current else {
            return .failed(error: "Background work could not start because result tracking is unavailable.")
        }
        guard let token = await gate.acquireOrJoin(startedAt: clock()) else {
            return .skipped(reason: LoopTickOutcome.coalescedSkipReason)
        }
        if let isDue, !(await isDue()) {
            await gate.finish(token: token)
            await onFinished()
            return .skipped(
                reason: LoopTickOutcome.notDueSkipReason,
                healthNeutral: true
            )
        }
        let loop = underlying
        let child = Task {
            let outcome = await loop.tickOutcome()
            // Only an uncancelled body that ran may stamp its own writes.
            if !Task.isCancelled && !outcome.isHealthNeutralSkip {
                PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: loopId)
            }
            await finishAfterRecording(token: token, accounting: accounting)
            return outcome
        }
        await gate.retain(child, token: token)
        return await withTaskCancellationHandler {
            await child.value
        } onCancel: {
            child.cancel()
        }
    }

    private func finishAfterRecording(
        token: UInt64, accounting: LoopTickAccounting
    ) async {
        let release: @Sendable () async -> Void = {
            await gate.finish(token: token)
            await onFinished()
        }
        await accounting.releaseAfterRecording(release)
    }
}
