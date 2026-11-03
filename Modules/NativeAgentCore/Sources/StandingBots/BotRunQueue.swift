import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `BotRunQueue.swift` | `BotRunQueue` owns durable requests, exact pre-execution refusals and writer claims; claim/refusal commits before queue removal; `enqueue`, `presence`, `refusal`; only per-helper daily reservations |

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
/// A nil source marks an event whose sender was not recorded.
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
    case paused, alreadyRunning = "already_running"
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
    /// consumes this request — never a Run once or a scheduled occurrence of the same bot.
    struct QueuedRequest: Codable, Equatable {
        var runID: UUID
        var context: String? = nil
        var origin: BotRunOrigin
        var provenance: BotEventProvenance? = nil
        var isEvent: Bool { origin == .event }
    }
    private static let admission = Admission()

    private struct Claim: Codable {
        let requestID: UUID
        let briefVersion: Int
        let admittedAt: Date
        var deadlineExceededAt: Date? = nil
        var executionAdmittedAt: Date? = nil
    }

    private func claimRecord(_ id: UUID) -> URL {
        disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run-claim.json")
    }

    /// Called only while holding both the store lock and this bot's writer lock.
    private func reconcileClaim(_ id: UUID, requests: inout [UUID: QueuedRequest]) throws {
        let path = claimRecord(id)
        guard let claim = try disk.read(Claim.self, at: path) else { return }
        if try refusalUnlocked(bot: id, requestID: claim.requestID) != nil {
            try FileManager.default.removeItem(at: path)
            return
        }
        let shelf = ShelfStore(dataRoot: dataRoot)
        let settled = try shelf.rawEntryLocked(claim.requestID)
        if let settled, settled.botId != id { throw StandingBotsError.corruptStore("helper claim/result identity") }
        guard settled != nil || claim.executionAdmittedAt != nil else {
            throw StandingBotsError.corruptStore("Helper request \(claim.requestID) lost its pre-execution admission outcome. Restore its refusal or execution evidence; no interrupted run was invented and nothing was replayed.")
        }
        let detail = "Helper admission ended without a settled result. Effects are unknown; do not replay the request."
        var entry = ShelfEntry(id: claim.requestID, botId: id, briefVersion: claim.briefVersion,
            runAt: claim.admittedAt, coverageStart: claim.admittedAt, coverageEnd: claim.admittedAt,
            headline: "Interrupted helper request", findings: "", changedSinceLastGood: "",
            uncertainties: [detail], runHealth: .partial, spend: ShelfSpend(tokens: nil, seconds: 0))
        entry.status = .interrupted
        entry.statusDetail = detail
        if settled == nil { try shelf.appendLocked(entry) }
        if requests[id]?.runID == claim.requestID {
            requests.removeValue(forKey: id)
            try disk.write(requests, at: self.path)
        }
        try FileManager.default.removeItem(at: path)
    }

    // Serializes the short disk transaction and process-wide active claims.
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var active: [String: [UUID: (descriptor: Int32, done: ScopedWaiter)]] = [:]
    }

    /// The bots whose runs are on this task's stack. Self-calls are refused
    /// before admission; a nested call finding its target busy cannot wait.
    /// This also prevents independently admitted runs from waiting on each
    /// other when neither target appears in its caller's ancestry.
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

    /// Inside the store lock. Present bytes must be the current request map.
    private func readRequests() throws -> [UUID: QueuedRequest] {
        let saved = try disk.read([UUID: QueuedRequest].self, at: path) ?? [:]
        // A refusal commits before queue removal. A crash between those writes
        // must not leave positively refused work executable again.
        return try saved.filter { try refusalUnlocked(bot: $0.key, requestID: $0.value.runID) == nil }
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

    func admitExecution(bot id: UUID, requestID: UUID) throws {
        try disk.locked {
            guard var claim = try disk.read(Claim.self, at: claimRecord(id)), claim.requestID == requestID else {
                throw StandingBotsError.corruptStore("exact helper execution claim unavailable")
            }
            claim.executionAdmittedAt = Date()
            try disk.write(claim, at: claimRecord(id))
        }
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

    func rejectPending(bot: UUID, requestID: UUID, detail: String) throws {
        try disk.locked {
            var requests = try readRequests()
            if requests[bot]?.runID == requestID {
                try recordRefusal(bot: bot, requestID: requestID, detail: detail)
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
        let run = try admit(bot: id, runID: requestID, manual: manual)
        NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
        return run
    }

    func claimWhenAvailable(bot id: UUID, requestID: UUID?, manual: Bool = false) async throws -> ClaimedRun {
        // Waiting on a run this task is already inside can only ever time out.
        guard !Self.ancestry.contains(id) else { throw BotRunAdmissionError.alreadyRunning }
        while true {
            try Task.checkCancellation()
            do { return try claim(bot: id, requestID: requestID, manual: manual) }
            catch BotRunAdmissionError.alreadyRunning {
                guard Self.ancestry.isEmpty else {
                    throw StandingBotsError.invalidValue("This helper is already running. A running helper cannot wait for another active helper; continue without waiting.")
                }
                // Select the execution under admission; finish may resolve it before parking.
                guard let waiter = Self.admission.lock.withLock({ Self.admission.active[rootKey]?[id]?.done }) else {
                    try Task.checkCancellation()
                    return try claim(bot: id, requestID: requestID, manual: manual)
                }
                await waiter.park()
            }
        }
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
            if runID != nil {
                // Read its input now; retain the durable request until its
                // successor claim (or refusal) has committed.
                let request = requests[id]
                context = request?.context
                if request?.isEvent == true {
                    provenance = request?.provenance ?? BotEventProvenance(source: nil)
                }
            }
            // A queued deliberate check is independent of scheduled checks.
            guard !bot.paused || runID != nil || manual else { throw BotRunAdmissionError.paused }
            guard bot.deleted != true else {
                try recordRefusal(bot: id, requestID: admittedID, detail: "The helper was deleted before execution. No helper turn ran.")
                if runID != nil {
                    requests.removeValue(forKey: id)
                    try disk.write(requests, at: path)
                }
                throw StandingBotsError.notFound(id)
            }
            let metadata = Data("\(getpid()) \(Date().timeIntervalSince1970)\n".utf8)
            guard ftruncate(descriptor, 0) == 0,
                  metadata.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == metadata.count else {
                throw StandingBotsError.corruptStore("bot run claim metadata unavailable")
            }
            try disk.write(Claim(requestID: admittedID, briefVersion: bot.briefVersion, admittedAt: Date()),
                           at: claimRecord(id))
            if runID != nil {
                // A failed claim write leaves the request queued. A crash or
                // queue-write failure after it leaves the exact claim for
                // reconciliation; missing settlement never authorizes replay.
                requests.removeValue(forKey: id)
                try disk.write(requests, at: path)
            }
            Self.admission.active[rootKey, default: [:]][id] = (descriptor, ScopedWaiter())
            retained = true
            return ClaimedRun(runID: admittedID, bot: bot, context: context, provenance: provenance)
        }
    }

    /// A positively refused pre-execution request has no unknown effects to
    /// reconcile. Keep the writer lock until this exact claim is retired.
    func retireUnstartedClaim(bot id: UUID, requestID: UUID, detail: String) throws {
        try disk.locked {
            guard let claim = try disk.read(Claim.self, at: claimRecord(id)), claim.requestID == requestID else {
                throw StandingBotsError.corruptStore("exact refused helper claim unavailable: \(requestID)")
            }
            try recordRefusal(bot: id, requestID: requestID, detail: detail)
            try FileManager.default.removeItem(at: claimRecord(id))
        }
    }

    private struct Refusal: Codable { let botID: UUID; let requestID: UUID; let detail: String }
    private func refusalPath(bot: UUID, requestID: UUID) -> URL {
        disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("refused")
            .appendingPathComponent(requestID.uuidString + ".json")
    }
    private func recordRefusal(bot: UUID, requestID: UUID, detail: String) throws {
        try disk.write(Refusal(botID: bot, requestID: requestID, detail: detail), at: refusalPath(bot: bot, requestID: requestID))
    }
    private func refusalUnlocked(bot: UUID, requestID: UUID) throws -> String? {
        guard let row = try disk.read(Refusal.self, at: refusalPath(bot: bot, requestID: requestID)) else { return nil }
        guard row.botID == bot, row.requestID == requestID else { throw StandingBotsError.corruptStore("refused helper request identity") }
        return row.detail
    }
    /// Positive pre-execution settlement, separate from execution history.
    /// Missing evidence says nothing about whether the request ran.
    public func refusal(bot: UUID, requestID: UUID) throws -> String? {
        try disk.locked { try refusalUnlocked(bot: bot, requestID: requestID) }
    }

    func finish(bot id: UUID) {
        Self.admission.lock.lock()
        defer {
            Self.admission.lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
        }
        let execution = Self.admission.active[rootKey]?.removeValue(forKey: id)
        if let execution { close(execution.descriptor) }
        if Self.admission.active[rootKey]?.isEmpty == true {
            Self.admission.active.removeValue(forKey: rootKey)
        }
        execution?.done.resume()
    }

    /// One cross-process transaction before any effects. Existing unreadable
    /// spend state throws rather than resetting this helper's allowance.
    func reserveDailySpend(tokens: Int, bot: UUID, ceiling: Int, at now: Date = Date()) throws {
        struct Spend: Codable { var day: Int; var tokens: Int }
        try disk.locked {
            let path = disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("daily-spend.json")
            let day = Int(floor(now.timeIntervalSince1970 / 86_400)) // UTC day
            let saved = try disk.read(Spend.self, at: path)
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
