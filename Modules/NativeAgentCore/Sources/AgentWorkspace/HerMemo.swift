import Foundation
import PersistenceCore
import ChatSessionWork
import NativeAgentCore
import ApprovalInbox
import MemoryV2
import NotificationInbox
import Desk
import StandingBots
import WorkshopExecution
import SwarmRuns
import NativeAgentShared
// Blueprint: | `HerMemo.swift` | `HerMemo` singleton retained workspace reads; file and owner lifecycle invalidations track revisions, publish completion and rebind child watches; observations share the 30-minute/128-key window, including keys without values; shutdown closes admission and cancels passive resources; serialized seen-file access, turn-pinned glances and repeated-home retention |

/// Retained world parts by input stamp; older reads never replace newer stored values.
package final class HerMemo: @unchecked Sendable {
    package static let shared = HerMemo()
    private let lock = NSLock()
    private var store: [String: (stamp: [String], value: Any, generation: Int, used: Date, at: Date)] = [:]
    private var generation = 0
    private var observations: [String: (id: UUID, revision: Int, used: Date, task: Task<Void, Never>)] = [:]
    private var stopped = false
    private var glances: [String: String?] = [:]
    private var glanceOrder: [String] = []

    /// Only the recent working window is retained, including transcript and send keys.
    private func prune(_ now: Date) {
        let keys = Set(store.keys).union(observations.keys)
        let recent = keys.map { key in
            (key: key, used: max(store[key]?.used ?? .distantPast, observations[key]?.used ?? .distantPast))
        }.filter { now.timeIntervalSince($0.used) <= 1800 }.sorted { $0.used > $1.used }
        let retained = Set(recent.prefix(128).map(\.key))
        for key in keys.subtracting(retained) {
            store.removeValue(forKey: key)
            observations.removeValue(forKey: key)?.task.cancel()
        }
    }

    /// Terminal engine retirement closes admission before cancelling readers.
    package func shutdown() {
        lock.withLock {
            stopped = true
            let tasks = observations.values.map(\.task)
            observations.removeAll()
            store.removeAll()
            tasks.forEach { $0.cancel() }
        }
    }

    private func keep(_ key: String, stamp: [String], value: Any) {
        guard !stopped else { return }
        generation += 1
        let now = Date()
        store[key] = (stamp, value, generation, now, now)
        prune(now)
    }

    func value<T>(_ key: String, stamp: [String], compute: () async -> T) async -> T {
        let (hit, generation): (T?, Int) = lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            observations[key]?.used = now
            return (store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil }, store[key]?.generation ?? 0)
        }
        if let hit { return hit }
        let value = await compute()
        lock.withLock {
            if (store[key]?.generation ?? 0) == generation { keep(key, stamp: stamp, value: value) }
        }
        return value
    }

    /// `value`, for a synchronous compute.
    func cached<T>(_ key: String, stamp: [String], compute: () throws -> T) rethrows -> T {
        let hit: T? = lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            observations[key]?.used = now
            return store[key].flatMap { $0.stamp == stamp ? $0.value as? T : nil }
        }
        if let hit { return hit }
        let value = try compute()
        lock.withLock { keep(key, stamp: stamp, value: value) }
        return value
    }

    /// Whatever is kept, and whether its stamp is still current.
    func peek<T>(_ key: String, stamp: [String]? = nil) -> (value: T, current: Bool, at: Date)? {
        lock.withLock {
            let now = Date()
            prune(now)
            store[key]?.used = now
            observations[key]?.used = now
            let current = stamp ?? [String(observations[key]?.revision ?? 0)]
            return store[key].flatMap { entry in (entry.value as? T).map { ($0, entry.stamp == current, entry.at) } }
        }
    }

    func put(_ key: String, _ value: Any, stamp: [String] = []) {
        lock.withLock { keep(key, stamp: stamp, value: value) }
    }

    /// Owner events invalidate before reading; completions publish the retained picture.
    func observe<T>(_ key: String, paths: @escaping @Sendable () -> [URL], notifications: [Notification.Name],
                    compute: @escaping @Sendable () async -> T?) {
        let ports = AgentWorkspacePorts.current
        lock.withLock {
            prune(Date())
            store[key]?.used = Date()
            observations[key]?.used = Date()
            guard !stopped else { return }
            guard observations[key] == nil else { return }
            let id = UUID()
            let task = Task.detached(priority: .utility) { [self] in
                guard !Task.isCancelled else { return }
                let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let invalidate: @Sendable () -> Void = { [self] in
                    let current = lock.withLock {
                        guard observations[key]?.id == id else { return false }
                        observations[key]?.revision += 1
                        return true
                    }
                    if current { events.continuation.yield(()) }
                }
                let notifications = ObservationNotifications(names: notifications, invalidate: invalidate)
                defer { notifications.cancel(); events.continuation.finish() }
                await withTaskCancellationHandler {
                    while !Task.isCancelled {
                        let watched = paths()
                        let watcher = FileChangeWatcher(paths: watched) { _ in invalidate() }
                        invalidate()
                        await withTaskCancellationHandler {
                            for await _ in events.stream {
                                guard !Task.isCancelled else { break }
                                guard paths() == watched else { break }
                                let revision = lock.withLock { observations[key]?.revision ?? 0 }
                                let value = await AgentWorkspacePorts.$binding.withValue(ports) { await compute() }
                                if let value, !Task.isCancelled {
                                    lock.withLock {
                                        if observations[key]?.id == id { keep(key, stamp: [String(revision)], value: value) }
                                    }
                                }
                                if lock.withLock({ !stopped && observations[key]?.id == id }), !Task.isCancelled {
                                    NotificationCenter.default.post(name: AgentWorkspaceScreenPreview.didChange, object: nil)
                                }
                            }
                        } onCancel: { watcher.cancel() }
                        watcher.cancel()
                    }
                } onCancel: {
                    notifications.cancel()
                    events.continuation.finish()
                }
            }
            observations[key] = (id, 0, Date(), task)
        }
    }

    /// The glance a turn already rendered, so every iteration of it is the same bytes.
    func glance(_ key: String) -> String?? { lock.withLock { glances[key] } }
    func keepGlance(_ key: String, _ text: String?) {
        lock.withLock {
            if glances.updateValue(text, forKey: key) == nil { glanceOrder.append(key) }
            if glanceOrder.count > 32 { glances.removeValue(forKey: glanceOrder.removeFirst()) }
        }
    }

    /// Read-merge-write of last_seen.json, one at a time.
    let seenLock = NSLock()

    /// The last full home each workspace was shown (its rows, ages blanked) and
    /// when. The time it was shown whole when these rows match it within
    /// `within` seconds; otherwise these become the kept ones and nil.
    private var homes: [String: (rows: String, at: Double)] = [:]
    func shownHome(_ key: String, rows: String, now: Double, within: Double) -> Double? {
        lock.withLock {
            if let last = homes[key], last.rows == rows, now - last.at < within { return last.at }
            if homes.count > 64 { homes = [:] }
            homes[key] = (rows, now)
            return nil
        }
    }
}
