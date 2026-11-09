import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationRunning.swift` | `AgentConversationRunning`, `begin`, `end` |

/// A desktop reply watch exists only while its owning process runs, so restart cannot leave a thread waiting on nothing.
public enum AgentConversationWatches {
    public static func begin(row: String, operation: String) { AgentConversationRunning.shared.beginWatch(row + ":" + operation) }
    public static func end(row: String, operation: String) { AgentConversationRunning.shared.endWatch(row + ":" + operation) }
    /// Settlement retains the reader until its owner exits.
    public static func retain(_ id: UUID, row: String, operation: String, task: Task<Void, Never>) {
        AgentConversationRunning.shared.retainWatch(id, row: row, operation: operation, task: task)
    }
    public static func finish(_ id: UUID) { AgentConversationRunning.shared.finishWatch(id) }
    public static func start() { AgentConversationRunning.shared.openWatches() }
    public static func stop() async { await AgentConversationRunning.shared.shutdownWatches() }
}

/// In-flight ownership is process-local; durable records remain the state every surface reads.
final class AgentConversationRunning: @unchecked Sendable {
    static let shared = AgentConversationRunning()
    private let lock = NSLock()
    private struct SendKey: Hashable {
        let row: String
        let operation: String
    }
    private struct Send {
        var stop: @Sendable () -> Void
        var stopped = false
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }
    // A ready row can begin its next send before the previous settlement exits. Each operation keeps its Stop waiters until its own matching end.
    private var sends: [SendKey: Send] = [:]
    private var conclusions: [String: Task<Void, Never>] = [:]
    private struct Sender {
        var task: Task<Void, Never>?
    }
    private var senders: [String: Sender] = [:]
    private var routeWatches: Set<String> = []
    private var retainedWatches: [UUID: (row: String, operation: String, task: Task<Void, Never>)] = [:]
    private var closed = false
    private var watches: [String: Int] = [:]
    private var generation = 0
    private var changeWaiter = ScopedWaiter()

    private init() {}
    func openWatches() { lock.withLock { closed = false } }

    func retainWatch(_ id: UUID, row: String, operation: String, task: Task<Void, Never>) {
        let admitted = lock.withLock {
            retainedWatches[id] = (row, operation, task)
            return !closed && sends[SendKey(row: row, operation: operation)]?.stopped != true
        }
        if !admitted { task.cancel() }
    }

    func finishWatch(_ id: UUID) { lock.withLock { _ = retainedWatches.removeValue(forKey: id) }; changed() }

    func observing(row: String, operation: String) -> Bool {
        lock.withLock { retainedWatches.values.contains { $0.row == row && $0.operation == operation } }
    }

    /// Explicit retirement joins every retained watch for this operation.
    func retireWatches(row: String, operation: String) async -> Bool {
        let tasks = lock.withLock {
            retainedWatches.values.filter { $0.row == row && $0.operation == operation }.map(\.task)
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        return !tasks.isEmpty
    }

    func shutdownWatches() async {
        let tasks = lock.withLock {
            closed = true // Close admission before retiring resources.
            return retainedWatches.values.map(\.task)
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    func begin(row: String, operation: String, stop: @escaping @Sendable () -> Void) {
        let key = SendKey(row: row, operation: operation)
        let stopped = lock.withLock {
            sends[key, default: Send(stop: stop)].stop = stop
            return sends[key]?.stopped == true
        }
        if stopped { stop() }
    }

    func end(row: String, operation: String) {
        let waiters = lock.withLock {
            sends.removeValue(forKey: SendKey(row: row, operation: operation))?.waiters ?? []
        }
        waiters.forEach { $0.resume(returning: true) }
        changed()
    }

    /// Accepted sends retain settlement through actual exit, including after Stop.
    func conclude(row: String, operation: String, work: @escaping @Sendable () async -> Void) {
        let key = row + ":" + operation
        lock.withLock {
            guard conclusions[key] == nil else { return }
            conclusions[key] = Task {
                defer { self.lock.withLock { _ = self.conclusions.removeValue(forKey: key) } }
                await work()
            }
        }
    }

    func live(row: String, operation: String) -> Bool {
        lock.withLock { sends[SendKey(row: row, operation: operation)] != nil }
    }

    func stop(row: String, operation: String) async -> Bool {
        await withCheckedContinuation { cancel(row: row, operation: operation, waiter: $0) }
    }

    func stopped(row: String, operation: String) -> Bool {
        lock.withLock { sends[SendKey(row: row, operation: operation)]?.stopped == true }
    }

    func cancel(row: String, operation: String, waiter: CheckedContinuation<Bool, Never>? = nil) {
        let key = SendKey(row: row, operation: operation)
        let stop = lock.withLock { () -> (@Sendable () -> Void)? in
            guard sends[key] != nil else { return nil }
            sends[key]?.stopped = true
            if let waiter { sends[key]?.waiters.append(waiter) }
            return sends[key]?.stop
        }
        if let stop { stop() } else { waiter?.resume(returning: false) }
    }

    func beginWatch(_ key: String) { lock.withLock { _ = routeWatches.insert(key) } }
    func endWatch(_ key: String) { lock.withLock { _ = routeWatches.remove(key) }; changed() }
    func routeWatching(row: String, operation: String) -> Bool { lock.withLock { routeWatches.contains(row + ":" + operation) } || observing(row: row,
        operation: operation) }

    /// One sender per queued message, for this process's lifetime.
    func adopt(_ item: String) -> Bool {
        lock.withLock {
            guard senders[item] == nil else { return false }
            senders[item] = Sender()
            return true
        }
    }
    func launch(_ item: String, work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            guard senders[item] != nil, senders[item]?.task == nil else { return }
            senders[item]?.task = Task { await work() }
        }
    }
    func release(_ item: String) { lock.withLock { _ = senders.removeValue(forKey: item) } }
    func waiting(_ item: String) -> Bool { lock.withLock { senders[item] != nil } }

    func watch(_ row: String) { lock.withLock { watches[row, default: 0] += 1 } }
    func unwatch(_ row: String) {
        lock.withLock {
            guard let count = watches[row] else { return }
            watches[row] = count > 1 ? count - 1 : nil
        }
        changed() // wakes whoever waits for the watch to end
    }
    func watched(_ row: String) -> Bool { lock.withLock { watches[row] != nil } }

    // MARK: Store changes (every conversation-store write in this process)

    var seen: Int { lock.withLock { generation } }

    func changed() {
        let woken = lock.withLock {
            generation &+= 1
            defer { changeWaiter = ScopedWaiter() }
            return changeWaiter
        }
        woken.resume()
    }

    func change(after seen: Int, until deadline: Date? = nil) async {
        guard let waiter = lock.withLock({ generation == seen ? changeWaiter : nil }) else { return }
        guard let deadline else { await waiter.park(); return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await waiter.park() }
            group.addTask {
                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                catch { return } // Cancellation withdraws this explicitly requested wait.
            }
            await group.next()
            group.cancelAll()
        }
    }
}
