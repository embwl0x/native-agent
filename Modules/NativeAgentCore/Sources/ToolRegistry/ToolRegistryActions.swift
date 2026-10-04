import Foundation
import NativeAgentCore
import PersistenceCore

public enum ToolRegistryActions {
    /// Read both supported registry shapes without mutating the store.
    public static func entries(dataRoot root: URL) throws -> [JSONValue] {
        let rows = try readRows(root.appendingPathComponent("tools/registry.json"))
        return rows.map { JSONValue(fromFoundation: $0) }
    }

    public static func updateTool(id: String, autoRun: Bool, dataRoot root: URL, validate: @escaping @Sendable (ToolRecord) throws -> Void) async throws -> ToolRecord {
        throw NSError(domain: "NativeAgentSwiftOnly", code: -405, userInfo: [
            NSLocalizedDescriptionKey: "Authored-tool auto-run is unavailable; this setting does not control execution. Quarantine the tool to stop it."
        ])
    }

    /// A proposal's row (`tool.propose`), replacing the one with its id, kept
    /// stamps and counts merged in; the Tools page lists it as the registry has it.
    public static func upsertProposal(_ record: JSONValue, dataRoot root: URL) async throws {
        let regPath = root.appendingPathComponent("tools/registry.json")
        let data = try record.serializedData(pretty: false)
        try await SwiftNativePersistenceCore().withFileLock(regPath) {
            guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var rows = try readRows(regPath)
            if let idx = rows.firstIndex(where: { ($0["id"] as? String) == row["id"] as? String }) {
                rows[idx].merge(row) { $1 }
            } else {
                rows.append(row)
            }
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            try out.write(to: regPath, options: .atomic)
        }
    }

    // MARK: - Lifecycle (`CapabilityLifecycle`), the same one her skills have

    /// A call of a tool she wrote is a use. Returns the one MY QUEUE line
    /// when this call made its failures in a row reach the streak.
    public static func recordCall(id: String, failed: Bool, cleanCode: String? = nil, dataRoot root: URL) async throws -> String? {
        try await withRows(root) { rows in
            guard let i = rows.firstIndex(where: { ($0["id"] as? String) == id }) else { return (false, nil) }
            let streak = failed ? ((rows[i]["failuresInARow"] as? Int) ?? 0) + 1 : 0
            rows[i]["lastUsedAt"] = SwiftNativeToolRegistry.isoTimestamp(Date())
            rows[i]["useCount"] = ((rows[i]["useCount"] as? Int) ?? 0) + 1
            rows[i]["failuresInARow"] = streak
            if let cleanCode { rows[i]["lastCleanCode"] = cleanCode }
            return (true, streak == CapabilityLifecycle.toolFailureStreak
                ? "\(id) failed twice in a row; improve it? (tool.quarantine, then tool.propose or tool.rollback)" : nil)
        }
    }

    /// Active and unused for 30 days → archived, never deleted: it doesn't
    /// run and isn't offered, and tool.restore brings it back. One line each.
    public static func upkeep(dataRoot root: URL, now: Date = Date()) async throws -> [String] {
        try await withRows(root) { rows in
            var lines: [String] = []
            for i in rows.indices where rows[i]["status"] as? String == "active" {
                let used = [rows[i]["lastUsedAt"], rows[i]["updatedAt"], rows[i]["createdAt"]].lazy.compactMap { $0 as? String }.first
                guard CapabilityLifecycle.isUnused(used: used, enabled: [rows[i]["promotedAt"] as? String, rows[i]["enabledAt"] as? String],
                                                   now: now) else { continue }
                rows[i]["status"] = CapabilityLifecycle.archived
                rows[i]["archivedAt"] = SwiftNativeToolRegistry.isoTimestamp(now)
                lines.append("\(rows[i]["id"] as? String ?? "a tool") archived: unused for \(CapabilityLifecycle.unusedDays) days, "
                    + "not deleted; tool.restore brings it back")
            }
            return (!lines.isEmpty, lines)
        }
    }

    /// Archived → active again, its clock started over; false when it isn't
    /// archived. `preview` answers the same and writes nothing.
    public static func restore(id: String, dataRoot root: URL, preview: Bool = false) async throws -> Bool {
        try await withRows(root) { rows in
            guard let i = rows.firstIndex(where: { ($0["id"] as? String) == id }),
                  rows[i]["status"] as? String == CapabilityLifecycle.archived else { return (false, false) }
            if preview { return (false, true) }
            rows[i]["status"] = "active"
            rows[i]["enabledAt"] = SwiftNativeToolRegistry.isoTimestamp(Date())
            rows[i].removeValue(forKey: "archivedAt")
            return (true, true)
        }
    }

    /// The SHA-256 of the code its last clean call ran, kept for rollback.
    public static func lastCleanCode(id: String, dataRoot root: URL) -> String? {
        let regPath = root.appendingPathComponent("tools/registry.json")
        guard FileManager.default.fileExists(atPath: regPath.path) else { return nil }
        return ((try? readRows(regPath)) ?? []).first { ($0["id"] as? String) == id }?["lastCleanCode"] as? String
    }

    /// Her archived tools, id and description, for find.
    public static func archived(dataRoot root: URL) -> [(id: String, about: String)] {
        let regPath = root.appendingPathComponent("tools/registry.json")
        guard FileManager.default.fileExists(atPath: regPath.path) else { return [] }
        return ((try? readRows(regPath)) ?? []).compactMap { row in
            guard row["status"] as? String == CapabilityLifecycle.archived, let id = row["id"] as? String else { return nil }
            return (id, row["description"] as? String ?? "")
        }
    }

    /// The rows under the registry's lock; written back only when `body` says it changed them.
    private static func withRows<T: Sendable>(_ root: URL, _ body: @escaping @Sendable (inout [[String: Any]]) -> (Bool, T)) async throws -> T {
        let regPath = root.appendingPathComponent("tools/registry.json")
        return try await SwiftNativePersistenceCore().withFileLock(regPath) {
            var rows = try readRows(regPath)
            let (changed, out) = body(&rows)
            if changed {
                try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted]).write(to: regPath, options: .atomic)
            }
            return out
        }
    }

    /// The registry's rows; absent is empty, unreadable bytes are an error, never empty.
    private static func readRows(_ regPath: URL) throws -> [[String: Any]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: regPath.path) else { return [] }
        let data = try Data(contentsOf: regPath)
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "updateTool: tools registry is malformed"
            ])
        }
        if let arr = raw as? [[String: Any]] { return arr }
        if let dict = raw as? [String: Any], let arr = dict["tools"] as? [[String: Any]] { return arr }
        throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
            NSLocalizedDescriptionKey: "updateTool: tools registry must contain an array of records"
        ])
    }

}
