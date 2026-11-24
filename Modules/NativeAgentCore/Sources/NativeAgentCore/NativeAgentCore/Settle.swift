import Foundation
import Synchronization
import NativeAgentShared
// Blueprint: | `Settle.swift` | `settle`, `WorkDrain`: the Stop law's settlement primitive and lock-held joinable task drain (docs/STOP.md) |

/// The Stop law (docs/STOP.md): Stop cancels the work, never its settlement. Work in flight has two parts. Its effect (send, write, run a process, wait for a
/// reply) is what Stop cancels. Its settlement (save what was produced, write the one terminal record, release what the work held, say what landed) always runs
/// to completion, exactly once, after the effect ends however it ended. `settle` runs that settlement outside the caller's cancellation: a cancelled caller
/// still waits for it to finish. Task-local values (turn trace, chat session) do not carry into the settlement; capture what it needs before calling.
public func settle<T: Sendable>(_ settlement: @escaping @Sendable () async -> T) async -> T {
    await Task.detached(priority: .userInitiated) { await settlement() }.value
}

public struct SettlementTicket: ~Copyable, Sendable {
    private let label: StaticString
    private let file: StaticString
    private let line: UInt
    public init(_ label: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        self.label = label; self.file = file; self.line = line
    }
    public consuming func settle<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) async -> Value {
        discard self
        return await NativeAgentCore.settle(body)
    }
    deinit {
        let message = "Dropped unsettled ticket: \(label) at \(file):\(line)"
        ModuleLog.app("[stop-law] %@", message)
        assertionFailure(message)
    }
}

private final class SettlementBox<Resource: ~Copyable & Sendable>: Sendable {
    let slot: Mutex<Resource?>
    init(_ resource: consuming Resource) { slot = Mutex(.some(consume resource)) }
}

public func withSettledScope<Resource: ~Copyable & Sendable, Value, Disposition: Sendable, Receipt: Sendable, Failure: Error>(
    _ resource: consuming Resource, isolation: isolated (any Actor)? = #isolation,
    work: (borrowing Resource) async throws(Failure) -> Value,
    disposition: (Value?) -> Disposition,
    release: @escaping @Sendable (consuming Resource, Disposition) async -> Receipt,
    observed: (Receipt) -> Void
) async throws(Failure) -> (value: Value, receipt: Receipt) {
    let outcome: Result<Value, Failure>
    do { outcome = .success(try await work(resource)) }
    catch { outcome = .failure(error) }
    let decision: Disposition
    switch outcome {
    case .success(let value): decision = disposition(.some(value))
    case .failure: decision = disposition(nil)
    }
    let box = SettlementBox(consume resource)
    let receipt = await settle { await release(box.slot.withLock { $0.take() }!, decision) }
    observed(receipt)
    return (try outcome.get(), receipt)
}

public final class WorkDrain: Sendable {
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    public init() {}

    @discardableResult
    public func launch(priority: TaskPriority? = nil,
                       _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        return tasks.withLock { tasks in
            let task = Task.detached(priority: priority) {
                await body()
                self.tasks.withLock { _ = $0.removeValue(forKey: id) }
            }
            tasks[id] = task
            return task
        }
    }

    public func drain() async {
        while true {
            let pending = tasks.withLock { Array($0.values) }
            guard !pending.isEmpty else { return }
            for task in pending { await task.value }
        }
    }
}
