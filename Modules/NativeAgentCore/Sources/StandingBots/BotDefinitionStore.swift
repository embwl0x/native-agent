import Foundation
// Blueprint: | `BotDefinitionStore.swift` | Definition persistence and editor model/budget/schedule/event admission; launch leaves saved definitions and model choices untouched, with no migration marker |

/// Empty until explicitly populated. Definition and audit rows commit in the same atomic JSON file.
public struct BotDefinitionStore: Sendable {
    private let disk: StandingBotsDisk
    public init(dataRoot: URL) { disk = StandingBotsDisk(dataRoot: dataRoot) }

    @discardableResult
    public func create(_ definition: BotDefinition) throws -> BotDefinition {
        let result = try disk.locked {
            guard try disk.bytes(at: disk.definitionPath(definition.id)) == nil else {
                throw StandingBotsError.alreadyExists(definition.id)
            }
            try disk.validate(definition, validateCron: true)
            guard definition.briefVersion == 1, definition.updatedAt == definition.createdAt else {
                throw StandingBotsError.invalidValue("new definition version/timestamps")
            }
            let row = BotAuditRow(id: UUID(), at: definition.createdAt, operation: .create, definition: definition)
            try disk.write(BotDefinitionDocument(definition: definition, audit: [row]), at: disk.definitionPath(definition.id))
            return definition
        }
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: nil)
        return result
    }

    /// The same validation `create` and `update` perform — the cadence floor
    /// included — with nothing written. A caller that must refuse a definition
    /// BEFORE it costs an approval click (the chat tools' pre-approval check)
    /// asks here rather than keeping a second copy of the rules.
    public func check(_ definition: BotDefinition) throws {
        try disk.validate(definition, validateCron: true)
    }

    public func get(_ id: UUID) throws -> BotDefinition {
        try disk.locked { try disk.definition(id).definition }
    }

    public func list(includeDeleted: Bool = false) throws -> [BotDefinition] {
        try disk.locked { try listUnlocked(includeDeleted: includeDeleted) }
    }

    /// The same read without the store lock, for a glance that must not wait:
    /// read-only; a definition caught mid-write fails its check and throws.
    public func listUnlocked(includeDeleted: Bool = false) throws -> [BotDefinition] {
        try disk.files(at: disk.root.appendingPathComponent("definitions"), extension: "json").map { path in
            guard let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else {
                throw StandingBotsError.corruptStore("invalid definition filename")
            }
            return try disk.definition(id).definition
        }.filter { includeDeleted || $0.deleted != true }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Pass the previously read value with edits. A concurrent update is rejected, never silently lost.
    /// Changed brief or body format increments briefVersion; cadence, sources and budget remain configuration.
    @discardableResult
    public func update(_ edited: BotDefinition, at: Date = Date()) throws -> BotDefinition {
        let result = try disk.locked {
            var document = try disk.definition(edited.id)
            let old = document.definition
            guard edited.createdAt == old.createdAt, edited.updatedAt == old.updatedAt,
                  edited.briefVersion == old.briefVersion else { throw StandingBotsError.staleDefinition(edited.id) }
            var next = edited
            if next.brief != old.brief || next.outputFormat != old.outputFormat || next.personality != old.personality {
                guard old.briefVersion < Int.max else { throw StandingBotsError.invalidValue("brief version overflow") }
                next.briefVersion += 1
            }
            next.updatedAt = try updatedTime(at, after: old.updatedAt)
            if !next.paused || next.cadence != old.cadence || next.eventTrigger != old.eventTrigger { next.offReason = nil }
            try disk.validate(next, validateCron: true)
            document.definition = next
            document.audit.append(BotAuditRow(id: UUID(), at: at, operation: .update, definition: next))
            try disk.write(document, at: disk.definitionPath(next.id))
            return next
        }
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: nil)
        return result
    }

    @discardableResult
    public func pause(_ id: UUID, paused: Bool = true, at: Date = Date()) throws -> BotDefinition {
        let result = try disk.locked {
            var document = try disk.definition(id)
            document.definition.updatedAt = try updatedTime(at, after: document.definition.updatedAt)
            document.definition.paused = paused
            if !paused { document.definition.offReason = nil }
            document.audit.append(BotAuditRow(id: UUID(), at: at, operation: paused ? .pause : .resume,
                                             definition: document.definition))
            try disk.write(document, at: disk.definitionPath(id))
            return document.definition
        }
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: nil)
        return result
    }

    public func delete(_ id: UUID) throws {
        try disk.locked {
            _ = try disk.definition(id)
            try FileManager.default.removeItem(at: disk.definitionPath(id))
        }
        NotificationCenter.default.post(name: BotRunQueue.didChange, object: nil)
    }

    private func updatedTime(_ at: Date, after old: Date) throws -> Date {
        guard at.timeIntervalSinceReferenceDate.isFinite else { throw StandingBotsError.invalidValue("updatedAt") }
        // A monotonic persisted revision stamp also detects writes in the same clock tick.
        return Date(timeIntervalSinceReferenceDate: max(at.timeIntervalSinceReferenceDate,
                                                       old.timeIntervalSinceReferenceDate.nextUp))
    }
}

extension BotDefinitionStore {
    public static func editorDefinition(_ definition: BotDefinition?, name: String, personality: String = "", brief: String,
        provider: String, model: String, think: String, modelPinned: Bool, providerReady: Bool,
        supportedEfforts: [String]?, supportsFast: Bool, fast: Bool?, tokens: String, seconds: String, daily: String,
        when: String, hours: String, cron: String, weekday: Int, clockText: String,
        timingUnchanged: Bool, eventSource: BotEventSource, eventFilter: String, eventKeyword: String,
        tell: Bool, condition: String) throws -> BotDefinition {
        if modelPinned {
            guard providerReady, supportedEfforts?.contains(think) == true else {
                throw EditorError.message("Choose a connected account, a model it serves, and a supported Think level.")
            }
        }
        let tokenLimit = tokens.isEmpty ? BotRunLimits.maximumTokens : Int(tokens) ?? 0
        let timeLimit = seconds.isEmpty ? BotRunLimits.maximumSeconds : Double(seconds) ?? 0
        // Blank means no daily ceiling: only a limit someone sets is enforced
        // (10-24: an unset ceiling silently became 256K and stopped a helper).
        let dailyLimit: Int? = daily.isEmpty ? nil : Int(daily) ?? 0
        guard tokenLimit > 0, timeLimit.isFinite, timeLimit > 0, dailyLimit.map({ $0 > 0 }) ?? true else {
            throw EditorError.message("Limits must be positive numbers, or blank for the defaults.")
        }
        let timing: BotCadence
        if let definition, timingUnchanged {
            timing = definition.cadence
        } else {
            switch when {
            case "Manual only": timing = .manual
            case "Daily", "Weekdays", "Weekly":
                timing = try StandingBotSchedule.parse(when == "Weekly"
                    ? "weekly on \(StandingBotSchedule.weekdays[weekday]) at \(clockText)" : "\(when) at \(clockText)")
            case "Every N hours":
                guard let value = Double(hours), value.isFinite, value > 0 else { throw EditorError.message("Enter the number of hours.") }
                timing = .interval(seconds: value * 3600)
            case "Custom": timing = .cron(expression: cron)
            // An event-woken bot keeps no schedule: the event is the occurrence.
            case "On an event": timing = .manual
            default: timing = .manual
            }
        }
        var trigger: BotEventTrigger?
        if when == "On an event" {
            let target = eventFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { throw EditorError.message("Enter the Slack channel ID.") }
            if !BotEventTrigger.isChannelID(target) {
                throw EditorError.message("Enter the Slack channel ID, such as C0123ABCD. In Slack, open the channel, choose View channel details, and copy the ID at the bottom.")
            }
            trigger = BotEventTrigger(source: eventSource,
                filter: target.uppercased(),
                keyword: eventKeyword)
        }
        var bot = definition ?? BotDefinition(name: name, brief: brief, cadence: timing,
            budget: BotBudget(tokens: tokenLimit, seconds: timeLimit))
        bot.name = name; bot.brief = brief; bot.outputFormat = nil
        let character = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.personality = character.isEmpty ? nil : character
        bot.provider = provider; bot.model = model; bot.reasoningEffort = think
        bot.modelPinned = modelPinned
        bot.fast = supportsFast ? (fast ?? false) : false
        if !modelPinned { bot.followProviders() }
        bot.eventTrigger = trigger
        bot.cadence = timing; bot.budget = BotBudget(tokens: tokenLimit, seconds: timeLimit); bot.dailyTokenCeiling = dailyLimit
        if tell && condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw EditorError.message("Enter a condition or turn Tell me if off.") }
        bot.notificationCondition = tell ? condition : nil
        return bot
    }
    private enum EditorError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let text): text } }
    }
}
