import Foundation
import Experiences

// Blueprint: | `BotEventTriggers.swift` | `BotEventRouter`, `BotEventStore`: Slack admission and durable wake evidence |

/// Reuse the socket-mode listener so trigger admission needs no separate event loop.
public enum BotEventSource: String, Codable, Sendable, CaseIterable {
    case slack

    public var label: String { "Slack" }
}

/// Store Slack channel IDs because incoming events cannot resolve names.
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

    public var label: String {
        let base = "\(source.label) · \(filter.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let keyword else { return base }
        return base + " · \(keyword)"
    }

    /// Slack delivers IDs without name resolution; storing a name would silently prevent matching.
    public static func isChannelID(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.count >= 8, let first = text.first, "CGD".contains(first) else { return false }
        return text.allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
    }

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

public struct BotIncomingEvent: Sendable, Equatable {
    public let id: String
    public let source: BotEventSource
    public let target: String
    public let summary: String
    public let detail: String
    public let provenance: BotEventProvenance

    public init(id: String, source: BotEventSource, target: String, summary: String, detail: String,
                verifiedUserID: String? = nil) {
        self.id = id
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

public struct BotEventRecord: Codable, Equatable, Sendable {
    public var source: BotEventSource
    public var target: String
    public var summary: String
    public var at: Date
    public var outcome: BotEventOutcome
    public var detail: String?
    /// The accepted request this event queued, so a later hold settles this event and no other.
    public var requestID: UUID?

    public init(source: BotEventSource, target: String, summary: String, at: Date = Date(),
                outcome: BotEventOutcome, detail: String? = nil, requestID: UUID? = nil) {
        self.source = source
        self.target = target
        self.summary = summary
        self.at = at
        self.outcome = outcome
        self.detail = detail
        self.requestID = requestID
    }
}

/// Wake evidence is read-only; inspecting it cannot execute a bot.
public struct BotEventStore: Sendable {
    private let disk: StandingBotsDisk
    public init(dataRoot: URL) { disk = StandingBotsDisk(dataRoot: dataRoot) }
    private var path: URL { disk.root.appendingPathComponent("last-events.json") }

    private func records() throws -> [String: BotEventRecord] {
        try disk.read([String: BotEventRecord].self, at: path) ?? [:]
    }

    public func lastEvents() throws -> [UUID: BotEventRecord] {
        let saved = try disk.locked { try records() }
        return Dictionary(saved.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Update the held request's own evidence; a later event queued for the same bot keeps its label.
    func hold(bot id: UUID, request: UUID, detail: String) throws {
        try disk.locked {
            var saved = try records()
            guard var record = saved[id.uuidString], record.outcome == .queued, record.requestID == request else { return }
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

/// Shared queue admission preserves concurrency, daily budgets and unattended-work authority.
public struct BotEventRouter: Sendable {
    private let dataRoot: URL
    private let isAutonomyEnabled: @Sendable () async -> Bool

    public init(dataRoot: URL, isAutonomyEnabled: @escaping @Sendable () async -> Bool = { true }) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.isAutonomyEnabled = isAutonomyEnabled
    }

    @discardableResult
    public func deliver(_ event: BotIncomingEvent, scope: BotRunScope) async throws -> [UUID] {
        do { return try await deliverChecked(event, scope: scope) }
        catch {
            RepairOwed.owe(dataRoot, id: "bot-event-admission:" + event.id, kind: .run,
                evidence: [.init(source: "slack/inbound_delivery_journal.json", id: event.id)],
                operation: "bots.event.admission:" + event.id,
                owner: "bots/definitions, run-queue.json and last-events.json",
                words: """
                    Helper event \(event.id) from \(event.source.label) in \(event.target) was not fully recorded: \(error). Its accepted \
                    input remains in slack/inbound_delivery_journal.json. Inspect accepted run-queue requests before repairing the wake \
                    record; do not admit the event again to replace missing evidence.
                    """,
                lever: "Repair the named helper storage and reconcile its retained queue receipt.")
            throw error
        }
    }

    private func deliverChecked(_ event: BotIncomingEvent, scope: BotRunScope) async throws -> [UUID] {
        let definitions = try BotDefinitionStore(dataRoot: dataRoot).list()
        let matched = definitions.filter { bot in
            guard !bot.paused, let trigger = bot.eventTrigger else { return false }
            return trigger.wants(event)
        }
        guard !matched.isEmpty else { return [] }
        let store = BotEventStore(dataRoot: dataRoot)
        let queue = BotRunQueue(dataRoot: dataRoot)
        // Event waking spends unattended provider work and must honor its master switch.
        let allowed = await isAutonomyEnabled()
        var woken: [UUID] = []
        for bot in matched {
            guard allowed else {
                try store.record(BotEventRecord(source: event.source, target: event.target,
                    summary: event.summary, outcome: .held,
                    detail: "Autonomy is off"), bot: bot.id)
                continue
            }
            let context = Self.context(event)
            let receipt: BotRunReceipt
            do {
                receipt = try queue.enqueue(bot: bot.id, context: context, origin: .event,
                                            provenance: event.provenance, scope: scope)
            } catch {
                let admissionError = error
                do {
                    try store.record(BotEventRecord(source: event.source, target: event.target,
                        summary: event.summary, outcome: .notRun,
                        detail: "Helper admission failed: \(admissionError)"), bot: bot.id)
                } catch {
                    throw StandingBotsError.corruptStore("""
                        Helper admission failed for \(bot.id): \(admissionError). Its wake record also failed: \(error). Inspect the queue and \
                        repair the named storage before reconciling this event.
                        """)
                }
                throw admissionError
            }
            do {
                try store.record(BotEventRecord(source: event.source, target: event.target,
                    summary: event.summary, outcome: receipt.accepted ? .queued : .notRun,
                    detail: receipt.accepted ? nil : receipt.reason, requestID: receipt.accepted ? receipt.runID : nil), bot: bot.id)
            } catch {
                throw StandingBotsError.corruptStore("""
                    Helper wake record unavailable for \(bot.id), request \(receipt.runID): \(error). The queue retains any accepted \
                    request; repair last-events.json without repeating admission.
                    """)
            }
            if receipt.accepted { woken.append(bot.id) }
        }
        return woken
    }

    /// Outside text is run input, never authority to instruct the app.
    static func context(_ event: BotIncomingEvent) -> String {
        var lines = ["\(event.source.label) · \(event.target)", event.summary]
        if event.detail != event.summary, !event.detail.isEmpty { lines.append(event.detail) }
        return lines.joined(separator: "\n")
    }
}
