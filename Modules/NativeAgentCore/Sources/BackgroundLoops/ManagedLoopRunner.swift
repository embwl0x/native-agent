import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `ManagedLoopRunner.swift` | LoopExecutionGate, ManagedLoopRunner: one run per registration until exit and accounting; agent passes await setup |

/// Coalesce requests against active execution and join its physical exit instead of invoking the worker twice.

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

    /// Give the owner its token; coalesced callers wait for settlement and receive nil.
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
    /// Whether the agent exists yet (setup finished); read at each start of a pass that needs the agent.
    let agentExists: @Sendable () -> Bool

    var loopId: String { underlying.loopId }
    var wake: OrganWake { underlying.wake }
    var tickTimeoutOverride: TimeInterval? { underlying.tickTimeoutOverride }

    /// Managed registrations require the manager's explicit accounting handshake.
    func tickOutcome() async -> LoopTickOutcome {
        .failed(error: "Background work must start through its manager so its result is recorded.")
    }

    func shutdown() async {
        await gate.close()
        await underlying.shutdown()
        await settle { await gate.join() }
    }

    /// Gate admission precedes the durable due and lifecycle checks.
    func tickOutcome(
        ifDue isDue: (@Sendable () async -> Bool)?, execution: ManagedLoopExecution
    ) async -> LoopTickOutcome {
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
        let agentExists = agentExists
        let child = Task {
            // The one gate for the agent's passes: before setup finishes there is no agent, so its pass is not started and records no failure.
            let outcome: LoopTickOutcome
            if loop.needsAgent && !agentExists() {
                outcome = .notNeeded(LoopTickOutcome.waitingForSetup)
            } else {
                outcome = await loop.tickOutcome()
            }
            // Only an uncancelled body that ran may stamp its own writes.
            if !Task.isCancelled && !outcome.isHealthNeutralSkip {
                PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: loopId)
            }
            await finishAfterRecording(token: token, accounting: execution.accounting)
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
