// SharedModels.swift — Codable structs shared between Mac and iOS targets.
// All structs here were verified byte-identical between:
//   Mac:  Sources/NativeAgentApp/Models.swift
//   iOS:  iOS/NativeAgentMobile/Sources/Models.swift
// Structs with divergent shapes (MissionRecord dual-casing, EvalRun,
// SchedulerJob, ChatMessageRecord) remain in their respective targets.
import Foundation

// MARK: - Core shared structs

public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var detail: String?
    public var status: String
    public var executionId: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, status, createdAt
        case executionId // encodes as "executionId" (P2-2 de-mission)
        case legacyExecutionId = "missionId" // decode-only fallback — FOREVER, see below
    }
}

// P2-2 de-mission: activity rows are Mac-local (<root>/activity/events.jsonl,
// never synced to iOS — no iOS target references ActivityEvent and the MacSync
// snapshot carries no activity), so the writer flips to "executionId" now.
//
// The "missionId" read-fallback is PERMANENT, not a migration window: 4762
// historical rows in the live events.jsonl carry the old key, the log is
// append-only and never rewritten, and `getActivity()` tails it. Removing the
// fallback silently blanks executionId on every one of those rows.
extension ActivityEvent {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.title = try c.decode(String.self, forKey: .title)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.status = try c.decode(String.self, forKey: .status)
        self.createdAt = try c.decode(String.self, forKey: .createdAt)
        // New key first; legacy rows fall back. Absent/null in both -> nil,
        // exactly as before the flip (the field has always been optional).
        self.executionId = try c.decodeIfPresent(String.self, forKey: .executionId)
            ?? c.decodeIfPresent(String.self, forKey: .legacyExecutionId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(executionId, forKey: .executionId) // new key ONLY
    }
}

public struct WorkshopCounts: Codable, Hashable, Sendable {
    public var active: Int
    public var done: Int
    public var blocked: Int
    public var total: Int

    public init(active: Int, done: Int, blocked: Int, total: Int) {
        self.active = active
        self.done = done
        self.blocked = blocked
        self.total = total
    }
}

public struct ConnectorSummary: Codable, Hashable, Sendable {
    public var enabled: Int
    public var healthy: Int
    public var total: Int

    public init(enabled: Int, healthy: Int, total: Int) {
        self.enabled = enabled
        self.healthy = healthy
        self.total = total
    }
}

public struct TrustSummary: Codable, Hashable, Sendable {
    public var permissionLevel: String?
    public var autonomyDefault: String?
    public var workspaceCount: Int?

    public init(permissionLevel: String?, autonomyDefault: String?, workspaceCount: Int?) {
        self.permissionLevel = permissionLevel
        self.autonomyDefault = autonomyDefault
        self.workspaceCount = workspaceCount
    }
}

public struct MultimodalAttachment: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var base64: String
    public var mime: String
    public var name: String?
    public var byteSize: Int
    public var path: String?

    public init(id: String = UUID().uuidString, type: String, base64: String, mime: String, name: String? = nil, byteSize: Int = 0, path: String? = nil) {
        self.id = id
        self.type = type
        self.base64 = base64
        self.mime = mime
        self.name = name
        self.byteSize = byteSize
        self.path = path
    }
}

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var source: String?
    public var sourceKey: String?
    public var createdAt: String
    public var updatedAt: String?
    public var archived: Bool?
    public var messageCount: Int?
    public var lastMessagePreview: String?
    public var summary: String?
    /// Optional lineage/project metadata stored on the canonical session row.
    /// These fields never create another transcript or session store.
    public var parentSessionId: String? = nil
    public var rootSessionId: String? = nil
    public var forkedAtMessageId: String? = nil
    public var projectSpaceId: String? = nil
    public var worktreePath: String? = nil
    public var providerId: String? = nil
    public var modelId: String? = nil
}

public extension ChatSession {
    /// The default title new sessions are created with. Display logic and
    /// persistence both key off this exact string — keep them on one
    /// constant so they can't drift.
    static let placeholderTitle = "New Chat"

    /// Title for display surfaces. The persistence layer only auto-titles a
    /// session from the first USER message, so agent-initiated sessions the
    /// user never typed into stay "New Chat" forever — a sidebar full of
    /// identical rows. Fall back to a compact cut of the last message
    /// preview so lists stay distinguishable. Display-only; renames and
    /// persistence keep using `title`.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != Self.placeholderTitle { return trimmed }
        let preview = (lastMessagePreview ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return trimmed.isEmpty ? Self.placeholderTitle : trimmed }
        return String(preview.prefix(48))
    }
}

public struct RuntimeHealth: Codable, Hashable, Sendable {
    public var ok: Bool
    public var app: String
    public var version: String
    public var dataDir: String
    public var uptimeSeconds: Double
}

public struct RunRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var status: String
    public var model: String?
    public var requestedModel: String?
    public var reasoningEffort: String?
    public var codexSandbox: String?
    public var fileAccessMode: String?
    public var prompt: String?
    public var output: String?
    public var error: String?
    public var createdAt: String
    public var durationSeconds: Double?
}

public struct MemoryRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var layer: String
    public var text: String
    public var sourceRunId: String?
    public var importance: Double
    public var confidence: Double
    public var status: String?
    public var pinned: Bool?
    public var tags: [String]?
    public var createdAt: String
    public var updatedAt: String?
}

public struct PersonalityTraits: Codable, Hashable, Sendable {
    public var warmth: Double
    public var directness: Double
    public var humor: Double
    public var proactivity: Double
    public var rigor: Double
    public var autonomy: Double
    public var creativity: Double
    public var brevity: Double

    public init(warmth: Double, directness: Double, humor: Double, proactivity: Double,
                rigor: Double, autonomy: Double, creativity: Double, brevity: Double) {
        self.warmth = warmth
        self.directness = directness
        self.humor = humor
        self.proactivity = proactivity
        self.rigor = rigor
        self.autonomy = autonomy
        self.creativity = creativity
        self.brevity = brevity
    }
}

/// Identity-neutral display formatting shared by Mac and iPhone UI.
/// Canonical persona/profile storage remains owned by PersonaEngine; this pure
/// helper only prevents generic onboarding labels from becoming a fake name.
public enum NativeAgentIdentity {
    private static let genericNames: Set<String> = ["agent", "custom", "ai", "male", "female"]

    public static func displayName(
        _ rawValue: String?,
        fallback: String = "NativeAgent"
    ) -> String {
        let name = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !genericNames.contains(name.lowercased()) else {
            return fallback
        }
        let scalars = name.unicodeScalars
        guard scalars.count > 80 else { return name }
        return String(String.UnicodeScalarView(scalars.prefix(80)))
    }
}

/// The PersonalityProfile struct is shared. The Mac-specific defaultProfile
/// static property lives in a Mac-side extension in Models.swift.
public struct PersonalityProfile: Codable, Hashable, Sendable {
    public var schemaVersion: Int?
    public var personaEngineVersion: String?
    public var name: String
    public var personaKind: String
    public var essence: String
    public var voice: String
    public var customDirective: String?
    public var traits: PersonalityTraits
    public var examples: [String]?
    public var forbiddenPatterns: [String]?
    public var instincts: [String]?
    public var boundaries: [String]?
    public var surfaceOverrides: [String: String]?
    public var updatedAt: String?

    public init(
        schemaVersion: Int? = nil,
        personaEngineVersion: String? = nil,
        name: String,
        personaKind: String,
        essence: String,
        voice: String,
        customDirective: String? = nil,
        traits: PersonalityTraits,
        examples: [String]? = nil,
        forbiddenPatterns: [String]? = nil,
        instincts: [String]? = nil,
        boundaries: [String]? = nil,
        surfaceOverrides: [String: String]? = nil,
        updatedAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.personaEngineVersion = personaEngineVersion
        self.name = name
        self.personaKind = personaKind
        self.essence = essence
        self.voice = voice
        self.customDirective = customDirective
        self.traits = traits
        self.examples = examples
        self.forbiddenPatterns = forbiddenPatterns
        self.instincts = instincts
        self.boundaries = boundaries
        self.surfaceOverrides = surfaceOverrides
        self.updatedAt = updatedAt
    }
}

public struct PersonalityDoc: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var filename: String
    public var path: String?
    public var content: String
    public var updatedAt: String?

    public init(
        id: String,
        title: String,
        filename: String,
        path: String? = nil,
        content: String,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.path = path
        self.content = content
        self.updatedAt = updatedAt
    }
}

public struct ApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var action: String
    public var risk: String
    public var reason: String?
    public var status: String
    public var createdAt: String?
    public var resolvedAt: String?
    public var decision: String?
    public var payloadPreview: String?
    public var localOnly: Bool?
    public var remoteResolvable: Bool?
    /// Originating chat session for a `chat_tool_approval` record, carried
    /// straight from the canonical inbox payload's `origin.sessionId`. Nil for
    /// every other approval kind. It exists so a surface can ask "does this
    /// approval belong to the conversation in front of me?" without opening a
    /// second approval store of its own.
    public var chatOriginSessionId: String?

    public init(
        id: String,
        title: String,
        action: String,
        risk: String,
        reason: String? = nil,
        status: String,
        createdAt: String? = nil,
        resolvedAt: String? = nil,
        decision: String? = nil,
        payloadPreview: String? = nil,
        localOnly: Bool? = nil,
        remoteResolvable: Bool? = nil,
        chatOriginSessionId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.risk = risk
        self.reason = reason
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.decision = decision
        self.payloadPreview = payloadPreview
        self.localOnly = localOnly
        self.remoteResolvable = remoteResolvable
        self.chatOriginSessionId = chatOriginSessionId
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { value = NSNull() }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}
