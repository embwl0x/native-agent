import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SavedWorkflows.swift` | `SavedWorkflows`: one checked registry schema and stable timestamp sorting for read-only list/projection and historical pack removal; list and Capabilities share exact legacy-seed normalization without changing customized rows or saved bytes; `WorkflowStep`, `WorkflowRecord`; no default seeding or read-side writes; backup/export inclusion, no raw phone sync and workflows privacy coverage are declared here |

// Owns workflows/registry.json: a JSON object array of saved planning templates.
// Pack mutations share this owner and the registry lock. Reads never seed defaults.
// Local backup/export include workflows; phone sync has no raw registry, and
// PrivacyMap lists workflows. ApprovalInbox owns the separate approvals subtree.
// The retired run engine's runs.jsonl and run_state files remain untouched.

extension SavedWorkflows {
    /// The same list as records, for the Capabilities panel; a malformed row
    /// fails the read.
    public func listWorkflowRecords() async throws -> [WorkflowRecord] {
        try await listWorkflows().map(WorkflowRecord.init(row:))
    }
}

public struct WorkflowStep: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String?
    public var status: String?
    public var requiresApproval: Bool?
    public var detail: String?
}

public struct WorkflowRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var status: String?
    public var trigger: String?
    public var steps: [WorkflowStep]
    public var createdAt: String?
    public var updatedAt: String?
}

extension WorkflowRecord {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"),
            description: try row.optionalString("description"), status: try row.optionalString("status"),
            trigger: try row.optionalString("trigger"),
            steps: try row.array("steps").map(WorkflowStep.init(row:)),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"))
    }
}

extension WorkflowStep {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), title: try row.string("title"), kind: try row.optionalString("kind"),
            status: try row.optionalString("status"), requiresApproval: try row.optionalBool("requiresApproval"),
            detail: try row.optionalString("detail"))
    }
}

// MARK: - SwiftNative registry owner

public final class SavedWorkflows: Sendable {
    private let root: URL

    public init(
        root: URL
    ) {
        self.root = root
    }

    private var registryPath: URL { root.appendingPathComponent("workflows/registry.json") }

    /// Only an absent directory entry means empty; damaged or unreadable
    /// saved workflows must survive a list attempt, including a dangling symlink.
    private static func readWorkflowRegistry(_ path: URL, pack: Bool = false) throws -> [[String: JSONValue]] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            var metadata = stat()
            if lstat(path.path, &metadata) != 0, errno == ENOENT { return [] }
            throw error
        }
        guard case .array(let rows) = try JSONValue.parse(data) else {
            throw NSError(domain: pack ? "NativeAgentSwiftOnly" : "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: pack ? "Capability pack registry must be an array: \(path.path)"
                    : "Workflow registry is unavailable: expected a JSON array at \(path.path). Saved bytes were preserved."
            ])
        }
        var seenIDs: Set<String> = []
        return try rows.map {
            guard case .object(let object) = $0, case .string(let id)? = object["id"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenIDs.insert(id).inserted else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Capability pack registry contains an invalid entry: \(path.path)"
                ])
            }
            return object
        }
    }

    public func listWorkflows() async throws -> [JSONValue] {
        let body: @Sendable () async throws -> [JSONValue] = { [registryPath] in
            Self.projectedRegistry(try Self.readWorkflowRegistry(registryPath))
        }
        return try await SwiftNativePersistenceCore.withFileLock(registryPath, body)
    }

    /// Capability aggregation shares the list's read-only legacy normalization.
    package static func readProjection(dataRoot: URL) throws -> [JSONValue] {
        projectedRegistry(try readWorkflowRegistry(dataRoot.appendingPathComponent("workflows/registry.json")))
    }

    private static func projectedRegistry(_ saved: [[String: JSONValue]]) -> [JSONValue] {
        saved.map(projectLegacySeed).enumerated().sorted { lhs, rhs in
            let left = RegistryTimestampSortKey.sortKey(lhs.element)
            let right = RegistryTimestampSortKey.sortKey(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    /// Only the exact original seed (apart from its stamps) claimed execution.
    /// Normalize its read projection, preserving customized rows and saved bytes.
    private static func projectLegacySeed(_ saved: [String: JSONValue]) -> JSONValue {
        guard saved["id"] == .string("memory-capture") else { return .object(saved) }
        let legacy: [String: JSONValue] = [
            "id": .string("memory-capture"),
            "name": .string("Memory Capture"),
            "description": .string("Execute a safe app-owned workflow that routes an objective, writes a memory, and records a trace receipt."),
            "status": .string("active"),
            "trigger": .string("remember this"),
            "steps": .array([
                .object(["id": .string("route"), "title": .string("Route objective"), "kind": .string("router"), "requiresApproval": .bool(false)]),
                .object(["id": .string("memory"), "title": .string("Write semantic memory"), "kind": .string("memory"), "requiresApproval": .bool(false), "layer": .string("semantic")]),
                .object(["id": .string("trace"), "title": .string("Record trace receipt"), "kind": .string("trace"), "requiresApproval": .bool(false)]),
            ]),
        ]
        let candidate = saved.filter { !["createdAt", "updatedAt"].contains($0.key) }
        guard candidate == legacy else { return .object(saved) }
        var projected = saved
        projected["description"] = .string("Saved template for capturing an objective as a semantic memory with a trace receipt. Workflow execution is unavailable.")
        projected["status"] = .string("template")
        return .object(projected)
    }

    package func removePackItems(_ ids: [String], installID: String, packID: String) async throws {
        try await SwiftNativePersistenceCore.withFileLock(registryPath) { [self] in
            var rows = try Self.readWorkflowRegistry(registryPath, pack: true)
            rows.removeAll { row in
                let marked = (row["capabilityPackInstallId"]?.scalarText ?? "") == installID || (row["installedByPack"]?.scalarText ?? "") == packID
                return marked && (ids.isEmpty || ids.contains((row["id"]?.scalarText ?? "")))
            }
            try await SwiftNativePersistenceCore.writeJSON(.array(rows.map { .object($0) }), to: registryPath)
        }
    }

}
