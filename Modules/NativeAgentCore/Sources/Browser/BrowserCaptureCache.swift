import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `BrowserCaptureCache.swift` | `BrowserCaptureCache`: serialized bounded storage and grouped eviction of disposable perception artifacts; expired captures require new observation |

/// Disposable observations only. Downloads, authored documents, profile state,
/// and generated images never enter this owner. Old receipt paths may expire;
/// callers must capture again rather than treating a missing file as evidence.
public actor BrowserCaptureCache {
    public static let shared = BrowserCaptureCache()

    public struct Policy: Sendable {
        public let maxBytes = 128 * 1_024 * 1_024
        public let maxGroups = 256
        public let maxAge: TimeInterval = 7 * 86_400
        public let maxArtifactBytes = 16 * 1_024 * 1_024
        public let maxGroupBytes = 32 * 1_024 * 1_024

        public var receipt: JSONValue {
            .object([
                "kind": .string("disposable_browser_capture"),
                "maxBytes": .int(Int64(maxBytes)),
                "maxCaptures": .int(Int64(maxGroups)),
                "maxAgeSeconds": .int(Int64(maxAge)),
                "maxArtifactBytes": .int(Int64(maxArtifactBytes)),
                "maxCaptureBytes": .int(Int64(maxGroupBytes)),
                "expiry": .string("Enforced on capture writes. Old paths may expire; capture again if unavailable."),
            ])
        }
    }

    public enum Kind: String, Sendable, Hashable {
        case text, links, screenshot
        fileprivate var suffix: String {
            switch self { case .text: ".txt"; case .links: "-links.json"; case .screenshot: ".png" }
        }
        fileprivate var directory: String { self == .screenshot ? "screenshots" : "sources" }
    }

    private struct Entry {
        let url: URL
        let bytes: Int
        let date: Date
    }

    public nonisolated let policy = Policy()

    /// One serialized admission point for every canonical perception writer.
    /// Matching text/links/screenshots are evicted together; adding a later
    /// screenshot never evicts the current operation's source text.
    public func store(id: String, artifacts: [Kind: Data], browserRoot: URL,
                      now: Date = Date()) throws -> [Kind: URL] {
        guard Self.isCaptureID(id), !artifacts.isEmpty else { throw failure("invalid_capture") }
        guard policy.maxBytes > 0, policy.maxGroups > 0, policy.maxAge > 0,
              artifacts.values.allSatisfy({ $0.count <= policy.maxArtifactBytes }) else {
            throw failure("capture_too_large", "Browser capture exceeds the per-artifact cache limit.")
        }
        let incomingBytes = try checkedBytes(artifacts.values.map(\.count))
        guard incomingBytes <= policy.maxGroupBytes, incomingBytes <= policy.maxBytes else {
            throw failure("capture_too_large", "Browser capture exceeds the cache limit.")
        }

        let fm = FileManager.default
        let root = browserRoot.standardizedFileURL
        // Refuse redirection inside the configured data root. The system's
        // /var or /tmp aliases above that root are not cache-owned directories.
        for directory in [root.deletingLastPathComponent().deletingLastPathComponent(),
                          root.deletingLastPathComponent(), root] {
            try requireOrdinaryDirectory(directory, create: false)
        }
        try requireOrdinaryDirectory(root, create: true)
        for name in ["sources", "screenshots"] {
            try requireOrdinaryDirectory(root.appendingPathComponent(name), create: true)
        }

        var groups: [String: [Entry]] = [:]
        var inspected = 0
        for directory in ["sources", "screenshots"] {
            let base = root.appendingPathComponent(directory)
            guard let iterator = fm.enumerator(at: base, includingPropertiesForKeys:
                [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
                throw failure("capture_cache_unreadable")
            }
            for case let url as URL in iterator {
                inspected += 1
                guard inspected <= 50_000 else { throw failure("capture_cache_inventory_too_large") }
                let values = try url.resourceValues(forKeys:
                    [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let captureID = Self.captureID(filename: url.lastPathComponent, directory: directory) else { continue }
                // Existing sparse/inherited files obey the same bounds as new
                // artifacts. An invalid inventory is reported before eviction.
                guard let size = values.fileSize, size >= 0, size <= policy.maxArtifactBytes else {
                    throw failure("capture_cache_invalid_size")
                }
                groups[captureID, default: []].append(Entry(url: url, bytes: size,
                                                           date: values.contentModificationDate ?? now))
            }
        }
        let currentBytes = try checkedBytes(groups[id, default: []].map(\.bytes))
        let combinedBytes = try checkedBytes([currentBytes, incomingBytes])
        guard combinedBytes <= policy.maxGroupBytes,
              combinedBytes <= policy.maxBytes else {
            throw failure("capture_too_large", "Combined browser capture exceeds the cache limit.")
        }
        var destinations: [Kind: URL] = [:] // Validate destinations before eviction.
        for kind in artifacts.keys {
            let destination = root.appendingPathComponent(kind.directory).appendingPathComponent(id + kind.suffix)
            // Never overwrite an existing file, directory, or symlink, even if
            // the caller accidentally repeats an operation ID.
            if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
                throw failure("capture_already_exists")
            }
            destinations[kind] = destination
        }

        var bytes = try checkedBytes(groups.values.flatMap { $0 }.map(\.bytes) + [incomingBytes])
        var count = groups.count + (groups[id] == nil ? 1 : 0)
        let oldest = groups.filter { $0.key != id }.map { (_, entries) in
            (entries: entries, date: entries.lazy.map(\.date).max() ?? .distantPast)
        }.sorted { $0.date < $1.date }
        for (entries, date) in oldest {
            guard now.timeIntervalSince(date) > policy.maxAge || bytes > policy.maxBytes || count > policy.maxGroups else { continue }
            for entry in entries {
                // No recursive deletion or symlink following. Directory changes
                // since enumeration abort the write instead of following them.
                try requireOrdinaryDirectory(entry.url.deletingLastPathComponent(), create: false)
                let attributes = try fm.attributesOfItem(atPath: entry.url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw failure("capture_cache_changed")
                }
                try fm.removeItem(at: entry.url)
                bytes -= entry.bytes
            }
            count -= 1
        }
        guard bytes <= policy.maxBytes, count <= policy.maxGroups else { throw failure("capture_cache_full") }
        for (kind, data) in artifacts {
            guard let destination = destinations[kind] else { continue }
            try requireOrdinaryDirectory(destination.deletingLastPathComponent(), create: false)
            try data.write(to: destination, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return destinations
    }

    private func checkedBytes(_ sizes: [Int]) throws -> Int {
        try sizes.reduce(0) { total, size in
            let (next, overflow) = total.addingReportingOverflow(size)
            guard size >= 0, !overflow else { throw failure("capture_cache_invalid_size") }
            return next
        }
    }

    private func requireOrdinaryDirectory(_ url: URL, create: Bool) throws {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw failure("capture_cache_unsafe_directory")
            }
        } else if create {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func isCaptureID(_ id: String) -> Bool {
        if UUID(uuidString: id) != nil { return true }
        for prefix in ["browser-text-", "browser-links-", "browser-shot-"] where id.hasPrefix(prefix) {
            if UUID(uuidString: String(id.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

    private static func captureID(filename: String, directory: String) -> String? {
        let kinds: [Kind] = directory == "sources" ? [.links, .text] : [.screenshot]
        for kind in kinds where filename.hasSuffix(kind.suffix) {
            let id = String(filename.dropLast(kind.suffix.count))
            if isCaptureID(id) { return id }
        }
        return nil
    }

    private func failure(_ reason: String, _ message: String? = nil) -> NSError {
        NSError(domain: "NativeAgentBrowserCaptureCache", code: 507, userInfo: [
            NSLocalizedDescriptionKey: message ?? "Browser capture was not saved: \(reason).",
            "reason": reason,
        ])
    }
}
