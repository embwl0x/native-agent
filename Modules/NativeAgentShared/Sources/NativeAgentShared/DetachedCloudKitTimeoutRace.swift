import Foundation
// Blueprint: | `DetachedCloudKitTimeoutRace.swift` | `DetachedCloudKitTimeoutOutcome` enum |

public enum DetachedCloudKitTimeoutOutcome<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    case timedOut
    case cancelled
}

/// Diagnostic race whose detached work cannot hold the caller past the timeout.
public func detachedCloudKitTimeoutRace<T: Sendable>(
    timeoutNanoseconds: UInt64,
    _ work: @Sendable @escaping () async throws -> T
) async -> DetachedCloudKitTimeoutOutcome<T> {
    let state = CloudKitTimeoutResultLatch<T>()

    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    switch await state.race(workTask: workTask, timeoutNanoseconds: timeoutNanoseconds) {
    case .success(let value): return .success(value)
    case .failure(let error): return .failure(String(describing: error))
    case .timedOut: return .timedOut
    case .cancelled: return .cancelled
    }
}
