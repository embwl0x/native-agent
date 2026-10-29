import PersistenceCore
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `RunLedger.swift` | `RunLedger`: cross-surface completed-run summary |

// MARK: - RunLedger

/// Native writer for the cross-surface run ledger at `<dataRoot>/runs/runs.json`.
///
/// This is the Swift-native writer: every discrete native run (invoke_codex / invoke_claude
/// sub-agent spawns, agent-swarm dispatches, execution planner LLM calls)
/// appends one row here at completion.
///
/// Contract notes:
/// - Reads accept a bare array or a {"runs": [...]} wrapper. Appends
///   preserve raw rows and write a bare array, newest first.
/// - Rows carry the RunRecord fields the readers decode:
///   id / kind / status / model / prompt / output / error / createdAt /
///   durationSeconds. Swarm rows also retain the selected run reasoningEffort;
///   older readers ignore this optional field.
/// - The ledger is bounded (`maxRetainedRuns`, newest kept) and every
///   read-modify-write runs under the cross-process `withFileLock` flock
///   with an atomic rewrite, so concurrent producers (chat tool loop,
///   background execution executor, Mac UI swarm) can't interleave or tear
///   the file.
/// - A ledger-write failure never fails the run it records. It is a repair
///   owed on the ledger, retained across relaunch, and settled by the next
///   append that lands. A damaged ledger is never replaced by a fresh one:
///   its rows stay where they are until it is repaired or moved aside.
public enum RunLedger {
    /// Cap on retained run records. The Runs page slices to 200;
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

    /// Append one completed run to the ledger. Never throws; see the failure
    /// note on the type. `createdAt` is the run START; `durationSeconds`
    /// spans start → completion.
    public static func append(
        id: String = UUID().uuidString,
        kind: String,
        status: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
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
            "createdAt": .string(NativeTimestampFormat.fractionalZulu(createdAt)),
        ]
        if let model, !model.isEmpty { row["model"] = .string(model) }
        if let reasoningEffort { row["reasoningEffort"] = .string(reasoningEffort) }
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
        do {
            try await SwiftNativePersistenceCore.withFileLock(path) {
                var rows = try Self.readLedgerRows(at: path)
                rows.insert(finalRow, at: 0)
                if rows.count > maxRetainedRuns {
                    rows.removeLast(rows.count - maxRetainedRuns)
                }
                try await SwiftNativePersistenceCore.writeJSON(.array(rows), to: path)
            }
            await RepairOwed.settle(dataRoot, operation: ledgerOperation, evidence: .init(source: "run", id: id)).value
        } catch {
            fputs("[RunLedger] append failed (run \(id), kind \(kind)): \(error)\n", stderr)
            await RepairOwed.owe(dataRoot, id: "run-ledger:" + id, kind: .run, operation: ledgerOperation, owner: path.path,
                           words: "Run \(id) (\(kind), \(status)) was not recorded in the run ledger: \(error.localizedDescription). "
                               + "Its existing rows are untouched; repair or move aside \(path.path) and the next run records again.").value
        }
    }

    static let ledgerOperation = "runs.ledger.append"

    /// Typed reader projection; raw rows remain authoritative for mutation.
    public static func records(from data: Data) throws -> [RunRecord] {
        try JSONDecoder().decode([RunRecord].self,
            from: JSONValue.array(ledgerRows(from: JSONDecoder().decode(JSONValue.self, from: data))).serializedData(pretty: false))
    }

    /// Missing means a first run. Anything that is not the ledger's shape is
    /// damaged history: the append refuses rather than replacing it.
    private static func readLedgerRows(at path: URL) throws -> [JSONValue] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return try ledgerRows(from: JSONValue.parse(data))
    }

    private static func ledgerRows(from raw: JSONValue) throws -> [JSONValue] {
        switch raw {
        case .array(let rows):
            return rows
        case .object(let obj):
            if case .array(let rows)? = obj["runs"] { return rows }
            fallthrough
        default:
            throw PersistenceCoreError.ioFailure("Not a run ledger (expected an array of runs)")
        }
    }

    static func clip(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "\n[truncated \(text.count - cap) chars]"
    }

}
