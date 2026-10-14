import Foundation
import NativeAgentCore
import PersistenceCore

public enum ToolRegistryActions {
    public static func mutate(id: String, dataRoot root: URL, ownerAuthorized: Bool = false,
        body: @escaping @Sendable ([String: JSONValue]?) throws -> [String: JSONValue]) async throws {
        try withRows(root, ownerAuthorized: ownerAuthorized) { rows in
            let index = rows.firstIndex { $0["id"] == .string(id) }
            let fields = try body(index.map { rows[$0] })
            guard fields["id"] == .string(id), ToolRecord(json: .object(fields)) != nil else {
                throw ToolRegistryError.invalidState("The tool mutation has no checked identity or status.")
            }
            if let index { rows[index] = fields } else { rows.append(fields) }
            return (true, ())
        }
    }

    public static func recordUse(id: String, version: String, receipt: JSONValue, codeFault: Bool,
                                 cleanCode: String?, dataRoot root: URL) async throws {
        try await mutate(id: id, dataRoot: root) { current in
            guard var row = current else { throw ToolRegistryError.toolNotFound(id) }
            guard row["codeFingerprint"] == .string(version) else { return row }
            let count: Int64 = if case .int(let count)? = row["useCount"] { count } else { 0 }
            let failures: Int64 = if case .int(let count)? = row["failuresInARow"] { count } else { 0 }
            let fields: [String: JSONValue] = if case .object(let fields) = receipt { fields } else { [:] }
            row["lastUsedAt"] = .string(SwiftNativeToolRegistry.isoTimestamp(Date()))
            row["useCount"] = .int(count + 1)
            row["lastRunVersion"] = .string(version)
            row["lastRun"] = .object(fields.filter { ["status", "effects", "version", "calls", "error", "stopped"].contains($0.key) })
            row["failuresInARow"] = .int(codeFault ? failures + 1 : cleanCode != nil ? 0 : failures)
            if let cleanCode { row["lastCleanCode"] = .string(cleanCode); row["lastCleanVersion"] = .string(version) }
            return row
        }
    }

    public static func drop(id: String, dataRoot root: URL, preview: Bool = false, ownerAuthorized: Bool = false) async throws -> Bool {
        try AbilityStore.withLock {
            let store = AbilityStore(dataRoot: root)
            guard try store.files(kind: .tool).contains(where: { $0.id == id }) else { throw ToolRegistryError.toolNotFound(id) }
            try store.remove(id: id, ownerAuthorized: ownerAuthorized, preview: preview)
            return true
        }
    }

    public static func rollbackVersion(_ value: JSONValue) -> String? {
        guard case .object(let row) = value, case .string(let digest)? = row["previousVersion"] else { return nil }
        return digest
    }

    public static func read(_ tool: ToolRecord) -> JSONValue {
        guard case .object(let row) = tool.toJSON() else { return .null }
        let rollback = rollbackVersion(tool.toJSON()).map(JSONValue.string) ?? .null
        return .object(["id": .string(tool.id), "name": .string(tool.name), "status": .string(tool.status),
            "description": .string(tool.description), "dropped": .bool(false),
            "versions": .object(["current": row["codeFingerprint"] ?? .null, "candidate": row["candidateDigest"] ?? .null,
                "last_clean": row["lastCleanVersion"] ?? .null,
                "retained": .array(rollback == .null ? [] : [.object(["digest": rollback])]),
                "drop": .object(["detail": .string("Permanently deletes this ability, its proposed and previous versions, and its run state.")]),
                "rollback": .object(["target": rollback, "detail": .string(rollback == .null
                    ? "No previous version." : "Swaps the current and previous versions; unadmitted code needs tool.approve, and the owner's off-switch remains.")])])])
    }

    public static func entries(dataRoot root: URL) throws -> [JSONValue] {
        guard case .array(let rows) = try AbilityStore(dataRoot: root).registry(kind: .tool) else {
            throw ToolRegistryError.registryUnreadable(reason: "abilities must contain tool records")
        }
        return rows
    }

    public static func updateTool(id: String, autoRun: Bool, dataRoot root: URL, validate: @escaping @Sendable (ToolRecord) throws -> Void) async throws -> ToolRecord {
        throw NSError(domain: "NativeAgentSwiftOnly", code: -405, userInfo: [
            NSLocalizedDescriptionKey: "Authored-tool auto-run is unavailable; this setting does not control execution. Turn the tool off to stop it."
        ])
    }

    public static func checkEnable(id: String, dataRoot root: URL) async throws {
        try withRows(root) { rows in
            guard let row = rows.first(where: { $0["id"] == .string(id) }) else { throw ToolRegistryError.toolNotFound(id) }
            _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, enabling: true)
            return (false, ())
        }
    }

    public static func restore(id: String, dataRoot root: URL, preview: Bool = false, ownerAuthorized: Bool = false) async throws -> String? {
        try withRows(root, ownerAuthorized: ownerAuthorized, enabling: true) { rows in
            guard let i = rows.firstIndex(where: { $0["id"] == .string(id) }), rows[i]["status"] == .string("disabled") else {
                return (false, nil)
            }
            let status = rows[i]["admission"] == nil ? "proposed" : "active"
            rows[i]["status"] = .string(status); rows[i]["phase"] = .string(status)
            rows[i]["enabledAt"] = .string(SwiftNativeToolRegistry.isoTimestamp(Date()))
            rows[i]["updatedAt"] = rows[i]["enabledAt"]
            return (!preview, status)
        }
    }

    public static func reject(id: String, dataRoot root: URL, preview: Bool = false) async throws -> Bool {
        try AbilityStore.withLock {
            let store = AbilityStore(dataRoot: root)
            guard let proposal = try store.read(id: id, slot: .next), proposal.kind == .tool else { return false }
            if !preview {
                if try store.read(id: id) == nil { try store.remove(id: id) }
                else { try store.remove(id: id, slot: .next) }
            }
            return true
        }
    }

    private static func withRows<T>(_ root: URL, ownerAuthorized: Bool = false, enabling: Bool = false,
        _ body: (inout [[String: JSONValue]]) throws -> (Bool, T)) throws -> T {
        try AbilityStore.withLock {
            let store = AbilityStore(dataRoot: root)
            var rows = try entries(dataRoot: root).map { value in
                guard case .object(let row) = value else { throw ToolRegistryError.registryUnreadable(reason: "tool record must be an object") }
                return row
            }
            let (changed, out) = try body(&rows)
            if changed { try store.saveRegistry(.array(rows.map(JSONValue.object)), kind: .tool, ownerAuthorized: ownerAuthorized, enabling: enabling) }
            else if enabling {
                _ = try CapabilityLifecycle.preservingOwnerOff(.array(rows.map(JSONValue.object)), before: store.registry(kind: .tool),
                    ownerAuthorized: ownerAuthorized, enabling: true)
            }
            return out
        }
    }
}
