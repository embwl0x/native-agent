import Foundation

/// Legacy URL strings remain decodable; new definitions may use explicit types.
public enum BotSource: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    case http(String)
    case tool(String)

    public init(stringLiteral value: String) { self = .http(value) }
    public var reference: String {
        switch self { case .http(let url): return url; case .tool(let name): return "tool:" + name }
    }
    private enum CodingKeys: String, CodingKey { case type, url, name }
    public init(from decoder: Decoder) throws {
        if let url = try? decoder.singleValueContainer().decode(String.self) { self = .http(url); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "http": self = .http(try c.decode(String.self, forKey: .url))
        case "tool": self = .tool(try c.decode(String.self, forKey: .name))
        default: throw StandingBotsError.invalidValue("sources accept http {url} or tool {name}")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .http(let url): var c = encoder.singleValueContainer(); try c.encode(url)
        case .tool(let name):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("tool", forKey: .type); try c.encode(name, forKey: .name)
        }
    }
}

public enum BotRunLimits {
    /// Person-owned app preference; no bot tool exposes a setter.
    public static let minimumIntervalMinutesKey = "standingBots.minimumIntervalMinutes"
    public static var minimumInterval: TimeInterval { minimumInterval(in: .standard) }
    public static func minimumInterval(in defaults: UserDefaults) -> TimeInterval {
        guard let value = defaults.object(forKey: minimumIntervalMinutesKey) as? NSNumber,
              value.doubleValue.isFinite, (1...15).contains(value.doubleValue) else { return 15 * 60 }
        return value.doubleValue * 60
    }
    public static let maximumTokens = 32_000
    public static let maximumSeconds: TimeInterval = 120
    /// Legacy daily allowance retained when decoding old definitions. New bots
    /// choose their own ceiling. Run reservations are never refunded.
    public static let dailyTokens = 256_000
}

/// Configuration only. Interpreting cron expressions and scheduling belong to the future runner.
public enum BotCadence: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: TimeInterval)
    case cron(expression: String, timeZone: String)
}

public struct BotBudget: Codable, Equatable, Sendable {
    public var tokens: Int
    public var seconds: TimeInterval
    public init(tokens: Int, seconds: TimeInterval) {
        self.tokens = tokens
        self.seconds = seconds
    }
}

public struct BotDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var brief: String
    public internal(set) var briefVersion: Int
    public var cadence: BotCadence
    /// Decode-only compatibility for the production view awaiting its next stage.
    public var sources: [BotSource]
    public var provider: String? = nil
    public var model: String? = nil
    public var reasoningEffort: String? = nil
    public var fast: Bool? = nil
    public var dailyTokenCeiling: Int? = nil
    public var notificationCondition: String? = nil
    public var deleted: Bool? = nil
    public var sessionID: String { "bot-" + id.uuidString.lowercased() }
    public var outputFormat: String?
    public var budget: BotBudget
    public var paused: Bool
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), name: String, brief: String, cadence: BotCadence,
                sources: [BotSource] = [], budget: BotBudget, paused: Bool = false,
                outputFormat: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.brief = brief
        self.briefVersion = 1
        self.cadence = cadence
        self.sources = []
        if !sources.isEmpty { self.brief += "\n\nSources: " + sources.map(\.reference).joined(separator: ", ") }
        self.outputFormat = outputFormat
        self.budget = budget
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

extension BotDefinition {
    private enum CodingKeys: String, CodingKey {
        case id, name, brief, briefVersion, cadence, sources, outputFormat, budget, paused, createdAt, updatedAt
        case provider, model, reasoningEffort, fast, dailyTokenCeiling, notificationCondition, deleted
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        brief = try c.decode(String.self, forKey: .brief)
        briefVersion = try c.decode(Int.self, forKey: .briefVersion)
        cadence = try c.decode(BotCadence.self, forKey: .cadence)
        let oldSources = try c.decodeIfPresent([BotSource].self, forKey: .sources) ?? []
        if !oldSources.isEmpty { brief += "\n\nSources: " + oldSources.map(\.reference).joined(separator: ", ") }
        sources = []
        outputFormat = try c.decodeIfPresent(String.self, forKey: .outputFormat)
        budget = try c.decode(BotBudget.self, forKey: .budget)
        paused = try c.decode(Bool.self, forKey: .paused)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        fast = try c.decodeIfPresent(Bool.self, forKey: .fast)
        dailyTokenCeiling = try c.decodeIfPresent(Int.self, forKey: .dailyTokenCeiling)
        notificationCondition = try c.decodeIfPresent(String.self, forKey: .notificationCondition)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
    }
}

public enum BotRunStatus: String, Codable, Sendable {
    case completed, interrupted, failed
    case waitingForApproval = "waiting for approval"
}

public struct BotArtifact: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public var type: String? = nil
    public var mime: String? = nil
    public var base64: String? = nil
    public var byteSize: Int? = nil
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public struct BotAuditRow: Codable, Equatable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable { case create, update, pause, resume }
    public let id: UUID
    public let at: Date
    public let operation: Operation
    /// Full snapshot keeps every prior brief/configuration reviewable.
    public let definition: BotDefinition
}

public enum ShelfRunHealth: String, Codable, Sendable {
    case ok, nothingNew, partial, failed
}

public struct ShelfSourceLink: Codable, Equatable, Sendable {
    public var url: String
    public var datedAt: Date
    public init(url: String, datedAt: Date) { self.url = url; self.datedAt = datedAt }
}

public struct ShelfSpend: Codable, Equatable, Sendable {
    public var tokens: Int
    public var seconds: TimeInterval
    public init(tokens: Int, seconds: TimeInterval) { self.tokens = tokens; self.seconds = seconds }
}

/// Untrusted run evidence. Storing or reading a book never promotes it to memory or context.
public struct ShelfEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let botId: UUID
    public let briefVersion: Int
    public let runAt: Date
    public let coverageStart: Date
    public let coverageEnd: Date
    public let headline: String
    public let findings: String
    public let changedSinceLastGood: String
    public let sourceLinks: [ShelfSourceLink]
    public let uncertainties: [String]
    public let runHealth: ShelfRunHealth
    public let spend: ShelfSpend
    public let failureEvidenceID: UUID?
    public var reply: String? = nil
    public var artifacts: [BotArtifact]? = nil
    public var status: BotRunStatus? = nil
    public var statusDetail: String? = nil
    public var sessionID: String? = nil
    public var actualReply: String { reply ?? findings }
    public var runtimeStatus: BotRunStatus { status ?? (runHealth == .failed ? .failed : runHealth == .partial ? .interrupted : .completed) }


    public init(id: UUID = UUID(), botId: UUID, briefVersion: Int, runAt: Date,
                coverageStart: Date, coverageEnd: Date, headline: String, findings: String,
                changedSinceLastGood: String, sourceLinks: [ShelfSourceLink] = [],
                uncertainties: [String] = [], runHealth: ShelfRunHealth, spend: ShelfSpend,
                failureEvidenceID: UUID? = nil) {
        self.id = id; self.botId = botId; self.briefVersion = briefVersion
        self.runAt = runAt; self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.headline = headline; self.findings = findings
        self.changedSinceLastGood = changedSinceLastGood; self.sourceLinks = sourceLinks
        self.uncertainties = uncertainties; self.runHealth = runHealth; self.spend = spend
        self.failureEvidenceID = failureEvidenceID
    }
}

public struct ShelfIndexRow: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let botId: UUID
    public let briefVersion: Int
    public let runAt: Date
    public let coverageStart: Date
    public let coverageEnd: Date
    public let headline: String
    public let headlineTruncated: Bool
    public let runHealth: ShelfRunHealth
}

public struct ShelfReadPage: Equatable, Sendable {
    public let rows: [ShelfIndexRow]
    public let nextCursor: String?
    /// True when another matching row exists, or an index headline was shortened.
    public let truncated: Bool
}

/// Sparse acknowledgements deliberately preserve holes: reading a later book cannot hide an earlier one.
public struct ShelfReaderCursor: Codable, Equatable, Sendable {
    public let readerId: String
    public internal(set) var readEntryIds: Set<UUID>
}

public enum StandingBotsError: Error, Equatable {
    case invalidValue(String)
    case notFound(UUID)
    case alreadyExists(UUID)
    case staleDefinition(UUID)
    case invalidCursor
    case corruptStore(String)
}
