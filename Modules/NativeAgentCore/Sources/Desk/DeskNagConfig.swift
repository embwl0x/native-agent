import NativeAgentCore
import Foundation
import PersistenceCore
// Blueprint: | `DeskNagConfig.swift` | `DeskNagLane`, `DeskNagPanelModel`; canonical nag scope interpretation |

// MARK: - DeskNagConfig — User's nag switch, persisted (default OFF)
// Nagging is opt-in and scoped; disabled evaluation must not even write observations.
// Preferences live outside work history so replay cannot resurrect an old mute.
// Flocked atomic writes serialize the chat tool and background loop across processes.
// Each deliberate unmute or enable opens one attention window: at most one nag per item.
// Staleness alone cannot notify; muted evaluation freezes baselines so drift remains visible on unmute.

public enum DeskNagScopeKind: String, Sendable, CaseIterable, Equatable {
    case project, item
}

/// Item scope wins over project scope so one card can be muted inside an enabled project.
public struct DeskNagScope: Sendable, Equatable {
    public var kind: DeskNagScopeKind
    /// Resolve visible aliases before storage because handles carry identity.
    public var id: String
    public var enabled: Bool

    public init(kind: DeskNagScopeKind, id: String, enabled: Bool) {
        self.kind = kind
        self.id = id
        self.enabled = enabled
    }

    public func toJSON() -> JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "id": .string(id),
            "enabled": .bool(enabled),
        ])
    }

    /// Reject only the malformed scope row so one bad entry cannot silently disable the saved configuration.
    public static func fromJSON(_ value: JSONValue) -> DeskNagScope? {
        guard case .object(let obj) = value,
              case .string(let rawKind)? = obj["kind"],
              let kind = DeskNagScopeKind(rawValue: rawKind),
              case .string(let id)? = obj["id"],
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var enabled = true
        if let value = obj["enabled"] {
            guard case .bool(let b) = value else { return nil }
            enabled = b
        }
        return DeskNagScope(kind: kind, id: id, enabled: enabled)
    }
}

/// Retain only the scalars needed to recognize content, blocker and defer deltas between ticks.
public struct DeskNagObservation: Sendable, Equatable {
    public var updatedAt: String
    public var effectiveBlockerCount: Int
    /// Positive readiness makes a false-to-true transition mean the defer date elapsed.
    public var deferElapsed: Bool

    public init(updatedAt: String, effectiveBlockerCount: Int, deferElapsed: Bool) {
        self.updatedAt = updatedAt
        self.effectiveBlockerCount = effectiveBlockerCount
        self.deferElapsed = deferElapsed
    }

    public func toJSON() -> JSONValue {
        .object([
            "updatedAt": .string(updatedAt),
            "effectiveBlockerCount": .int(Int64(effectiveBlockerCount)),
            "deferElapsed": .bool(deferElapsed),
        ])
    }

    public static func fromJSON(_ value: JSONValue) -> DeskNagObservation? {
        guard case .object(let obj) = value,
              case .string(let updatedAt)? = obj["updatedAt"] else { return nil }
        var blockers = 0
        if let value = obj["effectiveBlockerCount"] {
            guard case .int(let i) = value else { return nil }
            blockers = Int(i)
        }
        var elapsed = true
        if let value = obj["deferElapsed"] {
            guard case .bool(let b) = value else { return nil }
            elapsed = b
        }
        return DeskNagObservation(updatedAt: updatedAt, effectiveBlockerCount: blockers, deferElapsed: elapsed)
    }
}

/// Diagnostics share the owner’s schema so unexpected writer fields cannot masquerade as preferences.
public enum DeskNagConfigSchema {
    public static let version = 1
    public static let rootKeys: Set<String> = [
        "version", "enabled", "scopes", "mutedUntil", "windowId", "ledger", "observed",
    ]
    public static let scopeKeys: Set<String> = ["kind", "id", "enabled"]
    public static let observationKeys: Set<String> = [
        "updatedAt", "effectiveBlockerCount", "deferElapsed",
    ]

    /// Validate every nested key and field type before decoding or replacing saved preferences.
    public static func unexpectedKeys(in value: JSONValue) -> [String] {
        guard case .object(let object) = value else { return [] }
        var unexpected = object.keys
            .filter { !rootKeys.contains($0) }
            .map { "root.\($0)" }

        if case .array(let scopes)? = object["scopes"] {
            for (index, scope) in scopes.enumerated() {
                guard case .object(let row) = scope else { continue }
                unexpected += row.keys
                    .filter { !scopeKeys.contains($0) }
                    .map { "scopes[\(index)].\($0)" }
            }
        }
        if case .object(let observed)? = object["observed"] {
            for (handle, observation) in observed {
                guard case .object(let row) = observation else { continue }
                unexpected += row.keys
                    .filter { !observationKeys.contains($0) }
                    .map { "observed.\(handle).\($0)" }
            }
        }
        return unexpected.sorted()
    }
}

public struct DeskNagConfig: Sendable, Equatable {
    /// Default off: nagging requires the person’s opt-in.
    public var enabled: Bool
    public var scopes: [DeskNagScope]
    public var mutedUntil: String?
    public var windowId: Int
    /// Digest mentions cannot consume the per-item nag budget for the current window.
    public var ledger: [String: Int]
    public var observed: [String: DeskNagObservation]

    /// One far-future sentinel represents indefinite mute without a second state flag.
    public static let indefiniteMuteSentinel = "9999-12-31"

    public init(
        enabled: Bool = false,
        scopes: [DeskNagScope] = [],
        mutedUntil: String? = nil,
        windowId: Int = 1,
        ledger: [String: Int] = [:],
        observed: [String: DeskNagObservation] = [:]
    ) {
        self.enabled = enabled
        self.scopes = scopes
        self.mutedUntil = mutedUntil
        self.windowId = windowId
        self.ledger = ledger
        self.observed = observed
    }

    // MARK: - Reads

    /// Treat malformed mute dates as unmuted so bad input cannot silently suppress notifications forever.
    public func isMuted(now: Date) -> Bool {
        guard let raw = mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let until = DeskSequencing.parseDeferStamp(raw) else { return false }
        return until > now
    }

    public func muteHasElapsed(now: Date) -> Bool {
        guard let raw = mutedUntil?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return !isMuted(now: now)
    }

    /// Global enable alone cannot nag every item: an item or project scope must opt in.
    public func scopeEnabled(for item: DeskItem) -> Bool {
        if let entry = scopes.first(where: { $0.kind == .item && $0.id == item.handle }) {
            return entry.enabled
        }
        if let entry = scopes.first(where: {
            $0.kind == .project && $0.id.compare(item.project, options: .caseInsensitive) == .orderedSame
        }) {
            return entry.enabled
        }
        return false
    }

    // MARK: - Transitions (value-returning; the store persists the result)

    /// Enabling opens a new window so prior nags do not consume the new attention budget.
    public func settingGlobal(_ on: Bool) -> DeskNagConfig {
        var next = self
        next.enabled = on
        if on && !enabled { next.windowId += 1 }
        return next
    }

    public func settingScope(kind: DeskNagScopeKind, id: String, enabled on: Bool) -> DeskNagConfig {
        var next = self
        if let idx = next.scopes.firstIndex(where: {
            $0.kind == kind && $0.id.compare(id, options: .caseInsensitive) == .orderedSame
        }) {
            next.scopes[idx].enabled = on
            next.scopes[idx].id = id
        } else {
            next.scopes.append(DeskNagScope(kind: kind, id: id, enabled: on))
        }
        return next
    }

    /// Muting suspends attention without rearming an item’s consumed budget.
    public func muted(until: String?) -> DeskNagConfig {
        var next = self
        let trimmed = until?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.mutedUntil = (trimmed?.isEmpty == false) ? trimmed : Self.indefiniteMuteSentinel
        return next
    }

    /// Unmuting opens a new window and pairs with a drift digest so resumption is informed.
    public func unmuted() -> DeskNagConfig {
        var next = self
        next.mutedUntil = nil
        next.windowId += 1
        return next
    }

    // MARK: - Wire

    /// Omit empty collections so an untouched preference remains human-readable.
    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "version": .int(Int64(DeskNagConfigSchema.version)),
            "enabled": .bool(enabled),
            "windowId": .int(Int64(windowId)),
        ]
        if !scopes.isEmpty { obj["scopes"] = .array(scopes.map { $0.toJSON() }) }
        if let mutedUntil, !mutedUntil.isEmpty { obj["mutedUntil"] = .string(mutedUntil) }
        if !ledger.isEmpty { obj["ledger"] = .object(ledger.mapValues { .int(Int64($0)) }) }
        if !observed.isEmpty { obj["observed"] = .object(observed.mapValues { $0.toJSON() }) }
        return .object(obj)
    }
}

// MARK: - Store

/// Lock the preference file independently so config writes need not wait for Desk appends.
/// A lost evaluation tick preserves its baseline, leaving the delta visible on the next read.
/// Local export and phone sync exclude this preference; off-disk backup retains it.
public struct DeskNagConfigStore: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public var configPath: URL {
        dataRoot
            .appendingPathComponent("desk", isDirectory: true)
            .appendingPathComponent("nag_config.json")
    }

    public func loadChecked() async throws -> DeskNagConfig {
        let raw = try await SwiftNativePersistenceCore.readJSON(configPath, ifMissing: .null)
        if raw == .null, !FileManager.default.fileExists(atPath: configPath.path) {
            return DeskNagConfig()
        }
        guard case .object(let object) = raw,
              object["version"] == nil || object["version"] == .int(Int64(DeskNagConfigSchema.version)),
              DeskNagConfigSchema.unexpectedKeys(in: raw).isEmpty else {
            throw UnavailableSettings()
        }
        var config = DeskNagConfig()
        for (key, value) in object {
            switch (key, value) {
            case ("version", .int): break
            case ("enabled", .bool(let enabled)): config.enabled = enabled
            case ("windowId", .int(let window)): config.windowId = max(1, Int(window))
            case ("mutedUntil", .string(let stamp)): config.mutedUntil = stamp.isEmpty ? nil : stamp
            case ("scopes", .array(let rows)):
                for row in rows {
                    guard let scope = DeskNagScope.fromJSON(row) else { throw UnavailableSettings() }
                    config.scopes.append(scope)
                }
            case ("ledger", .object(let rows)):
                for (handle, value) in rows {
                    guard case .int(let window) = value else { throw UnavailableSettings() }
                    config.ledger[handle] = Int(window)
                }
            case ("observed", .object(let rows)):
                for (handle, value) in rows {
                    guard let observation = DeskNagObservation.fromJSON(value) else { throw UnavailableSettings() }
                    config.observed[handle] = observation
                }
            default:
                throw UnavailableSettings()
            }
        }
        try Self.checkWindow(config)
        return config
    }

    private static func checkWindow(_ config: DeskNagConfig) throws {
        guard config.windowId < Int.max else { throw WindowExhausted() }
    }

    private struct WindowExhausted: LocalizedError {
        var errorDescription: String? {
            "The reminder window counter is exhausted. Saved reminder settings were left unchanged."
        }
    }

    private struct UnavailableSettings: LocalizedError {
        var errorDescription: String? {
            "I couldn’t read your reminder settings. I’ve left them unchanged. Try opening them with the app version that last saved them."
        }
    }

    /// Read-modify-write under the same flock so chat and background mutations cannot lose one another.
    @discardableResult
    public func update(_ transform: @Sendable (DeskNagConfig) -> DeskNagConfig) async throws -> DeskNagConfig {
        try await updating { (transform($0), ()) }.config
    }

    /// Compute proposals outside the lock, then compare their source before any baseline or window commits.
    public func updating<T: Sendable>(
        _ transform: @Sendable (DeskNagConfig) throws -> (DeskNagConfig, T)
    ) async throws -> (config: DeskNagConfig, value: T) {
        try await SwiftNativePersistenceCore.withFileLock(configPath) {
            let current = try await loadChecked()
            let (next, value) = try transform(current)
            try Self.checkWindow(next)
            // Unchanged config is not rewritten, so the file watcher stays quiet.
            if next != current {
                try await SwiftNativePersistenceCore.writeJSON(next.toJSON(), to: configPath)
            }
            return (next, value)
        }
    }
}

public struct DeskNagLane: Identifiable, Equatable, Sendable {
    public let project: String
    public let enabled: Bool
    public let itemCount: Int
    public var id: String { project }
}

public enum DeskNagPanelModel {
    /// Absence of project scope means off, matching the owner’s item-before-project decision.
    public static func lanes(items: [DeskItem], config: DeskNagConfig) -> [DeskNagLane] {
        let active = DeskBoardLayout.activeItems(items)
        let byProject = Dictionary(grouping: active, by: \.project)
        return byProject.keys.sorted().map { project in
            let entry = config.scopes.first {
                $0.kind == .project && $0.id.compare(project, options: .caseInsensitive) == .orderedSame
            }
            return DeskNagLane(
                project: project,
                enabled: entry?.enabled ?? false,
                itemCount: byProject[project]?.count ?? 0)
        }
    }

    public static func summary(_ config: DeskNagConfig, items: [DeskItem], now: Date) -> String {
        if config.isMuted(now: now) {
            let phrase = config.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
                ? "indefinitely" : "until \(config.mutedUntil ?? "?")"
            return "Muted \(phrase) — still tracking, nothing will ping."
        }
        let on = DeskBoardLayout.activeItems(items).filter { config.scopeEnabled(for: $0) }.count
        guard config.enabled else {
            return on > 0
                ? "Nagging is OFF globally — \(on) live item\(on == 1 ? "" : "s") enabled but silent."
                : "Nagging is OFF. Nothing will ping."
        }
        return on == 0
            ? "Nagging is ON, but no live item is enabled — nothing will ping until you enable one."
            : "Nagging is ON for \(on) live item\(on == 1 ? "" : "s")."
    }

    /// Resolve against the supplied clock so near-midnight choices use one consistent instant.
    public struct SnoozeOption: Identifiable, Equatable, Sendable {
        public let label: String
        public let until: String?
        public var id: String { label }
    }

    public static func snoozeOptions(from now: Date, calendar: Calendar = .current) -> [SnoozeOption] {
        [
            SnoozeOption(label: "Through tomorrow", until: DeskDeferPreset.tomorrow.day(from: now, calendar: calendar)),
            SnoozeOption(label: "Through " + DeskDeferPreset.nextWeek.day(from: now, calendar: calendar), until: DeskDeferPreset.nextWeek.day(from: now,
                calendar: calendar)),
            SnoozeOption(label: "Indefinitely", until: nil),
        ]
    }
}
