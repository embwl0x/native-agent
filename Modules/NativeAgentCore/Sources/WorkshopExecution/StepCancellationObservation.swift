import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Desk
import Privacy
import SwarmRuns
import os
import ProviderRouting
import TrustCenter
import MacIntegration
import ToolRegistry
import ChatToolParsing
// Blueprint: | `StepCancellationObservation.swift` | WorkshopExecutorLoop step cancellation and deadline observation; returned effects settle before continuation |

extension WorkshopExecutorLoop {
    /// Marker error the cancellation watcher throws when cancel() flipped
    /// execution.json to "cancelled" while a step was in flight.
    internal struct WorkshopExecutionCancelledDuringStep: Error {}

    /// A deadline-won step retains its joined outcome and maps to failure in dispatchStep.
    internal struct WorkshopStepTimedOut: Error {
        let seconds: TimeInterval
        let returned: WorkshopStepOutcome?
        let cause: String?
    }

    /// Identifies which child completed the step race. Observer cancellation
    /// caused by a parent/pass cancellation is not itself the step result: the
    /// operation may still return a successful side effect that must be
    /// committed before the claim is released.
    private enum StepRaceEvent<Value: Sendable>: Sendable {
        case operationSucceeded(Value)
        case operationFailed(any Error)
        case workshopExecutionCancelled
        case timedOut
        case observerCancelled
        case observerFailed(any Error)
    }

    /// Observe execution and canonical Desk cancellation without polling.
    /// Cancellation stops the child cooperatively, then waits for its actual
    /// outcome: a late successful effect must reach durable settlement.
    internal func raceWithCancellationWatch(
        execution: WorkshopExecutionRecord,
        _ op: @escaping @Sendable () async throws -> WorkshopStepOutcome
    ) async throws -> WorkshopStepOutcome {
        let executionRecordJSON = executionRecordPath(execution.id)
        let deadlineNanos = stepTimeoutNanos
        let store = SwiftNativeDeskStore(dataRoot: root)
        let changes = FileChangeEvents(paths: [executionRecordJSON, store.opsPath, store.basePath, store.archivePath])
        return try await withThrowingTaskGroup(of: StepRaceEvent<WorkshopStepOutcome>.self) { group in
            group.addTask {
                do {
                    return .operationSucceeded(try await op())
                } catch {
                    return .operationFailed(error)
                }
            }
            group.addTask {
                defer { changes.cancel() }
                do {
                    for await _ in changes.stream {
                        try Task.checkCancellation()
                        if try await self.deskCanceled(execution) { return .workshopExecutionCancelled }
                        if try await ExecutionRecordFile.read(at: executionRecordJSON).record?.status == "cancelled" {
                            return .workshopExecutionCancelled
                        }
                    }
                    return .observerCancelled
                } catch is CancellationError {
                    return .observerCancelled
                } catch {
                    return .observerFailed(error)
                }
            }
            // The deadline cancels the effect and selects failure, then joins
            // the operation. Its returned outcome is settlement evidence, not
            // permission to admit another step. Zero disables the deadline;
            // no deadline promises a bound on noncooperative settlement.
            if deadlineNanos > 0 {
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanos)
                        return .timedOut
                    } catch is CancellationError {
                        return .observerCancelled
                    }
                }
            }
            var executionWasCanceled = false
            var timedOut = false
            while let event = try await group.next() {
                switch event {
                case .operationSucceeded(let value):
                    group.cancelAll()
                    if timedOut {
                        throw WorkshopStepTimedOut(seconds: Double(deadlineNanos) / 1_000_000_000,
                            returned: value, cause: nil)
                    }
                    return value
                case .operationFailed(let error):
                    group.cancelAll()
                    if timedOut {
                        throw WorkshopStepTimedOut(seconds: Double(deadlineNanos) / 1_000_000_000,
                            returned: nil, cause: String(describing: error))
                    }
                    throw error
                case .workshopExecutionCancelled:
                    executionWasCanceled = true
                    group.cancelAll()
                    continue
                case .timedOut:
                    if executionWasCanceled { continue }
                    timedOut = true
                    group.cancelAll()
                    continue
                case .observerCancelled:
                    // Parent/pass cancellation also cancels the observer
                    // children. Keep waiting for the operation: a cooperative
                    // child reports CancellationError, while an operation that
                    // already completed its side effect can still return the
                    // success that must cross the durable boundary.
                    if Task.isCancelled || executionWasCanceled || timedOut { continue }
                    group.cancelAll()
                    throw CancellationError()
                case .observerFailed(let error):
                    if timedOut || executionWasCanceled { continue }
                    group.cancelAll()
                    throw error
                }
            }
            throw WorkshopExecutionError.underlying("empty task group")
        }
    }
}
