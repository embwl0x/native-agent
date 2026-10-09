import Foundation
import Darwin

public struct BotRunReceipt: Sendable, Equatable {
    public let runID: UUID
    public let accepted: Bool
    public let reason: String
}

/// Who asked for a run. A manual Run once is the person asking and stays
/// outside the unattended gates; an event-woken request is unattended provider
/// spend, so the gates are read again where it is actually admitted — a request
/// can wait behind other work, or survive a restart, long after the person
/// turned Autonomy off or paused the bot.
public enum BotRunOrigin: String, Codable, Sendable {
    case manual, event
}

/// Transport identity travels in the same durable request as its event text.
/// A nil source marks a legacy event whose sender was not recorded.
public struct BotEventProvenance: Codable, Equatable, Sendable {
    public let source: BotEventSource?
    public let verifiedChatID: String?
    public let verifiedUserID: String?

    public init(source: BotEventSource?, verifiedChatID: String? = nil, verifiedUserID: String? = nil) {
        self.source = source
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
    }
}

public enum BotRunAdmissionError: String, Error {
    case paused, overBudget = "over_budget", alreadyRunning = "already_running"
}

/// Durable local requests, consumed before work so an interrupted run is never
/// replayed. All runners in this process share admission with tool callers.
public struct BotRunQueue: Sendable {
    public static let didChange = Notification.Name("StandingBots.scheduleDidChange")
    public static let alreadyExecutingWords = "This helper is executing its standing job now. Complete the work and return its result in this turn; do not queue or wait on your own Run control."
    private let disk: StandingBotsDisk
    private let dataRoot: URL
    private var path: URL { disk.root.appendingPathComponent("run-queue.json") }

    /// One queued request. The event text that woke the bot travels ON the
    /// request, in the same write, so it can only ever reach the run that
    /// consumes this request — never a Run once or a scheduled occurrence of the
    /// same bot. Requests written before 0.4.12 were bare run ids and still read.
    struct QueuedRequest: Codable, Equatable {
        var runID: UUID
        var context: String? = nil
        /// Absent on every request written before this. 0.4.12 already wrote
        /// event requests — with the waking text in `context` and no origin —
        /// and reading those as manual would walk them straight past the
        /// unattended gates after an upgrade. Carrying event context IS the
        /// evidence; a bare legacy run id stays manual.
        var origin: BotRunOrigin? = nil
        var provenance: BotEventProvenance? = nil
        var isEvent: Bool { origin.map { $0 == .event } ?? (context?.isEmpty == false) }
    }
    private static let admission = Admission()

    private struct Claim: Codable {
        let requestID: UUID
        let briefVersion: Int
        let admittedAt: Date
        var deadlineExceededAt: Date? = nil
    }

    private func claimRecord(_ id: UUID) -> URL {
        disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run-claim.json")
    }

    /// Called only while holding both the store lock and this bot's writer lock.
    private func reconcileClaim(_ id: UUID, requests: inout [UUID: QueuedRequest]) throws {
        let path = claimRecord(id)
        guard let claim = try disk.read(Claim.self, at: path) else { return }
        let detail = "Helper admission ended without a settled result. Effects are unknown; do not replay the request."
        var entry = ShelfEntry(id: claim.requestID, botId: id, briefVersion: claim.briefVersion,
            runAt: claim.admittedAt, coverageStart: claim.admittedAt, coverageEnd: claim.admittedAt,
            headline: "Interrupted helper request", findings: "", changedSinceLastGood: "",
            uncertainties: [detail], runHealth: .partial, spend: ShelfSpend(tokens: nil, seconds: 0))
        entry.status = .interrupted
        entry.statusDetail = detail
        do { try ShelfStore(dataRoot: dataRoot).appendLocked(entry) }
        catch StandingBotsError.alreadyExists { }
        if requests[id]?.runID == claim.requestID {
            requests.removeValue(forKey: id)
            try disk.write(requests, at: self.path)
        }
        try FileManager.default.removeItem(at: path)
    }

    // Serializes the short disk transaction and process-wide active claims.
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var active: [String: [UUID: Int32]] = [:]
        /// Waiters keyed by their own id so a cancelled one can be REMOVED and
        /// resumed by its cancellation handler. An array could only ever be
        /// drained by `finish`, which is exactly the claim a self-call is
        /// waiting on.
        var waiting: [String: [UUID: [UUID: CheckedContinuation<Bool, Never>]]] = [:]
    }

    /// The bots whose runs are on this task's stack. A bot reached from inside
    /// its own run — `bot_ask(self)`, or a cycle A -> B -> A — would park on a
    /// claim that only its own caller can release, and no deadline could free
    /// it because the wait was not cancellable. Such a claim is refused instead
    /// of parked.
    @TaskLocal public static var ancestry: Set<UUID> = []
    @TaskLocal public static var eventProvenance: BotEventProvenance?
    @TaskLocal public static var eventContext: String?

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        disk = StandingBotsDisk(dataRoot: self.dataRoot)
    }

    private var rootKey: String { dataRoot.resolvingSymlinksInPath().path }

    /// `context` is the event text that woke the bot, if any. It is the run's
    /// input, never an instruction to the app.
    public func enqueue(bot id: UUID, context: String? = nil,
                        origin: BotRunOrigin = .manual,
                        provenance: BotEventProvenance? = nil) throws -> BotRunReceipt {
        guard !Self.ancestry.contains(id) else {
            throw StandingBotsError.invalidValue(Self.alreadyExecutingWords)
        }
        let receipt: BotRunReceipt
        do {
            Self.admission.lock.lock()
            defer { Self.admission.lock.unlock() }
            receipt = try disk.locked {
                let bot = try disk.definition(id).definition
                guard bot.deleted != true else { throw StandingBotsError.notFound(id) }
                var requests = try readRequests()
                if origin == .manual, Self.admission.active[rootKey]?[id] != nil {
                    guard let claim = try disk.read(Claim.self, at: claimRecord(id)) else {
                        throw StandingBotsError.corruptStore("exact bot run claim unavailable")
                    }
                    return BotRunReceipt(runID: claim.requestID, accepted: false, reason: BotRunAdmissionError.alreadyRunning.rawValue)
                }
                if let existing = requests[id] {
                    return BotRunReceipt(runID: existing.runID, accepted: false, reason: BotRunAdmissionError.alreadyRunning.rawValue)
                }
                let runID = UUID()
                let text = (context?.isEmpty ?? true) ? nil : context
                requests[id] = QueuedRequest(runID: runID, context: text, origin: origin, provenance: provenance)
                try disk.write(requests, at: path)
                return BotRunReceipt(runID: runID, accepted: true, reason: "queued")
            }
        }
        if receipt.accepted { NotificationCenter.default.post(name: Self.didChange, object: dataRoot) }
        return receipt
    }

    /// Inside the store lock. Pre-0.4.12 requests decode as a bare run id and
    /// are rewritten in the new shape by the next write.
    private func readRequests() throws -> [UUID: QueuedRequest] {
        if let records = (try? disk.read([UUID: QueuedRequest].self, at: path)) ?? nil { return records }
        let legacy = try disk.read([UUID: UUID].self, at: path) ?? [:]
        return legacy.mapValues { QueuedRequest(runID: $0) }
    }

    func pending() throws -> [UUID: QueuedRequest] {
        try disk.locked {
            var requests = try readRequests()
            for directory in try disk.files(at: disk.root, extension: "") {
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      try disk.bytes(at: claimRecord(id)) != nil else { continue }
                let lock = directory.appendingPathComponent("run.lock")
                try disk.validatePath(lock)
                let fd = open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw StandingBotsError.corruptStore("bot run claim unavailable") }
                defer { close(fd) }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { try reconcileClaim(id, requests: &requests) }
                else if errno != EWOULDBLOCK { throw StandingBotsError.corruptStore("bot run claim unavailable") }
            }
            return requests
        }
    }

    public func activeOrQueuedIDs(locked: Bool = true) throws -> Set<UUID> {
        let ids = try activeAndQueuedIDs(locked: locked)
        return ids.active.union(ids.queued)
    }

    public func activeAndQueuedIDs(locked: Bool = true) throws -> (active: Set<UUID>, queued: Set<UUID>) {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        // Unlocked: a read-only look at the queue file for a glance that must not wait.
        let queued = locked ? try pending() : try readRequests()
        return (Set(Self.admission.active[rootKey]?.keys.map { $0 } ?? []), Set(queued.keys))
    }

    public enum RequestPresence: Sendable { case queued, running, deadlineExceeded, absent }

    func markDeadlineExceeded(bot id: UUID, requestID: UUID) throws {
        try disk.locked {
            guard var claim = try disk.read(Claim.self, at: claimRecord(id)), claim.requestID == requestID else {
                throw StandingBotsError.corruptStore("exact bot run claim unavailable")
            }
            claim.deadlineExceededAt = Date()
            try disk.write(claim, at: claimRecord(id))
        }
        NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
    }

    /// Exact queue correlation, plus a conservative live-claim check. A live
    /// writer may be settling the requested shelf row; absence is definitive
    /// only once neither the exact queue entry nor any bot writer owns it.
    /// This never starts, consumes or retries a run.
    public func presence(bot id: UUID, requestID: UUID) throws -> RequestPresence {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try readRequests()
            let claim = disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run.lock")
            try disk.validatePath(claim)
            let fd = open(claim.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 {
                if errno == ENOENT { return requests[id]?.runID == requestID ? .queued : .absent }
                throw StandingBotsError.corruptStore("bot run claim unavailable")
            }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try reconcileClaim(id, requests: &requests)
                return requests[id]?.runID == requestID ? .queued : .absent
            }
            if errno == EWOULDBLOCK {
                if let saved = try disk.read(Claim.self, at: claimRecord(id)), saved.requestID == requestID {
                    return saved.deadlineExceededAt == nil ? .running : .deadlineExceeded
                }
                return requests[id]?.runID == requestID ? .queued : .absent
            }
            throw StandingBotsError.corruptStore("bot run claim unavailable")
        }
    }

    func rejectPending(bot: UUID, requestID: UUID) throws {
        try disk.locked {
            var requests = try readRequests()
            if requests[bot]?.runID == requestID {
                // The event text is part of the request, so it goes with it.
                requests.removeValue(forKey: bot)
                try disk.write(requests, at: path)
            }
        }
    }

    /// The claimed definition and the event text the claimed request carried.
    struct ClaimedRun {
        let runID: UUID
        let bot: BotDefinition
        let context: String?
        let provenance: BotEventProvenance?
    }

    func claim(bot id: UUID, requestID: UUID?, manual: Bool = false) throws -> ClaimedRun {
        try admit(bot: id, runID: requestID, manual: manual)
    }

    func claimWhenAvailable(bot id: UUID, requestID: UUID?, manual: Bool = false) async throws -> ClaimedRun {
        // Waiting on a run this task is already inside can only ever time out.
        guard !Self.ancestry.contains(id) else { throw BotRunAdmissionError.alreadyRunning }
        while true {
            try Task.checkCancellation()
            do { return try claim(bot: id, requestID: requestID, manual: manual) }
            catch BotRunAdmissionError.alreadyRunning {
                // Register under the same lock as finish; no missed wakeup and
                // no polling timer. External processes still fail closed at flock.
                let waiterID = UUID()
                let waited = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        Self.admission.lock.lock()
                        if !Task.isCancelled, Self.admission.active[rootKey]?[id] != nil {
                            Self.admission.waiting[rootKey, default: [:]][id, default: [:]][waiterID] = continuation
                            Self.admission.lock.unlock()
                        } else {
                            Self.admission.lock.unlock()
                            continuation.resume(returning: false)
                        }
                    }
                } onCancel: {
                    // The deadline's only way out: take this waiter off the
                    // list and resume it, since `finish` may never run.
                    Self.admission.lock.lock()
                    let continuation = Self.admission.waiting[rootKey]?[id]?.removeValue(forKey: waiterID)
                    Self.admission.lock.unlock()
                    continuation?.resume(returning: false)
                }
                if !waited {
                    try Task.checkCancellation()
                    return try claim(bot: id, requestID: requestID, manual: manual)
                }
            }
        }
    }

    func configuredBudget(bot id: UUID) throws -> BotBudget {
        try disk.locked { try disk.definition(id).definition.budget }
    }

    private func admit(bot id: UUID, runID: UUID?, manual: Bool = false) throws -> ClaimedRun {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try readRequests()
            guard Self.admission.active[rootKey]?[id] == nil,
                  requests[id] == nil || manual || requests[id]?.runID == runID else {
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
            try reconcileClaim(id, requests: &requests)
            let bot = try disk.definition(id).definition
            // Claiming a queued request consumes it even if settings now reject
            // it. A budget edit must not leave a request to replay later.
            var context: String? = nil
            var provenance: BotEventProvenance? = nil
            if let runID, requests[id]?.runID != runID { throw BotRunAdmissionError.alreadyRunning }
            let admittedID = runID ?? UUID()
            try disk.write(Claim(requestID: admittedID, briefVersion: bot.briefVersion, admittedAt: Date()),
                           at: claimRecord(id))
            if let runID {
                // Consumed with the request: the text reaches this run only.
                let request = requests.removeValue(forKey: id)
                context = request?.context
                if request?.isEvent == true {
                    provenance = request?.provenance ?? BotEventProvenance(source: nil)
                }
                try disk.write(requests, at: path)
            }
            // A queued deliberate check is independent of scheduled checks.
            guard !bot.paused || runID != nil || manual else { throw BotRunAdmissionError.paused }
            guard bot.deleted != true else { throw StandingBotsError.notFound(id) }
            let metadata = Data("\(getpid()) \(Date().timeIntervalSince1970)\n".utf8)
            guard ftruncate(descriptor, 0) == 0,
                  metadata.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == metadata.count else {
                throw StandingBotsError.corruptStore("bot run claim metadata unavailable")
            }
            Self.admission.active[rootKey, default: [:]][id] = descriptor
            retained = true
            return ClaimedRun(runID: admittedID, bot: bot, context: context, provenance: provenance)
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
        let waiting = Self.admission.waiting[rootKey]?.removeValue(forKey: id) ?? [:]
        if Self.admission.waiting[rootKey]?.isEmpty == true { Self.admission.waiting.removeValue(forKey: rootKey) }
        waiting.values.forEach { $0.resume(returning: true) }
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
