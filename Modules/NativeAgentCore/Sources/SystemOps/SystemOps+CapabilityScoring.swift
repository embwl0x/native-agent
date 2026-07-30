import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Token classifier (shared by RouterPlan SwiftNative impl)

/// `keyword_tokens` byte-for-byte. Regex
/// `[a-zA-Z0-9_][a-zA-Z0-9_-]{2,}` against lowercased input, minus the
/// stopword set.
public func keywordTokens(_ value: String) -> Set<String> {
    let lower = value.lowercased()
    let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "your", "you", "are", "how", "what"]
    var out: Set<String> = []
    let scalars = Array(lower.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]
        if isWordStart(c) {
            var j = i + 1
            while j < scalars.count, isWordCont(scalars[j]) { j += 1 }
            let len = j - i
            // Regex requires {2,} after the first char → total length ≥ 3.
            if len >= 3 {
                let token = String(String.UnicodeScalarView(scalars[i..<j]))
                if !stop.contains(token) { out.insert(token) }
            }
            i = j
        } else {
            i += 1
        }
    }
    return out
}

private func isWordStart(_ c: Unicode.Scalar) -> Bool {
    // [a-zA-Z0-9_]
    return (c.value >= 0x30 && c.value <= 0x39) ||
           (c.value >= 0x41 && c.value <= 0x5A) ||
           (c.value >= 0x61 && c.value <= 0x7A) ||
           c.value == 0x5F
}

private func isWordCont(_ c: Unicode.Scalar) -> Bool {
    // [a-zA-Z0-9_-]
    return isWordStart(c) || c.value == 0x2D
}

// MARK: - Capability scoring (port of select_context_capabilities)
//
// Wave 11 (2026-05-31). Byte-for-byte port of Python's
// `score_context_capability` and
// `select_context_capabilities` (L15238), restricted to the two capability
// record sources that already have Swift-native ports:
//   • featureSurfaceRecords()  — 19 static entries
//   • connectorActionDescriptors() — 84 static entries
//
// Python's `capability_records()` ALSO includes skill, tool, manifest-skill,
// workflow, and MCP-server records. Those record sources are Python-only
// today; the Swift router-plan path is FLIPPABLE FOR THE NARROWED INPUT SET
// only. See SystemOps RESIDUAL CAVEATS block + CUTOVER_PLAN.md §6.14.

/// In-memory capability record used for scoring. Subset of the Python dict
/// shape — only the fields `score_context_capability` reads + those the
/// summary projection in `select_context_capabilities` emits.
public struct CapabilityScoringRecord: Sendable {
    public let id: String
    public let sourceId: String
    public let name: String
    public let kind: String
    public let status: String
    public let description: String
    public let triggers: [String]
    public let permissions: [String]
    public let riskClass: String
    public let endpoints: [String]
    public let useCount: Int
    /// Pre-sort tie-breaker key. Python L15742:
    /// `sorted(records, key=lambda item: str(item.get("updatedAt") or item.get("name") or ""), reverse=True)`.
    /// Empty string means fall back to `name` (matches the retired `or` chain).
    public let updatedAt: String

    public init(
        id: String,
        sourceId: String,
        name: String,
        kind: String,
        status: String,
        description: String,
        triggers: [String],
        permissions: [String],
        riskClass: String,
        endpoints: [String],
        useCount: Int,
        updatedAt: String = ""
    ) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.kind = kind
        self.status = status
        self.description = description
        self.triggers = triggers
        self.permissions = permissions
        self.riskClass = riskClass
        self.endpoints = endpoints
        self.useCount = useCount
        self.updatedAt = updatedAt
    }
}

/// Output of `scoreContextCapability` — kept as a struct rather than a dict
/// so the caller doesn't re-parse JSON.
struct CapabilityScoreParts {
    let score: Double
    let overlap: [String]
    let reasons: [String]
}

/// Byte-for-byte port of `score_context_capability`
///. Numeric rules:
///   • +1.2 × overlap_count
///   • +4.0 per trigger substring hit
///   • +3.0 for name-substring hit
///   • +1.5 for mode/kind/source/id bias hit
///   • +0.3 for status ∈ {active, installed, ready, configured}
///   • +min(1.0, useCount/20) bonus
/// Rounded to 3 decimals. `overlap` clamped to first 8 in the return.
public func scoreContextCapability(_ record: CapabilityScoringRecord, message: String, mode: String) -> Double {
    scoreContextCapabilityParts(record, message: message, mode: mode).score
}

func scoreContextCapabilityParts(_ record: CapabilityScoringRecord, message: String, mode: String) -> CapabilityScoreParts {
    let tokens = keywordTokens(message)
    // Python builds haystack in this exact order: name, description,
    // triggers joined, endpoints joined, permissions joined. Order matters
    // only for the joined string's literal content; tokens are a set.
    let haystackParts: [String] = [
        record.name,
        record.description,
        record.triggers.map { $0 }.joined(separator: " "),
        record.endpoints.map { $0 }.joined(separator: " "),
        record.permissions.map { $0 }.joined(separator: " "),
    ]
    let haystack = haystackParts.joined(separator: " ")
    let hayTokens = keywordTokens(haystack)
    let overlap = Array(tokens.intersection(hayTokens)).sorted()
    let lower = message.lowercased()
    var score = Double(overlap.count) * 1.2
    var reasons: [String] = []
    for trigger in record.triggers {
        let triggerText = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !triggerText.isEmpty && lower.contains(triggerText) {
            score += 4.0
            reasons.append("trigger:" + String(triggerText.prefix(40)))
        }
    }
    let nameLower = record.name.lowercased()
    if !nameLower.isEmpty && lower.contains(nameLower) {
        score += 3.0
        reasons.append("name match")
    }
    let modeKindBias: [String: Set<String>] = [
        "memory": ["feature:memory_system", "skill", "tool"],
        "workflow": ["workflow", "tool", "skill", "mcp", "feature:agent_swarm"],
        "research": ["feature:research_browser", "mcp", "catalog"],
        "ops": ["feature:trust_doctor", "feature:eval_release_ops", "feature:nextgen_runtime"],
        "personality": ["feature:personality_engine", "skill"],
        "capability": ["feature", "skill", "tool", "workflow", "mcp", "catalog"],
        "full": ["feature", "skill", "tool", "workflow", "mcp", "catalog"],
    ]
    let biases = modeKindBias[mode] ?? []
    // Python: `record.get("sourceId") or record.get("id") or ""` — empty
    // string sourceId falls through to id.
    let sourceIdEffective = !record.sourceId.isEmpty ? record.sourceId : record.id
    if biases.contains(record.kind) || biases.contains(sourceIdEffective) || biases.contains(record.id) {
        score += 1.5
        reasons.append("mode:" + mode)
    }
    let statusActiveSet: Set<String> = ["active", "installed", "ready", "configured"]
    if statusActiveSet.contains(record.status) {
        score += 0.3
    }
    if record.useCount > 0 {
        score += min(1.0, Double(record.useCount) / 20.0)
    }
    // Round to 3 decimals (Python's round(x, 3) uses banker's rounding but
    // we only feed integer-multiples-of-0.1 deltas, so half-rounding never
    // engages — straight scale-rounding-divide matches exactly).
    let rounded = (score * 1000.0).rounded() / 1000.0
    return CapabilityScoreParts(score: rounded, overlap: Array(overlap.prefix(8)), reasons: reasons)
}

/// Byte-for-byte port of `select_context_capabilities`
///. Limit defaults:
///   • mode=="minimal" → 2
///   • mode=="full"    → 18
///   • else            → 8
/// Drops zero-score entries except in "full" mode. Sort key matches Python
/// `(score, status)` with `reverse=True` — both DESCENDING.
public func selectContextCapabilities(
    records: [CapabilityScoringRecord],
    message: String,
    mode: String,
    limit: Int? = nil
) -> [JSONValue] {
    let resolvedLimit: Int
    if let l = limit {
        resolvedLimit = l
    } else if mode == "minimal" {
        resolvedLimit = 2
    } else if mode == "full" {
        resolvedLimit = 18
    } else {
        resolvedLimit = 8
    }

    struct Scored {
        let score: Double
        let status: String
        let summary: JSONValue
        let inputIndex: Int
    }
    var scored: [Scored] = []
    for (inputIndex, record) in records.enumerated() {
        let parts = scoreContextCapabilityParts(record, message: message, mode: mode)
        if parts.score <= 0 && mode != "full" { continue }
        let trimmedDesc = String(record.description.prefix(500))
        let trimmedTriggers = Array(record.triggers.prefix(6)).map { JSONValue.string($0) }
        let trimmedPerms = Array(record.permissions.prefix(6)).map { JSONValue.string($0) }
        let trimmedEndpoints = Array(record.endpoints.prefix(6)).map { JSONValue.string($0) }
        let matchedTerms = parts.overlap.map { JSONValue.string($0) }
        let reasons = parts.reasons.isEmpty
            ? [JSONValue.string("fallback ranking")]
            : parts.reasons.map { JSONValue.string($0) }
        let summary = JSONValue.object([
            "id": .string(record.id),
            "sourceId": .string(record.sourceId),
            "name": .string(record.name),
            "kind": .string(record.kind),
            "status": .string(record.status),
            "description": .string(trimmedDesc),
            "triggers": .array(trimmedTriggers),
            "permissions": .array(trimmedPerms),
            "riskClass": .string(record.riskClass),
            "endpoints": .array(trimmedEndpoints),
            "score": .double(parts.score),
            "matchedTerms": .array(matchedTerms),
            "selectionReasons": .array(reasons),
        ])
        scored.append(Scored(score: parts.score, status: record.status, summary: summary, inputIndex: inputIndex))
    }
    // Python `reverse=True` flips the entire tuple — both score and status DESC.
    // Swift's Array.sort is NOT stable; restore stability by using inputIndex
    // (ascending) as the final tie-breaker so the pre-sort order from
    // swiftNativeCapabilityRecords carries through full-tie rows the way
    // Python's Timsort does.
    scored.sort { (a, b) in
        if a.score != b.score { return a.score > b.score }
        if a.status != b.status { return a.status > b.status }
        return a.inputIndex < b.inputIndex
    }
    let take = max(0, resolvedLimit)
    return Array(scored.prefix(take)).map { $0.summary }
}

/// Build the in-process capability-records array for the routerPlan
/// classifier. Restricted to the two Swift-native sources:
///   • featureSurfaceRecords()
///   • connectorActionDescriptors()
///
/// Python additionally includes skill, tool, manifest-skill, workflow, and
/// MCP-server records — those record sources are Python-only and are NOT
/// re-implemented here. See CUTOVER_PLAN.md §6.14.
public func swiftNativeCapabilityRecords(nowISO: String) -> [CapabilityScoringRecord] {
    var records: [CapabilityScoringRecord] = []
    records.reserveCapacity(featureSurfaceRecordsCount + connectorActionDescriptorsCount)
    for fs in featureSurfaceRecords(nowISO: nowISO) {
        records.append(CapabilityScoringRecord(
            id: fs.id,
            sourceId: fs.sourceId,
            name: fs.name,
            kind: fs.kind,
            status: fs.status,
            description: fs.description,
            triggers: fs.triggers,
            permissions: fs.permissions,
            riskClass: fs.riskClass,
            endpoints: fs.endpoints,
            useCount: fs.useCount,
            updatedAt: nowISO
        ))
    }
    // Mirrors Python L21031-L21036 cold-bootstrap default: when the
    // connectors map is empty, `enabled` falls back to `native_connector`
    // (True for the static set below), and `status` becomes "active" for
    // enabled actions, "needs_setup" otherwise. Runtime healthStatus /
    // authState layering is NOT Swift-native — see RESIDUAL CAVEATS.
    let nativeConnectorSet: Set<String> = [
        "mobile", "scheduler", "mac", "mac_assistant",
        "local_files", "searxng", "codex_work", "codex_handoff",
        "slack",
    ]
    for action in connectorActionDescriptors() {
        let actionId = action.id
        let connectorId = action.connectorId
        let category = action.category ?? ""
        let nameRaw = action.name ?? actionId
        let descRaw = action.description ?? "Connector action \(actionId)."
        let name = String(nameRaw.prefix(160))
        let description = String(descRaw.prefix(500))
        // Python: triggers=[action_id, connectorId, category or ""] — three
        // entries, NOT filtered for empty.
        let triggers = [actionId, connectorId, category]
        let risk = action.risk
        let enabled = nativeConnectorSet.contains(connectorId)
        let status = enabled ? "active" : "needs_setup"
        records.append(CapabilityScoringRecord(
            id: "connector_action:\(actionId)",
            sourceId: actionId,
            name: name,
            kind: "tool",
            status: status,
            description: description,
            triggers: triggers,
            permissions: [risk],
            riskClass: risk,
            endpoints: [],
            useCount: 0,
            updatedAt: ""
        ))
    }
    // Python L15742 pre-sort by `str(updatedAt or name or "")` DESC. The
    // later (score, status) sort in select_context_capabilities is STABLE in
    // CPython (Timsort), so this pre-sort is the tie-breaker for equal
    // score+status rows. Swift's stable-sort emulation uses the surviving
    // input index — that index is anchored here.
    records.sort { a, b in
        let keyA = a.updatedAt.isEmpty ? a.name : a.updatedAt
        let keyB = b.updatedAt.isEmpty ? b.name : b.updatedAt
        return keyA > keyB
    }
    return records
}
