// iOS minimal port of the Mac-side CKLandmine helper. Same surface as the
// non-throwing withCKTimeout: race a work closure against a wall-clock
// timeout so a wedged cloudd / KVS subsystem can't block a caller forever.
// See Sources/NativeAgentApp/Diagnostics/CKLandmine.swift for the full
// (throwing variant + CloudKitHealth) Mac implementation.
import Foundation

private enum CKTimeoutRace<T: Sendable>: Sendable {
    case success(T)
    case failure(String)
    case timedOut
    case cancelled
}

private actor CKTimeoutState<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>?, Never>?

    func wait() async -> Result<T, Error>? {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancelWaiter() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

func withCKTimeout<T: Sendable>(
    _ label: String,
    seconds: TimeInterval = 5,
    _ work: @Sendable @escaping () async throws -> T
) async -> T? {
    let state = CKTimeoutState<T>()
    let timeoutNanoseconds = UInt64(max(0, seconds) * 1_000_000_000)

    let workTask = Task.detached(priority: .utility) {
        do {
            await state.finish(.success(try await work()))
        } catch {
            await state.finish(.failure(error))
        }
    }

    return await withTaskGroup(of: CKTimeoutRace<T>.self, returning: T?.self) { group in
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

        guard let first = await group.next() else {
            group.cancelAll()
            workTask.cancel()
            await state.cancelWaiter()
            return nil
        }

        group.cancelAll()
        workTask.cancel()
        await state.cancelWaiter()

        switch first {
        case .success(let value):
            return value
        case .failure(let error):
            NSLog("[ck-landmine] \(label) failed: \(error)")
            return nil
        case .timedOut:
            NSLog("[ck-landmine] \(label) timed out after \(Int(seconds))s; cloudd unhealthy?")
            return nil
        case .cancelled:
            return nil
        }
    }
}
