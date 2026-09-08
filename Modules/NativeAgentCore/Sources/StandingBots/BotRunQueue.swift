import Foundation
import Darwin

public struct BotRunReceipt: Sendable, Equatable {
    public let runID: UUID
    public let accepted: Bool
    public let reason: String
}

public enum BotRunAdmissionError: String, Error {
    case paused, overBudget = "over_budget", alreadyRunning = "already_running"
}

/// Durable local requests, consumed before work so an interrupted run is never
/// replayed. All runners in this process share admission with tool callers.
public struct BotRunQueue: Sendable {
    public static let didChange = Notification.Name("StandingBots.scheduleDidChange")
    private let disk: StandingBotsDisk
    private let dataRoot: URL
    private var path: URL { disk.root.appendingPathComponent("run-queue.json") }
    private static let admission = Admission()

    // Serializes the short disk transaction and process-wide active claims.
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var active: [String: [UUID: Int32]] = [:]
    }

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        disk = StandingBotsDisk(dataRoot: self.dataRoot)
    }

    private var rootKey: String { dataRoot.resolvingSymlinksInPath().path }

    public func enqueue(bot id: UUID) throws -> BotRunReceipt {
        let runID = UUID()
        do {
            _ = try admit(bot: id, runID: runID, enqueue: true)
            NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
            return BotRunReceipt(runID: runID, accepted: true, reason: "queued")
        } catch let error as BotRunAdmissionError {
            return BotRunReceipt(runID: runID, accepted: false, reason: error.rawValue)
        }
    }

    /// The synchronous tool adapter does no HTTP or provider work.
    public func enqueueRequest(bot id: UUID) throws -> UUID {
        let receipt = try enqueue(bot: id)
        guard receipt.accepted else {
            throw BotRunAdmissionError(rawValue: receipt.reason)!
        }
        return receipt.runID
    }

    func pending() throws -> [UUID: UUID] {
        try disk.locked { try disk.read([UUID: UUID].self, at: path) ?? [:] }
    }

    func rejectPending(bot: UUID, requestID: UUID) throws {
        try disk.locked {
            var requests = try disk.read([UUID: UUID].self, at: path) ?? [:]
            if requests[bot] == requestID {
                requests.removeValue(forKey: bot)
                try disk.write(requests, at: path)
            }
        }
    }

    func claim(bot id: UUID, requestID: UUID?) throws -> BotDefinition {
        try admit(bot: id, runID: requestID, enqueue: false)
    }

    func configuredBudget(bot id: UUID) throws -> BotBudget {
        try disk.locked { try disk.definition(id).definition.budget }
    }

    private func admit(bot id: UUID, runID: UUID?, enqueue: Bool) throws -> BotDefinition {
        let previous = try ShelfStore(dataRoot: dataRoot).lastGood(bot: id)
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try disk.read([UUID: UUID].self, at: path) ?? [:]
            guard Self.admission.active[rootKey]?[id] == nil,
                  requests[id] == nil || (!enqueue && requests[id] == runID) else {
                throw BotRunAdmissionError.alreadyRunning
            }
            // Never unlink this inode: flock is shared by every process and is
            // released by the kernel on exit, including crashes. Unlike a timed
            // lease, a slow live writer cannot lose ownership to a second run.
            let claimPath = disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run.lock")
            try disk.validatePath(claimPath)
            try FileManager.default.createDirectory(at: claimPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(claimPath.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw StandingBotsError.corruptStore("bot run claim unavailable") }
            var retained = false
            defer { if !retained { close(descriptor) } }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw BotRunAdmissionError.alreadyRunning }
                throw StandingBotsError.corruptStore("bot run claim unavailable")
            }
            // Claiming a queued request consumes it even if settings now reject
            // it. A pause or budget edit must not leave a request to replay later.
            if !enqueue, let runID {
                guard requests[id] == runID else { throw BotRunAdmissionError.alreadyRunning }
                requests.removeValue(forKey: id)
                try disk.write(requests, at: path)
            }
            let bot = try disk.definition(id).definition
            guard !bot.paused else { throw BotRunAdmissionError.paused }
            try BotRunner.checkBudget(bot: bot, previous: previous)
            if enqueue {
                requests[id] = runID
                try disk.write(requests, at: path)
            } else {
                let metadata = Data("\(getpid()) \(Date().timeIntervalSince1970)\n".utf8)
                guard ftruncate(descriptor, 0) == 0,
                      metadata.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == metadata.count else {
                    throw StandingBotsError.corruptStore("bot run claim metadata unavailable")
                }
                Self.admission.active[rootKey, default: [:]][id] = descriptor
                retained = true
            }
            return bot
        }
    }

    func finish(bot id: UUID) {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        if let descriptor = Self.admission.active[rootKey]?.removeValue(forKey: id) { close(descriptor) }
        if Self.admission.active[rootKey]?.isEmpty == true {
            Self.admission.active.removeValue(forKey: rootKey)
        }
    }

    /// One cross-process transaction before any effects. Existing unreadable
    /// spend state throws rather than resetting the fleet's allowance.
    func reserveDailySpend(tokens: Int, at now: Date = Date()) throws {
        struct Spend: Codable { var day: Int; var tokens: Int }
        try disk.locked {
            let path = disk.root.appendingPathComponent("daily-spend.json")
            let day = Int(floor(now.timeIntervalSince1970 / 86_400)) // UTC day
            let saved = try disk.read(Spend.self, at: path)
            guard saved == nil || (saved!.tokens >= 0 && saved!.tokens <= BotRunLimits.dailyTokens) else {
                throw StandingBotsError.corruptStore("daily spend")
            }
            // A backwards wall-clock change must not mint another allowance.
            var spend = saved ?? Spend(day: day, tokens: 0)
            if day > spend.day { spend = Spend(day: day, tokens: 0) }
            guard tokens > 0, tokens <= BotRunLimits.dailyTokens - spend.tokens else {
                throw BotRunnerError.dailySpendLimit
            }
            spend.tokens += tokens
            try disk.write(spend, at: path)
        }
    }
}
