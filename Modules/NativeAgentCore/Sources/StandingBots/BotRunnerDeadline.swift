import Foundation

/// A terminal gate returns at the deadline even if a fake/provider ignores
/// cancellation. The child has no store references and late values are dropped.
enum BotRunnerDeadline {
    /// Storage cannot be preempted safely. Cancel at the absolute budget but
    /// retain ownership until the terminal receipt settles. Provider candidates
    /// still use run(), so non-cooperative network work cannot hold this open.
    static func settled<T: Sendable>(seconds: TimeInterval, body: @escaping @Sendable () async throws -> T) async throws -> T {
        let child = Task { try await body() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(max(0, seconds))) }
            catch { return }
            child.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
    }

    static func run<T: Sendable>(seconds: TimeInterval, body: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = BotRunnerTerminal<T>()
        let child = Task {
            do { gate.finish(.success(try await body())) }
            catch { gate.finish(.failure(error)) }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(min(seconds, Double(Int64.max / 2)))) }
            catch { return }
            gate.finish(.failure(BotRunnerError.budgetStop))
            child.cancel()
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.install($0) }
        } onCancel: {
            child.cancel()
            gate.finish(.failure(CancellationError()))
        }
        child.cancel()
        deadline.cancel()
        return try result.get()
    }
}

private final class BotRunnerTerminal<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>, Never>?
    func install(_ continuation: CheckedContinuation<Result<T, Error>, Never>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(returning: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: result)
    }
}
