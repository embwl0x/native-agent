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
        var waiting: [String: [UUID: [CheckedContinuation<Bool, Never>]]] = [:]
    }

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        disk = StandingBotsDisk(dataRoot: self.dataRoot)
    }

    private var rootKey: String { dataRoot.resolvingSymlinksInPath().path }

    public func enqueue(bot id: UUID) throws -> BotRunReceipt {
        let runID = UUID()
        do {
            try disk.locked {
                let bot = try disk.definition(id).definition
                guard bot.deleted != true else { throw StandingBotsError.notFound(id) }
                var requests = try disk.read([UUID: UUID].self, at: path) ?? [:]
                guard requests[id] == nil else { throw BotRunAdmissionError.alreadyRunning }
                requests[id] = runID
                try disk.write(requests, at: path)
            }
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

    public func activeOrQueuedIDs() throws -> Set<UUID> {
        let queued = try pending()
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return Set(queued.keys).union(Self.admission.active[rootKey]?.keys.map { $0 } ?? [])
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

    func claim(bot id: UUID, requestID: UUID?, manual: Bool = false) throws -> BotDefinition {
        try admit(bot: id, runID: requestID, enqueue: false, manual: manual)
    }

    func claimWhenAvailable(bot id: UUID, requestID: UUID?, manual: Bool = false) async throws -> BotDefinition {
        while true {
            try Task.checkCancellation()
            do { return try claim(bot: id, requestID: requestID, manual: manual) }
            catch BotRunAdmissionError.alreadyRunning {
                // Register under the same lock as finish; no missed wakeup and
                // no polling timer. External processes still fail closed at flock.
                let waited = await withCheckedContinuation { continuation in
                    Self.admission.lock.lock()
                    if Self.admission.active[rootKey]?[id] != nil {
                        Self.admission.waiting[rootKey, default: [:]][id, default: []].append(continuation)
                        Self.admission.lock.unlock()
                    } else {
                        Self.admission.lock.unlock()
                        continuation.resume(returning: false)
                    }
                }
                if !waited { return try claim(bot: id, requestID: requestID, manual: manual) }
            }
        }
    }

    func configuredBudget(bot id: UUID) throws -> BotBudget {
        try disk.locked { try disk.definition(id).definition.budget }
    }

    private func admit(bot id: UUID, runID: UUID?, enqueue: Bool, manual: Bool = false) throws -> BotDefinition {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try disk.read([UUID: UUID].self, at: path) ?? [:]
            guard Self.admission.active[rootKey]?[id] == nil,
                  requests[id] == nil || manual || (!enqueue && requests[id] == runID) else {
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
            // it. A budget edit must not leave a request to replay later.
            if !enqueue, let runID {
                guard requests[id] == runID else { throw BotRunAdmissionError.alreadyRunning }
                requests.removeValue(forKey: id)
                try disk.write(requests, at: path)
            }
            let bot = try disk.definition(id).definition
            // A queued deliberate check is independent of scheduled checks.
            guard !bot.paused || enqueue || runID != nil || manual else { throw BotRunAdmissionError.paused }
            guard bot.deleted != true else { throw StandingBotsError.notFound(id) }
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
        defer {
            Self.admission.lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
        }
        if let descriptor = Self.admission.active[rootKey]?.removeValue(forKey: id) { close(descriptor) }
        if Self.admission.active[rootKey]?.isEmpty == true {
            Self.admission.active.removeValue(forKey: rootKey)
        }
        let waiting = Self.admission.waiting[rootKey]?.removeValue(forKey: id) ?? []
        if Self.admission.waiting[rootKey]?.isEmpty == true { Self.admission.waiting.removeValue(forKey: rootKey) }
        waiting.forEach { $0.resume(returning: true) }
    }

    /// One cross-process transaction before any effects. Existing unreadable
    /// spend state throws rather than resetting the fleet's allowance.
    func reserveDailySpend(tokens: Int, bot: UUID, ceiling: Int, at now: Date = Date()) throws {
        struct Spend: Codable { var day: Int; var tokens: Int }
        try disk.locked {
            let path = disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("daily-spend.json")
            let day = Int(floor(now.timeIntervalSince1970 / 86_400)) // UTC day
            let saved = try disk.read(Spend.self, at: path)
                ?? disk.read(Spend.self, at: disk.root.appendingPathComponent("daily-spend.json"))
            guard saved == nil || (saved!.tokens >= 0) else {
                throw StandingBotsError.corruptStore("daily spend")
            }
            // A backwards wall-clock change must not mint another allowance.
            var spend = saved ?? Spend(day: day, tokens: 0)
            if day > spend.day { spend = Spend(day: day, tokens: 0) }
            guard tokens > 0, tokens <= ceiling - spend.tokens else {
                throw BotRunnerError.dailySpendLimit
            }
            spend.tokens += tokens
            try disk.write(spend, at: path)
        }
    }
}
