import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
// Blueprint: | `WorkflowOrchestration.swift` | Saved workflow records: one checked registry schema and stable timestamp sorting for read-only list/projection and pack admission/install/removal; list and Capabilities share exact legacy-seed normalization without changing customized rows or saved bytes; `WorkflowStep`, `WorkflowRecord`; no default seeding or read-side writes; backup/export inclusion, no raw phone sync and workflows privacy coverage are declared here |

// Owns workflows/registry.json: a JSON object array of saved planning templates.
// Pack mutations share this owner and the registry lock. Reads never seed defaults.
// Local backup/export include workflows; phone sync has no raw registry, and
// PrivacyMap lists workflows. ApprovalInbox owns the separate approvals subtree.
// The retired run engine's runs.jsonl and run_state files remain untouched.

extension SwiftNativeWorkflowOrchestrationClient {
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

public final class SwiftNativeWorkflowOrchestrationClient: Sendable {
    private let root: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        root: URL,
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.root = root
        self.persistence = persistence
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
        return try await persistence.withFileLock(registryPath, body)
    }

    /// Capability aggregation shares the list's read-only legacy normalization.
    package static func readProjection(dataRoot: URL, nowISO _: String) throws -> [JSONValue] {
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

    /// The enclosing pack transaction holds the registry lock through admission
    /// and replacement, before any of its catalog or part writes.
    package func preflightPackItems(_ items: [[String: JSONValue]], installID: String) throws {
        let rows = try Self.readWorkflowRegistry(registryPath, pack: true)
        let ids = Set(items.map { Self.scalarString($0, "id") })
        guard items.allSatisfy({
                  if case .string(let id)? = $0["id"] {
                      return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }
                  return false
              }), ids.count == items.count,
              !rows.contains(where: {
                  ids.contains(Self.scalarString($0, "id")) && Self.scalarString($0, "capabilityPackInstallId") != installID
              }) else {
            throw NSError(domain: "NativeAgentSwiftOnly", code: -422, userInfo: [
                NSLocalizedDescriptionKey: "Capability pack items collide with existing entries or have invalid IDs in \(registryPath.lastPathComponent)."
            ])
        }
    }

    package func installPackItems(_ items: [[String: JSONValue]], installID: String, packID: String, nowISO: String) async throws {
        guard !items.isEmpty else { return }
        try await persistence.withFileLock(registryPath) { [self] in
            var rows = try Self.readWorkflowRegistry(registryPath, pack: true)
            let ids = Set(items.map { Self.scalarString($0, "id") }.filter { !$0.isEmpty })
            rows.removeAll { ids.contains(Self.scalarString($0, "id")) }
            for item in items {
                var row = item
                row["status"] = .string(Self.scalarString(row, "status").isEmpty ? "active" : Self.scalarString(row, "status"))
                row["createdAt"] = row["createdAt"] ?? .string(nowISO)
                row["updatedAt"] = .string(nowISO)
                row["installedByPack"] = .string(packID)
                row["capabilityPackInstallId"] = .string(installID)
                rows.append(row)
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: registryPath)
        }
    }

    package func removePackItems(_ ids: [String], installID: String, packID: String) async throws {
        try await persistence.withFileLock(registryPath) { [self] in
            var rows = try Self.readWorkflowRegistry(registryPath, pack: true)
            rows.removeAll { row in
                let marked = Self.scalarString(row, "capabilityPackInstallId") == installID || Self.scalarString(row, "installedByPack") == packID
                return marked && (ids.isEmpty || ids.contains(Self.scalarString(row, "id")))
            }
            try await persistence.writeJSON(.array(rows.map { .object($0) }), to: registryPath)
        }
    }

    private static func scalarString(_ object: [String: JSONValue], _ key: String) -> String {
        switch object[key] {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return ""
        }
    }
}
