import Foundation
import MCPDispatcher
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #12b: Capability Trust Network
//
// Routes ported from the retired native_agentd surface:
//   GET  /v1/capability-trust           → runtime.capability_trust_network()
//
//   POST /v1/capability-trust/evaluate  → runtime.evaluate_capability_trust(body)
//
//
// Wave 13 disposition (2026-05-31): capabilityTrust is now FLIPPABLE.
// All 9 dynamic prereqs have closed:
//   1-7: list_skills / persona_skill_manifest_records / list_tools /
//        manifest_registered_skills / list_workflows / list_mcp_servers /
//        list_capability_catalog (CapabilityRecords+Dynamic.swift)
//   8-9: catalog_sources / capability_trust_roots (ported as the two
//        on-disk-merge actors below).
//
// `SwiftNativeCapabilityTrust` now serves `capability_trust_network()` and
// `evaluate_capability_trust()` in-process. It
// reuses `capabilityRecordsFull(...)` for the record list and the inline
// `SwiftNativeCatalogSources` / `SwiftNativeCapabilityTrustRoots` actors
// for the two merge-and-write sources. Side effects intentionally omitted:
// the old evaluate() appended to `catalog/trust/events.jsonl` and called
// `record_trace`; SwiftNative skips both to avoid double-write.

// MARK: - Wire types
//
// Shape matches Sources/NativeAgentApp/Models.swift:1593-1636 exactly.

public struct CapabilityTrustRoot: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var kind: String?
    public var fingerprint: String?
    public var status: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String, name: String, kind: String? = nil, fingerprint: String? = nil,
        status: String? = nil, createdAt: String? = nil, updatedAt: String? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind
        self.fingerprint = fingerprint; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct CapabilityCatalogSource: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var kind: String?
    public var url: String?
    public var status: String?
    public var trustedRootId: String?
    public var lastCheckedAt: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String, name: String, kind: String? = nil, url: String? = nil,
        status: String? = nil, trustedRootId: String? = nil,
        lastCheckedAt: String? = nil, createdAt: String? = nil, updatedAt: String? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.url = url
        self.status = status; self.trustedRootId = trustedRootId
        self.lastCheckedAt = lastCheckedAt; self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CapabilityTrustRecord: Sendable, Codable, Equatable {
    public var id: String
    public var name: String?
    public var kind: String?
    public var status: String?
    public var riskClass: String?
    public var trustScore: Double?
    public var trustTier: String?
    public var reasons: [String]?

    public init(
        id: String, name: String? = nil, kind: String? = nil, status: String? = nil,
        riskClass: String? = nil, trustScore: Double? = nil,
        trustTier: String? = nil, reasons: [String]? = nil
    ) {
        self.id = id; self.name = name; self.kind = kind; self.status = status
        self.riskClass = riskClass; self.trustScore = trustScore
        self.trustTier = trustTier; self.reasons = reasons
    }
}

public struct CapabilityTrustSummary: Sendable, Codable, Equatable {
    public var trusted: Int
    public var review: Int
    public var untrusted: Int

    public init(trusted: Int, review: Int, untrusted: Int) {
        self.trusted = trusted; self.review = review; self.untrusted = untrusted
    }
}

public struct CapabilityTrustNetwork: Sendable, Codable, Equatable {
    public var status: String
    public var roots: [CapabilityTrustRoot]
    public var sources: [CapabilityCatalogSource]
    public var records: [CapabilityTrustRecord]
    public var summary: CapabilityTrustSummary?
    public var createdAt: String?

    public init(
        status: String, roots: [CapabilityTrustRoot],
        sources: [CapabilityCatalogSource], records: [CapabilityTrustRecord],
        summary: CapabilityTrustSummary? = nil, createdAt: String? = nil
    ) {
        self.status = status; self.roots = roots; self.sources = sources
        self.records = records; self.summary = summary; self.createdAt = createdAt
    }
}

public struct CapabilityTrustEvaluation: Sendable, Codable, Equatable {
    public var id: String
    public var name: String?
    public var trustScore: Double
    public var trustTier: String
    public var reasons: [String]
    public var createdAt: String?

    public init(
        id: String, name: String? = nil, trustScore: Double,
        trustTier: String, reasons: [String], createdAt: String? = nil
    ) {
        self.id = id; self.name = name; self.trustScore = trustScore
        self.trustTier = trustTier; self.reasons = reasons; self.createdAt = createdAt
    }
}

// MARK: - Errors

public enum CapabilityTrustError: Error, LocalizedError {
    case unknownCapability(String)
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCapability(let id): return "capability-trust: unknown capability: \(id)"
        case .invalidResponse(let s): return "capability-trust: native implementation returned unexpected status \(s)"
        case .unavailable: return "capability-trust: unavailable"
        case .underlying(let m): return "capability-trust: \(m)"
        }
    }
}

// MARK: - Protocol

public protocol CapabilityTrustProtocol: Sendable {
    func network() async throws -> CapabilityTrustNetwork
    func evaluate(capabilityId: String) async throws -> CapabilityTrustEvaluation
}

// MARK: - Pure scoring (port of capability_trust_score, the retired daemon)
//
// Verified byte-equivalent to the Python algorithm: base 0.45, +0.15 if
// sourcePackId/provenance present, +0.20 if signature present, +0.10 if
// status ∈ {active, installed, ready}, +0.10 if lastUsedAt/useCount present,
// -0.20 if riskClass ∈ {risky_tool, external_write, external_send}. Clamp
// to [0,1], round to 3 decimals.

public struct CapabilityTrustScore: Sendable, Equatable {
    public let score: Double
    public let reasons: [String]
    public init(score: Double, reasons: [String]) {
        self.score = score; self.reasons = reasons
    }
}

/// Pure score function. Mirrors `capability_trust_score` in
/// the retired daemon byte-for-byte.
public func scoreCapabilityRecord(_ record: [String: JSONValue]) -> CapabilityTrustScore {
    var score = 0.45
    var reasons = ["Base local capability record."]

    func present(_ key: String) -> Bool {
        switch record[key] {
        case .none, .null: return false
        case .string(let s): return !s.isEmpty
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .bool(let b): return b
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    if present("sourcePackId") || present("provenance") {
        score += 0.15
        reasons.append("Has provenance metadata.")
    }
    if present("signature") {
        score += 0.20
        reasons.append("Has a pack signature.")
    }
    let status: String = {
        if case .string(let s)? = record["status"] { return s }
        return ""
    }()
    if ["active", "installed", "ready"].contains(status) {
        score += 0.10
        reasons.append("Currently active or installed.")
    }
    if present("lastUsedAt") || present("useCount") {
        score += 0.10
        reasons.append("Has successful usage evidence.")
    }
    let risk: String = {
        if case .string(let s)? = record["riskClass"] { return s }
        return ""
    }()
    if ["risky_tool", "external_write", "external_send"].contains(risk) {
        score -= 0.20
        reasons.append("Risk class requires extra approval.")
    }

    let clamped = max(0.0, min(1.0, score))
    let scaled = (clamped * 1000.0).rounded(.toNearestOrEven) / 1000.0
    return CapabilityTrustScore(score: scaled, reasons: reasons)
}

/// Tier threshold ports of the inline ternaries in `capability_trust_network`
/// and `evaluate_capability_trust`.
public func capabilityTrustTier(forScore score: Double) -> String {
    if score >= 0.75 { return "trusted" }
    if score >= 0.50 { return "review" }
    return "untrusted"
}

// MARK: - Static capability record (manifest-derived subset)

public struct CapabilityRecord: Codable, Sendable, Equatable {
    public var id: String
    public var sourceId: String?
    public var name: String?
    public var kind: String?
    public var status: String?
    public var description: String?
    public var triggers: [String]?
    public var permissions: [String]?
    public var riskClass: String?
    public var autoload: Bool?
    public var useCount: Int?
    public var lastUsedAt: String?
    public var updatedAt: String?

    public init(
        id: String, sourceId: String? = nil, name: String? = nil,
        kind: String? = nil, status: String? = nil, description: String? = nil,
        triggers: [String]? = nil, permissions: [String]? = nil,
        riskClass: String? = nil, autoload: Bool? = nil,
        useCount: Int? = nil, lastUsedAt: String? = nil, updatedAt: String? = nil
    ) {
        self.id = id; self.sourceId = sourceId; self.name = name
        self.kind = kind; self.status = status; self.description = description
        self.triggers = triggers; self.permissions = permissions
        self.riskClass = riskClass; self.autoload = autoload
        self.useCount = useCount; self.lastUsedAt = lastUsedAt
        self.updatedAt = updatedAt
    }
}

/// Static subset of the Python aggregator `capability_records()`. Manifest-only.
public func staticCapabilityRecordsFromManifests(nowISO: String) -> [CapabilityRecord] {
    var out: [CapabilityRecord] = []

    for fs in featureSurfaceRecords(nowISO: nowISO) {
        out.append(CapabilityRecord(
            id: fs.id,
            sourceId: fs.sourceId,
            name: fs.name,
            kind: fs.kind,
            status: fs.status,
            description: fs.description,
            triggers: fs.triggers,
            permissions: fs.permissions,
            riskClass: fs.riskClass,
            autoload: fs.autoload,
            useCount: fs.useCount,
            lastUsedAt: fs.lastUsedAt,
            updatedAt: fs.updatedAt
        ))
    }

    for action in connectorActionDescriptors() {
        let name = action.name ?? action.id
        let description = action.description ?? "Connector action \(action.id)."
        out.append(CapabilityRecord(
            id: "connector_action:\(action.id)",
            sourceId: action.id,
            name: name,
            kind: "tool",
            status: "active",
            description: description,
            triggers: [action.id, action.connectorId, action.category ?? ""],
            permissions: [action.risk],
            riskClass: action.risk,
            autoload: false,
            useCount: 0,
            lastUsedAt: nil,
            updatedAt: nil
        ))
    }

    let indexed = out.enumerated().map { ($0.offset, $0.element) }
    out = indexed.sorted { lhs, rhs in
        let l = lhs.1.updatedAt ?? lhs.1.name ?? ""
        let r = rhs.1.updatedAt ?? rhs.1.name ?? ""
        if l != r { return l > r }
        return lhs.0 < rhs.0
    }.map { $0.1 }
    return out
}

// MARK: - Sources #8/#9: catalog_sources + capability_trust_roots
//
// The two on-disk-merge actors (`SwiftNativeCatalogSources` and
// `SwiftNativeCapabilityTrustRoots`) live in CapabilityCatalog.swift — both
// wrap their read-merge-write in `persistence.withFileLock` symmetric with
// the daemon's `with file_lock(...)` block at the retired daemon and :6661.


// MARK: - SwiftNative impl (wave 13 full in-process port)
//
// Builds the network from `capabilityRecordsFull(...)` (the 9-source
// aggregator) + the two on-disk-merge actors above. No daemon round-trip.

public actor SwiftNativeCapabilityTrust: CapabilityTrustProtocol {
    private let dataRoot: URL
    private let personaRoot: URL?
    private let persistence: any PersistenceCoreProtocol
    private let clock: @Sendable () -> Date
    private let catalogSourcesActor: SwiftNativeCatalogSources
    private let trustRootsActor: SwiftNativeCapabilityTrustRoots
    private let mcpDispatcher: SwiftNativeMCPDispatcher?

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        personaRoot: URL? = nil,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = { Date() },
        mcpDispatcher: SwiftNativeMCPDispatcher? = nil
    ) {
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
        self.persistence = persistence
        self.clock = clock
        self.catalogSourcesActor = SwiftNativeCatalogSources(
            dataRoot: dataRoot, persistence: persistence, clock: clock
        )
        self.trustRootsActor = SwiftNativeCapabilityTrustRoots(
            dataRoot: dataRoot, persistence: persistence, clock: clock
        )
        self.mcpDispatcher = mcpDispatcher
    }

    /// Byte-for-byte port of the retired daemon capability_trust_network().
    public func network() async throws -> CapabilityTrustNetwork {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let allRecords = await capabilityRecordsFull(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            nowISO: nowISO,
            persistence: persistence,
            mcpDispatcher: mcpDispatcher
        )
        let sliced = Array(allRecords.prefix(200))
        var records: [CapabilityTrustRecord] = []
        records.reserveCapacity(sliced.count)
        var trustedCount = 0
        var reviewCount = 0
        var untrustedCount = 0
        for record in sliced {
            let trust = scoreCapabilityRecord(record)
            let tier = capabilityTrustTier(forScore: trust.score)
            switch tier {
            case "trusted":   trustedCount += 1
            case "review":    reviewCount += 1
            default:          untrustedCount += 1
            }
            records.append(CapabilityTrustRecord(
                id: jsonOptionalStringField(record, "id") ?? "",
                name: jsonOptionalStringField(record, "name"),
                kind: jsonOptionalStringField(record, "kind"),
                status: jsonOptionalStringField(record, "status"),
                riskClass: jsonOptionalStringField(record, "riskClass"),
                trustScore: trust.score,
                trustTier: tier,
                reasons: trust.reasons
            ))
        }

        let rootDicts = try await trustRootsActor.capabilityTrustRoots()
        let sourceDicts = try await catalogSourcesActor.catalogSources()

        return CapabilityTrustNetwork(
            status: "ready",
            roots: rootDicts.map(decodeTrustRoot),
            sources: sourceDicts.map(decodeCatalogSource),
            records: records,
            summary: CapabilityTrustSummary(
                trusted: trustedCount, review: reviewCount, untrusted: untrustedCount
            ),
            createdAt: nowISO
        )
    }

    /// Byte-for-byte port of the retired daemon evaluate_capability_trust().
    /// Side effects (events.jsonl append + record_trace) intentionally omitted —
    /// the daemon's route still performs the audit write when the flag is OFF.
    public func evaluate(capabilityId: String) async throws -> CapabilityTrustEvaluation {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let records = await capabilityRecordsFull(
            dataRoot: dataRoot,
            personaRoot: personaRoot,
            nowISO: nowISO,
            persistence: persistence,
            mcpDispatcher: mcpDispatcher
        )
        let match = records.first { rec in
            let id = jsonOptionalStringField(rec, "id") ?? ""
            let sid = jsonOptionalStringField(rec, "sourceId") ?? ""
            return id == capabilityId || sid == capabilityId
        }
        guard let record = match else {
            throw CapabilityTrustError.unknownCapability(capabilityId)
        }
        let trust = scoreCapabilityRecord(record)
        let tier = capabilityTrustTier(forScore: trust.score)
        return CapabilityTrustEvaluation(
            id: jsonOptionalStringField(record, "id") ?? capabilityId,
            name: jsonOptionalStringField(record, "name"),
            trustScore: trust.score,
            trustTier: tier,
            reasons: trust.reasons,
            createdAt: nowISO
        )
    }
}

// MARK: - JSONValue → struct decoders (file-local)

private func jsonOptionalStringField(_ obj: [String: JSONValue], _ key: String) -> String? {
    if case .string(let s)? = obj[key] { return s }
    return nil
}

private func decodeTrustRoot(_ dict: [String: JSONValue]) -> CapabilityTrustRoot {
    CapabilityTrustRoot(
        id: jsonOptionalStringField(dict, "id") ?? "",
        name: jsonOptionalStringField(dict, "name") ?? "",
        kind: jsonOptionalStringField(dict, "kind"),
        fingerprint: jsonOptionalStringField(dict, "fingerprint"),
        status: jsonOptionalStringField(dict, "status"),
        createdAt: jsonOptionalStringField(dict, "createdAt"),
        updatedAt: jsonOptionalStringField(dict, "updatedAt")
    )
}

private func decodeCatalogSource(_ dict: [String: JSONValue]) -> CapabilityCatalogSource {
    CapabilityCatalogSource(
        id: jsonOptionalStringField(dict, "id") ?? "",
        name: jsonOptionalStringField(dict, "name") ?? "",
        kind: jsonOptionalStringField(dict, "kind"),
        url: jsonOptionalStringField(dict, "url"),
        status: jsonOptionalStringField(dict, "status"),
        trustedRootId: jsonOptionalStringField(dict, "trustedRootId"),
        lastCheckedAt: jsonOptionalStringField(dict, "lastCheckedAt"),
        createdAt: jsonOptionalStringField(dict, "createdAt"),
        updatedAt: jsonOptionalStringField(dict, "updatedAt")
    )
}

// MARK: - Factory

/// Wave 13: SwiftNative is a full in-process port. No daemon round-trip.
/// Records flow through `capabilityRecordsFull` (9 sources); roots/sources
/// flow through the two on-disk-merge actors with symmetric flock against
/// the Python side. The Python-backed impl stays available as the rollback
/// when `capabilityTrust` is absent from `NATIVE_AGENT_SWIFT_SUBSYSTEMS`.
public func makeCapabilityTrust() -> any CapabilityTrustProtocol {
    return SwiftNativeCapabilityTrust()
}
