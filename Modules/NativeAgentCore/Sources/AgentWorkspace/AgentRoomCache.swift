import AppKit
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import ChatSessionWork
import Transcripts
import ChatToolParsing
import Darwin
// Blueprint: | `AgentRoomCache.swift` | Session-scoped room bindings with bounded lasting item names and current-draw verbs |
// Expire bindings with their session and retain only the latest 512 lasting item bindings per room.

/// Stable item numbers retain their targets; verbs come only from the current draw. Scope contextual verbs and window positions to their conversation.
final class AgentRoomCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [String: (at: Date, values: [String: Value], order: [String], dropped: [String])] = [:]
    private let entryLimit = 512
    private let lasting: Bool

    init(lasting: Bool = false) { self.lasting = lasting }

    private func prune(_ now: Date) {
        if !lasting { rooms = rooms.filter { now.timeIntervalSince($0.value.at) <= 1800 } }
        while rooms.count > 128, let oldest = rooms.min(by: { $0.value.at < $1.value.at }) {
            rooms.removeValue(forKey: oldest.key)
        }
    }

    func keep(_ root: URL, _ values: [String: Value], room: String? = nil, scope: String? = nil) {
        lock.withLock {
            let prefix = root.standardizedFileURL.path + "\u{0}"
            let bound = Dictionary(uniqueKeysWithValues: values.map { name, value in
                (scope.map { $0 + "\u{0}" + name } ?? name, value)
            })
            let groups = room.map { [$0: bound] } ?? Dictionary(grouping: bound.keys, by: { String($0.split(separator: ".").first ?? "") })
                .mapValues { keys in bound.filter { keys.contains($0.key) } }
            let now = Date()
            for (name, entries) in groups {
                let old = lasting ? rooms[prefix + name] : nil
                let items = (old?.values ?? [:]).filter { scope == nil && Self.isItem($0.key) }
                let merged = items.merging(entries) { _, new in new }
                let order = Array(((old?.order ?? []).filter { merged[$0] != nil && entries[$0] == nil }
                    + entries.keys.sorted()).suffix(entryLimit))
                let retained = Set(order)
                let removed = Set((old?.values ?? [:]).keys.filter { !Self.isItem($0) && entries[$0] == nil })
                let dropped = Array(((old?.dropped ?? []).filter { entries[$0] == nil && !removed.contains($0) }
                    + removed.sorted()).suffix(entryLimit))
                rooms[prefix + name] = (now, merged.filter { retained.contains($0.key) }, order, dropped)
            }
            prune(now)
        }
    }

    func value(_ root: URL, _ name: String) -> Value? {
        lock.withLock {
            prune(Date())
            let prefix = root.standardizedFileURL.path + "\u{0}"
            return rooms.filter { $0.key.hasPrefix(prefix) && $0.value.values[name] != nil }
                .max(by: { $0.value.at < $1.value.at })?.value.values[name]
        }
    }

    /// Withdraw verbs omitted by a room's redraw.
    func withdrawn(_ root: URL, _ name: String) -> Bool {
        lock.withLock {
            prune(Date())
            let prefix = root.standardizedFileURL.path + "\u{0}"
            return rooms.contains { $0.key.hasPrefix(prefix) && $0.value.dropped.contains(name) }
        }
    }

    /// An item name ends in a number; a verb ends in a word, keeping the namespaces distinct.
    private static func isItem(_ name: String) -> Bool { name.split(separator: ".").last.map { Int($0) != nil } ?? false }

    func removeSession(_ key: String) {
        lock.withLock { rooms = rooms.filter { !$0.key.hasPrefix(key + "\u{0}") } }
    }
}
