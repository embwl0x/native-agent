import Foundation
import PersistenceCore

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
    private var cache: [String: (mtime: Date?, entries: [MacAppMapEntry])] = [:]
    private var dirty: Set<String> = []

    public init(directory: URL) { self.directory = directory }

    private func url(_ bundle: String) -> URL? {
        MacAppMaps.fileName(bundle).map { directory.appendingPathComponent($0) }
    }

    /// nil = the file exists but could not be read (I/O): nothing may be
    /// written over it this time. A malformed file is moved aside to
    /// `.corrupt` and the map starts fresh.
    private func load(_ bundle: String) -> [MacAppMapEntry]? {
        guard let url = url(bundle) else { return nil }
        // Unflushed changes are newer than the file.
        if dirty.contains(bundle), let cached = cache[bundle] { return cached.entries }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = cache[bundle], cached.mtime == mtime { return cached.entries }
        guard mtime != nil else {
            cache[bundle] = (nil, [])
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let entries = try? JSONDecoder().decode([MacAppMapEntry].self, from: data) {
            cache[bundle] = (mtime, entries)
            return entries
        }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return nil }
        cache[bundle] = (nil, [])
        return []
    }

    private func store(_ bundle: String, _ entries: [MacAppMapEntry]) {
        cache[bundle] = (cache[bundle]?.mtime, entries)
        dirty.insert(bundle)
    }

    public func entries(bundle: String, window: String) -> [MacAppMapEntry] {
        (load(bundle) ?? []).filter { $0.window == window }
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
        guard !asked.isEmpty, !label.isEmpty, !path.isEmpty, var entries = load(bundle) else { return }
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
        store(bundle, entries)
    }

    /// The live window no longer agreed. `evict` when something ELSE is at that
    /// path now; otherwise one hit is taken off and the entry goes at zero.
    public func penalize(bundle: String, window: String, path: [Int], evict: Bool) {
        guard var entries = load(bundle),
              let index = entries.firstIndex(where: { $0.window == window && $0.path == path }) else { return }
        entries[index].hits -= 1
        if evict || entries[index].hits <= 0 { entries.remove(at: index) }
        store(bundle, entries)
    }

    /// One write per act call. A failed write stays dirty for the next one.
    public func flush() {
        guard !dirty.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for bundle in dirty {
            guard let url = url(bundle), let entries = cache[bundle]?.entries,
                  let data = try? encoder.encode(entries),
                  (try? data.write(to: url, options: .atomic)) != nil else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            cache[bundle] = (mtime, entries)
            dirty.remove(bundle)
        }
    }
}
