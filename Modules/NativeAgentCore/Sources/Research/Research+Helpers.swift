import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeResearchClient {
    // MARK: Helpers

    func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// Build a URL preserving query-item INSERTION ORDER. Python's
    /// `urllib.parse.urlencode({"q": ..., "format": ...})` serializes dict
    /// items in insertion order (`q=...&format=json`); receipt JSON `url`
    /// fields must match byte-for-byte across the cutover, so we cannot
    /// use `[String: String]` (which is unordered) or sort by key
    /// (which would invert to `format=json&q=...`). Pass an ordered list
    /// of `(key, value)` pairs instead.
    func makeURL(base: String, path: String, query: [(String, String)]) -> URL? {
        var comps = URLComponents(string: base + path)
        comps?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps?.url
    }

    /// Match Python's `now_iso()`: `datetime.now(timezone.utc).isoformat()` —
    /// ISO-8601 with fractional seconds, `+00:00` suffix (not `Z`).
    /// Same convention as `SwiftNativeMCPDispatcher.isoTimestamp`.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let zulu = fmt.string(from: date)
        if zulu.hasSuffix("Z") {
            return String(zulu.dropLast()) + "+00:00"
        }
        return zulu
    }

    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }

    // MARK: Receipt retention (2026-07-21 audit)

    /// Bound on per-call search/fetch receipt files in `receiptsDir`
    /// (`data/research/<id>.json` + `data/research/source-<id>.json`).
    /// Before this cap every search() / fetchURL() call appended one JSON
    /// file with no retention — an unbounded pile under data/.
    static let receiptRetentionLimit = 200

    /// Keep the newest `receiptRetentionLimit` receipt files; delete the
    /// rest. Best-effort and non-throwing — a prune failure must never fail
    /// the search/fetch that just succeeded. Only receipt-shaped files are
    /// eligible (`source-*.json`, or `<uuid>.json`): `config.json` and the
    /// `lab/` subdirectory share the directory and are never touched.
    func pruneReceiptsIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: receiptsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var receipts: [(url: URL, modified: Date)] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let stem = String(name.dropLast(".json".count))
            let isReceipt = stem.hasPrefix("source-") || UUID(uuidString: stem) != nil
            guard isReceipt else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            receipts.append((url, modified))
        }
        guard receipts.count > Self.receiptRetentionLimit else { return }
        receipts.sort { $0.modified > $1.modified }
        for victim in receipts.dropFirst(Self.receiptRetentionLimit) {
            try? fm.removeItem(at: victim.url)
        }
    }
}
