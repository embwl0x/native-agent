import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ToolRegistry
// Blueprint: | `CapabilityRecords+Dynamic.swift` | Owner-derived capability rows preserve missing evidence. |

// Aggregate owner projections without altering extra fields; SavedWorkflows alone validates and mutates its registry.

// MARK: - Helpers (file-local)

private func capabilityStatus(_ row: JSONRow) throws -> JSONValue {
    guard let status = try row.optionalString("status") else { return .null }
    guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw JSONRow.Malformed.field("status")
    }
    return .string(status)
}

// MARK: - Risky tool permissions
public let riskyToolPermissions: Set<String> = [
    "network_localhost", "network_public", "network",
    "shell", "computer_files", "arbitrary_file_write",
]

// MARK: - Prompt-safe capability text

/// Normalize NUL/whitespace and neutralize prompt markers in metadata.
public func promptSafeCapabilityText(_ raw: String?, limit: Int = 500) -> String {
    let source = (raw ?? "").replacingOccurrences(of: "\u{0000}", with: " ")
    let tokens = source.unicodeScalars.split(
        whereSeparator: { CharacterSet.whitespacesAndNewlines.contains($0) }
    ).map { String(String.UnicodeScalarView($0)) }
    var text = tokens.joined(separator: " ")
    let lowered = text.lowercased()
    let markers = [
        "ignore previous", "system prompt", "developer message",
        "you are now", "<system", "</system", "```",
    ]
    let markerHits = markers.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
    if markerHits > 0 {
        let pattern = "(ignore previous|system prompt|developer message|you are now|</?system[^>]*>|```)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "[metadata]"
            )
        }
    }
    if text.count > limit {
        let scalars = Array(text.unicodeScalars)
        if scalars.count > limit {
            let cut = scalars.prefix(limit)
            return String(String.UnicodeScalarView(cut))
        }
    }
    return text
}


// MARK: - Authored abilities

public func listTools(
    dataRoot: URL
) async throws -> [[String: JSONValue]] {
    let rows = try Parts(root: dataRoot).rows(kind: .part)
    let dated = try rows.enumerated().map { index, value in
        (index: index, fields: value, stamp: try RegistryTimestampSortKey.sortKey(.object(value)))
    }
    return dated.sorted { lhs, rhs in
        switch (lhs.stamp, rhs.stamp) {
        case (.some(let left), .some(let right)) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.index < rhs.index
        }
    }.map(\.fields)
}

// MARK: - Saved workflows
// Listing saved workflows must not seed defaults or mutate authority.
public func listWorkflows(dataRoot: URL) async throws -> [[String: JSONValue]] {
    try SavedWorkflows.readProjection(dataRoot: dataRoot).map {
        _ = try WorkflowRecord(row: $0)
        return try JSONRow($0).fields
    }
}


private func capabilityTrustMetadata(_ source: [String: JSONValue]) -> [String: JSONValue] {
    source.filter { ["provenance", "signature"].contains($0.key) }
}

// MARK: - Capability aggregation

public func capabilityRecordsFull(
    dataRoot: URL,
    nowISO: String,
    connectorActionStatuses: @Sendable () async throws -> [String: String]
) async throws -> [[String: JSONValue]] {

    var records: [[String: JSONValue]] = []

    for fs in featureSurfaceRecords(nowISO: nowISO) {
        if case .object(let record) = fs.contextLookupJSON() { records.append(record) }
    }

    let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot)
    for skill in skills.prefix(230) {
        var rec: [String: JSONValue] = [:]
        let sid = skill.id
        rec["id"] = .string("skill:\(sid)")
        rec["sourceId"] = .string(sid)
        rec["name"] = .string(promptSafeCapabilityText(skill.name))
        rec["kind"] = .string("skill")
        rec["status"] = skill.status.map(JSONValue.string) ?? .null
        rec["description"] = .string(promptSafeCapabilityText(skill.description))
        rec["triggers"] = .array(skill.triggers.map(JSONValue.string))
        rec["permissions"] = .array([])
        rec["riskClass"] = .string("routine")
        rec["autoload"] = .bool(false)
        rec["useCount"] = skill.useCount.map { .int(Int64($0)) } ?? .null
        rec["lastUsedAt"] = skill.lastUsedAt.map(JSONValue.string) ?? .null
        rec["updatedAt"] = skill.updatedAt.map(JSONValue.string) ?? .null
        records.append(rec)
    }

    let tools = try await listTools(dataRoot: dataRoot)
    for tool in tools.prefix(150) {
        let row = try JSONRow(.object(tool))
        var rec = capabilityTrustMetadata(tool)
        let tid = try row.string("id")
        rec["id"] = .string("tool:\(tid)")
        rec["sourceId"] = .string(tid)
        rec["name"] = tool["name"] ?? .null
        rec["kind"] = .string("tool")
        rec["status"] = try capabilityStatus(row)
        rec["description"] = tool["description"] ?? .null
        rec["triggers"] = try row.optionalStrings("triggers").map { .array($0.map(JSONValue.string)) } ?? .null
        let perms = try row.optionalStrings("permissions")
        rec["permissions"] = perms.map { .array($0.map(JSONValue.string)) } ?? .null
        rec["riskClass"] = perms.map {
            .string(Set($0).intersection(riskyToolPermissions).isEmpty ? "app_owned_tool" : "risky_tool")
        } ?? .null
        rec["autoload"] = .bool(false)
        let useCount = try row.optionalInt("useCount")
        if let useCount, useCount < 0 { throw JSONRow.Malformed.field("useCount") }
        rec["useCount"] = useCount.map { .int(Int64($0)) } ?? .null
        rec["lastUsedAt"] = tool["lastUsedAt"] ?? .null
        rec["updatedAt"] = tool["updatedAt"] ?? .null
        records.append(rec)
    }

    let workflows = try await listWorkflows(dataRoot: dataRoot)
    for workflow in workflows.prefix(100) {
        let row = try JSONRow(.object(workflow))
        var rec = capabilityTrustMetadata(workflow)
        let wid = try row.string("id")
        rec["id"] = .string("workflow:\(wid)")
        rec["sourceId"] = .string(wid)
        rec["name"] = workflow["name"] ?? .null
        rec["kind"] = .string("workflow")
        rec["status"] = try capabilityStatus(row)
        rec["description"] = workflow["description"] ?? .null
        rec["triggers"] = try row.optionalString("trigger").map { .array([.string($0)]) } ?? .null
        rec["permissions"] = .array([])
        let requirements = try row.array("steps").map { try JSONRow($0).optionalBool("requiresApproval") }
        rec["riskClass"] = requirements.contains(true) ? .string("approval_gated")
            : requirements.contains(nil) ? .null : .string("app_data")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .null
        rec["lastUsedAt"] = .null
        rec["updatedAt"] = workflow["updatedAt"] ?? .null
        records.append(rec)
    }

    let actionStatuses = try await connectorActionStatuses()
    for action in connectorActionDescriptors().prefix(200) {
        var rec: [String: JSONValue] = [:]
        rec["id"] = .string("connector_action:\(action.id)")
        rec["sourceId"] = .string(action.id)
        let nameSource = action.name ?? action.id
        rec["name"] = .string(promptSafeCapabilityText(nameSource, limit: 160))
        rec["kind"] = .string("tool")
        guard let status = actionStatuses[action.id] else {
            throw CapabilityTrustError.unavailable
        }
        rec["status"] = .string(status)
        rec["description"] = action.description.map { .string(promptSafeCapabilityText($0, limit: 500)) } ?? .null
        rec["triggers"] = .array(([action.id, action.connectorId] + [action.category].compactMap { $0 }).map(JSONValue.string))
        rec["permissions"] = action.risk.isEmpty ? .null : .array([.string(action.risk)])
        rec["riskClass"] = action.risk.isEmpty ? .null : .string(action.risk)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .null
        rec["lastUsedAt"] = .null
        // Static actions have no update timestamp.
        rec["updatedAt"] = .null
        records.append(rec)
    }

    // All consumers share checked rows so alternate projections cannot bypass validation.
    for record in records { _ = try CapabilityRecord(catalogRow: record) }

    // Stable sorting preserves absent dates/names and equal-key merge order without rewriting evidence.
    let indexed = records.enumerated().map { ($0.offset, $0.element) }
    let sorted = indexed.sorted { lhs, rhs in
        let lk = lhs.1["updatedAt"]?.stringValue ?? lhs.1["name"]?.stringValue
        let rk = rhs.1["updatedAt"]?.stringValue ?? rhs.1["name"]?.stringValue
        switch (lk, rk) {
        case (.some(let left), .some(let right)) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.0 < rhs.0
        }
    }
    return sorted.map { $0.1 }
}
