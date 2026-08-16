import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Durable single-use spend for injection approvals

/// Outcome of a durable spend attempt.
///
/// `.spent` is returned to EXACTLY ONE caller per approval id, ever — across
/// tasks, across processes, across restarts.
public enum InjectionApprovalSpendOutcome: String, Sendable, Equatable {
    /// This caller won the CAS; it — and only it — may proceed to inject.
    case spent
    /// A durable marker for this id already exists. The approval is burned.
    case alreadySpent
    /// The marker could not be read or written (unreadable/corrupt/failed IO).
    /// Fail CLOSED: a spend that cannot be recorded must not authorize a
    /// keystroke, because nothing would stop the next process replaying it.
    case unavailable
}

/// The durable half of injection single-use.
///
/// Why this exists (adversarial review, 2026-08-12): before it, the only
/// restart-surviving evidence that an approved injection had already run was
/// the record's `executedAction`, and the executor writes that only AFTER
/// dispatch returns. A crash in the window between "the click landed" and "the
/// annotation was written" left a resolved-approved record with
/// `executedAction == nil` on disk. The process-global consumption ledger died
/// with the process, and non-text injections carry no secret-vault dependency
/// to block a replay — so the record was reusable and an already-approved
/// click, scroll or keystroke could fire a second time after restart.
///
/// The fix is to move the SPEND to the front of the transaction: the verifier
/// durably marks the approval spent BEFORE it returns `.verified`, so the
/// crash window contains no reusable state. The outcome (`executedAction`) is
/// still written later by the executor — a spend is not an outcome.
///
/// The marker lives in its own sidecar file, not in the record, deliberately:
/// `ApprovalRecord` round-trips through `init(json:)`/`toJSON()` on every
/// resolve/annotate/archive write, which silently drops unknown keys. An
/// authority bit that a later ordinary write can erase is not an authority bit.
public protocol InjectionApprovalSpendingInbox: ApprovalInboxProtocol {
    /// Atomically transition this approval to SPENT. Returns `.spent` to the
    /// first caller and `.alreadySpent` to every caller after it.
    ///
    /// The spend is PERMANENT and is never rolled back — not when the
    /// injection that follows it fails, not when the app crashes mid-flight.
    /// The alternative (roll back on failure) reopens the exact window this
    /// closes, because a crash cannot run rollback code. A re-ask costs User a
    /// sentence; a replayed keystroke costs whatever the keystroke does.
    func consumeInjectionApproval(
        id: String,
        digest: String,
        tool: String,
        surface: String
    ) async -> InjectionApprovalSpendOutcome
}

extension SwiftNativeApprovalInbox: InjectionApprovalSpendingInbox {
    public static let injectionSpendSchema = "mac-injection-approval-spend.v1"

    /// Markers are bounded. The requests file itself keeps only the newest 300
    /// records (see `_createImpl`), so a marker whose record has already aged
    /// out of the queue can never be presented again — pruning the oldest
    /// entries well above that bound cannot resurrect a live approval.
    static let injectionSpendCap = 2000

    /// `<root>/workflows/approvals/injection_spends.json`
    /// Internal + test-only (gpt-5.5 NIT): no external diagnostics caller.
    nonisolated var injectionSpendPath: URL {
        root
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("injection_spends.json")
    }

    public func consumeInjectionApproval(
        id: String,
        digest: String,
        tool: String,
        surface: String
    ) async -> InjectionApprovalSpendOutcome {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return .unavailable }
        let path = injectionSpendPath
        let now = clock()
        let persistence = self.persistence
        do {
            // The flock IS the CAS: read-check-write happens entirely inside
            // one exclusive lock on the marker file, and `withFileLock` opens a
            // fresh descriptor per acquisition, so two concurrent tasks in THIS
            // process exclude each other exactly as two processes do.
            return try await persistence.withFileLock(path) {
                try await Self._consumeInjectionApprovalImpl(
                    id: trimmedID,
                    digest: digest,
                    tool: tool,
                    surface: surface,
                    persistence: persistence,
                    path: path,
                    now: now
                )
            }
        } catch {
            return .unavailable
        }
    }

    /// Read-only probe for tests only (gpt-5.5 NIT: kept internal). Never mutates.
    func injectionApprovalSpend(id: String) async -> JSONValue? {
        guard let spends = try? Self.loadSpends(at: injectionSpendPath) else { return nil }
        return spends[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    private nonisolated static func _consumeInjectionApprovalImpl(
        id: String,
        digest: String,
        tool: String,
        surface: String,
        persistence: any PersistenceCoreProtocol,
        path: URL,
        now: Date
    ) async throws -> InjectionApprovalSpendOutcome {
        // A marker store that exists but cannot be parsed fails CLOSED: the
        // caller gets `.unavailable` (via the thrown error) and no injection
        // runs, rather than an empty map that would un-spend every prior
        // approval on disk.
        var spends = try loadSpends(at: path)
        if spends[id] != nil { return .alreadySpent }

        spends[id] = .object([
            "digest": .string(digest),
            "tool": .string(tool),
            "surface": .string(surface),
            "spentAt": .string(isoTimestamp(now)),
        ])
        if spends.count > injectionSpendCap {
            let ordered = spends.sorted { lhs, rhs in
                spentAtStamp(lhs.value) < spentAtStamp(rhs.value)
            }
            for entry in ordered.prefix(spends.count - injectionSpendCap) {
                spends.removeValue(forKey: entry.key)
            }
        }
        try await persistence.writeJSON(
            .object([
                "schema": .string(injectionSpendSchema),
                "spends": .object(spends),
            ]),
            to: path
        )
        return .spent
    }

    nonisolated static func loadSpends(at path: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ApprovalInboxError.unavailable(
                underlying: "injection spend store unreadable: \(error.localizedDescription)"
            )
        }
        guard !data.isEmpty else {
            throw ApprovalInboxError.malformedResponse(
                "injection spend store exists but is empty"
            )
        }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw ApprovalInboxError.malformedResponse(
                "injection spend store contains malformed JSON: \(error.localizedDescription)"
            )
        }
        guard case .object(let root) = raw else {
            throw ApprovalInboxError.malformedResponse("injection spend store is not a JSON object")
        }
        guard root["schema"] == .string(injectionSpendSchema) else {
            throw ApprovalInboxError.malformedResponse(
                "injection spend store has an unsupported schema"
            )
        }
        guard case .object(let spends)? = root["spends"] else {
            throw ApprovalInboxError.malformedResponse("injection spend store has no spends map")
        }
        for (id, value) in spends {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  case .object(let marker) = value,
                  case .string(let digest)? = marker["digest"], !digest.isEmpty,
                  case .string(let tool)? = marker["tool"], !tool.isEmpty,
                  case .string(let surface)? = marker["surface"], !surface.isEmpty,
                  case .string(let spentAt)? = marker["spentAt"], !spentAt.isEmpty else {
                throw ApprovalInboxError.malformedResponse(
                    "injection spend store contains a malformed marker"
                )
            }
        }
        return spends
    }

    private nonisolated static func spentAtStamp(_ value: JSONValue) -> String {
        guard case .object(let obj) = value, case .string(let s)? = obj["spentAt"] else { return "" }
        return s
    }
}
