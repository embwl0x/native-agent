import Foundation
import NativeAgentShared

/// Small value owners used by the bridge itself.  They deliberately keep the
/// difficult boundaries (transport writes, restart generations, and persisted
/// defaults) observable without making a test talk to iCloud or a live app.
enum ICloudBridgeStatusPublication {
    /// Returns the cache value that is safe to retain.  A failed transport write
    /// must leave the prior value intact so the next identical projection retries.
    static func publish(
        key: String,
        value: String,
        lastPublished: String?,
        transport: DeviceSyncTransport
    ) async -> (succeeded: Bool, retainedValue: String?) {
        guard value != lastPublished else { return (true, lastPublished) }
        do {
            try await transport.setStatus(key: key, value: value)
            return (true, value)
        } catch {
            return (false, lastPublished)
        }
    }
}

enum ICloudSeenIDDefaultsStore {
    static func load(defaults: UserDefaults, key: String, cap: Int) -> [String] {
        guard let stored = defaults.array(forKey: key) as? [String] else { return [] }
        let normalized = cappedUnique(stored, cap: cap)
        // This is the same durable replay filter the bridge restores into
        // memory. Heal duplicate or oversized legacy bytes now so a restart
        // cannot see a different filter from the currently running bridge.
        if normalized != stored {
            defaults.set(normalized, forKey: key)
        }
        return normalized
    }

    static func save(_ ids: [String], defaults: UserDefaults, key: String, cap: Int) {
        defaults.set(cappedUnique(ids, cap: cap), forKey: key)
    }

    private static func cappedUnique(_ ids: [String], cap: Int) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        return Array(unique.suffix(max(0, cap)))
    }
}

enum ICloudIncomingMessageDisposition: Equatable, Sendable {
    case deliver
    case permanentlyRejected(reason: String)

    static func classify(_ message: BridgeMessage, secret: Data, now: Date) -> ICloudIncomingMessageDisposition {
        guard message.sender == "ios" else {
            return .permanentlyRejected(reason: "sender_invalid")
        }
        guard message.signature != nil, message.verifySignature(secret: secret) else {
            return .permanentlyRejected(reason: "signature_invalid")
        }
        let age = now.timeIntervalSince(message.timestamp)
        guard age <= 24 * 60 * 60, age >= -15 * 60 else {
            return .permanentlyRejected(reason: "stale_timestamp")
        }
        return .deliver
    }
}

enum ICloudDeliveryNudgePlan {
    static let delaysNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
}

/// Shared KVS keyspace contract. The ubiquitous store hard-stops at 1,024
/// keys; leave deterministic room for pairing, snapshots, and inbox nudges so
/// a stream-progress overwrite never reports success from a full keyspace.
struct ICloudKVSKeyspaceSnapshot: Equatable, Sendable {
    let totalKeyCount: Int
    let inboxResponseKeyCount: Int
    let progressKeyExists: Bool
}

enum ICloudKVSProgressWriteAdmission: Equatable, Sendable {
    static let hardKeyQuota = 1_024
    static let reservedKeyHeadroom = 64
    static let totalKeyCeiling = hardKeyQuota - reservedKeyHeadroom
    static let inboxResponseKeyPrefix = "inbox_response_"
    static let inboxResponseKeyCeiling = 800

    case allowed(ICloudKVSKeyspaceSnapshot)
    case responseSweepOverCeiling(ICloudKVSKeyspaceSnapshot)
    case keyspaceAtHeadroomLimit(ICloudKVSKeyspaceSnapshot)

    static func assess(keys: Set<String>, progressKey: String) -> ICloudKVSProgressWriteAdmission {
        let snapshot = ICloudKVSKeyspaceSnapshot(
            totalKeyCount: keys.count,
            inboxResponseKeyCount: keys.filter { $0.hasPrefix(inboxResponseKeyPrefix) }.count,
            progressKeyExists: keys.contains(progressKey)
        )
        if snapshot.inboxResponseKeyCount > inboxResponseKeyCeiling {
            return .responseSweepOverCeiling(snapshot)
        }
        // An existing progress key is an overwrite, so it may use the final
        // safe slot. A new key must leave the headroom intact after insertion.
        if snapshot.totalKeyCount > totalKeyCeiling
            || (!snapshot.progressKeyExists && snapshot.totalKeyCount >= totalKeyCeiling) {
            return .keyspaceAtHeadroomLimit(snapshot)
        }
        return .allowed(snapshot)
    }

    var snapshot: ICloudKVSKeyspaceSnapshot {
        switch self {
        case .allowed(let snapshot), .responseSweepOverCeiling(let snapshot), .keyspaceAtHeadroomLimit(let snapshot):
            snapshot
        }
    }

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    var failureDescription: String? {
        switch self {
        case .allowed:
            nil
        case .responseSweepOverCeiling(let snapshot):
            "inbox response-key sweep is over its \(Self.inboxResponseKeyCeiling)-key ceiling (\(snapshot.inboxResponseKeyCount))"
        case .keyspaceAtHeadroomLimit(let snapshot):
            "keyspace is at its \(Self.totalKeyCeiling)-key headroom limit (\(snapshot.totalKeyCount))"
        }
    }
}

enum ICloudKVSProgressDeliveryResult: Equatable, Sendable {
    case synchronized
    case synchronizeFailed
    case blocked(ICloudKVSProgressWriteAdmission)
    case timedOut
}

struct MacSyncChatSnapshotCoalescerState: Equatable {
    private(set) var activeGeneration: UInt64?
    private(set) var needsTranscripts = false

    /// True only for the caller that must start the one deferred task.
    mutating func enqueue(includeTranscripts: Bool, generation: UInt64) -> Bool {
        needsTranscripts = needsTranscripts || includeTranscripts
        guard activeGeneration == nil else { return false }
        activeGeneration = generation
        return true
    }

    /// Finishes only the matching lifecycle.  A stale task cannot erase work
    /// queued by a newer lifecycle, while a matching stale generation clears its
    /// own latch rather than leaving every later request permanently upgraded.
    mutating func resolve(generation: UInt64, currentGeneration: UInt64, isActive: Bool) -> Bool? {
        guard activeGeneration == generation else { return nil }
        activeGeneration = nil
        defer { needsTranscripts = false }
        guard generation == currentGeneration, isActive else { return nil }
        return needsTranscripts
    }

    mutating func reset() {
        activeGeneration = nil
        needsTranscripts = false
    }
}

enum MacSyncArchiveRetentionWatchPaths {
    static func resolve(inboxDirectory: URL?, responsesDirectory: URL?, fileManager: FileManager = .default) -> [URL] {
        guard let inboxDirectory, let responsesDirectory else { return [] }
        let rejected = inboxDirectory.appendingPathComponent("_rejected", isDirectory: true)
        let paths = [inboxDirectory, responsesDirectory, rejected]
        for path in paths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { return [] }
                continue
            }
            do {
                try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            } catch {
                return []
            }
            guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                return []
            }
        }
        return paths
    }
}

enum MacSyncInboxResponseSweep {
    struct Entry: Equatable, Sendable {
        var key: String
        var modified: Date?
        var exists: Bool
    }

    struct Plan: Equatable, Sendable {
        var keysToRemove: [String]
        var retainedCount: Int
        var exceedsCap: Bool
    }

    /// Missing and expired responses are always safe to remove.  Under pressure,
    /// an unreadable/orphaned entry may be evicted, but a recent readable
    /// response is never sacrificed merely to reach a numerical cap.
    static func keysToRemove(entries: [Entry], now: Date, ttl: TimeInterval, cap: Int) -> [String] {
        var removed: [String] = []
        let survivors = entries.filter { entry in
            guard entry.exists else {
                removed.append(entry.key)
                return false
            }
            if let modified = entry.modified, now.timeIntervalSince(modified) > ttl {
                removed.append(entry.key)
                return false
            }
            return true
        }
        let overflow = max(0, survivors.count - cap)
        guard overflow > 0 else { return removed }
        let evictable = survivors.filter { $0.modified == nil }.sorted { $0.key < $1.key }
        removed.append(contentsOf: evictable.prefix(overflow).map(\.key))
        return removed
    }

    static func plan(entries: [Entry], now: Date, ttl: TimeInterval, cap: Int) -> Plan {
        let keysToRemove = keysToRemove(entries: entries, now: now, ttl: ttl, cap: cap)
        let removed = Set(keysToRemove)
        let retainedCount = entries.reduce(into: 0) { count, entry in
            if !removed.contains(entry.key) { count += 1 }
        }
        return Plan(
            keysToRemove: keysToRemove,
            retainedCount: retainedCount,
            exceedsCap: retainedCount > cap
        )
    }

    /// Apply the exact, already-audited eviction plan to any key-value store.
    /// Production supplies the KVS remover; hermetic evaluations supply a
    /// dictionary-backed fake without touching the user's iCloud account.
    static func apply(_ plan: Plan, remove: (String) -> Void) {
        for key in plan.keysToRemove {
            remove(key)
        }
    }
}
