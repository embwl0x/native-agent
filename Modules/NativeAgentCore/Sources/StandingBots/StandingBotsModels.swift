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
    /// HTTP checks wait at least 15 minutes after completion, including cron schedules.
    public static let minimumInterval: TimeInterval = 15 * 60
    public static let maximumTokens = 32_000
    public static let maximumSeconds: TimeInterval = 120
    /// 2026-09-07: bound unattended fleet spend across bots/restarts without
    /// depending on provider pricing. This is reserved input + output tokens,
    /// not a dollar estimate; interrupted reservations are never refunded.
    public static let dailyTokens = 256_000
}

/// Configuration only. Interpreting cron expressions and scheduling belong to the future runner.
public enum BotCadence: Codable, Equatable, Sendable {
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
    public var sources: [BotSource]
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
        self.sources = sources
        self.outputFormat = outputFormat
        self.budget = budget
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
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

    public init(id: UUID = UUID(), botId: UUID, briefVersion: Int, runAt: Date,
                coverageStart: Date, coverageEnd: Date, headline: String, findings: String,
                changedSinceLastGood: String, sourceLinks: [ShelfSourceLink] = [],
                uncertainties: [String] = [], runHealth: ShelfRunHealth, spend: ShelfSpend) {
        self.id = id; self.botId = botId; self.briefVersion = briefVersion
        self.runAt = runAt; self.coverageStart = coverageStart; self.coverageEnd = coverageEnd
        self.headline = headline; self.findings = findings
        self.changedSinceLastGood = changedSinceLastGood; self.sourceLinks = sourceLinks
        self.uncertainties = uncertainties; self.runHealth = runHealth; self.spend = spend
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
