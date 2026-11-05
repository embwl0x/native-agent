import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MacAppMaps.swift` | `MacAppMapStore`: Verified control maps; scoped press evidence; checked reads/flushes |

// Remember only verified app-chrome controls. Paths are hints: live role/label agreement remains required before acting. Never store field values, secure
// fields, rows, titles or content-like labels; ambiguous labels are not retained.

public struct MacAppMapEntry: Codable, Sendable, Equatable {
    public var window: String
    public var asked: String
    public var label: String
    public var kind: String
    /// Paths use the same walked root as act/ax_act so map hints resolve in the right coordinate tree.
    public var path: [Int]
    /// Use UTC timestamps for LRU ordering.
    public var verified: String
    public var hits: Int
}

/// Outcomes for one exact control/context. Counts retain contrary and uncertain attempts; only the latest verified pointer outcome nominates it.
public struct MacPressRouteEvidence: Codable, Sendable, Equatable {
    public var counts: [String: Int] = [:]
    public var lastMethod = ""
    public var lastOutcome = ""
    public var observedAt = ""
    public var suggestsPointer: Bool { lastMethod == "pointer" && lastOutcome == "satisfied" }
}

public struct MacAppMap: Codable, Sendable, Equatable {
    public var controls: [MacAppMapEntry] = []
    private var learned: [String: String] = [:]
    public var pressRoutes: [String: MacPressRouteEvidence] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controls = try container.decode([MacAppMapEntry].self, forKey: .controls)
        learned = try container.decodeIfPresent([String: String].self, forKey: .learned) ?? [:]
        pressRoutes = try container.decodeIfPresent([String: MacPressRouteEvidence].self, forKey: .pressRoutes) ?? [:]
    }
}

public enum MacAppMaps {
    public static let maxEntriesPerApp = 300

    /// Key by role/subrole only so window content never enters map identity.
    public static func windowKind(role: String?, subrole: String?) -> String {
        (role ?? "AXWindow") + (subrole.map { "/" + $0 } ?? "")
    }

    static let systemLabels: Set<String> = Set<String>([
        "ok", "cancel", "save", "done", "close", "open", "delete", "back", "forward", "share", "send", "reply",
        "new", "edit", "search", "settings", "add", "remove", "next", "previous", "apply", "undo", "redo",
        "copy", "paste", "cut", "print", "refresh", "reload", "home", "help", "more", "menu", "options",
        "bold", "italic", "underline", "zoom in", "zoom out", "sidebar", "info", "filter", "sort",
        "ac", "c", "ce", "mc", "mr", "m+", "m-", "rad", "deg",
    ]).union(MacFourVerbs.symbolAliases.values.flatMap { $0 })

    /// A label that cannot be anyone's content: a known system word, a single character, or ≤4 digits/operators ("7", "×", "+/-"). Two letters could be
    /// someone's initials, so they are not enough on their own.
    static func isStableSystemLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if systemLabels.contains(trimmed.lowercased()) { return true }
        if trimmed.count == 1 { return true }
        return (1...4).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol }
    }

    /// Store keys are bundle ids; anything else is refused rather than becoming a path component.
    static func fileName(_ bundle: String) -> String? {
        guard !bundle.isEmpty, bundle.count <= 200,
              bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              !bundle.hasPrefix(".") else { return nil }
        return bundle + ".json"
    }
}

/// One small JSON per app, cached in memory on the file's mtime; writes are batched — `flush()` runs once at the end of each `act` call.
public actor MacAppMapStore {
    public static let shared = MacAppMapStore(
        directory: PersistenceCore.defaultDataRoot()
            .appendingPathComponent("her_screen", isDirectory: true)
            .appendingPathComponent("app_maps", isDirectory: true)
    )

    private let directory: URL
    private var cache: [String: (mtime: Date?, map: MacAppMap)] = [:]
    private var dirty: Set<String> = []

    public init(directory: URL) { self.directory = directory }

    private func url(_ bundle: String) -> URL? {
        MacAppMaps.fileName(bundle).map { directory.appendingPathComponent($0) }
    }

    /// Malformed maps remain in place and are not overwritten.
    private func load(_ bundle: String) throws -> MacAppMap {
        guard let url = url(bundle) else {
            throw ToolFailureError("Invalid app-map bundle identity.", effects: .none)
        }
        if dirty.contains(bundle), let cached = cache[bundle] { return cached.map }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            let empty = MacAppMap()
            cache[bundle] = (nil, empty)
            return empty
        }
        let mtime = attributes[.modificationDate] as? Date
        if let cached = cache[bundle], cached.mtime == mtime { return cached.map }
        let data = try Data(contentsOf: url)
        let map = try JSONDecoder().decode(MacAppMap.self, from: data)
        cache[bundle] = (mtime, map)
        return map
    }

    private func store(_ bundle: String, _ map: MacAppMap) {
        cache[bundle] = (cache[bundle]?.mtime, map)
        dirty.insert(bundle)
    }

    public func entries(bundle: String, window: String) throws -> [MacAppMapEntry] {
        (try load(bundle).controls).filter { $0.window == window }
    }

    public func pressRoute(bundle: String, control: String) throws -> MacPressRouteEvidence? {
        try load(bundle).pressRoutes[control]
    }

    public func recordPress(bundle: String, control: String, pointer: Bool, outcome: String) throws {
        var map = try load(bundle)
        var evidence = map.pressRoutes[control] ?? MacPressRouteEvidence()
        let method = pointer ? "pointer" : "accessibility"
        let key = method + ":" + outcome
        let count = evidence.counts[key] ?? 0
        evidence.counts[key] = count < Int.max ? count + 1 : count
        evidence.lastMethod = method
        evidence.lastOutcome = outcome
        evidence.observedAt = NativeTimestampFormat.plainZulu(Date())
        map.pressRoutes[control] = evidence
        if map.pressRoutes.count > MacAppMaps.maxEntriesPerApp,
           let oldest = map.pressRoutes.keys.sorted(by: {
               let left = map.pressRoutes[$0]?.observedAt ?? ""
               let right = map.pressRoutes[$1]?.observedAt ?? ""
               return left == right ? $0 < $1 : left < right
           }).first {
            map.pressRoutes.removeValue(forKey: oldest)
        }
        store(bundle, map)
    }

    /// Existing entries already passed the chrome-only label privacy boundary.
    public func has(bundle: String, window: String, asked: String, label: String) throws -> Bool {
        try entries(bundle: bundle, window: window).contains { $0.asked == asked && $0.label == label }
    }

    /// Refresh only verified controls and LRU-evict beyond the cap so map growth stays bounded.
    public func record(bundle: String, window: String, asked: String, label: String, kind: String, path: [Int], at date: Date = Date()) throws {
        guard !asked.isEmpty, !label.isEmpty, !path.isEmpty else { return }
        var map = try load(bundle)
        var entries = map.controls
        let stamp = NativeTimestampFormat.plainZulu(date)
        if let index = entries.firstIndex(where: { $0.window == window && $0.asked == asked && $0.kind == kind }) {
            entries[index].label = label
            entries[index].path = path
            entries[index].verified = stamp
            if entries[index].hits < Int.max { entries[index].hits += 1 }
        } else {
            entries.append(MacAppMapEntry(window: window, asked: asked, label: label, kind: kind,
                                          path: path, verified: stamp, hits: 1))
        }
        if entries.count > MacAppMaps.maxEntriesPerApp {
            entries.sort { $0.verified > $1.verified }
            entries = Array(entries.prefix(MacAppMaps.maxEntriesPerApp))
        }
        map.controls = entries
        store(bundle, map)
    }

    /// Evict a contradicted live path; otherwise weaken its hit count until zero rather than treating missing evidence as removal.
    public func penalize(bundle: String, window: String, path: [Int], evict: Bool) throws {
        var map = try load(bundle)
        guard let index = map.controls.firstIndex(where: { $0.window == window && $0.path == path }) else { return }
        if map.controls[index].hits > 0 { map.controls[index].hits -= 1 }
        if evict || map.controls[index].hits <= 0 { map.controls.remove(at: index) }
        store(bundle, map)
    }

    /// One write per act call. A failed write stays dirty for the next one.
    public func flush() -> [String: String] {
        var failures: [String: String] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for bundle in Array(dirty) {
            do {
                guard let url = url(bundle), let map = cache[bundle]?.map else {
                    throw ToolFailureError("Dirty app-map has no valid destination or cached map.", effects: .none)
                }
                let data = try encoder.encode(map)
                try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: url)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                cache[bundle] = (attributes[.modificationDate] as? Date, map)
                dirty.remove(bundle)
            } catch { failures[bundle] = error.localizedDescription }
        }
        return failures
    }
}
