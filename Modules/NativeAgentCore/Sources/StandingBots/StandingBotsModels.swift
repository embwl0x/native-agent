import Foundation
import CoreFoundation
// Blueprint: | `StandingBotsModels.swift` | Helper identity/job/provider/budget definitions and cadence, run and shelf values |

public enum BotRunLimits {
    /// Person-owned app preference; no bot tool exposes a setter.
    public static let minimumIntervalMinutesKey = "standingBots.minimumIntervalMinutes"
    /// Display-only availability. Admission and scheduling use the checked read.
    public static var minimumInterval: TimeInterval? { try? checkedMinimumInterval() }
    public static func checkedMinimumInterval(in defaults: UserDefaults = .standard) throws -> TimeInterval {
        guard let saved = defaults.object(forKey: minimumIntervalMinutesKey) else { return 15 * 60 }
        guard let value = saved as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, (1...15).contains(value.doubleValue) else {
            throw StandingBotsError.invalidValue("""
                Closest a bot may run is unreadable. Set it to a number from 1 to 15 minutes in Helpers settings before scheduling or \
                changing a cadence.
                """)
        }
        return value.doubleValue * 60
    }
    public static let maximumTokens = 32_000
    public static let maximumSeconds: TimeInterval = 120
}

/// Share calendar math between cadence and scheduler; cron follows the Mac's local civil clock.
public enum BotCadence: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: TimeInterval)
    case cron(expression: String)
}

public struct BotBudget: Codable, Equatable, Sendable {
    public var tokens: Int
    /// Crossing records "still finishing"; it does not cancel the helper's work.
    public var seconds: TimeInterval
    public init(tokens: Int, seconds: TimeInterval) {
        self.tokens = tokens
        self.seconds = seconds
    }
}

public struct BotDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    /// Nil personality means the helper is defined by its job alone.
    public var personality: String? = nil
    public var brief: String
    public internal(set) var briefVersion: Int
    public var cadence: BotCadence
    public var eventTrigger: BotEventTrigger? = nil
    public var provider: String? = nil
    public var model: String? = nil
    /// Nil inherits Providers instead of pinning a model choice.
    public var modelPinned: Bool? = false
    public var reasoningEffort: String? = nil
    public var fast: Bool? = nil
    public var dailyTokenCeiling: Int? = nil
    public var notificationCondition: String? = nil
    public var deleted: Bool? = nil
    public var sessionID: String { Self.sessionID(for: id) }
    public static func sessionID(for id: UUID) -> String { "bot-" + id.uuidString.lowercased() }

    /// Resolve helper routing only; a locator does not establish conversation ownership.
    public static func id(forSession sessionID: String?) -> UUID? {
        guard let sessionID, sessionID.hasPrefix("bot-") else { return nil }
        return UUID(uuidString: String(sessionID.dropFirst(4)))
    }
    public var budget: BotBudget
    public var paused: Bool
    public let createdAt: Date
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), name: String, brief: String, cadence: BotCadence,
                budget: BotBudget, paused: Bool = false,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.brief = brief
        self.briefVersion = 1
        self.cadence = cadence
        self.budget = budget
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

extension BotDefinition {
    private enum CodingKeys: String, CodingKey {
        case id, name, personality, brief, briefVersion, cadence, budget, paused, createdAt, updatedAt
        case provider, model, modelPinned, reasoningEffort, fast, dailyTokenCeiling, notificationCondition, deleted
        case eventTrigger
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        personality = try c.decodeIfPresent(String.self, forKey: .personality)
        brief = try c.decode(String.self, forKey: .brief)
        briefVersion = try c.decode(Int.self, forKey: .briefVersion)
        cadence = try c.decode(BotCadence.self, forKey: .cadence)
        budget = try c.decode(BotBudget.self, forKey: .budget)
        paused = try c.decode(Bool.self, forKey: .paused)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        modelPinned = try c.decodeIfPresent(Bool.self, forKey: .modelPinned)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        fast = try c.decodeIfPresent(Bool.self, forKey: .fast)
        dailyTokenCeiling = try c.decodeIfPresent(Int.self, forKey: .dailyTokenCeiling)
        notificationCondition = try c.decodeIfPresent(String.self, forKey: .notificationCondition)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
        eventTrigger = try c.decodeIfPresent(BotEventTrigger.self, forKey: .eventTrigger)
    }

}

public enum BotRunStatus: String, Codable, Sendable {
    case completed, stopped, interrupted, failed
    case waitingForApproval = "waiting for approval"
    /// The run awaits a person's answer to its card, without interruption or failure.
    case waitingOnPerson = "waiting on you"
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
    /// Record measured usage only: a daily reservation is a ceiling, and missing measurement is not zero.
    public var tokens: Int?
    public var seconds: TimeInterval
    public init(tokens: Int?, seconds: TimeInterval) { self.tokens = tokens; self.seconds = seconds }
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
    public var reply: String? = nil
    public var artifacts: [BotArtifact]? = nil
    public var status: BotRunStatus? = nil
    public var statusDetail: String? = nil
    public var sessionID: String? = nil
    /// Retain the actual run model so settled cards remain honest after provider choices change.
    public var model: String? = nil
    /// Canonical approval state owns waiting; the shelf must reconcile it rather than freeze the saved status.
    public var approvalID: String? = nil
    /// True for a helper-message answer (bot_ask); nil means this field was not recorded.
    public var asked: Bool? = nil
    /// A missing verdict still owes notification with uncertainty; only an explicit false suppresses it.
    public var conditionMet: Bool? = nil
    public var conditionNotificationTitle: String? = nil
    public var actualReply: String { reply ?? findings }
    public var runtimeStatus: BotRunStatus { status ?? (runHealth == .failed ? .failed : runHealth == .partial ? .interrupted : .completed) }


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
    public let truncated: Bool
    public var nextOffset: Int? = nil
}

/// Sparse acknowledgements deliberately preserve holes: reading a later book cannot hide an earlier one.
public struct ShelfReaderCursor: Codable, Equatable, Sendable {
    public let readerId: String
    public internal(set) var readEntryIds: Set<UUID>
}

/// Record expired occurrences without retrying them; the scheduler advances to the next occurrence.
public struct BotMissedRun: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case autonomyOff, appClosed, asleep, queueBusy, overBudget, notRun
        /// Refused before any turn began; detail preserves the gate's observed reason.
        case blocked
        /// Show only what the scheduler can establish.
        public var words: String {
            switch self {
            case .autonomyOff: return "Autonomy was off"
            case .appClosed: return "the app was closed"
            case .asleep: return "the Mac was asleep"
            case .queueBusy: return "the queue was busy"
            case .overBudget: return "the daily token ceiling was reached"
            case .notRun: return "not run"
            case .blocked: return "could not run"
            }
        }
    }
    public var dueAt: Date
    public var reason: Reason
    /// Carry an actionable remedy when the reason alone does not explain repair.
    public var detail: String? = nil
    public init(dueAt: Date, reason: Reason, detail: String? = nil) {
        self.dueAt = dueAt; self.reason = reason; self.detail = detail
    }
    public var words: String {
        [reason.words, detail].compactMap { $0 }.joined(separator: ": ")
    }
}

public enum StandingBotsError: Error, Equatable {
    case invalidValue(String)
    case notFound(UUID)
    case alreadyExists(UUID)
    case staleDefinition(UUID)
    case invalidCursor
    case corruptStore(String)
}
