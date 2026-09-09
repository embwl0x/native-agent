import Foundation
import Darwin
import PersistenceCore
import TriggerScheduler

/// Both stores share one short, synchronous cross-process transaction boundary.
struct StandingBotsDisk: Sendable {
    let root: URL
    private let dataRoot: URL
    init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        root = self.dataRoot.appendingPathComponent("bots", isDirectory: true)
    }

    /// Resolve the configured root once, but never follow links within bot storage,
    /// including dangling links. All disk entry points share this boundary.
    func validatePath(_ path: URL) throws {
        let components = path.standardizedFileURL.pathComponents
        let base = dataRoot.pathComponents
        guard components.count > base.count, Array(components.prefix(base.count)) == base else {
            throw StandingBotsError.corruptStore("bot storage outside data root")
        }
        var current = dataRoot
        for component in components.dropFirst(base.count) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard info.st_mode & S_IFMT != S_IFLNK else {
                    throw StandingBotsError.corruptStore("symlink in bot storage")
                }
            } else if errno != ENOENT {
                throw StandingBotsError.corruptStore("bot storage path unavailable")
            }
        }
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try validatePath(root.appendingPathComponent("store.lock"))
        return try CredentialFileLock.withLock(root.appendingPathComponent("store"), body)
    }

    func read<T: Decodable>(_ type: T.Type, at path: URL) throws -> T? {
        guard let data = try bytes(at: path) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func bytes(at path: URL) throws -> Data? {
        try validatePath(path)
        do { return try Data(contentsOf: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func write<T: Encodable>(_ value: T, at path: URL) throws {
        try validatePath(path)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(encode(value), to: path)
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func files(at directory: URL, extension suffix: String) throws -> [URL] {
        try validatePath(directory)
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == suffix }.sorted { $0.path < $1.path }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func definitionPath(_ id: UUID) -> URL {
        root.appendingPathComponent("definitions").appendingPathComponent(id.uuidString + ".json")
    }

    func definition(_ id: UUID) throws -> BotDefinitionDocument {
        guard let document = try read(BotDefinitionDocument.self, at: definitionPath(id)) else {
            throw StandingBotsError.notFound(id)
        }
        guard document.definition.id == id, document.audit.last?.definition == document.definition else {
            throw StandingBotsError.corruptStore("definition/audit mismatch")
        }
        try validate(document.definition)
        return document
    }

    func validate(_ bot: BotDefinition, validateCron: Bool = false) throws {
        guard !bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bot.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bot.briefVersion > 0, bot.budget.tokens > 0, bot.budget.tokens <= BotRunLimits.maximumTokens,
              bot.budget.seconds.isFinite, bot.budget.seconds > 0, bot.budget.seconds <= BotRunLimits.maximumSeconds,
              bot.createdAt.timeIntervalSince1970.isFinite, bot.updatedAt.timeIntervalSince1970.isFinite else {
            throw StandingBotsError.invalidValue("definition")
        }
        switch bot.cadence {
        case .interval(let seconds):
            let floor = validateCron ? BotRunLimits.minimumInterval : 60
            guard seconds.isFinite, seconds >= floor else {
                throw StandingBotsError.invalidValue("The agent's bot cadence must be at least \(floor / 60) minutes. The person can change Minimum cadence on the Bots page; the agent cannot change this setting.")
            }
        case .cron(let expression, let zone):
            guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  TimeZone(identifier: zone) != nil else { throw StandingBotsError.invalidValue("cron") }
            if validateCron { _ = try Self.nextOccurrence(bot, after: bot.updatedAt) }
        }
    }

    static func nextOccurrence(_ bot: BotDefinition, after date: Date,
                               minimumInterval: TimeInterval = BotRunLimits.minimumInterval) throws -> Date {
        switch bot.cadence {
        case .interval(let seconds): return date.addingTimeInterval(max(seconds, minimumInterval))
        case .cron(let expression, let zone):
            let value: JSONValue = .object(["schedule": .object([
                "type": .string("cron"), "expression": .string(expression), "timezone": .string(zone)
            ])])
            do {
                guard let epoch = try SchedulerJobRuntime.nextRunEpoch(for: value,
                    afterEpoch: date.addingTimeInterval(minimumInterval).timeIntervalSince1970) else {
                    throw StandingBotsError.invalidValue("cron has no next occurrence")
                }
                return Date(timeIntervalSince1970: epoch)
            } catch { throw StandingBotsError.invalidValue("cron: \(error)") }
        }
    }
}

struct BotDefinitionDocument: Codable {
    var definition: BotDefinition
    var audit: [BotAuditRow]
}
