import Synchronization
import Foundation
import MindCore
import os
// Blueprint: | `LazyContextBox.swift` | A turn shares one prompt preparation between its part's reaches and its first model request |

public final class LazyContextBox: Sendable {
    struct Prepared: Sendable {
        let context: TurnContext
        var projection: (request: CognitiveCapsuleRequest, projection: CognitionAtTurn)?
    }

    private enum State: Sendable {
        case idle(@Sendable () async throws -> Prepared)
        case running(Task<Prepared, Error>)
        case opened(Result<Prepared, Error>)
    }

    let opening: TurnContext
    private let state: Mutex<State>

    init(opening: TurnContext, prepare: @escaping @Sendable () async throws -> Prepared) {
        self.opening = opening
        state = Mutex(.idle(prepare))
    }

    public init(prepared: TurnContext) {
        opening = prepared
        state = Mutex(.opened(.success(Prepared(context: prepared))))
    }

    var reading: Result<Prepared, Error>? {
        state.withLock { if case .opened(let result) = $0 { result } else { nil } }
    }

    var opened: Prepared? {
        if case .success(let prepared)? = reading { prepared } else { nil }
    }

    @discardableResult
    private func startReading() -> State {
        state.withLock { current in
            if case .idle(let prepare) = current { current = .running(Task { try await prepare() }) }
            return current
        }
    }

    func start() { startReading() }

    func ensurePrepared() async throws -> TurnContext {
        try Task.checkCancellation()
        switch startReading() {
        case .opened(let result): return try result.get().context
        case .running(let task):
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            state.withLock { $0 = .opened(result) }
            return try result.get().context
        case .idle:
            preconditionFailure("Context preparation must have started under its lock.")
        }
    }

    func finish() async {
        guard case .running(let task) = state.withLock({ $0 }) else { return }
        task.cancel()
        _ = await task.result
    }
}
