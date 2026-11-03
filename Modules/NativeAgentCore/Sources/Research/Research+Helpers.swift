import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Synchronization
// Blueprint: | `Research+Helpers.swift` | Research URL/time helpers and one per-directory receipt retention owner; checked file ages precede deletion, actual completion owns release, retained repairable errors surface in fetch readouts without failing completed fetches |

extension SwiftNativeResearchClient {
    // MARK: Helpers

    func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// Preserve query-item insertion order in URLs and receipts.
    func makeURL(base: String, path: String, query: [(String, String)]) -> URL? {
        var comps = URLComponents(string: base + path)
        comps?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps?.url
    }

    /// ISO-8601 with fractional seconds and a `+00:00` UTC suffix.
    public nonisolated static func isoTimestamp(_ date: Date) -> String {
        NativeTimestampFormat.fractionalUTCOffset(date)
    }

    public nonisolated static func defaultDataRoot() -> URL {
        PersistenceCore.defaultDataRoot()
    }

    // MARK: Receipt retention

    /// Bound on fetched-source receipts and retained search receipts
    /// in `receiptsDir`; search results are returned without a duplicate file.
    static let receiptRetentionLimit = 200

    private struct RetentionState: Sendable {
        var running = false
        var completed = false
        var error: String?
    }

    /// One state and operation per directory across all short-lived clients.
    private static let aging = Mutex<[String: RetentionState]>([:])

    nonisolated static func receiptRetentionStatus(in directory: URL) -> JSONValue {
        aging.withLock { states in
            let state = states[directory.path] ?? RetentionState()
            return .object([
                "status": .string(state.error != nil ? "failed" : (state.running ? "pending" : (state.completed ? "ok" : "unmeasured"))),
                "in_flight": .bool(state.running),
                "error": state.error.map(JSONValue.string) ?? .null,
                "remedy": state.error == nil ? .null : .string("Check receipt file metadata and write access in \(directory.path). The next fetch requests a new retention pass; the completed fetch is still valid."),
            ])
        }
    }

    /// Keep the newest `receiptRetentionLimit` receipt files; delete the
    /// rest. Housekeeping: it runs on its own, off this call's return path, so
    /// an arrived result never waits on a directory scan, and a prune failure
    /// never fails the fetch that just succeeded. Only receipt-shaped
    /// files are eligible (`source-*.json`, or `<uuid>.json`): `config.json`
    /// and the `lab/` subdirectory share the directory and are never touched.
    nonisolated func pruneReceiptsIfNeeded() {
        let receiptsDir = receiptsDir
        guard Self.aging.withLock({ states in
            var state = states[receiptsDir.path] ?? RetentionState()
            guard !state.running else { return false }
            state.running = true
            state.completed = false
            states[receiptsDir.path] = state
            return true
        }) else { return }
        // The scan blocks on the filesystem, so it runs on VolumeIO, never the pool.
        Task {
            do {
                try await VolumeIO.run(onFinish: {
                    Self.aging.withLock { $0[receiptsDir.path]?.running = false }
                }) {
                    do {
                        try Self.pruneReceipts(in: receiptsDir)
                        Self.aging.withLock { states in
                            states[receiptsDir.path]?.completed = true
                            states[receiptsDir.path]?.error = nil
                        }
                    } catch {
                        Self.recordRetentionFailure(error, directory: receiptsDir)
                        throw error
                    }
                }
            } catch {
                // A VolumeIO deadline ends our wait, not an issued prune. Its
                // body may later publish its actual result; onFinish releases
                // the directory only when the physical operation has ended.
                Self.recordRetentionFailure(error, directory: receiptsDir, onlyIfUnfinished: true)
            }
        }
    }

    private nonisolated static func recordRetentionFailure(_ error: Error, directory: URL, onlyIfUnfinished: Bool = false) {
        let detail = error.localizedDescription
        let recorded = aging.withLock { states in
            guard var state = states[directory.path], !onlyIfUnfinished || !state.completed else { return false }
            state.error = detail
            if !onlyIfUnfinished { state.completed = true }
            states[directory.path] = state
            return true
        }
        if recorded {
            NSLog("[Research.retention] %@: %@. Completed fetch preserved; repair receipt metadata/access before the next retention pass.", directory.path, detail)
        }
    }

    private static func pruneReceipts(in receiptsDir: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: receiptsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var receipts: [(url: URL, modified: Date)] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let stem = String(name.dropLast(".json".count))
            let isReceipt = stem.hasPrefix("source-") || UUID(uuidString: stem) != nil
            guard isReceipt else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let modified = values.contentModificationDate else {
                throw ResearchClientError.malformedResponse("Receipt metadata is unavailable at \(url.path); retention did not choose an age for it.")
            }
            receipts.append((url, modified))
        }
        guard receipts.count > Self.receiptRetentionLimit else { return }
        receipts.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        for victim in receipts.dropFirst(Self.receiptRetentionLimit) {
            try fm.removeItem(at: victim.url)
        }
    }
}
