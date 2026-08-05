import Foundation

// MARK: - RunLedger

/// Native writer for the cross-surface run ledger at `<dataRoot>/runs/runs.json`.
///
/// This is the Swift-native writer: every discrete native run (invoke_codex / invoke_claude
/// sub-agent spawns, agent-swarm dispatches, execution planner LLM calls)
/// appends one row here at completion.
///
/// Contract notes:
/// - The on-disk shape is a BARE ARRAY of row objects, newest-first — the
///   shape `NativeClient.getRunsStrict()` already parses. Readers are not
///   changed by this writer. If a daemon-era `{"runs": [...]}` wrapper file
///   is ever encountered, its rows are preserved and the file is rewritten
///   as a bare array.
/// - Rows carry the RunRecord fields the readers decode:
///   id / kind / status / model / prompt / output / error / createdAt /
///   durationSeconds. Unknown extra keys are tolerated by JSONDecoder, but
///   this writer sticks to the known set.
/// - The ledger is bounded (`maxRetainedRuns`, newest kept) and every
///   read-modify-write runs under the cross-process `withFileLock` flock
///   with an atomic rewrite, so concurrent producers (chat tool loop,
///   background execution executor, Mac UI swarm) can't interleave or tear
///   the file.
/// - Appends are BEST-EFFORT by design: a ledger-write failure must never
///   fail the run it records. Failures are logged loudly to stderr instead
///   of thrown.
public enum RunLedger {
    /// Cap on retained run records. The daemon-era reader slices to 200;
    /// keep a deeper on-disk tail so the UI cap isn't also the history cap.
    public static let maxRetainedRuns = 500

    /// Clip caps for the free-text payloads. Prompts on the sub-agent seams
    /// embed packed context and Workshop execution planner prompts embed instructions —
    /// unclipped they'd dominate the file (500 rows × ~100 KB) and ride into
    /// the iOS snapshot. The Runs UI shows a one-line preview; a clipped
    /// payload is honest enough and the full text lives in the per-run audit
    /// files (`from_codex/`, `from_claude/`) where they exist.
    static let promptCap = 4_000
    static let outputCap = 8_000
    static let errorCap = 4_000

    /// Append one completed run to the ledger. Never throws; see best-effort
    /// note on the type. `createdAt` is the run START; `durationSeconds`
    /// spans start → completion.
    public static func append(
        id: String = UUID().uuidString,
        kind: String,
        status: String,
        model: String? = nil,
        prompt: String? = nil,
        output: String? = nil,
        error: String? = nil,
        createdAt: Date,
        durationSeconds: Double? = nil,
        dataRoot: URL = defaultDataRoot()
    ) async {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "kind": .string(kind),
            "status": .string(status),
            "createdAt": .string(Self.isoTimestamp(createdAt)),
        ]
        if let model, !model.isEmpty { row["model"] = .string(model) }
        if let prompt { row["prompt"] = .string(Self.clip(prompt, cap: promptCap)) }
        if let output { row["output"] = .string(Self.clip(output, cap: outputCap)) }
        if let error { row["error"] = .string(Self.clip(error, cap: errorCap)) }
        if let durationSeconds { row["durationSeconds"] = .double(durationSeconds) }
        // Immutable snapshot — the withFileLock body is a @Sendable closure
        // and can't capture the mutable `row`.
        let finalRow: JSONValue = .object(row)

        let path = dataRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent("runs.json")
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                let raw = Self.readLedgerJSON(at: path)
                var rows: [JSONValue]
                switch raw {
                case .array(let existing):
                    rows = existing
                case .object(let obj):
                    // Daemon-era wrapper tolerance: keep the rows, drop the
                    // wrapper (readers accept both; the writer emits bare).
                    if case .array(let existing)? = obj["runs"] {
                        rows = existing
                    } else {
                        rows = []
                    }
                default:
                    rows = []
                }
                rows.insert(finalRow, at: 0)
                if rows.count > maxRetainedRuns {
                    rows.removeLast(rows.count - maxRetainedRuns)
                }
                try await persistence.writeJSON(.array(rows), to: path)
            }
        } catch {
            fputs("[RunLedger] append failed (run \(id), kind \(kind)): \(error)\n", stderr)
        }
    }

    /// Read the existing ledger, distinguishing a MISSING file (normal first
    /// run → empty) from a CORRUPT one. Scoped to RunLedger (audit 2026-07-21):
    /// `readJSON`'s default-on-any-failure contract is right for its many other
    /// callers, but here one corrupted runs.json would silently wipe up to
    /// `maxRetainedRuns` retained rows on the next append. A corrupt file is
    /// preserved as a timestamped sibling BEFORE the rewrite (bounded to the
    /// newest `maxCorruptBackups`) and the loss is logged loudly.
    private static func readLedgerJSON(at path: URL) -> JSONValue {
        guard FileManager.default.fileExists(atPath: path.path) else { return .array([]) }
        if let data = try? Data(contentsOf: path), let parsed = try? JSONValue.parse(data) {
            return parsed
        }
        fputs(
            "[RunLedger] \(path.path) exists but does not parse — preserving it as a .corrupt-*.bak sibling and starting a fresh ledger (previous rows survive in the backup)\n",
            stderr
        )
        preserveCorruptLedger(at: path)
        return .array([])
    }

    /// Corrupt-ledger backups retained beside runs.json (bounded writer).
    private static let maxCorruptBackups = 3

    /// Copy the unreadable ledger to a timestamped sibling and prune older
    /// backups past `maxCorruptBackups`. Best-effort: a backup failure must
    /// never block the append it protects.
    private static func preserveCorruptLedger(at path: URL) {
        let fm = FileManager.default
        let stamp = isoTimestamp(Date()).replacingOccurrences(of: ":", with: "-")
        let backup = path.deletingLastPathComponent()
            .appendingPathComponent("\(path.lastPathComponent).corrupt-\(stamp).bak")
        try? fm.copyItem(at: path, to: backup)
        guard let siblings = try? fm.contentsOfDirectory(
            at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ) else { return }
        let backups = siblings.filter {
            $0.lastPathComponent.hasPrefix("\(path.lastPathComponent).corrupt-")
                && $0.pathExtension == "bak"
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in backups.dropFirst(maxCorruptBackups) {
            try? fm.removeItem(at: stale)
        }
    }

    static func clip(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "\n[truncated \(text.count - cap) chars]"
    }

    /// Fractional-second ISO-8601 so same-second rows still sort stably under
    /// the reader's lexicographic `createdAt` sort.
    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
