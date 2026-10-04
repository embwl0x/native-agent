import Foundation
import NativeAgentCore
import PersistenceCore
import Skills
import ToolRegistry
import WorkflowOrchestration

// MARK: - Wave 13: dynamic source ports for capability_records() aggregator
//
// Byte-shape ports of the 7 dynamic Python sources called by the
// capability_records() aggregator at the retired daemon
// (read 2026-05-31):
//
//   1. InstalledSkillInventory (canonical registry and body inventory)
//   3. list_tools
//   4. manifest_registered_skills
//   5. list_workflows
//   6. list_mcp_servers
//   7. list_capability_catalog
//
// Each returns a list-of-dicts in Python; here we return [JSONValue.object]
// because the aggregator only consumes ~6 well-known keys per source and
// the on-disk records are schema-loose (any extra daemon-written keys
// round-trip via the dict bag — preserving lossless re-emit).
//
// Read-side semantics mirror Python exactly:
//   - read_json with default [] / {} (PersistenceCore.readJSON)
//   - sort key + DESC ordering matches Python's sorted(...)
//   - default merge (R-M-W) is honored on the four read-then-write paths
//     (#3 list_tools is read-only; #4 manifest_registered_skills is also
//     read-only — it just merges two existing files into one in-memory dict)
//
// The two on-disk-merge sources (catalog_sources, capability_trust_roots)
// are in CapabilityCatalog.swift because they need write+flock symmetry.
// list_workflows / list_mcp_servers / list_capability_catalog also do
// read-merge-write per the Python — those WRITES are intentionally NOT
// reproduced in Swift (read-only port to keep the aggregator side-effect
// free; the daemon still writes when it serves its own routes).

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


// MARK: - Source #3: list_tools
//
// Port of the retired daemon:
//   def list_tools(self) -> list[dict[str, Any]]:
//       tools = read_json(self.tools_path, [])
//       return sorted(tools, key=lambda item: str(item.get("updatedAt") or item.get("createdAt") or ""), reverse=True)
//
// Path: <dataRoot>/tools/registry.json
//
// NOTE: SwiftNativeToolRegistry exists with the same surface. We re-read
// directly here because:
//   (1) the aggregator wants the dict bag, not the typed ToolRecord;
//       round-tripping through ToolRecord would lose `permissions`,
//       `triggers`, and the per-tool `useCount` which the aggregator
//       consumes verbatim.
//   (2) avoids actor-isolation friction for what is a pure read.
public func listTools(
    dataRoot: URL,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    let path = dataRoot
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    let raw = try await persistence.readJSON(path, ifMissing: .array([]))
    guard case .array(let items) = raw else { return [] }
    let dicts: [[String: JSONValue]] = items.compactMap {
        if case .object(let o) = $0 { return o }
        return nil
    }
    return dicts.sorted { lhs, rhs in
        let lk = jsonString(lhs, "updatedAt").isEmpty
            ? jsonString(lhs, "createdAt") : jsonString(lhs, "updatedAt")
        let rk = jsonString(rhs, "updatedAt").isEmpty
            ? jsonString(rhs, "createdAt") : jsonString(rhs, "updatedAt")
        return lk > rk
    }
}

// MARK: - Source #4: manifest_registered_skills
//
// Port of the retired daemon. Merges two on-disk registries
// keyed by skill-name; second source wins:
//   1. ~/Library/Application Support/NativeAgent/skills/manifest_registry.json (legacy)
//   2. <dataRoot>/skills/manifest_registry.json
//
// Returns `{"schemaVersion": 1, "skills": {<name>: {...entry, sourceRoot, registryPath}}}`.
// Python uses `setdefault` so previously-stamped sourceRoot/registryPath
// are preserved on the legacy side and overwritten on the modern side
// (because the second iteration's `setdefault` is a no-op once the key is set).
//
// Catches Exception per file and `continue` — we mirror with try?.
public func manifestRegisteredSkills(
    dataRoot: URL,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [String: JSONValue] {
    var merged: [String: JSONValue] = [
        "schemaVersion": .int(1),
        "skills": .object([:]),
    ]
    var skillsAccum: [String: JSONValue] = [:]

    let legacyDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first?
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("manifest_registry.json")

    let modernPath = dataRoot
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("manifest_registry.json")

    // Python iteration order: legacy, then modern.
    var pathsToScan: [URL] = []
    if let legacy = legacyDir { pathsToScan.append(legacy) }
    pathsToScan.append(modernPath)

    for path in pathsToScan {
        let raw = try await persistence.readJSON(
            path,
            ifMissing: .object(["schemaVersion": .int(1), "skills": .object([:])])
        )
        guard case .object(let topObj) = raw,
              case .object(let skills) = topObj["skills"] ?? .null else {
            continue
        }
        for (name, entry) in skills {
            guard case .object(var item) = entry else { continue }
            // setdefault sourceRoot, registryPath
            let dirPath = path.deletingLastPathComponent().path
            if item["sourceRoot"] == nil {
                item["sourceRoot"] = .string(dirPath)
            }
            if item["registryPath"] == nil {
                item["registryPath"] = .string(path.path)
            }
            skillsAccum[name] = .object(item)
        }
    }
    merged["skills"] = .object(skillsAccum)
    return merged
}

// Insertion-order-preserving variant of `manifestRegisteredSkills`. Python's
// dict preserves insertion order and `list(items())[:150]` slices in that
// order — the dict-returning variant above loses it via Swift's unordered
// dictionary. The aggregator's stage 4 uses this so the same legacy-then-
// modern subset is taken when >150 entries exist.
public func manifestRegisteredSkillsOrdered(
    dataRoot: URL,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> (schemaVersion: Int, skills: [(String, JSONValue)]) {
    var ordered: [(String, JSONValue)] = []
    var indexByKey: [String: Int] = [:]

    let legacyDir = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first?
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("manifest_registry.json")

    let modernPath = dataRoot
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent("manifest_registry.json")

    var pathsToScan: [URL] = []
    if let legacy = legacyDir { pathsToScan.append(legacy) }
    pathsToScan.append(modernPath)

    for path in pathsToScan {
        let raw = try await persistence.readJSON(
            path,
            ifMissing: .object(["schemaVersion": .int(1), "skills": .object([:])])
        )
        guard case .object(let topObj) = raw,
              case .object(let skills) = topObj["skills"] ?? .null else {
            continue
        }
        // Python's `merged[name] = item` keeps a key's first-seen insertion
        // position on re-assignment; setdefault is a no-op once stamped.
        for (name, entry) in skills {
            guard case .object(var item) = entry else { continue }
            let dirPath = path.deletingLastPathComponent().path
            if item["sourceRoot"] == nil {
                item["sourceRoot"] = .string(dirPath)
            }
            if item["registryPath"] == nil {
                item["registryPath"] = .string(path.path)
            }
            if let existing = indexByKey[name] {
                ordered[existing] = (name, .object(item))
            } else {
                indexByKey[name] = ordered.count
                ordered.append((name, .object(item)))
            }
        }
    }
    return (schemaVersion: 1, skills: ordered)
}

// MARK: - Source #5: list_workflows
//
// Reads <dataRoot>/workflows/registry.json with WorkflowOrchestration's
// defaults, unchanged-seed migration and merge. The workflow client owns
// write-back; capability aggregation only reads the sorted projection.
public func listWorkflows(
    dataRoot: URL,
    nowISO: String,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    let path = dataRoot
        .appendingPathComponent("workflows", isDirectory: true)
        .appendingPathComponent("registry.json")
    let raw = try await persistence.readJSON(path, ifMissing: .array([]))
    let saved: [JSONValue]
    if case .array(let items) = raw {
        saved = items
    } else {
        saved = []
    }
    let defaults = WorkflowDefaults.defaults(now: nowISO)
    return WorkflowMerge.mergeRegistry(defaults: defaults, saved: saved).sorted.compactMap {
        if case .object(let record) = $0 { return record }
        return nil
    }
}

// MARK: - Source #6: list_mcp_servers
//
// The MCP owner lists its servers (MCPDispatcher's `listMCPServersAsDicts`);
// the caller hands that listing in, so TrustCenter imports no executor.

// MARK: - Source #7: list_capability_catalog
//
// Port of the retired daemon. Reads <dataRoot>/catalog/registry.json,
// merges with default_catalog_items() (4 entries), sorts by name/id ascending.
// READ-ONLY in Swift (Python writes back; carve documented same as workflows).
public func listCapabilityCatalog(
    dataRoot: URL,
    nowISO: String,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
) async throws -> [[String: JSONValue]] {
    let path = dataRoot
        .appendingPathComponent("catalog", isDirectory: true)
        .appendingPathComponent("registry.json")
    let raw = try await persistence.readJSON(path, ifMissing: .array([]))
    let savedDicts: [[String: JSONValue]]
    if case .array(let items) = raw {
        savedDicts = items.compactMap {
            if case .object(let o) = $0 { return o }
            return nil
        }
    } else {
        savedDicts = []
    }

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

/// Port of the retired daemon default_catalog_items(). Four
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
            "id": .string("mcp-builder-pack"),
            "name": .string("MCP Builder Pack"),
            "kind": .string("connector_pack"),
            "description": .string("Scaffolds MCP server entries and readiness checks without autoloading them into chat."),
            "status": .string("available"),
            "riskClass": .string("network_localhost"),
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
//   4. manifest_registered_skills().get("skills", {})[:150]          (kind: tool|skill)
//   5. list_workflows()[:100]                                        (kind: workflow)
//   6. connector_actions_registry().actions[:200]                    (kind: tool)
//   7. list_mcp_servers()[:50]                                       (kind: mcp)
//   8. list_capability_catalog()                                     (kind: catalog)
//
// Final sort: by str(updatedAt or name or "") DESC.
public func capabilityRecordsFull(
    dataRoot: URL,
    personaRoot: URL? = nil,
    nowISO: String,
    persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
    connectorActionStatuses: @Sendable () async throws -> [String: String],
    mcpServers: @Sendable () async throws -> [[String: JSONValue]]
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
    let skills = try InstalledSkillInventory.entries(dataRoot: dataRoot, personaRoot: personaRoot)
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
        rec["riskClass"] = .string("instruction")
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

    // 4. manifest_registered_skills → kind: tool|skill
    // Use the ordered variant so the prefix(150) slice matches Python's
    // `list(manifest_skills.items())[:150]` (insertion order: legacy first,
    // then any modern-only keys). The dict-returning variant above loses
    // order via Swift's unordered dictionary.
    let manifestOrdered = try await manifestRegisteredSkillsOrdered(
        dataRoot: dataRoot, persistence: persistence
    )
    for (manifestName, entry) in manifestOrdered.skills.prefix(150) {
        guard case .object(let entryObj) = entry else { continue }
        // kind = entry.type or entry.kind or "skill"
        let kindRaw = jsonString(entryObj, "type").isEmpty
            ? (jsonString(entryObj, "kind").isEmpty ? "skill" : jsonString(entryObj, "kind"))
            : jsonString(entryObj, "type")
        var rec = capabilityTrustMetadata(entryObj)
        rec["id"] = .string("manifest:\(manifestName)")
        rec["sourceId"] = .string(manifestName)
        let nameRaw = jsonString(entryObj, "name")
        rec["name"] = .string(
            promptSafeCapabilityText(nameRaw.isEmpty ? manifestName : nameRaw, limit: 160)
        )
        rec["kind"] = .string(kindRaw == "tool" ? "tool" : "skill")
        // status = entry.state or entry.status or "drafted"
        let entryStatus = jsonString(entryObj, "state").isEmpty
            ? (jsonString(entryObj, "status").isEmpty ? "drafted" : jsonString(entryObj, "status"))
            : jsonString(entryObj, "state")
        rec["status"] = .string(entryStatus)
        let descRaw = jsonString(entryObj, "description")
        let descSource = descRaw.isEmpty ? "Manifest-registered \(kindRaw)." : descRaw
        rec["description"] = .string(
            promptSafeCapabilityText(descSource, limit: 500)
        )
        let triggers = jsonStringArray(entryObj, "triggers")
        rec["triggers"] = triggers.isEmpty
            ? .array([.string(manifestName)])
            : .array(triggers.map { .string($0) })
        let perms = jsonStringArray(entryObj, "permissions")
        rec["permissions"] = .array(perms.map { .string($0) })
        rec["riskClass"] = .string(kindRaw == "tool" ? "manifest_tool" : "instruction")
        rec["autoload"] = .bool(false)
        let updated = jsonString(entryObj, "updatedAt")
        let installed = jsonString(entryObj, "installedAt")
        rec["updatedAt"] = .string(updated.isEmpty ? installed : updated)
        records.append(rec)
    }

    // 5. list_workflows → kind: workflow
    let workflows = try await listWorkflows(
        dataRoot: dataRoot, nowISO: nowISO, persistence: persistence
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

    // 7. list_mcp_servers → kind: mcp
    let servers = try await mcpServers()
    for server in servers.prefix(50) {
        var rec = capabilityTrustMetadata(server)
        let sid = jsonString(server, "id")
        rec["id"] = .string("mcp:\(sid)")
        rec["sourceId"] = .string(sid)
        rec["name"] = server["name"] ?? .null
        rec["kind"] = .string("mcp")
        // status = server.status or server.healthStatus or "configured"
        let sstat = jsonString(server, "status")
        let shealth = jsonString(server, "healthStatus")
        let resolvedSStatus = !sstat.isEmpty ? sstat :
            (!shealth.isEmpty ? shealth : "configured")
        rec["status"] = .string(resolvedSStatus)
        // description = f"{transport} MCP endpoint with {toolCount} tool(s)."
        let transport = jsonString(server, "transport")
        let toolCount = jsonInt(server, "toolCount")
        rec["description"] = .string("\(transport) MCP endpoint with \(toolCount) tool(s).")
        rec["triggers"] = .array([server["name"] ?? .null])
        // permissions: ["network_localhost"] if transport != stdio else []
        rec["permissions"] = transport != "stdio"
            ? .array([.string("network_localhost")])
            : .array([])
        let riskClass = jsonString(server, "riskClass")
        rec["riskClass"] = .string(riskClass.isEmpty ? "network_localhost" : riskClass)
        rec["autoload"] = .bool(false)
        rec["useCount"] = .int(0)
        rec["lastUsedAt"] = .null
        let updated = jsonString(server, "updatedAt")
        let created = jsonString(server, "createdAt")
        rec["updatedAt"] = .string(updated.isEmpty ? created : updated)
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
