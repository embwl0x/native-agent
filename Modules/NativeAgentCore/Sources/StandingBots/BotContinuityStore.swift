import Foundation

/// Bot-owned working material, never a resident memory or chat transcript.
public struct BotKeptReport: Codable, Sendable, Equatable {
    public let name: String
    public let content: String
    public init(name: String, content: String) { self.name = name; self.content = content }
}

public struct BotDocumentReference: Codable, Sendable, Equatable {
    public let name: String
    public let version: UUID
    public let previousVersion: UUID?
    public let runID: UUID
    public let savedAt: Date
    public let bytes: Int
}

public struct BotDocumentPage: Codable, Sendable {
    public let documents: [BotDocumentReference]
    public let nextOffset: Int?
}

public struct BotDocumentRead: Codable, Sendable {
    public let document: BotDocumentReference
    public let content: String
    public let offset: Int
    public let nextOffset: Int?
}

public struct BotWorkingContext: Codable, Sendable {
    public var notes: String = ""
    public var compacted: Bool = false
    public var lastRunID: UUID?
    public var documents: [BotDocumentReference] = []
}

/// One bounded current manifest and immutable report revisions under bots/<id>.
/// Revisions are written before atomic manifest publication. An interrupted
/// publication can leave an unreferenced revision, but cannot rewrite history.
public struct BotContinuityStore: Sendable {
    public static let maximumContextBytes = 12_000
    public static let maximumDocuments = 8
    public static let maximumDocumentBytes = 32_000
    public static let maximumReadCharacters = 8_000
    private let disk: StandingBotsDisk
    public init(dataRoot: URL) { disk = StandingBotsDisk(dataRoot: dataRoot) }

    public func context(bot: UUID) throws -> BotWorkingContext {
        try disk.locked { try load(bot) }
    }

    public func list(bot: UUID, offset: Int = 0, limit: Int = 20) throws -> BotDocumentPage {
        guard offset >= 0, (1...100).contains(limit) else { throw StandingBotsError.invalidValue("document page") }
        return try disk.locked {
            let documents = try load(bot).documents.sorted { $0.name < $1.name }
            let start = min(offset, documents.count)
            let end = start + min(limit, documents.count - start)
            return BotDocumentPage(documents: Array(documents[start..<end]), nextOffset: end < documents.count ? end : nil)
        }
    }

    /// Character offsets never split UTF-8. Continue with the returned version
    /// to read a stable revision while a later run publishes a new one.
    public func read(bot: UUID, name: String, version: UUID? = nil,
                     offset: Int = 0, limit: Int = 4_000) throws -> BotDocumentRead {
        try Self.validateName(name)
        guard offset >= 0, (1...Self.maximumReadCharacters).contains(limit) else {
            throw StandingBotsError.invalidValue("document read page")
        }
        return try disk.locked {
            let state = try load(bot)
            guard let current = state.documents.first(where: { $0.name == name }) else {
                throw StandingBotsError.invalidValue("unknown kept document")
            }
            let document = try revision(bot: bot, name: name, version: version ?? current.version)
            let start = min(offset, document.content.count)
            let content = String(document.content.dropFirst(start).prefix(limit))
            let end = start + content.count
            return BotDocumentRead(document: document.reference, content: content, offset: start,
                                   nextOffset: end < document.content.count ? end : nil)
        }
    }

    /// Bounded material projection for run/ask prompts. Truncation is explicit;
    /// retained full documents remain available through paginated shelf reads.
    public func material(bot: UUID, maximumBytes: Int) throws -> String {
        try disk.locked {
            let state = try load(bot)
            let share = max(0, maximumBytes / (state.documents.count + 1) - 180)
            let notes = state.notes.utf8.count <= share ? state.notes
                : "[Earlier notes omitted]\n" + String(decoding: state.notes.utf8.suffix(max(0, share - 30)), as: UTF8.self)
            var text = "Working notes (compacted: \(state.compacted)):\n\(notes)\n"
            for reference in state.documents.sorted(by: { $0.name < $1.name }) {
                text += "\nKept document: \(reference.name), version: \(reference.version)\n"
                text += Self.bounded(try revision(bot: bot, name: reference.name, version: reference.version).content, bytes: share)
            }
            return Self.bounded(text, bytes: maximumBytes)
        }
    }

    func publish(bot: UUID, runID: UUID, notes: String, compacted: Bool, reports: [BotKeptReport]) throws {
        guard notes.utf8.count <= Self.maximumContextBytes else { throw BotRunnerError.budgetStop }
        try Self.validateReports(reports)
        try disk.locked {
            try Task.checkCancellation()
            var state = try load(bot)
            guard state.lastRunID != runID else { throw StandingBotsError.alreadyExists(runID) }
            guard Set(state.documents.map(\.name)).union(reports.map(\.name)).count <= Self.maximumDocuments else {
                throw StandingBotsError.invalidValue("at most eight kept documents per bot")
            }
            for report in reports {
                try Task.checkCancellation()
                let previous = state.documents.first { $0.name == report.name }
                let reference = BotDocumentReference(name: report.name, version: UUID(), previousVersion: previous?.version,
                    runID: runID, savedAt: Date(), bytes: report.content.utf8.count)
                let document = Revision(reference: reference, content: report.content)
                try disk.write(document, at: revisionPath(bot, reference.version))
                state.documents.removeAll { $0.name == report.name }
                state.documents.append(reference)
            }
            state.notes = notes
            state.compacted = compacted
            state.lastRunID = runID
            try Task.checkCancellation()
            try disk.write(state, at: contextPath(bot))
        }
    }

    static func validateReports(_ reports: [BotKeptReport]) throws {
        guard reports.count <= maximumDocuments, Set(reports.map(\.name)).count == reports.count else {
            throw StandingBotsError.invalidValue("duplicate or excessive kept documents")
        }
        for report in reports {
            try validateName(report.name)
            guard report.content.utf8.count <= maximumDocumentBytes else { throw BotRunnerError.budgetStop }
        }
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        let cap = max(0, bytes)
        guard text.utf8.count > cap else { return text }
        let marker = "\n[Material truncated; use shelf_document for full kept reports.]"
        let prefix = String(decoding: text.utf8.prefix(max(0, cap - marker.utf8.count - 3)), as: UTF8.self)
        return prefix + String(marker.prefix(cap < marker.utf8.count ? cap : marker.count))
    }

    private func load(_ bot: UUID) throws -> BotWorkingContext {
        _ = try disk.definition(bot)
        let state = try disk.read(BotWorkingContext.self, at: contextPath(bot)) ?? BotWorkingContext()
        guard state.notes.utf8.count <= Self.maximumContextBytes,
              state.documents.count <= Self.maximumDocuments,
              Set(state.documents.map(\.name)).count == state.documents.count else {
            throw StandingBotsError.corruptStore("bot working context bounds")
        }
        for reference in state.documents {
            try Self.validateName(reference.name)
            guard (0...Self.maximumDocumentBytes).contains(reference.bytes) else {
                throw StandingBotsError.corruptStore("kept document bounds")
            }
        }
        return state
    }

    private struct Revision: Codable {
        let reference: BotDocumentReference
        let content: String
    }

    private func revision(bot: UUID, name: String, version: UUID) throws -> Revision {
        guard let value = try disk.read(Revision.self, at: revisionPath(bot, version)),
              value.reference.version == version, value.reference.name == name,
              value.content.utf8.count == value.reference.bytes,
              value.content.utf8.count <= Self.maximumDocumentBytes else {
            throw StandingBotsError.corruptStore("kept document revision")
        }
        return value
    }

    private static func validateName(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil else {
            throw StandingBotsError.invalidValue("document name must be 1...80 ASCII letters, digits, dots, underscores or hyphens, starting with a letter or digit")
        }
    }
    private func contextPath(_ bot: UUID) -> URL {
        disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("context.json")
    }
    private func revisionPath(_ bot: UUID, _ version: UUID) -> URL {
        disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("documents")
            .appendingPathComponent(version.uuidString + ".json")
    }
}
