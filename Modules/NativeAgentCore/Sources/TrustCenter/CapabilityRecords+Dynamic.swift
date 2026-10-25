import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import ToolRegistry
import WorkflowOrchestration
// Blueprint: | `CapabilityRecords+Dynamic.swift` | Read-only capability projections; workflow and catalog registries use their owners' checked schemas, never default over damaged saved state |

// Read-only capability aggregation. Authored parts and saved workflow templates
// come from their owners; extra JSON fields remain intact in the projections.
// WorkflowOrchestration alone reads, validates and mutates the workflow registry.

// MARK: - Helpers (file-local)

private func jsonString(_ obj: [String: JSONValue], _ key: String) -> String {
    if case .string(let s) = obj[key] ?? .null { return s }
    return ""
}

private func jsonOptionalString(_ obj: [String: JSONValue], _ key: String) -> String? {
    if case .string(let s) = obj[key] ?? .null { return s }
    return nil
}

private func jsonInt(_ obj: [String: JSONValue], _ key: String) -> Int {
    switch obj[key] ?? .null {
    case .int(let i): return Int(i)
    case .double(let d): return Int(exactly: d.rounded(.towardZero)) ?? 0
    case .bool(let b): return b ? 1 : 0
    default: return 0
    }
}

private func jsonBool(_ obj: [String: JSONValue], _ key: String, default defaultValue: Bool = false) -> Bool {
    switch obj[key] ?? .null {
    case .bool(let b): return b
    case .null: return defaultValue
    default: return defaultValue
    }
}

private func jsonStringArray(_ obj: [String: JSONValue], _ key: String) -> [String] {
    if case .array(let arr) = obj[key] ?? .null {
        return arr.compactMap { v -> String? in
            if case .string(let s) = v { return s }
            return nil
        }
    }
    return []
}

// MARK: - Risk class set (port of RISKY_TOOL_PERMISSIONS)
//
// Mirrors the retired daemon:
//   RISKY_TOOL_PERMISSIONS = {"network_localhost", "network_public",
//                             "network", "shell", "computer_files",
//                             "arbitrary_file_write"}
public let riskyToolPermissions: Set<String> = [
    "network_localhost", "network_public", "network",
    "shell", "computer_files", "arbitrary_file_write",
]

// MARK: - Prompt-safe capability text (port of prompt_safe_capability_text)
//
// Mirrors the static method at the retired daemon:
//   text = " ".join(str(value or "").replace("\x00", " ").split())
//   if any prompt-injection marker present, replace markers with [metadata]
//   return text[:limit]
//
// Python's str.split() with no args splits on any run of whitespace and
// drops empty tokens — `Array.split(separator:omittingEmptySubsequences:)`
// with a CharacterSet predicate matches.
public func promptSafeCapabilityText(_ raw: String?, limit: Int = 500) -> String {
    let source = (raw ?? "").replacingOccurrences(of: "\u{0000}", with: " ")
    // Python's split() with no args splits on ANY whitespace (incl. tabs,
    // newlines, vertical tabs, NBSP NOT included — see CPython str.split docs)
    // and drops empty tokens. .whitespacesAndNewlines is the closest match.
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
        // Python: re.sub(r"(?i)(ignore previous|system prompt|developer message|you are now|</?system[^>]*>|```)", "[metadata]", text)
        // NSRegularExpression with caseInsensitive matches the (?i) flag.
        let pattern = "(ignore previous|system prompt|developer message|you are now|</?system[^>]*>|```)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: "[metadata]"
            )
        }
    }
    // Python str[:limit] — slice by code-point count? Actually Python str
    // slicing uses UTF-32 code points (CPython 3.4+). We match by Character
    // (extended grapheme cluster) for human-meaningful truncation, since the
    // ASCII-only happy path is identical either way and the records are
    // overwhelmingly ASCII. For full byte-parity on multi-codepoint emoji
    // strings, swap to .unicodeScalars.prefix(limit) — but the Python source
    // also has the same Character-vs-codepoint ambiguity for grapheme clusters.
    if text.count > limit {
        // Match Python's character-by-character slicing (code-point based).
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
    dataRoot: URL,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    guard case .array(let rows) = try AbilityStore(dataRoot: dataRoot).registry(kind: .part) else { return [] }
    return rows.compactMap {
        if case .object(let fields) = $0 { return fields }
        return nil
    }.sorted { lhs, rhs in
        let left = jsonString(lhs, "updatedAt").isEmpty ? jsonString(lhs, "createdAt") : jsonString(lhs, "updatedAt")
        let right = jsonString(rhs, "updatedAt").isEmpty ? jsonString(rhs, "createdAt") : jsonString(rhs, "updatedAt")
        return left > right
    }
}

// MARK: - Source #5: list_workflows
//
// Reads saved <dataRoot>/workflows/registry.json rows through WorkflowOrchestration's
// checked schema and stable timestamp sort. Neither listing nor capability
// aggregation seeds defaults or writes the registry.
public func listWorkflows(
    dataRoot: URL,
    nowISO: String
) async throws -> [[String: JSONValue]] {
    try SwiftNativeWorkflowOrchestrationClient.readProjection(dataRoot: dataRoot, nowISO: nowISO).compactMap {
        if case .object(let record) = $0 { return record }
        return nil
    }
}

// MARK: - Source #7: list_capability_catalog
//
// Read the catalog owner's checked schema, merge defaults, sort by name/id.
public func listCapabilityCatalog(
    dataRoot: URL,
    nowISO: String,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    let path = dataRoot
        .appendingPathComponent("catalog", isDirectory: true)
        .appendingPathComponent("registry.json")
    let savedDicts = try await CapabilityCatalogStoreReader.loadRegistryChecked(path, persistence: persistence)

    var byID: [String: [String: JSONValue]] = [:]
    for item in savedDicts {
        byID[jsonString(item, "id")] = item
    }

    var merged: [[String: JSONValue]] = []
    var mergedIDs: Set<String> = []
    for defaultItem in defaultCatalogItems(nowISO: nowISO) {
        var record = defaultItem
        if let override = byID[jsonString(defaultItem, "id")] {
            for (k, v) in override { record[k] = v }
        }
        let id = jsonString(record, "id")
        if !id.isEmpty { mergedIDs.insert(id) }
        merged.append(record)
    }
    for item in savedDicts {
        let id = jsonString(item, "id")
        if !mergedIDs.contains(id) {
            merged.append(item)
            if !id.isEmpty { mergedIDs.insert(id) }
        }
    }
    return merged.sorted { lhs, rhs in
        let lk = jsonString(lhs, "name").isEmpty
            ? jsonString(lhs, "id") : jsonString(lhs, "name")
        let rk = jsonString(rhs, "name").isEmpty
            ? jsonString(rhs, "id") : jsonString(rhs, "name")
        return lk < rk
    }
}

/// Port of the retired daemon default_catalog_items(). Three
/// static catalog items. `nowISO` is the static `now_iso()` stamp.
public func defaultCatalogItems(nowISO: String) -> [[String: JSONValue]] {
    let now: JSONValue = .string(nowISO)
    return [
        [
            "id": .string("research-brief-pack"),
            "name": .string("Research Brief Pack"),
            "kind": .string("skill_pack"),
            "description": .string("Adds reusable research planning, source capture, and citation brief patterns."),
            "status": .string("available"),
            "riskClass": .string("network_read"),
            "installed": .bool(false),
            "provenance": .string("nativeagent-foundation"),
            "createdAt": now,
        ],
        [
            "id": .string("workflow-operator-pack"),
            "name": .string("Workflow Operator Pack"),
            "kind": .string("workflow_pack"),
            "description": .string("Templates for approval-gated multi-step workflows and run receipts."),
            "status": .string("available"),
            "riskClass": .string("app_data_write"),
            "installed": .bool(false),
            "provenance": .string("nativeagent-foundation"),
            "createdAt": now,
        ],
        [
            "id": .string("personal-os-pack"),
            "name": .string("Personal OS Pack"),
            "kind": .string("workspace_pack"),
            "description": .string("Organizes Workshop tasks, sessions, memories, and jobs into lightweight personal operating spaces."),
            "status": .string("available"),
            "riskClass": .string("app_data_read"),
            "installed": .bool(false),
            "provenance": .string("nativeagent-foundation"),
            "createdAt": now,
        ],
    ]
}

private func capabilityTrustMetadata(_ source: [String: JSONValue]) -> [String: JSONValue] {
    source.filter { ["sourcePackId", "provenance", "signature"].contains($0.key) }
}

// MARK: - Aggregator: full capability_records() port
//
// Projects installed capabilities without independently rediscovering skills.
//
// Merge order preserved from the retired runtime:
//   1. feature_surface_records (19)
//   2. InstalledSkillInventory                                    (kind: skill)
//   3. list_tools()[:150]                                            (kind: tool)
//   5. list_workflows()[:100]                                        (kind: workflow)
//   6. connector_actions_registry().actions[:200]                    (kind: tool)
//   8. list_capability_catalog()                                     (kind: catalog)
//
// Final sort: by str(updatedAt or name or "") DESC.
public func capabilityRecordsFull(
    dataRoot: URL,
    personaRoot: URL? = nil,
    nowISO: String,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
    connectorActionStatuses: @Sendable () async throws -> [String: String]
) async throws -> [[String: JSONValue]] {

    var records: [[String: JSONValue]] = []

    // 1. feature_surface_records (static, already ported)
    for fs in featureSurfaceRecords(nowISO: nowISO) {
        let rec: [String: JSONValue] = [
            "id": .string(fs.id),
            "sourceId": .string(fs.sourceId),
            "name": .string(fs.name),
            "kind": .string(fs.kind),
            "status": .string(fs.status),
            "description": .string(fs.description),
            "triggers": .array(fs.triggers.map { .string($0) }),
            "permissions": .array(fs.permissions.map { .string($0) }),
            "riskClass": .string(fs.riskClass),
            "autoload": .bool(fs.autoload),
            "useCount": .int(Int64(fs.useCount)),
            "lastUsedAt": fs.lastUsedAt.map { .string($0) } ?? .null,
            "updatedAt": .string(fs.updatedAt),
            "endpoints": .array(fs.endpoints.map { .string($0) }),
        ]
        // Python's feature_surface_records DOES include `endpoints` in the
        // dict. capability_records() reads it through verbatim (the
        // initial `list(...)` line preserves all keys). Round-trip keeps it.
        records.append(rec)
    }

    // 2. Canonical installed skills → kind: skill
    let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot)
    for entry in skills.prefix(230) {
        let skill = entry.row
        var rec = capabilityTrustMetadata(skill)
        let sid = jsonString(skill, "id")
        rec["id"] = .string("skill:\(sid)")
        rec["sourceId"] = .string(sid)
        rec["name"] = .string(promptSafeCapabilityText(jsonOptionalString(skill, "name")))
        rec["kind"] = .string("skill")
        let status = jsonString(skill, "status")
        rec["status"] = .string(status.isEmpty ? "active" : status)
        rec["description"] = .string(
            promptSafeCapabilityText(jsonOptionalString(skill, "description"))
        )
        rec["triggers"] = .array(jsonStringArray(skill, "triggers").map { .string($0) })
        rec["permissions"] = .array([])
        rec["riskClass"] = .string("routine")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(Int64(jsonInt(skill, "useCount")))
        rec["lastUsedAt"] = skill["lastUsedAt"] ?? .null
        let updated = jsonString(skill, "updatedAt")
        let created = jsonString(skill, "createdAt")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // 3. list_tools → kind: tool
    let tools = try await listTools(dataRoot: dataRoot, persistence: persistence)
    for tool in tools.prefix(150) {
        var rec = capabilityTrustMetadata(tool)
        let tid = jsonString(tool, "id")
        rec["id"] = .string("tool:\(tid)")
        rec["sourceId"] = .string(tid)
        rec["name"] = tool["name"] ?? .null
        rec["kind"] = .string("tool")
        // status = tool.status or tool.phase or "proposal"
        let toolStatus = jsonString(tool, "status")
        let toolPhase = jsonString(tool, "phase")
        let resolvedStatus = !toolStatus.isEmpty ? toolStatus :
            (!toolPhase.isEmpty ? toolPhase : "proposal")
        rec["status"] = .string(resolvedStatus)
        rec["description"] = tool["description"] ?? .null
        rec["triggers"] = .array(jsonStringArray(tool, "triggers").map { .string($0) })
        let perms = jsonStringArray(tool, "permissions")
        rec["permissions"] = .array(perms.map { .string($0) })
        let isRisky = !Set(perms).intersection(riskyToolPermissions).isEmpty
        rec["riskClass"] = .string(isRisky ? "risky_tool" : "app_owned_tool")
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(Int64(jsonInt(tool, "useCount")))
        rec["lastUsedAt"] = tool["lastUsedAt"] ?? .null
        let updated = jsonString(tool, "updatedAt")
        let created = jsonString(tool, "createdAt")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // 5. list_workflows → kind: workflow
    let workflows = try await listWorkflows(
        dataRoot: dataRoot, nowISO: nowISO
    )
    for workflow in workflows.prefix(100) {
        var rec = capabilityTrustMetadata(workflow)
        let wid = jsonString(workflow, "id")
        rec["id"] = .string("workflow:\(wid)")
        rec["sourceId"] = .string(wid)
        rec["name"] = workflow["name"] ?? .null
        rec["kind"] = .string("workflow")
        let wstatus = jsonString(workflow, "status")
        rec["status"] = .string(wstatus.isEmpty ? "active" : wstatus)
        rec["description"] = workflow["description"] ?? .null
        let trigger = jsonString(workflow, "trigger")
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
        let updated = jsonString(workflow, "updatedAt")
        let created = jsonString(workflow, "createdAt")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
        records.append(rec)
    }

    // 6. connector_actions_registry (static port) → kind: tool
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
        // Python: str(action.get("risk") or "low") — empty/None falls back to "low".
        let risk = action.risk.isEmpty ? "low" : action.risk
        rec["permissions"] = .array([.string(risk)])
        rec["riskClass"] = .string(risk)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        rec["lastUsedAt"] = .null
        // Python: action.get("updatedAt") — static actions have no updatedAt
        rec["updatedAt"] = .null
        records.append(rec)
    }

    // 8. list_capability_catalog → kind: catalog
    let catalog = try await listCapabilityCatalog(
        dataRoot: dataRoot, nowISO: nowISO, persistence: persistence
    )
    for item in catalog {
        var rec = capabilityTrustMetadata(item)
        let iid = jsonString(item, "id")
        rec["id"] = .string("catalog:\(iid)")
        rec["sourceId"] = .string(iid)
        rec["name"] = item["name"] ?? .null
        rec["kind"] = .string("catalog")
        let installed = jsonBool(item, "installed")
        rec["status"] = .string(installed ? "installed" : "available")
        rec["description"] = item["description"] ?? .null
        rec["triggers"] = .array([item["name"] ?? .null])
        rec["permissions"] = .array([])
        let riskClass = jsonString(item, "riskClass")
        rec["riskClass"] = .string(riskClass.isEmpty ? "app_data" : riskClass)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        let installedAt = jsonString(item, "installedAt")
        rec["lastUsedAt"] = installedAt.isEmpty ? .null : .string(installedAt)
        let created = jsonString(item, "createdAt")
        let resolvedUpdated = !installedAt.isEmpty ? installedAt : created
        rec["updatedAt"] = resolvedUpdated.isEmpty ? .null : .string(resolvedUpdated)
        records.append(rec)
    }

    // Final sort: str(updatedAt or name or "") DESC, STABLE.
    // Python's sorted() is stable; Swift Array.sort is NOT. The index-aware
    // tiebreaker preserves the merge order for ties (matches the static-port
    // helper above).
    let indexed = records.enumerated().map { ($0.offset, $0.element) }
    let sorted = indexed.sorted { lhs, rhs in
        let lk = jsonString(lhs.1, "updatedAt").isEmpty
            ? jsonString(lhs.1, "name") : jsonString(lhs.1, "updatedAt")
        let rk = jsonString(rhs.1, "updatedAt").isEmpty
            ? jsonString(rhs.1, "name") : jsonString(rhs.1, "updatedAt")
        if lk != rk { return lk > rk }
        return lhs.0 < rhs.0
    }
    return sorted.map { $0.1 }
}
