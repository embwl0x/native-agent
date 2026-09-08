import Foundation

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

    return await withTaskGroup(of: DetachedCloudKitTimeoutOutcome<T>.self) { group in
        group.addTask {
            guard let result = await state.wait() else {
                return .cancelled
            }
            switch result {
            case .success(let value):
                return .success(value)
            case .failure(let error):
                return .failure(String(describing: error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            } catch {
                return .cancelled
            }
        }

        let first = await group.next()
        group.cancelAll()
        workTask.cancel()
        await state.cancelWaiter()
        return first ?? .cancelled
    }
}
