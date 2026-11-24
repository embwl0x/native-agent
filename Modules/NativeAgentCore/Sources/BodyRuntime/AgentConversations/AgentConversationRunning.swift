import Foundation
import Synchronization
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationRunning.swift` | `AgentConversationRunning`, `begin`, `end` |

/// A desktop reply watch exists only while its owning process runs, so restart cannot leave a thread waiting on nothing.
public enum AgentConversationWatches {
    public static func begin(row: String, operation: String) { AgentConversationRunning.shared.beginWatch(row + ":" + operation) }
    public static func end(row: String, operation: String) { AgentConversationRunning.shared.endWatch(row + ":" + operation) }
}

/// In-flight ownership is process-local; durable records remain the state every surface reads.
final class AgentConversationRunning: Sendable {
    static let shared = AgentConversationRunning()
    private struct SendKey: Hashable {
        let row: String
        let operation: String
    }
    private struct Send {
        var stop: @Sendable () -> Void
        var stopped = false
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }
    private struct Sender {
        var task: Task<Void, Never>?
    }
    private struct State {
        var sends: [SendKey: Send] = [:]
        var conclusions: [String: Task<Void, Never>] = [:]
        var senders: [String: Sender] = [:]
        var routeWatches: Set<String> = []
        var watches: [String: Int] = [:]
        var generation = 0
        var changeWaiter = ScopedWaiter()
    }
    private let state = Mutex(State())

    private init() {}

    func begin(row: String, operation: String, stop: @escaping @Sendable () -> Void) {
        let key = SendKey(row: row, operation: operation)
        let stopped = state.withLock { state in
            state.sends[key, default: Send(stop: stop)].stop = stop
            return state.sends[key]?.stopped == true
        }
        if stopped { stop() }
    }

    func end(row: String, operation: String) {
        let waiters = state.withLock { state in
            state.sends.removeValue(forKey: SendKey(row: row, operation: operation))?.waiters ?? []
        }
        waiters.forEach { $0.resume(returning: true) }
        changed()
    }

    /// Accepted sends retain settlement through actual exit, including after Stop.
    func conclude(row: String, operation: String, work: @escaping @Sendable () async -> Void) {
        let key = row + ":" + operation
        state.withLock { state in
            guard state.conclusions[key] == nil else { return }
            state.conclusions[key] = Task {
                defer { self.state.withLock { _ = $0.conclusions.removeValue(forKey: key) } }
                await work()
            }
        }
    }

    func live(row: String, operation: String) -> Bool {
        state.withLock { $0.sends[SendKey(row: row, operation: operation)] != nil }
    }

    func stop(row: String, operation: String) async -> Bool {
        await withCheckedContinuation { cancel(row: row, operation: operation, waiter: $0) }
    }

    func stopped(row: String, operation: String) -> Bool {
        state.withLock { $0.sends[SendKey(row: row, operation: operation)]?.stopped == true }
    }

    func cancel(row: String, operation: String, waiter: CheckedContinuation<Bool, Never>? = nil) {
        let key = SendKey(row: row, operation: operation)
        let stop = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.sends[key] != nil else { return nil }
            state.sends[key]?.stopped = true
            if let waiter { state.sends[key]?.waiters.append(waiter) }
            return state.sends[key]?.stop
        }
        if let stop { stop() } else { waiter?.resume(returning: false) }
    }

    func beginWatch(_ key: String) { state.withLock { _ = $0.routeWatches.insert(key) } }
    func endWatch(_ key: String) { state.withLock { _ = $0.routeWatches.remove(key) }; changed() }
    func routeWatching(row: String, operation: String) -> Bool {
        state.withLock { $0.routeWatches.contains(row + ":" + operation) }
    }

    /// One sender per queued message, for this process's lifetime.
    func adopt(_ item: String) -> Bool {
        state.withLock { state in
            guard state.senders[item] == nil else { return false }
            state.senders[item] = Sender()
            return true
        }
    }
    func launch(_ item: String, work: @escaping @Sendable () async -> Void) {
        state.withLock { state in
            guard state.senders[item] != nil, state.senders[item]?.task == nil else { return }
            state.senders[item]?.task = Task { await work() }
        }
    }
    func release(_ item: String) { state.withLock { _ = $0.senders.removeValue(forKey: item) } }
    func waiting(_ item: String) -> Bool { state.withLock { $0.senders[item] != nil } }

    func watch(_ row: String) { state.withLock { $0.watches[row, default: 0] += 1 } }
    func unwatch(_ row: String) {
        state.withLock { state in
            guard let count = state.watches[row] else { return }
            state.watches[row] = count > 1 ? count - 1 : nil
        }
        changed() // wakes whoever waits for the watch to end
    }
    func watched(_ row: String) -> Bool { state.withLock { $0.watches[row] != nil } }

    // MARK: Store changes (every conversation-store write in this process)

    var seen: Int { state.withLock { $0.generation } }

    func changed() {
        let woken = state.withLock { state in
            state.generation &+= 1
            defer { state.changeWaiter = ScopedWaiter() }
            return state.changeWaiter
        }
        woken.resume()
    }

    func change(after seen: Int, until deadline: Date? = nil) async {
        guard let waiter = state.withLock({ $0.generation == seen ? $0.changeWaiter : nil }) else { return }
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
