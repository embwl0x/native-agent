import Foundation
import NativeAgentCore
import PersistenceCore

/// Compatibility boundary for daemon-written `<dataRoot>/context/<runId>.json`
/// files. It never scans arbitrary receipts to answer a current-context read:
/// callers must supply the run ID referenced by the session/message owner.
public enum LegacyContextReceiptFeed {
    public enum ReadOutcome: Equatable, Sendable {
        case invalidRunID
        case missing
        case malformed
        case nonObject
        case runIDMismatch
        case receipt(JSONValue)
    }

    public struct RetentionReport: Equatable, Sendable {
        public var discovered: Int
        public var protected: Int
        public var removed: Int
        public var failedRemovals: Int
        public var unavailable: Bool

        public init(
            discovered: Int = 0,
            protected: Int = 0,
            removed: Int = 0,
            failedRemovals: Int = 0,
            unavailable: Bool = false
        ) {
            self.discovered = discovered
            self.protected = protected
            self.removed = removed
            self.failedRemovals = failedRemovals
            self.unavailable = unavailable
        }
    }

    /// Unreferenced compatibility receipts are retained for a bounded forensic
    /// window. Referenced run IDs are never removed by this sweep.
    public static let maximumUnprotectedFiles = 128
    public static let maximumUnprotectedAge: TimeInterval = 30 * 24 * 3_600

    /// Resolves a daemon receipt name without allowing an untrusted run ID to
    /// become a path component. Existing IDs may contain ordinary punctuation
    /// (including interior dots), but never path separators or hidden-dot names.
    public static func receiptPath(dataRoot: URL, runID: String) -> URL? {
        guard isSafeRunID(runID) else { return nil }
        let directory = dataRoot
            .appendingPathComponent("context", isDirectory: true)
            .standardizedFileURL
        let path = directory
            .appendingPathComponent(runID, isDirectory: false)
            .appendingPathExtension("json")
            .standardizedFileURL
        guard path.deletingLastPathComponent().path == directory.path else { return nil }
        return path
    }

    public static func read(
        dataRoot: URL,
        runID: String
    ) -> ReadOutcome {
        let fm = FileManager.default
        guard let path = receiptPath(dataRoot: dataRoot, runID: runID) else {
            return .invalidRunID
        }
        guard fm.fileExists(atPath: path.path) else { return .missing }
        guard let attributes = try? path.resourceValues(forKeys: [.isSymbolicLinkKey]),
              attributes.isSymbolicLink != true else {
            return .malformed
        }
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONValue.parse(data) else {
            return .malformed
        }
        guard case .object(let receipt) = value else { return .nonObject }
        if let declaredRunID = nonEmptyPythonString(receipt["runId"]),
           declaredRunID != runID {
            return .runIDMismatch
        }
        return .receipt(value)
    }

    /// Removes only old/excess receipts that no current session references.
    /// Each deletion shares the receipt's cross-process lock with the legacy
    /// daemon writer, then rechecks its mtime while holding that lock.
    public static func prune(
        dataRoot: URL,
        protectedRunIDs: Set<String>,
        now: Date = Date(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async -> RetentionReport {
        let directory = dataRoot.appendingPathComponent("context", isDirectory: true)
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // A missing directory is an empty dormant feed. Other filesystem
            // failures are unavailable maintenance, never a clean zero report.
            if !fm.fileExists(atPath: directory.path) { return .init() }
            return .init(unavailable: true)
        }

        let candidates = urls.compactMap { url -> (url: URL, modified: Date, runID: String)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate
            else { return nil }
            return (url, modified, url.deletingPathExtension().lastPathComponent)
        }
        var report = RetentionReport(discovered: candidates.count)
        let protected = Set(candidates.map(\.runID)).intersection(protectedRunIDs)
        report.protected = protected.count
        let unprotectedNewestFirst = candidates
            .filter { !protectedRunIDs.contains($0.runID) }
            .sorted { lhs, rhs in lhs.modified > rhs.modified }
        let cutoff = now.addingTimeInterval(-maximumUnprotectedAge)
        let removals = unprotectedNewestFirst.enumerated().compactMap { offset, candidate in
            candidate.modified < cutoff || offset >= maximumUnprotectedFiles ? candidate : nil
        }

        for candidate in removals {
            do {
                let removed = try await persistence.withFileLock(candidate.url) {
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: candidate.url.path),
                          let currentModified = try? candidate.url.resourceValues(
                            forKeys: [.contentModificationDateKey]
                          ).contentModificationDate,
                          currentModified <= candidate.modified,
                          !protectedRunIDs.contains(candidate.runID)
                    else { return false }
                    try fm.removeItem(at: candidate.url)
                    return true
                }
                if removed { report.removed += 1 }
            } catch {
                report.failedRemovals += 1
            }
        }
        return report
    }

    private static func nonEmptyPythonString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null: return nil
        case .bool(let value): return value ? "True" : "False"
        case .int(let value): return value == 0 ? nil : String(value)
        case .double(let value): return value == 0 ? nil : String(value)
        case .string(let value): return value.isEmpty ? nil : value
        case .array(let value): return value.isEmpty ? nil : "<array>"
        case .object(let value): return value.isEmpty ? nil : "<object>"
        }
    }

    private static func isSafeRunID(_ runID: String) -> Bool {
        guard !runID.isEmpty,
              !runID.hasPrefix("."),
              !runID.contains("/"),
              !runID.contains("\\"),
              !runID.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 })
        else { return false }
        return true
    }
}
