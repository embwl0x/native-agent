import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ToolRegistry
// Blueprint: | `CapabilityRecords+Dynamic.swift` | Read-only capability projections; workflow and catalog registries use their owners' checked schemas, never default over damaged saved state |

// Read-only capability aggregation. Authored parts and saved workflow templates
// come from their owners; extra JSON fields remain intact in the projections.
// SavedWorkflows alone reads, validates and mutates the workflow registry.

// MARK: - Helpers (file-local)

private func jsonInt(_ obj: [String: JSONValue], _ key: String) -> Int {
    switch obj[key] ?? .null {
    case .int(let i): return Int(i)
    case .double(let d): return Int(exactly: d.rounded(.towardZero)) ?? 0
    case .bool(let b): return b ? 1 : 0
    default: return 0
    }
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
    // When the character count exceeds the limit, truncate by Unicode scalar.
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
    guard case .array(let rows) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else { return [] }
    return rows.compactMap {
        if case .object(let fields) = $0 { return fields }
        return nil
    }.sorted { lhs, rhs in
        let left = (lhs["updatedAt"]?.stringValue ?? "").isEmpty ? (lhs["createdAt"]?.stringValue ?? "") : (lhs["updatedAt"]?.stringValue ?? "")
        let right = (rhs["updatedAt"]?.stringValue ?? "").isEmpty ? (rhs["createdAt"]?.stringValue ?? "") : (rhs["updatedAt"]?.stringValue ?? "")
        return left > right
    }
}

// MARK: - Saved workflows
//
// Reads saved <dataRoot>/workflows/registry.json rows through SavedWorkflows'
// checked schema and stable timestamp sort. Neither listing nor capability
// aggregation seeds defaults or writes the registry.
public func listWorkflows(dataRoot: URL) async throws -> [[String: JSONValue]] {
    try SavedWorkflows.readProjection(dataRoot: dataRoot).compactMap {
        if case .object(let record) = $0 { return record }
        return nil
    }
}

// MARK: - Capability catalog
//
// Read only the catalog owner's checked records, sorted by name/id.
public func listCapabilityCatalog(dataRoot: URL) async throws -> [[String: JSONValue]] {
    let path = dataRoot
        .appendingPathComponent("catalog", isDirectory: true)
        .appendingPathComponent("registry.json")
    return try await CapabilityCatalogStoreReader.loadRegistryChecked(path).sorted { lhs, rhs in
        let lk = (lhs["name"]?.stringValue ?? "").isEmpty
            ? (lhs["id"]?.stringValue ?? "") : (lhs["name"]?.stringValue ?? "")
        let rk = (rhs["name"]?.stringValue ?? "").isEmpty
            ? (rhs["id"]?.stringValue ?? "") : (rhs["name"]?.stringValue ?? "")
        return lk < rk
    }
}

private func capabilityTrustMetadata(_ source: [String: JSONValue]) -> [String: JSONValue] {
    source.filter { ["sourcePackId", "provenance", "signature"].contains($0.key) }
}

// MARK: - Capability aggregation

// Merge built-in features, installed skills, authored parts, workflows, connectors and catalog records in that order.
public func capabilityRecordsFull(
    dataRoot: URL,
    nowISO: String,
    connectorActionStatuses: @Sendable () async throws -> [String: String]
) async throws -> [[String: JSONValue]] {

    var records: [[String: JSONValue]] = []

    // Built-in features
    for fs in featureSurfaceRecords(nowISO: nowISO) {
        if case .object(let record) = fs.contextLookupJSON() { records.append(record) }
    }

    // Installed skills
    let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot)
    for skill in skills.prefix(230) {
        var rec: [String: JSONValue] = [:]
        let sid = skill.id
        rec["id"] = .string("skill:\(sid)")
        rec["sourceId"] = .string(sid)
        rec["name"] = .string(promptSafeCapabilityText(skill.name))
        rec["kind"] = .string("skill")
        let status = skill.status ?? ""
        rec["status"] = .string(status.isEmpty ? "active" : status)
        rec["description"] = .string(
            promptSafeCapabilityText(skill.description)
        )
        rec["triggers"] = .array(skill.triggers.map(JSONValue.string))
        rec["permissions"] = .array([])
        rec["riskClass"] = .string("routine")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(Int64(skill.useCount ?? 0))
        rec["lastUsedAt"] = skill.lastUsedAt.map(JSONValue.string) ?? .null
        let updated = skill.updatedAt ?? ""
        let created = skill.createdAt ?? ""
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // Authored parts
    let tools = try await listTools(dataRoot: dataRoot)
    for tool in tools.prefix(150) {
        var rec = capabilityTrustMetadata(tool)
        let tid = (tool["id"]?.stringValue ?? "")
        rec["id"] = .string("tool:\(tid)")
        rec["sourceId"] = .string(tid)
        rec["name"] = tool["name"] ?? .null
        rec["kind"] = .string("tool")
        // status = tool.status or tool.phase or "proposal"
        let toolStatus = (tool["status"]?.stringValue ?? "")
        let toolPhase = (tool["phase"]?.stringValue ?? "")
        let resolvedStatus = !toolStatus.isEmpty ? toolStatus :
            (!toolPhase.isEmpty ? toolPhase : "proposal")
        rec["status"] = .string(resolvedStatus)
        rec["description"] = tool["description"] ?? .null
        rec["triggers"] = .array((tool["triggers"]?.arrayValue?.compactMap(\.stringValue) ?? []).map { .string($0) })
        let perms = (tool["permissions"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        rec["permissions"] = .array(perms.map { .string($0) })
        let isRisky = !Set(perms).intersection(riskyToolPermissions).isEmpty
        rec["riskClass"] = .string(isRisky ? "risky_tool" : "app_owned_tool")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(Int64(jsonInt(tool, "useCount")))
        rec["lastUsedAt"] = tool["lastUsedAt"] ?? .null
        let updated = (tool["updatedAt"]?.stringValue ?? "")
        let created = (tool["createdAt"]?.stringValue ?? "")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // Saved workflows
    let workflows = try await listWorkflows(dataRoot: dataRoot)
    for workflow in workflows.prefix(100) {
        var rec = capabilityTrustMetadata(workflow)
        let wid = (workflow["id"]?.stringValue ?? "")
        rec["id"] = .string("workflow:\(wid)")
        rec["sourceId"] = .string(wid)
        rec["name"] = workflow["name"] ?? .null
        rec["kind"] = .string("workflow")
        let wstatus = (workflow["status"]?.stringValue ?? "")
        rec["status"] = .string(wstatus.isEmpty ? "active" : wstatus)
        rec["description"] = workflow["description"] ?? .null
        let trigger = (workflow["trigger"]?.stringValue ?? "")
        rec["triggers"] = trigger.isEmpty ? .array([]) : .array([.string(trigger)])
        rec["permissions"] = .array([])
        // requires approval check on steps
        var anyRequires = false
        if case .array(let steps) = workflow["steps"] ?? .null {
            for step in steps {
                guard case .object(let so) = step else { continue }
                if case .bool(true) = so["requiresApproval"] ?? .null {
                    anyRequires = true; break
                }
            }
        }
        rec["riskClass"] = .string(anyRequires ? "approval_gated" : "app_data")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        rec["lastUsedAt"] = .null
        let updated = (workflow["updatedAt"]?.stringValue ?? "")
        let created = (workflow["createdAt"]?.stringValue ?? "")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // Connector actions
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
        let descSource = action.description ?? "Connector action \(action.id)."
        rec["description"] = .string(promptSafeCapabilityText(descSource, limit: 500))
        rec["triggers"] = .array([
            .string(action.id),
            .string(action.connectorId),
            .string(action.category ?? ""),
        ])
        let risk = action.risk.isEmpty ? "low" : action.risk
        rec["permissions"] = .array([.string(risk)])
        rec["riskClass"] = .string(risk)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        rec["lastUsedAt"] = .null
        // Static actions have no update timestamp.
        rec["updatedAt"] = .null
        records.append(rec)
    }

    // Catalog records
    let catalog = try await listCapabilityCatalog(dataRoot: dataRoot)
    for item in catalog {
        var rec = capabilityTrustMetadata(item)
        let iid = (item["id"]?.stringValue ?? "")
        rec["id"] = .string("catalog:\(iid)")
        rec["sourceId"] = .string(iid)
        rec["name"] = item["name"] ?? .null
        rec["kind"] = .string("catalog")
        let installed = (item["installed"]?.boolValue ?? false)
        rec["status"] = .string(installed ? "installed" : "available")
        rec["description"] = item["description"] ?? .null
        rec["triggers"] = .array([item["name"] ?? .null])
        rec["permissions"] = .array([])
        let riskClass = (item["riskClass"]?.stringValue ?? "")
        rec["riskClass"] = .string(riskClass.isEmpty ? "app_data" : riskClass)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        let installedAt = (item["installedAt"]?.stringValue ?? "")
        rec["lastUsedAt"] = installedAt.isEmpty ? .null : .string(installedAt)
        let created = (item["createdAt"]?.stringValue ?? "")
        let resolvedUpdated = !installedAt.isEmpty ? installedAt : created
        rec["updatedAt"] = resolvedUpdated.isEmpty ? .null : .string(resolvedUpdated)
        records.append(rec)
    }

    // Sort by updatedAt or name descending, preserving merge order for equal keys.
    let indexed = records.enumerated().map { ($0.offset, $0.element) }
    let sorted = indexed.sorted { lhs, rhs in
        let lk = (lhs.1["updatedAt"]?.stringValue ?? "").isEmpty
            ? (lhs.1["name"]?.stringValue ?? "") : (lhs.1["updatedAt"]?.stringValue ?? "")
        let rk = (rhs.1["updatedAt"]?.stringValue ?? "").isEmpty
            ? (rhs.1["name"]?.stringValue ?? "") : (rhs.1["updatedAt"]?.stringValue ?? "")
        if lk != rk { return lk > rk }
        return lhs.0 < rhs.0
    }
    return sorted.map { $0.1 }
}
