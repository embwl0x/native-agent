import Foundation
import NativeAgentCore
import PersistenceCore
import ToolRegistry

// Blueprint: | `CapabilityTrust.swift` | `SwiftNativeCapabilityTrust`: checked capability trust/catalog values, scoring, evaluation and display projections |

// Capability trust is a checked metadata projection, without evaluation writes.

// MARK: - Wire types
//
// The app renders these directly (Capabilities, engine.trust).

public struct CapabilityTrustRoot: Sendable, Codable, Hashable, Identifiable {
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

public struct CapabilityCatalogSource: Sendable, Codable, Hashable, Identifiable {
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

public struct CapabilityCatalogItem: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String?
    public var description: String?
    public var status: String?
    public var riskClass: String?
    public var installed: Bool?
    public var provenance: String?
    public var installedAt: String?
}

public struct CapabilityPackInstall: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var packId: String
    public var name: String?
    public var version: String?
    public var status: String
    public var signature: String?
    public var installedAt: String?
    public var rolledBackAt: String?
}

// Checked projections of the catalog owner's rows: a present field of the
// wrong type makes the row malformed, and a malformed row fails the read.
extension CapabilityCatalogSource {
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"), kind: try row.optionalString("kind"),
            url: try row.optionalString("url"), status: try row.optionalString("status"),
            trustedRootId: try row.optionalString("trustedRootId"),
            lastCheckedAt: try row.optionalString("lastCheckedAt"),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"))
    }
}

extension CapabilityCatalogItem {
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"), kind: try row.optionalString("kind"),
            description: try row.optionalString("description"), status: try row.optionalString("status"),
            riskClass: try row.optionalString("riskClass"), installed: try row.optionalBool("installed"),
            provenance: try row.optionalString("provenance"), installedAt: try row.optionalString("installedAt"))
    }
}

extension CapabilityPackInstall {
    public init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), packId: try row.string("packId"), name: try row.optionalString("name"),
            version: try row.optionalString("version"), status: try row.string("status"),
            signature: try row.optionalString("signature"), installedAt: try row.optionalString("installedAt"),
            rolledBackAt: try row.optionalString("rolledBackAt"))
    }
}

public struct CapabilityTrustRecord: Sendable, Codable, Hashable, Identifiable {
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

public struct CapabilityTrustSummary: Sendable, Codable, Hashable {
    public var trusted: Int
    public var review: Int
    public var untrusted: Int

    public init(trusted: Int, review: Int, untrusted: Int) {
        self.trusted = trusted; self.review = review; self.untrusted = untrusted
    }
}

public struct CapabilityTrustNetwork: Sendable, Codable, Hashable {
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

public struct CapabilityTrustEvaluation: Sendable, Codable, Hashable {
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
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unknownCapability(let id): return "capability_unknown: No capability matches '\(id)'. Use Capabilities > Refresh, then select a capability from the current list."
        case .unavailable: return "capability_status_unavailable: Checked connector-action status is unavailable. Ask NativeAgent's maintainer to repair the capability-status wiring; evaluation cannot proceed without a complete checked snapshot."
        }
    }
}

// MARK: - Pure scoring
//
// Base 0.45, +0.15 if
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

/// Metadata heuristic, not signature verification or executable permission.
public func scoreCapabilityRecord(_ record: [String: JSONValue]) -> CapabilityTrustScore {
    var score = 0.45
    var reasons = ["Base local capability record."]

    func present(_ key: String) -> Bool {
        record[key]?.isTruthy == true
    }

    if present("sourcePackId") || present("provenance") {
        score += 0.15
        reasons.append("Has provenance metadata.")
    }
    if present("signature") {
        score += 0.20
        reasons.append("Has signature metadata (not verified by this score).")
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
        reasons.append("Has usage metadata.")
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

/// Display score tiers; "trusted" is a heuristic label, not pack admission.
public func capabilityTrustTier(forScore score: Double) -> String {
    if score >= 0.75 { return "trusted" }
    if score >= 0.50 { return "review" }
    return "untrusted"
}

// MARK: - Static capability record (manifest-derived subset)

public struct CapabilityRecord: Codable, Sendable, Hashable, Identifiable {
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

    /// Typed read of the dynamic catalog/intent row, without a JSON byte round-trip.
    /// The mounted catalog requires both identity and kind; malformed optional
    /// fields reject the row.
    public init(catalogRow row: [String: JSONValue]) throws {
        let row = try JSONRow(.object(row))
        self.init(
            id: try row.string("id"), sourceId: try row.optionalString("sourceId"), name: try row.optionalString("name"),
            kind: try row.string("kind"), status: try row.optionalString("status"), description: try row.optionalString("description"),
            triggers: try row.optionalStrings("triggers"), permissions: try row.optionalStrings("permissions"),
            riskClass: try row.optionalString("riskClass"), autoload: try row.optionalBool("autoload"),
            useCount: try row.optionalInt("useCount"),
            lastUsedAt: try row.optionalString("lastUsedAt"), updatedAt: try row.optionalString("updatedAt")
        )
    }
}

// The network joins capabilityRecordsFull with catalog sources and trust roots.

public actor SwiftNativeCapabilityTrust {
    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let connectorActionStatuses: @Sendable () async throws -> [String: String]

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        connectorActionStatuses: @escaping @Sendable () async throws -> [String: String]
    ) {
        self.dataRoot = dataRoot
        self.clock = clock
        self.connectorActionStatuses = connectorActionStatuses
    }

    /// Score the first 200 capability records for display.
    public func network() async throws -> CapabilityTrustNetwork {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let allRecords = try await capabilityRecordsFull(
            dataRoot: dataRoot,
            nowISO: nowISO,
            connectorActionStatuses: connectorActionStatuses
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
                id: record["id"]?.stringValue ?? "",
                name: record["name"]?.stringValue,
                kind: record["kind"]?.stringValue,
                status: record["status"]?.stringValue,
                riskClass: record["riskClass"]?.stringValue,
                trustScore: trust.score,
                trustTier: tier,
                reasons: trust.reasons
            ))
        }

        let rootDicts = try CapabilityCatalogStoreReader.capabilityTrustRoots(dataRoot: dataRoot, clock: clock)
        let sourceDicts = try CapabilityCatalogStoreReader.catalogSources(dataRoot: dataRoot, clock: clock)

        return CapabilityTrustNetwork(
            status: "ready",
            roots: rootDicts.map(decodeTrustRoot),
            sources: try sourceDicts.map { try CapabilityCatalogSource(row: .object($0)) },
            records: records,
            summary: CapabilityTrustSummary(
                trusted: trustedCount, review: reviewCount, untrusted: untrustedCount
            ),
            createdAt: nowISO
        )
    }

    /// Return a read-only score for a capability ID or source ID.
    public func evaluate(capabilityId: String) async throws -> CapabilityTrustEvaluation {
        let nowISO = SwiftNativeManifestSigner.isoTimestamp(clock())
        let records = try await capabilityRecordsFull(
            dataRoot: dataRoot,
            nowISO: nowISO,
            connectorActionStatuses: connectorActionStatuses
        )
        let match = records.first { rec in
            let id = rec["id"]?.stringValue ?? ""
            let sid = rec["sourceId"]?.stringValue ?? ""
            return id == capabilityId || sid == capabilityId
        }
        guard let record = match else {
            throw CapabilityTrustError.unknownCapability(capabilityId)
        }
        let trust = scoreCapabilityRecord(record)
        let tier = capabilityTrustTier(forScore: trust.score)
        return CapabilityTrustEvaluation(
            id: record["id"]?.stringValue ?? capabilityId,
            name: record["name"]?.stringValue,
            trustScore: trust.score,
            trustTier: tier,
            reasons: trust.reasons,
            createdAt: nowISO
        )
    }
}

// MARK: - JSONValue → struct decoders (file-local)

private func decodeTrustRoot(_ dict: [String: JSONValue]) -> CapabilityTrustRoot {
    CapabilityTrustRoot(
        id: dict["id"]?.stringValue ?? "",
        name: dict["name"]?.stringValue ?? "",
        kind: dict["kind"]?.stringValue,
        fingerprint: dict["fingerprint"]?.stringValue,
        status: dict["status"]?.stringValue,
        createdAt: dict["createdAt"]?.stringValue,
        updatedAt: dict["updatedAt"]?.stringValue
    )
}

extension CapabilityRecord {
    /// One case style for every row: sentence case, proper nouns kept.
    public static func title(for capability: CapabilityRecord) -> String {
        sentenceCase(rawTitle(for: capability))
    }

    /// The records to list: built-in features first, then each service's
    /// actions together (`slack.*`, `github.*`, …), by title within a group.
    public static func displayRecords(_ records: [CapabilityRecord]) -> [CapabilityRecord] {
        func service(_ record: CapabilityRecord) -> String {
            let id = record.sourceId ?? ""
            return id.contains(".") ? String(id.prefix { $0 != "." }).lowercased() : ""
        }
        return records
        .map { (service($0), title(for: $0), $0) }
        .sorted { ($0.0, $0.1.lowercased()) < ($1.0, $1.1.lowercased()) }
        .map(\.2)
    }

    /// "Slack List Channels" → "Slack list channels". Only a title written in
    /// Title Case is lowered (anything else may carry names this can't know);
    /// proper nouns, acronyms and mixed-case words (GitHub, iPhone, OAuth1)
    /// keep their case.
    public static func sentenceCase(_ title: String) -> String {
        var words = title.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Title-ish when at least half the later words are capitalised
        // ("X Following timeline"); mixed-case words (iPhone) don't count against.
        let later = words.dropFirst().filter { $0.first?.isLetter == true && !smallWords.contains($0) }
        let capitalised = later.filter { $0.first?.isUppercase == true }
        let isTitleCase = !later.isEmpty && capitalised.count * 2 >= later.count
        if isTitleCase {
            for index in words.indices.dropFirst() {
                let word = words[index]
                guard word.first?.isUppercase == true else { continue }
                let keeps = properNouns.contains(word)
                    || word.dropFirst().contains(where: { $0.isUppercase || $0.isNumber })
                    || !word.allSatisfy(\.isLetter)
                if !keeps { words[index] = word.lowercased() }
            }
        }
        if let first = words.first, let letter = first.first, letter.isLowercase,
           !first.dropFirst().contains(where: \.isUppercase) {
            words[0] = letter.uppercased() + first.dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// Words kept as written inside a sentence-cased title.
    private static let properNouns: Set<String> = [
        "X", "I", "Mac", "Slack", "Notion", "Gmail", "Google", "Telegram", "Apple",
        "Spotlight", "Safari", "Chrome", "Finder", "Shortcuts", "Calendar",
        "Swift", "Python", "Markdown", "Codex", "Claude",
    ]

    /// Small words a Title Case string leaves lowercase.
    private static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "via", "with",
    ]

    private static func rawTitle(for capability: CapabilityRecord) -> String {
        if capability.sourceId == "mac.jxa" { return "Automate Mac apps with JavaScript" }
        let name = (capability.name ?? capability.id)
        // A skill handle like "after-card-verify" reads "After card verify".
        guard capability.kind == "skill", !name.contains(" ") else { return name }
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    public static func description(for capability: CapabilityRecord) -> String? {
        if capability.kind == "tool" {
            return capability.description.flatMap { $0.isEmpty ? nil : $0 } ?? "An additional tool I can use for your tasks."
        }
        guard let description = capability.description else { return nil }
        return capability.kind == "skill" ? plainSkillLine(description) : description
    }

    /// A skill's description is written for me to pick it by ("Use this when
    /// you…"). For User, one clean line: its first sentence that is not that
    /// trigger line; failing that, the trigger with its lead-in stripped and
    /// said as me ("I'm shaping a helper…"). Always a capital first, a full
    /// stop last, and "helper" where the skill says "bot".
    public static func plainSkillLine(_ text: String) -> String {
        let leadIns = ["use this skill when ", "use this whenever ", "use this when ", "use whenever ", "use when "]
        func leadIn(_ sentence: String) -> String? {
            leadIns.first { sentence.lowercased().hasPrefix($0) }
        }
        let sentences = text.components(separatedBy: ". ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = sentences.first else { return text }
        var line = first
        if let lead = leadIn(first) {
            if let plain = sentences.dropFirst().first(where: { !$0.isEmpty && leadIn($0) == nil }) {
                line = plain
            } else {
                line = String(first.dropFirst(lead.count))
                for (you, me) in [("you are ", "I'm "), ("you're ", "I'm "), ("you ", "I ")]
                    where line.lowercased().hasPrefix(you) {
                    line = me + line.dropFirst(you.count)
                    for (later, mine) in [(" you are ", " I am "), (" you're ", " I'm "), (" your ", " my ")] {
                        line = line.replacingOccurrences(of: later, with: mine)
                    }
                    break
                }
            }
        }
        line = line.replacing(/\bbots\b/, with: "helpers").replacing(/\bbot\b/, with: "helper")
        if let first = line.first { line = String(first).uppercased() + line.dropFirst() }
        return line.hasSuffix(".") || line.hasSuffix("!") || line.hasSuffix("?") ? line : line + "."
    }

}
