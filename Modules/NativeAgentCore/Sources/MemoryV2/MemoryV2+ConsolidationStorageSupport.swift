import Foundation
import GRDB
import PersistenceCore

extension MemoryConsolidationGate {
    // MARK: paths

    static func consolidationDir(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("consolidation", isDirectory: true)
    }

    static func candidatesDir(dataRoot: URL) -> URL {
        consolidationDir(dataRoot: dataRoot)
            .appendingPathComponent("candidates", isDirectory: true)
    }

    static func candidateRoot(dataRoot: URL, runId: String) -> URL {
        candidatesDir(dataRoot: dataRoot).appendingPathComponent(runId, isDirectory: true)
    }

    /// The candidate is a full MemoryStorage data root so the storage actor
    /// opens it with its own public init: <candidateRoot>/memory/memory.sqlite.
    static func candidateDBPath(dataRoot: URL, runId: String) -> URL {
        candidateRoot(dataRoot: dataRoot, runId: runId)
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    /// The live store this gate swaps into.
    static func liveStorePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    static func manifestPath(dataRoot: URL, runId: String) -> URL {
        candidateRoot(dataRoot: dataRoot, runId: runId).appendingPathComponent("manifest.json")
    }

    /// User, 2026-09-06: the swap's applied marker, one row per run, written
    /// INSIDE the swap transaction and living in the live store itself.
    ///
    /// The committed store need not match `manifest.candidateFingerprint`: the
    /// usage veto keeps a row active where the candidate archived it, and the
    /// row-cap prune can drop rows the candidate carried. So `applySwap`'s
    /// crash-window branch cannot recognise a landed swap by fingerprint
    /// equality alone, and any marker written AFTER the commit — the
    /// `applied_fingerprint.txt` file this replaces — leaves a window where a
    /// crash, or a canonical write landing before the next reconcile, makes a
    /// swap that DID commit read as stale: candidate deleted, nothing applied,
    /// the pending USER.md/Spotlight/KG/Fluid Context projections abandoned.
    /// Being part of the transaction, this row is present exactly when the
    /// swap committed, whatever the live fingerprint says afterwards.
    static let appliedMarkerTable = "consolidation_applied"

    /// True when the live store carries THIS run's applied marker. Any read
    /// failure answers false: an unreadable store is not proof of a swap.
    static func swapMarkerApplied(livePath: URL, runId: String) -> Bool {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: livePath.path, configuration: config) else {
            return false
        }
        defer { try? queue.close() }
        let found = try? queue.read { db -> Bool in
            guard try db.tableExists(appliedMarkerTable) else { return false }
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM \(appliedMarkerTable) WHERE run_id = ?)",
                arguments: [runId]
            ) ?? false
        }
        return found ?? false
    }

    static func receiptsDir(dataRoot: URL) -> URL {
        consolidationDir(dataRoot: dataRoot).appendingPathComponent("receipts", isDirectory: true)
    }

    static func receiptPath(dataRoot: URL, runId: String) -> URL {
        receiptsDir(dataRoot: dataRoot).appendingPathComponent("\(runId).json")
    }

    /// Derive the data root from a MemoryStorage's sqlite path. The public
    /// init pins <root>/memory/memory.sqlite, so a parent dir named
    /// "memory" means root is one level above it. The in-memory test init
    /// puts the sqlite in a unique temp dir — treat THAT dir as the root so
    /// gate side-files stay self-contained.
    static func deriveDataRoot(storagePath: URL) -> URL {
        let parent = storagePath.deletingLastPathComponent()
        if parent.lastPathComponent == "memory" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    // MARK: - Cleanup helpers

    static func cleanupCandidate(dataRoot: URL, runId: String) {
        try? FileManager.default.removeItem(at: candidateRoot(dataRoot: dataRoot, runId: runId))
    }

    /// Candidate dirs no approval references, older than `olderThan` —
    /// staging crashed between manifest and card. Sweep them.
    static func sweepOrphans(dataRoot: URL, referenced: Set<String>, olderThan: TimeInterval) {
        let dir = candidatesDir(dataRoot: dataRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for entry in entries {
            let runId = entry.lastPathComponent
            guard !referenced.contains(runId) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: entry)
                logger.info("consolidation sweep: removed orphan candidate \(runId, privacy: .public)")
            }
        }
    }

    // MARK: - Payload helpers

    static func payloadKind(of payload: JSONValue) -> String? {
        MemoryKindBackfill.payloadKind(payload)
    }

    public static func runId(of payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let runId)? = obj["run_id"] else { return nil }
        return runId
    }

    static func makeRunId(now: Date) -> String {
        "\(timestamp(now))-\(UUID().uuidString.lowercased().prefix(8))"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }

    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
