import AgentWorkspace
import Foundation
import PersistenceCore

/// The app's startup pass over queued follow-ups left without a sender by a
/// restart (see `AgentConversationSession.resumeQueued`).
public enum AgentConversationQueues {
    public static func orphaned(dataRoot: URL) -> [AgentConversationRecord] {
        AgentConversationSession.orphanedQueues(dataRoot: dataRoot)
    }

    public static func resume(_ row: AgentConversationRecord, dataRoot: URL,
                              perform: @escaping @Sendable (String, [String: JSONValue]) async throws -> JSONValue) {
        AgentConversationSession.resumeQueued(row, dataRoot: dataRoot, perform: perform)
    }
}

/// A route that returned "waiting" and watches for the answer itself (Grok's
/// desktop chat): the exchange is in flight only while this process still
/// runs that watch, so a restart never leaves the thread waiting on nothing.
public enum AgentConversationWatches {
    public static func begin(row: String, operation: String) { AgentConversationRunning.shared.beginWatch(row + ":" + operation) }
    public static func end(row: String, operation: String) { AgentConversationRunning.shared.endWatch(row + ":" + operation) }
}

/// What this process is doing for a thread right now: the in-flight send it
/// can stop, and the queued follow-ups it has a sender waiting on. Memory
/// only; the record on disk stays the state every surface reads.
final class AgentConversationRunning: @unchecked Sendable {
    static let shared = AgentConversationRunning()
    private let lock = NSLock()
    private var sends: [String: (operation: String, stop: @Sendable () -> Void)] = [:]
    private var senders: Set<String> = []
    private var routeWatches: Set<String> = []
    private var watches: [String: Int] = [:]
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var abandoned: Set<UUID> = []

    func begin(row: String, operation: String, stop: @escaping @Sendable () -> Void) {
        lock.withLock { sends[row] = (operation, stop) }
    }

    func end(row: String, operation: String) {
        lock.withLock { if sends[row]?.operation == operation { sends[row] = nil } }
    }

    func live(row: String, operation: String) -> Bool {
        lock.withLock { sends[row]?.operation == operation }
    }

    /// Stops this process's own in-flight send for that exact operation.
    func stop(row: String, operation: String) -> Bool {
        guard let stop = lock.withLock({ sends[row]?.operation == operation ? sends[row]?.stop : nil }) else { return false }
        stop()
        return true
    }

    func beginWatch(_ key: String) { lock.withLock { _ = routeWatches.insert(key) } }
    func endWatch(_ key: String) { lock.withLock { _ = routeWatches.remove(key) }; changed() }
    func routeWatching(row: String, operation: String) -> Bool { lock.withLock { routeWatches.contains(row + ":" + operation) } }

    /// One sender per queued message, for this process's lifetime.
    func adopt(_ item: String) -> Bool { lock.withLock { senders.insert(item).inserted } }
    func release(_ item: String) { lock.withLock { _ = senders.remove(item) } }
    func waiting(_ item: String) -> Bool { lock.withLock { senders.contains(item) } }

    /// A `wait` is watching this thread for its reply right now.
    func watch(_ row: String) { lock.withLock { watches[row, default: 0] += 1 } }
    func unwatch(_ row: String) {
        lock.withLock { watches[row] = (watches[row] ?? 1) > 1 ? watches[row]! - 1 : nil }
        changed() // wakes whoever waits for the watch to end
    }
    func watched(_ row: String) -> Bool { lock.withLock { watches[row] != nil } }

    // MARK: Store changes (every conversation-store write in this process)

    var seen: Int { lock.withLock { generation } }

    func changed() {
        let woken: [CheckedContinuation<Void, Never>] = lock.withLock {
            generation += 1
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        woken.forEach { $0.resume() }
    }

    /// Returns at the first store write after `seen`, or at `deadline`.
    func change(after seen: Int, until deadline: Date) async {
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        let now: Bool = self.lock.withLock {
                            if self.generation != seen || self.abandoned.remove(id) != nil { return true }
                            self.waiters[id] = continuation
                            return false
                        }
                        if now { continuation.resume() }
                    }
                } onCancel: {
                    let waiting: CheckedContinuation<Void, Never>? = self.lock.withLock {
                        if let continuation = self.waiters.removeValue(forKey: id) { return continuation }
                        self.abandoned.insert(id)
                        return nil
                    }
                    waiting?.resume()
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            await group.next()
            group.cancelAll()
        }
        lock.withLock { _ = abandoned.remove(id) }
    }
}
