import Foundation
import PersistenceCore
// Blueprint: | `MacAppMaps.swift` | `MacAppMapStore` owns per-app control maps and learned choices; malformed maps remain in place without overwrite; no quarantine/reset copy |

// Her-screen Phase 5 — MUSCLE MEMORY: per-app maps.
//
// After a VERIFIED act (the closed loop saw the effect, and the element acted
// on answered the name asked), the app remembers where that named control
// lives: `data/her_screen/app_maps/<bundle id>.json`. `screen` lists the
// remembered controls its text render cut (KNOWN), and when a name misses by
// resolution, `act` uses a remembered path ONLY if the live element there
// still answers the name — role and label, the same `answers()` rule. A map entry is a hint about WHERE to look, never a license
// to act: nothing here is ever clicked without a live read agreeing.
//
// Stored: the window KIND (AX role/subrole only — never a title), the name as
// asked and as labelled, the kind, the AX path relative to the walked root,
// when it was last verified, and how often. Only APP CHROME is stored: a label
// that is a stable system word, a key-sized label, or one the app's own menu
// bar carries. Never a field's value, a secure field, a row, or anything that
// could be a name, subject or file name — when in doubt, nothing is stored.
//
// `learned` is the part's learned property, kept by the stem for every app
// (docs/AGENT_IS_THE_APP.md): which route a press of a kind of control takes
// in this app, `"press tab": "pointer"`, folded from what showed a consequence.

/// One remembered control.
public struct MacAppMapEntry: Codable, Sendable, Equatable {
    /// `role/subrole` — see `MacAppMaps.windowKind`.
    public var window: String
    /// The name as she asked for it, normalised.
    public var asked: String
    /// The label the control carried when it was verified.
    public var label: String
    /// The renderer's kind word (`button`, `checkbox`, …).
    public var kind: String
    /// The AX path relative to the walked root, as `act`/`ax_act` address it.
    public var path: [Int]
    /// ISO-8601, UTC. LRU order.
    public var verified: String
    public var hits: Int
}

/// One app's file: its remembered controls and what use has taught.
public struct MacAppMap: Codable, Sendable, Equatable {
    public var controls: [MacAppMapEntry] = []
    public var learned: [String: String] = [:]

    public init() {}

    /// A map written before `learned` existed is the bare controls array.
    public init(from decoder: Decoder) throws {
        if let controls = try? decoder.singleValueContainer().decode([MacAppMapEntry].self) {
            self.controls = controls
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controls = try container.decode([MacAppMapEntry].self, forKey: .controls)
        learned = try container.decodeIfPresent([String: String].self, forKey: .learned) ?? [:]
    }
}

public enum MacAppMaps {
    public static let maxEntriesPerApp = 300

    /// The window's KIND, never its content: AX role/subrole only
    /// (`AXWindow/AXStandardWindow`, `AXSheet`, `AXWindow/AXDialog`).
    public static func windowKind(role: String?, subrole: String?) -> String {
        (role ?? "AXWindow") + (subrole.map { "/" + $0 } ?? "")
    }

    /// Words every app uses for its own chrome.
    static let systemLabels: Set<String> = Set<String>([
        "ok", "cancel", "save", "done", "close", "open", "delete", "back", "forward", "share", "send", "reply",
        "new", "edit", "search", "settings", "add", "remove", "next", "previous", "apply", "undo", "redo",
        "copy", "paste", "cut", "print", "refresh", "reload", "home", "help", "more", "menu", "options",
        "bold", "italic", "underline", "zoom in", "zoom out", "sidebar", "info", "filter", "sort",
        // Calculator-style keys.
        "ac", "c", "ce", "mc", "mr", "m+", "m-", "rad", "deg",
    ]).union(MacFourVerbs.symbolAliases.values.flatMap { $0 })

    /// A label that cannot be anyone's content: a known system word, a single
    /// character, or ≤4 digits/operators ("7", "×", "+/-"). Two letters could
    /// be someone's initials, so they are not enough on their own.
    static func isStableSystemLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if systemLabels.contains(trimmed.lowercased()) { return true }
        if trimmed.count == 1 { return true }
        return (1...4).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol }
    }

    /// Store keys are bundle ids; anything else is refused rather than
    /// becoming a path component.
    static func fileName(_ bundle: String) -> String? {
        guard !bundle.isEmpty, bundle.count <= 200,
              bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              !bundle.hasPrefix(".") else { return nil }
        return bundle + ".json"
    }
}

/// One small JSON per app, cached in memory on the file's mtime; writes are
/// batched — `flush()` runs once at the end of each `act` call.
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
    private func load(_ bundle: String) -> MacAppMap? {
        guard let url = url(bundle) else { return nil }
        // Unflushed changes are newer than the file.
        if dirty.contains(bundle), let cached = cache[bundle] { return cached.map }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = cache[bundle], cached.mtime == mtime { return cached.map }
        guard mtime != nil else {
            cache[bundle] = (nil, MacAppMap())
            return MacAppMap()
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let map = try? JSONDecoder().decode(MacAppMap.self, from: data) {
            cache[bundle] = (mtime, map)
            return map
        }
        return nil
    }

    private func store(_ bundle: String, _ map: MacAppMap) {
        cache[bundle] = (cache[bundle]?.mtime, map)
        dirty.insert(bundle)
    }

    public func entries(bundle: String, window: String) -> [MacAppMapEntry] {
        (load(bundle)?.controls ?? []).filter { $0.window == window }
    }

    public func learned(bundle: String, _ choice: String) -> String? {
        load(bundle)?.learned[choice]
    }

    /// What use taught: `value` for `choice` in this app, or nil to forget it.
    public func learn(bundle: String, _ choice: String, _ value: String?) {
        guard var map = load(bundle), map.learned[choice] != value else { return }
        map.learned[choice] = value
        store(bundle, map)
    }

    public func paths(bundle: String, window: String) -> Set<[Int]> {
        Set(entries(bundle: bundle, window: window).map(\.path))
    }

    /// Whether this exact control is already remembered (its label was vetted
    /// as chrome when it was first stored).
    public func has(bundle: String, window: String, asked: String, label: String) -> Bool {
        entries(bundle: bundle, window: window).contains { $0.asked == asked && $0.label == label }
    }

    /// A verified act: add the entry, or refresh it (live path/label, date,
    /// hit). LRU-evicts past the cap.
    public func record(bundle: String, window: String, asked: String, label: String, kind: String, path: [Int], at date: Date = Date()) {
        guard !asked.isEmpty, !label.isEmpty, !path.isEmpty, var map = load(bundle) else { return }
        var entries = map.controls
        let stamp = ISO8601DateFormatter().string(from: date)
        if let index = entries.firstIndex(where: { $0.window == window && $0.asked == asked && $0.kind == kind }) {
            entries[index].label = label
            entries[index].path = path
            entries[index].verified = stamp
            entries[index].hits += 1
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

    /// The live window no longer agreed. `evict` when something ELSE is at that
    /// path now; otherwise one hit is taken off and the entry goes at zero.
    public func penalize(bundle: String, window: String, path: [Int], evict: Bool) {
        guard var map = load(bundle),
              let index = map.controls.firstIndex(where: { $0.window == window && $0.path == path }) else { return }
        map.controls[index].hits -= 1
        if evict || map.controls[index].hits <= 0 { map.controls.remove(at: index) }
        store(bundle, map)
    }

    /// One write per act call. A failed write stays dirty for the next one.
    public func flush() {
        guard !dirty.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for bundle in dirty {
            guard let url = url(bundle), let map = cache[bundle]?.map,
                  let data = try? encoder.encode(map),
                  (try? data.write(to: url, options: .atomic)) != nil else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            cache[bundle] = (mtime, map)
            dirty.remove(bundle)
        }
    }
}
