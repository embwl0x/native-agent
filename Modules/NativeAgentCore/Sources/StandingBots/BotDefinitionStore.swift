import Foundation

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

    public func get(_ id: UUID) throws -> BotDefinition {
        try disk.locked { try disk.definition(id).definition }
    }

    public func list() throws -> [BotDefinition] {
        try disk.locked {
            try disk.files(at: disk.root.appendingPathComponent("definitions"), extension: "json").map { path in
                guard let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else {
                    throw StandingBotsError.corruptStore("invalid definition filename")
                }
                return try disk.definition(id).definition
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
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
            if next.brief != old.brief || next.outputFormat != old.outputFormat {
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

    public func audit(_ id: UUID) throws -> [BotAuditRow] {
        try disk.locked { try disk.definition(id).audit }
    }

    private func updatedTime(_ at: Date, after old: Date) throws -> Date {
        guard at.timeIntervalSinceReferenceDate.isFinite else { throw StandingBotsError.invalidValue("updatedAt") }
        // A monotonic persisted revision stamp also detects writes in the same clock tick.
        return Date(timeIntervalSinceReferenceDate: max(at.timeIntervalSinceReferenceDate,
                                                       old.timeIntervalSinceReferenceDate.nextUp))
    }
}
