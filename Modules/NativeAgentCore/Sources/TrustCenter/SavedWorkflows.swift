import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SavedWorkflows.swift` | `SavedWorkflows`: one checked registry schema and stable timestamp sorting for read-only list/projection; list and Capabilities project current saved templates without seed normalization; `WorkflowStep`, `WorkflowRecord`; no default seeding or read-side writes; backup/export inclusion, no raw phone sync and workflows privacy coverage are declared here |

// Owns workflows/registry.json: a JSON object array of saved planning templates.
// Reads share the registry lock and never seed defaults.
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
    private static func readWorkflowRegistry(_ path: URL) throws -> [[String: JSONValue]] {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            var metadata = stat()
            if lstat(path.path, &metadata) != 0, errno == ENOENT { return [] }
            throw error
        }
        guard case .array(let rows) = try JSONValue.parse(data) else {
            throw NSError(domain: "WorkflowOrchestration", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Workflow registry is unavailable: expected a JSON array at \(path.path). Saved bytes were preserved."
            ])
        }
        var seenIDs: Set<String> = []
        return try rows.map {
            guard case .object(let object) = $0, case .string(let id)? = object["id"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenIDs.insert(id).inserted else {
                throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                    NSLocalizedDescriptionKey: "Workflow registry contains an invalid entry: \(path.path)"
                ])
            }
            return object
        }
    }

    public func listWorkflows() async throws -> [JSONValue] {
        let body: @Sendable () async throws -> [JSONValue] = { [registryPath] in
            try Self.projectedRegistry(Self.readWorkflowRegistry(registryPath))
        }
        return try await SwiftNativePersistenceCore.withFileLock(registryPath, body)
    }

    /// Capability aggregation shares the checked saved-template projection.
    package static func readProjection(dataRoot: URL) throws -> [JSONValue] {
        try projectedRegistry(readWorkflowRegistry(dataRoot.appendingPathComponent("workflows/registry.json")))
    }

    private static func projectedRegistry(_ saved: [[String: JSONValue]]) throws -> [JSONValue] {
        let dated = try saved.enumerated().map { index, fields in
            let value = JSONValue.object(fields)
            return (index: index, value: value, stamp: try RegistryTimestampSortKey.sortKey(value))
        }
        return dated.sorted { lhs, rhs in
            switch (lhs.stamp, rhs.stamp) {
            case (.some(let left), .some(let right)) where left != right: return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.index < rhs.index
            }
        }.map(\.value)
    }

}
