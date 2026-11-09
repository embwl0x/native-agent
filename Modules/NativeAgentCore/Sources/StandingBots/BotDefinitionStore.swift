import Foundation
import Experiences
// Blueprint: | `BotDefinitionStore.swift` | Atomic definition/audit persistence, exact session ownership and typed edits |

/// Commit definitions with their audit rows atomically so revisions cannot lose their evidence.
public struct BotDefinitionStore: Sendable {
    private let disk: StandingBotsDisk
    private let dataRoot: URL
    public init(dataRoot: URL) { self.dataRoot = dataRoot; disk = StandingBotsDisk(dataRoot: dataRoot) }

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

    /// Share validation with writers so pre-approval checks cannot drift.
    public func check(_ definition: BotDefinition) throws {
        try disk.validate(definition, validateCron: true)
    }

    public func get(_ id: UUID) throws -> BotDefinition {
        try disk.locked { try disk.definition(id).definition }
    }

    /// Resolve exact ownership first so unrelated damaged definitions cannot block a conversation.
    public func definition(forSession sessionID: String?) throws -> BotDefinition? {
        guard let id = BotDefinition.id(forSession: sessionID) else { return nil }
        return try get(id)
    }

    public func list(includeDeleted: Bool = false) throws -> [BotDefinition] {
        try disk.locked { try listUnlocked(includeDeleted: includeDeleted) }
    }

    public func definitionFiles() throws -> [URL] {
        try disk.files(at: disk.root.appendingPathComponent("definitions"), extension: "json")
    }

    /// A nonblocking glance may fail on a concurrent write; it never takes the store lock.
    public func listUnlocked(includeDeleted: Bool = false) throws -> [BotDefinition] {
        let definitions = try definitionFiles().map { path -> BotDefinition in
            guard let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else {
                throw StandingBotsError.corruptStore("invalid definition filename")
            }
            return try disk.definition(id).definition
        }.filter { includeDeleted || $0.deleted != true }.sorted { $0.id.uuidString < $1.id.uuidString }
        // A valid owner read settles storage repair independently of event replay.
        RepairOwed.settle(dataRoot, operation: "bot.event.definitions",
            evidence: .init(source: "bots/definitions", id: UUID().uuidString.lowercased()))
        return definitions
    }

    /// Pass the previously read value with edits. A concurrent update is rejected, never silently lost.
    /// Changed job or personality increments briefVersion; cadence and budget remain configuration.
    @discardableResult
    public func update(_ edited: BotDefinition, at: Date = Date()) throws -> BotDefinition {
        let result = try disk.locked {
            var document = try disk.definition(edited.id)
            let old = document.definition
            guard edited.createdAt == old.createdAt, edited.updatedAt == old.updatedAt,
                  edited.briefVersion == old.briefVersion else { throw StandingBotsError.staleDefinition(edited.id) }
            var next = edited
            if next.brief != old.brief || next.personality != old.personality {
                guard old.briefVersion < Int.max else { throw StandingBotsError.invalidValue("brief version overflow") }
                next.briefVersion += 1
            }
            next.updatedAt = try updatedTime(at, after: old.updatedAt)
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
            guard document.definition.cadence != .manual || document.definition.eventTrigger != nil else {
                throw StandingBotsError.invalidValue("This helper has no schedule to pause or resume. Manual messages and Run once remain available.")
            }
            document.definition.updatedAt = try updatedTime(at, after: document.definition.updatedAt)
            document.definition.paused = paused
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
            var document = try disk.definition(id)
            guard document.definition.deleted != true else { return }
            let at = Date()
            document.definition.updatedAt = try updatedTime(at, after: document.definition.updatedAt)
            document.definition.deleted = true
            // Preserve settlement evidence for owned runs while excluding this tombstone from admission.
            document.audit.append(BotAuditRow(id: UUID(), at: at, operation: .update,
                                             definition: document.definition))
            try disk.write(document, at: disk.definitionPath(id))
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
    /// Accept domain values so form parsing cannot bypass the owner's validation.
    public static func editedDefinition(_ definition: BotDefinition?, name: String, personality: String?, brief: String,
        provider: String, model: String, think: String, modelPinned: Bool, fast: Bool,
        budget: BotBudget, dailyTokenCeiling: Int?, cadence: BotCadence,
        eventTrigger: BotEventTrigger?, notificationCondition: String?) -> BotDefinition {
        var bot = definition ?? BotDefinition(name: name, brief: brief, cadence: cadence, budget: budget)
        bot.name = name; bot.brief = brief; bot.personality = personality
        bot.provider = provider; bot.model = model; bot.reasoningEffort = think
        bot.modelPinned = modelPinned; bot.fast = fast
        if !modelPinned { bot.followProviders() }
        bot.eventTrigger = eventTrigger; bot.cadence = cadence; bot.budget = budget
        bot.dailyTokenCeiling = dailyTokenCeiling; bot.notificationCondition = notificationCondition
        return bot
    }
}
