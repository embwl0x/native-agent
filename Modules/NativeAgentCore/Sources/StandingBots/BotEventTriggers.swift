import Foundation

// Blueprint: | `BotEventTriggers.swift` | `BotEventRouter` and `BotEventStore`: Slack event matching/admission and durable wake records from already received events |

/// Slack events wake bots through StandingBots matching, admission and wake
/// records; the listener stays with the socket-mode runner that receives them.
public enum BotEventSource: String, Codable, Sendable, CaseIterable {
    case slack

    public var label: String { "Slack" }
}

/// Persisted on the definition. `filter` is the Slack channel ID; `keyword` is
/// optional and must appear in the event text.
public struct BotEventTrigger: Codable, Equatable, Sendable {
    public var source: BotEventSource
    public var filter: String
    public var keyword: String?

    public init(source: BotEventSource, filter: String, keyword: String? = nil) {
        self.source = source
        self.filter = filter
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyword = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// "Slack · C0123ABCD", with the keyword appended.
    public var label: String {
        let base = "\(source.label) · \(filter.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let keyword else { return base }
        return base + " · \(keyword)"
    }

    /// Slack delivers a channel ID, never a name, and nothing in the app resolves
    /// one to the other — so a Slack trigger stores the ID and the editor asks for
    /// it. A name would silently never match.
    public static func isChannelID(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.count >= 8, let first = text.first, "CGD".contains(first) else { return false }
        return text.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
    }

    /// Match the admitted Slack channel ID before applying the optional keyword.
    func wants(_ event: BotIncomingEvent) -> Bool {
        guard filter.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            event.target.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { return false }
        if let keyword {
            let haystack = (event.summary + "\n" + event.detail).lowercased()
            guard haystack.contains(keyword.lowercased()) else { return false }
        }
        return true
    }
}

/// What an arriving event is: where it came from, one line for the card, and the
/// text the run reads.
public struct BotIncomingEvent: Sendable, Equatable {
    public let source: BotEventSource
    /// The Slack channel id the runner received.
    public let target: String
    public let summary: String
    public let detail: String
    public let provenance: BotEventProvenance

    public init(source: BotEventSource, target: String, summary: String, detail: String,
                verifiedUserID: String? = nil) {
        self.source = source
        self.target = target
        self.summary = summary
        self.detail = detail
        self.provenance = BotEventProvenance(source: source, verifiedChatID: target, verifiedUserID: verifiedUserID)
    }
}

public enum BotEventOutcome: String, Codable, Sendable {
    case queued, held, notRun = "not_run"
}

/// The last event that woke a bot, shown on the bot card.
public struct BotEventRecord: Codable, Equatable, Sendable {
    public var source: BotEventSource
    public var target: String
    public var summary: String
    public var at: Date
    public var outcome: BotEventOutcome
    public var detail: String?

    public init(source: BotEventSource, target: String, summary: String, at: Date = Date(),
                outcome: BotEventOutcome, detail: String? = nil) {
        self.source = source
        self.target = target
        self.summary = summary
        self.at = at
        self.outcome = outcome
        self.detail = detail
    }
}

/// One small file beside the definitions. Evidence only: reading it never runs
/// anything.
public struct BotEventStore: Sendable {
    private let disk: StandingBotsDisk
    public init(dataRoot: URL) { disk = StandingBotsDisk(dataRoot: dataRoot) }
    private var path: URL { disk.root.appendingPathComponent("last-events.json") }

    /// Discard records for retired GitHub triggers on read.
    private func records() throws -> [String: BotEventRecord] {
        struct Saved: Decodable {
            let record: BotEventRecord?
            init(from decoder: Decoder) throws {
                struct Source: Decodable { let source: String }
                record = try Source(from: decoder).source == "github" ? nil : BotEventRecord(from: decoder)
            }
        }
        return try disk.read([String: Saved].self, at: path)?.compactMapValues(\.record) ?? [:]
    }

    public func lastEvents() throws -> [UUID: BotEventRecord] {
        let saved = try disk.locked { try records() }
        return Dictionary(saved.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The event was accepted when it arrived and a gate shut before its request
    /// was admitted. The record already on disk is the one that describes it, so
    /// it is the one that changes — nothing here invents an event.
    func hold(bot id: UUID, detail: String) throws {
        try disk.locked {
            var saved = try records()
            guard var record = saved[id.uuidString], record.outcome == .queued else { return }
            record.outcome = .held
            record.detail = detail
            saved[id.uuidString] = record
            try disk.write(saved, at: path)
        }
    }

    func record(_ record: BotEventRecord, bot id: UUID) throws {
        try disk.locked {
            var saved = try records()
            saved[id.uuidString] = record
            try disk.write(saved, at: path)
        }
    }
}

/// Delivery: match the event against every bot's trigger, then admit through
/// the ordinary run queue so concurrency and the daily budget are unchanged.
/// Autonomy off holds the event instead of running it — the record says so.
public struct BotEventRouter: Sendable {
    private let dataRoot: URL
    private let isAutonomyEnabled: @Sendable () async -> Bool

    public init(dataRoot: URL, isAutonomyEnabled: @escaping @Sendable () async -> Bool = { true }) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.isAutonomyEnabled = isAutonomyEnabled
    }

    /// Returns the bots this event woke. A bot with no trigger, a paused bot, or
    /// a trigger that does not want the event is untouched.
    @discardableResult
    public func deliver(_ event: BotIncomingEvent) async -> [UUID] {
        let definitions = (try? BotDefinitionStore(dataRoot: dataRoot).list()) ?? []
        let matched = definitions.filter { bot in
            guard !bot.paused, let trigger = bot.eventTrigger else { return false }
            return trigger.wants(event)
        }
        guard !matched.isEmpty else { return [] }
        let store = BotEventStore(dataRoot: dataRoot)
        let queue = BotRunQueue(dataRoot: dataRoot)
        // Event waking is unattended provider spend and passes the same master
        // Autonomy switch scheduled runs pass.
        let allowed = await isAutonomyEnabled()
        var woken: [UUID] = []
        for bot in matched {
            guard allowed else {
                try? store.record(BotEventRecord(source: event.source, target: event.target,
                    summary: event.summary, outcome: .held,
                    detail: "Autonomy is off"), bot: bot.id)
                continue
            }
            let context = Self.context(event)
            do {
                let receipt = try queue.enqueue(bot: bot.id, context: context, origin: .event,
                                                provenance: event.provenance)
                try? store.record(BotEventRecord(source: event.source, target: event.target,
                    summary: event.summary, outcome: receipt.accepted ? .queued : .notRun,
                    detail: receipt.accepted ? nil : receipt.reason), bot: bot.id)
                if receipt.accepted { woken.append(bot.id) }
            } catch {
                try? store.record(BotEventRecord(source: event.source, target: event.target,
                    summary: event.summary, outcome: .notRun,
                    detail: String(describing: error)), bot: bot.id)
            }
        }
        return woken
    }

    /// The text the brief sees. Untrusted outside content: it is the run's
    /// input, never an instruction to the app.
    static func context(_ event: BotIncomingEvent) -> String {
        var lines = ["\(event.source.label) · \(event.target)", event.summary]
        if event.detail != event.summary, !event.detail.isEmpty { lines.append(event.detail) }
        return lines.joined(separator: "\n")
    }
}
